/*
 * OCGatewayServer.m
 * LegacyPodClaw - Native Gateway Server Implementation
 *
 * Complete gateway: HTTP server + WebSocket protocol v3 + agent execution
 * + session persistence + event broadcasting + cron. Chat channels run in the app.
 *
 * Memory budget: ~20MB for the gateway subsystem on 256MB device.
 */

#import "GatewayServer.h"
#import "ToolDispatcher.h"
#import "ProviderRegistry.h"
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>
#import <notify.h>

static const NSInteger kProtocolVersion = 3;
static const NSTimeInterval kDefaultTickInterval = 30.0;
static const NSUInteger kMaxWSMessageSize = 256 * 1024;
static const NSTimeInterval kWSAuthDeadline = 10.0;

static NSString *GWString(NSDictionary *dict, NSString *key) {
    id v = [dict isKindOfClass:[NSDictionary class]] ? [dict objectForKey:key] : nil;
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static NSDictionary *GWDict(NSDictionary *dict, NSString *key) {
    id v = [dict isKindOfClass:[NSDictionary class]] ? [dict objectForKey:key] : nil;
    return [v isKindOfClass:[NSDictionary class]] ? v : nil;
}

static NSUInteger GWLimit(id value, NSUInteger fallback) {
    if (![value respondsToSelector:@selector(integerValue)]) return fallback;
    NSInteger n = [value integerValue];
    return (n > 0 && n <= 1000) ? (NSUInteger)n : fallback;
}

/* Base64 encoder (iOS 6 compat) */
static NSString *GWBase64Encode(NSData *data) {
    static const char t[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const uint8_t *in = [data bytes];
    NSUInteger len = [data length];
    NSMutableString *r = [NSMutableString stringWithCapacity:((len + 2) / 3) * 4];
    for (NSUInteger i = 0; i < len; i += 3) {
        uint32_t v = (uint32_t)in[i] << 16;
        if (i + 1 < len) v |= (uint32_t)in[i + 1] << 8;
        if (i + 2 < len) v |= (uint32_t)in[i + 2];
        [r appendFormat:@"%c%c%c%c", t[(v>>18)&0x3F], t[(v>>12)&0x3F],
         (i+1<len)?t[(v>>6)&0x3F]:'=', (i+2<len)?t[v&0x3F]:'='];
    }
    return r;
}

static NSString *GWGenerateUUID(void) {
    CFUUIDRef uuid = CFUUIDCreate(kCFAllocatorDefault);
    NSString *str = (NSString *)CFUUIDCreateString(kCFAllocatorDefault, uuid);
    CFRelease(uuid);
    return [str autorelease];
}

#pragma mark - Config

@implementation OCGatewayConfig
- (instancetype)init {
    if ((self = [super init])) {
        _port = 18789;
        _bindAddress = [@"0.0.0.0" copy];
        _maxConnections = 8;
        _tickInterval = kDefaultTickInterval;
        _defaultProviderId = [@"anthropic" copy];
        _defaultModelId = [OCDefaultModelId copy];
    }
    return self;
}
- (void)dealloc {
    [_bindAddress release]; [_dataDirectory release]; [_defaultModelId release];
    [_defaultApiKey release]; [_defaultBaseURL release]; [_defaultProviderId release];
    [super dealloc];
}
@end

#pragma mark - WS Client

@implementation OCGatewayWSClient
- (instancetype)init {
    if ((self = [super init])) {
        _connectionId = [GWGenerateUUID() copy];
        _connectedAt = [[NSDate date] retain];
        _subscribedSessions = [[NSMutableSet alloc] init];
    }
    return self;
}
- (void)dealloc {
    [_connectionId release]; [_clientId release]; [_displayName release];
    [_platform release]; [_role release]; [_scopes release];
    [_connectedAt release]; [_webSocket release]; [_subscribedSessions release];
    [super dealloc];
}
- (void)sendJSON:(NSDictionary *)json {
    // dataWithJSONObject throws on non-json values, which would take the app down
    if (![NSJSONSerialization isValidJSONObject:json]) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    if (!data) return;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [_webSocket sendText:text];
    [text release];
}
- (void)sendEvent:(NSString *)event payload:(id)payload {
    [self sendJSON:@{
        @"type": @"event",
        @"event": event,
        @"payload": payload ?: [NSNull null]
    }];
}
@end

#pragma mark - Session Entry

@implementation OCGatewaySessionEntry
- (instancetype)init {
    if ((self = [super init])) {
        _status = [@"active" copy];
        _startedAt = [[NSDate date] retain];
        _updatedAt = [[NSDate date] retain];
    }
    return self;
}
- (void)dealloc {
    [_sessionKey release]; [_displayName release]; [_status release];
    [_model release]; [_startedAt release]; [_updatedAt release];
    [_lastChannel release];
    [super dealloc];
}
- (NSDictionary *)toDictionary {
    return @{
        @"key": _sessionKey ?: @"",
        @"displayName": _displayName ?: @"",
        @"status": _status ?: @"active",
        @"model": _model ?: @"",
        @"totalTokens": @(_totalTokens),
        @"startedAt": @([_startedAt timeIntervalSince1970] * 1000),
        @"updatedAt": @([_updatedAt timeIntervalSince1970] * 1000)
    };
}
@end

#pragma mark - Cron Job

@implementation OCCronJob
- (void)dealloc {
    [_jobId release]; [_name release]; [_schedule release];
    [_action release]; [_sessionKey release]; [_text release];
    [_lastRunAt release]; [_nextRunAt release];
    [super dealloc];
}
@end

#pragma mark - Gateway Server

@interface OCGatewayServer () {
    OCHTTPServer *_httpServer;
    OCStore *_store;
    OCKeyValueStore *_kvStore;
    NSMutableArray *_tools;

    NSMutableDictionary *_clients;        // connId -> OCGatewayWSClient
    NSMutableDictionary *_sessionEntries;  // key -> OCGatewaySessionEntry
    NSMutableDictionary *_sessionHistory;  // key -> NSMutableArray of message dicts
    NSMutableArray *_cronJobs;
    NSMutableDictionary *_activeRuns;      // runId -> {sessionKey, runId, agent}

    NSTimer *_tickTimer;
    NSTimer *_cronTimer;
    NSDate *_startedAt;
    NSUInteger _seqCounter;
}
@end

@implementation OCGatewayServer

- (instancetype)initWithConfig:(OCGatewayConfig *)config {
    if ((self = [super init])) {
        _config = [config retain];
        _clients = [[NSMutableDictionary alloc] initWithCapacity:8];
        _sessionEntries = [[NSMutableDictionary alloc] initWithCapacity:16];
        _sessionHistory = [[NSMutableDictionary alloc] initWithCapacity:16];
        _cronJobs = [[NSMutableArray alloc] initWithCapacity:4];
        _activeRuns = [[NSMutableDictionary alloc] initWithCapacity:4];
        _tools = [[NSMutableArray alloc] initWithArray:[OCBuiltinTools deviceTools]];
        _seqCounter = 0;
    }
    return self;
}

- (void)dealloc {
    /* no notification here: a block that captured self would outlive the object */
    [self _shutdownNotifying:NO];
    [_config release]; [_clients release]; [_sessionEntries release];
    [_sessionHistory release]; [_cronJobs release]; [_activeRuns release];
    [_tools release]; [_webhookHandler release];
    [super dealloc];
}

#pragma mark - Lifecycle

- (BOOL)start:(NSError **)error {
    if (_isRunning) return YES;

    // without a token every request would be refused, so refuse to start instead
    if (![OCGatewayToken currentToken]) {
        if (error) *error = [NSError errorWithDomain:@"OCGatewayServer" code:-10
            userInfo:@{NSLocalizedDescriptionKey: @"Could not create the gateway access token"}];
        return NO;
    }

    /* Ensure data directory */
    NSString *dataDir = _config.dataDirectory;
    if (!dataDir) {
        dataDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0]
                   stringByAppendingPathComponent:@"openclaw-gw"];
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:dataDir
                              withIntermediateDirectories:YES attributes:nil error:nil];

    /* Initialize store */
    NSString *dbPath = [dataDir stringByAppendingPathComponent:@"gateway.db"];
    _store = [[OCStore alloc] initWithPath:dbPath];
    if (![_store open:error]) {
        [_store release]; _store = nil;
        return NO;
    }

    [self _setupSchema];

    _kvStore = [[OCKeyValueStore alloc] initWithStore:_store tableName:@"gw_config"];
    [_kvStore setup:nil];

    /* Load persisted sessions */
    [self _loadSessions];

    /* Start HTTP server */
    _httpServer = [[OCHTTPServer alloc] init];
    /* tool calls may wait up to 60 s for the user to approve them on the device */
    _httpServer.handlerTimeout = 75.0;
    _httpServer.delegate = self;
    _httpServer.port = _config.port;
    _httpServer.bindAddress = _config.bindAddress;
    _httpServer.maxConnections = _config.maxConnections + 8; /* Extra for HTTP */
    _httpServer.authorizer = ^BOOL(OCHTTPRequest *req) {
        return [OCGatewayToken isValidToken:[req bearerToken]];
    };

    [self _registerHTTPRoutes];
    __unsafe_unretained OCGatewayServer *upgradeSelf = self;
    [_httpServer onWebSocketUpgrade:^(OCHTTPRequest *request,
                                       NSInputStream *input,
                                       NSOutputStream *output,
                                       NSData *pendingData) {
        [upgradeSelf _handleWSUpgrade:request input:input output:output pendingData:pendingData];
    }];

    if (![_httpServer start:error]) {
        [self _releaseResources];
        return NO;
    }

    /* Start tick timer */
    _tickTimer = [NSTimer scheduledTimerWithTimeInterval:_config.tickInterval
                                                  target:self
                                                selector:@selector(_sendTicks)
                                                userInfo:nil
                                                 repeats:YES];

    /* Start cron timer (check every 60s) */
    _cronTimer = [NSTimer scheduledTimerWithTimeInterval:60.0
                                                  target:self
                                                selector:@selector(_checkCron)
                                                userInfo:nil
                                                 repeats:YES];

    _startedAt = [[NSDate date] retain];
    _isRunning = YES;

    NSLog(@"[LegacyPodClaw Gateway] Started on port %d", _config.port);

    dispatch_async(dispatch_get_main_queue(), ^{
        if ([_delegate respondsToSelector:@selector(gatewayServerDidStart:)]) {
            [_delegate gatewayServerDidStart:self];
        }
    });

    return YES;
}

- (void)stop {
    [self _shutdownNotifying:YES];
}

- (void)_releaseResources {
    _httpServer.delegate = nil;
    [_httpServer release]; _httpServer = nil;
    [_store close];
    [_kvStore release]; _kvStore = nil;
    [_store release]; _store = nil;
    [_startedAt release]; _startedAt = nil;
    [_sessionEntries removeAllObjects];
    [_sessionHistory removeAllObjects];
}

- (void)_shutdownNotifying:(BOOL)notify {
    if (!_isRunning) return;

    [_tickTimer invalidate]; _tickTimer = nil;
    [_cronTimer invalidate]; _cronTimer = nil;
    [_httpServer stop];

    /* Disconnect all clients */
    for (OCGatewayWSClient *client in [_clients allValues]) {
        client.webSocket.delegate = nil;
        if (client.authenticated) [client sendEvent:@"shutdown" payload:@{@"reason": @"server_stopping"}];
        [client.webSocket closeWithCode:1001 reason:@"server stopping"];
    }
    [_clients removeAllObjects];

    for (NSDictionary *run in [_activeRuns allValues]) {
        OCAgent *agent = [run objectForKey:@"agent"];
        agent.delegate = nil;
        [agent abort];
    }
    [_activeRuns removeAllObjects];

    [self _persistSessions];
    [self _releaseResources];
    _isRunning = NO;

    if (!notify) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([_delegate respondsToSelector:@selector(gatewayServerDidStop:)]) {
            [_delegate gatewayServerDidStop:self];
        }
    });
}

#pragma mark - HTTP Routes

- (void)_registerHTTPRoutes {
    __unsafe_unretained OCGatewayServer *weakSelf = self;

    // liveness only: no body, so an unauthenticated scan learns nothing beyond the open port
    [_httpServer publicGet:@"/healthz" handler:^(OCHTTPRequest *req, void(^respond)(OCHTTPResponse *)) {
        respond([OCHTTPResponse responseWithStatus:204]);
    }];

    [_httpServer get:@"/health" handler:^(OCHTTPRequest *req, void(^respond)(OCHTTPResponse *)) {
        if (![weakSelf _authHTTP:req respond:respond]) return;
        respond([OCHTTPResponse jsonResponse:[weakSelf healthStatus]]);
    }];

    /* Sessions HTTP API */
    [_httpServer get:@"/api/sessions" handler:^(OCHTTPRequest *req, void(^respond)(OCHTTPResponse *)) {
        if (![weakSelf _authHTTP:req respond:respond]) return;
        NSMutableArray *list = [NSMutableArray array];
        for (OCGatewaySessionEntry *s in [weakSelf->_sessionEntries allValues]) {
            [list addObject:[s toDictionary]];
        }
        respond([OCHTTPResponse jsonResponse:@{@"sessions": list}]);
    }];

    [_httpServer get:@"/api/sessions/*" handler:^(OCHTTPRequest *req, void(^respond)(OCHTTPResponse *)) {
        if (![weakSelf _authHTTP:req respond:respond]) return;
        /* Extract session key from path: /api/sessions/{key}/history */
        NSArray *parts = [req.path componentsSeparatedByString:@"/"];
        NSString *key = [parts count] >= 4 ? [parts objectAtIndex:3] : nil;
        if ([key length] == 0 || [key length] > 128) {
            respond([OCHTTPResponse errorResponse:400 message:@"Invalid session path"]);
            return;
        }
        NSUInteger limit = GWLimit([[req queryParams] objectForKey:@"limit"], 100);
        NSArray *msgs = [weakSelf historyForSession:key limit:limit];
        respond([OCHTTPResponse jsonResponse:@{@"sessionKey": key, @"messages": msgs ?: @[]}]);
    }];

    /* Tool invoke */
    [_httpServer post:@"/tools/invoke" handler:^(OCHTTPRequest *req, void(^respond)(OCHTTPResponse *)) {
        if (![weakSelf _authHTTP:req respond:respond]) return;
        NSDictionary *body = [req jsonBody];
        NSString *toolName = GWString(body, @"tool");
        id rawArgs = [body objectForKey:@"args"];
        if (rawArgs && ![rawArgs isKindOfClass:[NSDictionary class]]) {
            respond([OCHTTPResponse errorResponse:400 message:@"'args' must be an object"]);
            return;
        }
        NSDictionary *args = rawArgs ?: @{};

        if (!toolName) {
            respond([OCHTTPResponse errorResponse:400 message:@"Missing 'tool' parameter"]);
            return;
        }

        OCToolDefinition *tool = [OCToolDispatcher toolNamed:toolName inTools:weakSelf->_tools];
        if (!tool || !tool.handler) {
            respond([OCHTTPResponse errorResponse:404 message:@"Tool not found"]);
            return;
        }

        /* remote callers pass through the same schema checks and user prompt as local ones */
        [[OCToolDispatcher shared] runTool:tool input:args caller:OCToolCallerRemote
                                completion:^(NSString *result, NSError *error) {
            if (error) {
                respond([OCHTTPResponse jsonResponse:@{@"ok": @NO, @"error": [error localizedDescription] ?: @""}]);
            } else {
                respond([OCHTTPResponse jsonResponse:@{@"ok": @YES, @"output": result ?: @""}]);
            }
        }];
    }];

    [_httpServer post:@"/webhook/incoming" handler:^(OCHTTPRequest *req, void(^respond)(OCHTTPResponse *)) {
        if (![weakSelf _authHTTP:req respond:respond]) return;
        NSString *(^handler)(NSDictionary *) = weakSelf.webhookHandler;
        if (!handler) {
            respond([OCHTTPResponse errorResponse:404 message:@"The webhook channel is not enabled"]);
            return;
        }
        NSString *problem = handler([req jsonBody]);
        respond(problem ? [OCHTTPResponse errorResponse:400 message:problem]
                        : [OCHTTPResponse jsonResponse:@{@"ok": @YES, @"queued": @YES}]);
    }];

    /* Cron API */
    [_httpServer get:@"/api/cron" handler:^(OCHTTPRequest *req, void(^respond)(OCHTTPResponse *)) {
        if (![weakSelf _authHTTP:req respond:respond]) return;
        NSMutableArray *jobs = [NSMutableArray array];
        for (OCCronJob *j in weakSelf->_cronJobs) {
            [jobs addObject:@{
                @"id": j.jobId ?: @"",
                @"name": j.name ?: @"",
                @"schedule": j.schedule ?: @"",
                @"enabled": @(j.enabled),
                @"sessionKey": j.sessionKey ?: @""
            }];
        }
        respond([OCHTTPResponse jsonResponse:@{@"jobs": jobs}]);
    }];
}

- (BOOL)_authHTTP:(OCHTTPRequest *)req respond:(void(^)(OCHTTPResponse *))respond {
    // the http layer enforces this already; repeating it guards against a route registered as public by mistake
    if (req.authorized) return YES;
    OCHTTPResponse *resp = [OCHTTPResponse errorResponse:401 message:@"Unauthorized"];
    [resp.headers setObject:@"Bearer" forKey:@"WWW-Authenticate"];
    respond(resp);
    return NO;
}

#pragma mark - Access Token

- (NSString *)accessToken {
    return [OCGatewayToken currentToken];
}

- (NSString *)regenerateAccessToken {
    NSString *token = [OCGatewayToken regenerateToken];
    if (!token) return nil;
    for (OCGatewayWSClient *client in [_clients allValues]) {
        [client.webSocket closeWithCode:1008 reason:@"token changed"];
    }
    return token;
}

#pragma mark - WebSocket Upgrade & Protocol

static NSData *GWHTTPError(NSInteger status, NSString *text) {
    NSString *s = [NSString stringWithFormat:
        @"HTTP/1.1 %ld %@\r\nConnection: close\r\nContent-Length: 0\r\n\r\n", (long)status, text];
    return [s dataUsingEncoding:NSUTF8StringEncoding];
}

- (void)_handleWSUpgrade:(OCHTTPRequest *)request
                   input:(NSInputStream *)input
                  output:(NSOutputStream *)output
             pendingData:(NSData *)pendingData {

    OCServerWebSocket *ws = [[[OCServerWebSocket alloc] initWithInputStream:input
                                                               outputStream:output
                                                                pendingData:pendingData] autorelease];
    ws.maxMessageSize = kMaxWSMessageSize;

    NSString *wsKey = [request headerValue:@"Sec-WebSocket-Key"];
    NSString *wsVersion = [request headerValue:@"Sec-WebSocket-Version"];
    if ([wsKey length] == 0 || [wsKey length] > 64 || ![wsVersion isEqualToString:@"13"]) {
        [ws rejectWithResponse:GWHTTPError(400, @"Bad Request")];
        return;
    }
    if ([_clients count] >= MAX(_config.maxConnections, (NSUInteger)1)) {
        [ws rejectWithResponse:GWHTTPError(503, @"Service Unavailable")];
        return;
    }

    /* Compute accept key */
    NSString *guid = @"258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    NSString *acceptSource = [NSString stringWithFormat:@"%@%@", wsKey, guid];
    NSData *acceptData = [acceptSource dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t sha1[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1([acceptData bytes], (CC_LONG)[acceptData length], sha1);
    NSData *sha1Data = [NSData dataWithBytes:sha1 length:CC_SHA1_DIGEST_LENGTH];
    NSString *acceptKey = GWBase64Encode(sha1Data);

    NSString *response = [NSString stringWithFormat:
        @"HTTP/1.1 101 Switching Protocols\r\n"
        @"Upgrade: websocket\r\n"
        @"Connection: Upgrade\r\n"
        @"Sec-WebSocket-Accept: %@\r\n"
        @"\r\n", acceptKey];

    OCGatewayWSClient *client = [[[OCGatewayWSClient alloc] init] autorelease];
    client.webSocket = ws;
    client.tokenVerified = request.authorized;
    ws.delegate = self;
    [_clients setObject:client forKey:client.connectionId];

    [ws startWithHandshakeResponse:[response dataUsingEncoding:NSUTF8StringEncoding]];

    /* Send challenge */
    [client sendEvent:@"connect.challenge" payload:@{
        @"nonce": GWGenerateUUID(),
        @"ts": @((unsigned long long)([[NSDate date] timeIntervalSince1970] * 1000))
    }];

    // an idle socket that never authenticates would otherwise hold a client slot indefinitely
    NSString *connId = [[client.connectionId copy] autorelease];
    [self retain];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kWSAuthDeadline * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        OCGatewayWSClient *c = [_clients objectForKey:connId];
        if (c && !c.authenticated) [c.webSocket closeWithCode:1008 reason:@"authentication timeout"];
        [self release];
    });

    NSLog(@"[Gateway] WebSocket client connected: %@", request.remoteAddress);
}

#pragma mark - WS Message Handling

- (void)_handleWSMessage:(NSString *)message fromClient:(OCGatewayWSClient *)client {
    BOOL first = !client.receivedFirstFrame;
    client.receivedFirstFrame = YES;

    NSData *data = [message dataUsingEncoding:NSUTF8StringEncoding];
    id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary *frame = [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;
    BOOL isConnect = frame && [GWString(frame, @"type") isEqualToString:@"req"] &&
                     [GWString(frame, @"method") isEqualToString:@"connect"];

    // without a header token the first frame must be connect, so nothing else is acted on before auth
    if (!client.authenticated && !client.tokenVerified && (!first || !isConnect)) {
        [client.webSocket closeWithCode:1008 reason:@"authentication required"];
        return;
    }
    if (!frame) return;

    if ([GWString(frame, @"type") isEqualToString:@"req"]) {
        [self _handleRequest:frame fromClient:client];
    }
}

- (void)_handleRequest:(NSDictionary *)frame fromClient:(OCGatewayWSClient *)client {
    NSString *reqId = GWString(frame, @"id");
    NSString *method = GWString(frame, @"method");
    id rawParams = [frame objectForKey:@"params"];
    NSDictionary *params = [rawParams isKindOfClass:[NSDictionary class]] ? rawParams : @{};

    if (!reqId || !method) return;

    /* Connect (auth) */
    if ([method isEqualToString:@"connect"]) {
        [self _handleConnect:params reqId:reqId client:client];
        return;
    }

    /* Require auth for all other methods */
    if (!client.authenticated) {
        [self _sendError:reqId code:@"UNAUTHORIZED" message:@"Not authenticated" client:client];
        return;
    }

    /* Route methods */
    if ([method isEqualToString:@"health"]) {
        [self _sendOk:reqId payload:[self healthStatus] client:client];
    }
    else if ([method isEqualToString:@"sessions.list"]) {
        [self _handleSessionsList:params reqId:reqId client:client];
    }
    else if ([method isEqualToString:@"sessions.create"]) {
        [self _handleSessionsCreate:params reqId:reqId client:client];
    }
    else if ([method isEqualToString:@"sessions.send"] || [method isEqualToString:@"chat.send"]) {
        [self _handleChatSend:params reqId:reqId client:client];
    }
    else if ([method isEqualToString:@"chat.history"]) {
        [self _handleChatHistory:params reqId:reqId client:client];
    }
    else if ([method isEqualToString:@"chat.abort"] || [method isEqualToString:@"sessions.abort"]) {
        [self _handleChatAbort:params reqId:reqId client:client];
    }
    else if ([method isEqualToString:@"sessions.delete"]) {
        NSString *key = GWString(params, @"key");
        if (key) { [self abortSession:key]; [self deleteSession:key]; }
        [self _sendOk:reqId payload:@{} client:client];
    }
    else if ([method isEqualToString:@"sessions.reset"]) {
        NSString *key = GWString(params, @"key");
        if (key) [self resetSession:key];
        [self _sendOk:reqId payload:@{} client:client];
    }
    else if ([method isEqualToString:@"sessions.messages.subscribe"]) {
        NSString *sk = GWString(params, @"sessionKey");
        // each entry costs memory for the life of the socket, so cap them
        if (sk && [client.subscribedSessions count] < 64) [client.subscribedSessions addObject:sk];
        [self _sendOk:reqId payload:@{} client:client];
    }
    else if ([method isEqualToString:@"sessions.messages.unsubscribe"]) {
        NSString *sk = GWString(params, @"sessionKey");
        if (sk) [client.subscribedSessions removeObject:sk];
        [self _sendOk:reqId payload:@{} client:client];
    }
    else if ([method isEqualToString:@"gateway.identity.get"]) {
        [self _sendOk:reqId payload:@{
            @"name": [[UIDevice currentDevice] name] ?: @"",
            @"version": @"0.4.2",
            @"platform": @"ios6-ipod4"
        } client:client];
    }
    else if ([method isEqualToString:@"tools.catalog"]) {
        NSMutableArray *tools = [NSMutableArray array];
        for (OCToolDefinition *t in _tools) {
            [tools addObject:@{
                @"name": t.name ?: @"",
                @"description": t.toolDescription ?: @"",
                @"inputSchema": t.inputSchema ?: @{}
            }];
        }
        [self _sendOk:reqId payload:@{@"tools": tools} client:client];
    }
    else {
        [self _sendError:reqId code:@"INVALID_REQUEST" message:@"Unknown method" client:client];
    }
}

#pragma mark - Auth

- (void)_handleConnect:(NSDictionary *)params reqId:(NSString *)reqId client:(OCGatewayWSClient *)client {
    NSDictionary *auth = GWDict(params, @"auth");
    BOOL authOk = client.authenticated || client.tokenVerified ||
                  [OCGatewayToken isValidToken:GWString(auth, @"token")];

    if (!authOk) {
        [self _sendError:reqId code:@"UNAUTHORIZED" message:@"Authentication failed" client:client];
        [client.webSocket closeWithCode:1008 reason:@"authentication failed"];
        return;
    }

    NSDictionary *clientInfo = GWDict(params, @"client");
    if (clientInfo) {
        client.clientId = GWString(clientInfo, @"id");
        client.displayName = GWString(clientInfo, @"displayName");
        client.platform = GWString(clientInfo, @"platform");
    }

    client.authenticated = YES;
    client.role = GWString(params, @"role") ?: @"operator";
    id scopes = [params objectForKey:@"scopes"];
    client.scopes = [scopes isKindOfClass:[NSArray class]] ? scopes : @[@"operator.admin"];

    NSDictionary *payload = @{
        @"type": @"hello-ok",
        @"protocol": @(kProtocolVersion),
        @"server": @{
            @"version": @"0.4.2-ios6",
            @"connId": client.connectionId
        },
        @"features": @{
            @"methods": @[@"chat.send", @"chat.history", @"chat.abort",
                          @"sessions.list", @"sessions.create", @"sessions.delete",
                          @"sessions.reset", @"sessions.send", @"sessions.abort",
                          @"sessions.messages.subscribe", @"sessions.messages.unsubscribe",
                          @"health", @"tools.catalog", @"gateway.identity.get"],
            @"events": @[@"tick", @"chat.event", @"sessions.changed", @"shutdown"]
        },
        @"policy": @{
            @"maxPayload": @(kMaxWSMessageSize),
            @"maxBufferedBytes": @(2 * 1024 * 1024),
            @"tickIntervalMs": @((NSUInteger)(_config.tickInterval * 1000))
        },
        @"auth": @{
            @"role": client.role ?: @"operator",
            @"scopes": client.scopes ?: @[]
        }
    };

    [self _sendOk:reqId payload:payload client:client];

    NSLog(@"[Gateway] Client authenticated: %@ (%@)", client.displayName, client.platform);

    [client retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([_delegate respondsToSelector:@selector(gatewayServer:didAcceptClient:)]) {
            [_delegate gatewayServer:self didAcceptClient:client];
        }
        [client release];
    });
}

#pragma mark - Session Methods

- (void)_handleSessionsList:(NSDictionary *)params reqId:(NSString *)reqId client:(OCGatewayWSClient *)client {
    NSMutableArray *list = [NSMutableArray array];
    for (OCGatewaySessionEntry *s in [_sessionEntries allValues]) {
        [list addObject:[s toDictionary]];
    }
    [self _sendOk:reqId payload:@{@"sessions": list} client:client];
}

- (void)_handleSessionsCreate:(NSDictionary *)params reqId:(NSString *)reqId client:(OCGatewayWSClient *)client {
    NSString *name = GWString(params, @"displayName") ?: @"New Chat";
    OCGatewaySessionEntry *session = [self createSession:name];
    [self _sendOk:reqId payload:@{@"key": session.sessionKey, @"sessionKey": session.sessionKey} client:client];
    [self broadcastEvent:@"sessions.changed" payload:@{@"action": @"created", @"key": session.sessionKey}];
}

- (void)_handleChatSend:(NSDictionary *)params reqId:(NSString *)reqId client:(OCGatewayWSClient *)client {
    NSString *sessionKey = GWString(params, @"key") ?: GWString(params, @"sessionKey");
    NSString *message = GWString(params, @"message");

    if ([sessionKey length] == 0 || [sessionKey length] > 128 || [message length] == 0) {
        [self _sendError:reqId code:@"INVALID_REQUEST" message:@"Missing key or message" client:client];
        return;
    }
    if ([self _runForSession:sessionKey]) {
        [self _sendError:reqId code:@"BUSY" message:@"A reply for this session is still running" client:client];
        return;
    }

    /* the caller chose the key, so the entry must be stored under that same key */
    if (![_sessionEntries objectForKey:sessionKey]) [self _createSessionWithKey:sessionKey displayName:sessionKey];

    NSString *runId = GWGenerateUUID();
    [self _sendOk:reqId payload:@{@"runId": runId} client:client];
    [self sendMessage:message sessionKey:sessionKey fromClient:client runId:runId];
}

- (void)_handleChatHistory:(NSDictionary *)params reqId:(NSString *)reqId client:(OCGatewayWSClient *)client {
    NSString *sessionKey = GWString(params, @"sessionKey");
    NSUInteger limit = GWLimit([params objectForKey:@"limit"], 100);
    NSArray *msgs = [self historyForSession:sessionKey limit:limit];
    [self _sendOk:reqId payload:@{@"messages": msgs ?: @[]} client:client];
}

- (void)_handleChatAbort:(NSDictionary *)params reqId:(NSString *)reqId client:(OCGatewayWSClient *)client {
    /* chat.send and sessions.delete accept "key", so abort must too */
    NSString *sessionKey = GWString(params, @"sessionKey") ?: GWString(params, @"key");
    if (sessionKey) [self abortSession:sessionKey];
    [self _sendOk:reqId payload:@{} client:client];
}

#pragma mark - Session Management

- (OCGatewaySessionEntry *)createSession:(NSString *)displayName {
    return [self _createSessionWithKey:GWGenerateUUID() displayName:displayName];
}

- (OCGatewaySessionEntry *)_createSessionWithKey:(NSString *)key displayName:(NSString *)displayName {
    OCGatewaySessionEntry *entry = [[OCGatewaySessionEntry alloc] init];
    entry.sessionKey = key;
    entry.displayName = displayName;
    [_sessionEntries setObject:entry forKey:entry.sessionKey];
    [self _persistSessions];
    return [entry autorelease];
}

- (OCGatewaySessionEntry *)sessionForKey:(NSString *)key {
    return [_sessionEntries objectForKey:key];
}

- (NSArray *)listSessions {
    return [_sessionEntries allValues];
}

- (void)deleteSession:(NSString *)key {
    [_sessionEntries removeObjectForKey:key];
    [_sessionHistory removeObjectForKey:key];
    [_store execute:@"DELETE FROM gw_messages WHERE session_key = ?" params:@[key] error:nil];
    [_store execute:@"DELETE FROM gw_sessions WHERE key = ?" params:@[key] error:nil];
    [self _persistSessions];
    [self broadcastEvent:@"sessions.changed" payload:@{@"action": @"deleted", @"key": key}];
}

- (void)resetSession:(NSString *)key {
    [self abortSession:key];
    [_sessionHistory removeObjectForKey:key];
    [_store execute:@"DELETE FROM gw_messages WHERE session_key = ?" params:@[key] error:nil];
    OCGatewaySessionEntry *entry = [_sessionEntries objectForKey:key];
    if (entry) {
        entry.totalTokens = 0;
        entry.updatedAt = [NSDate date];
    }
    [self broadcastEvent:@"sessions.changed" payload:@{@"action": @"reset", @"key": key}];
}

#pragma mark - Agent Execution

- (NSDictionary *)_runForSession:(NSString *)sessionKey {
    for (NSDictionary *run in [_activeRuns allValues])
        if ([[run objectForKey:@"sessionKey"] isEqualToString:sessionKey]) return run;
    return nil;
}

- (NSDictionary *)_runForAgent:(OCAgent *)agent {
    for (NSDictionary *run in [_activeRuns allValues])
        if ([run objectForKey:@"agent"] == agent) return run;
    return nil;
}

- (void)_appendMessage:(NSString *)content role:(NSString *)role toSession:(NSString *)sessionKey {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSMutableArray *history = [_sessionHistory objectForKey:sessionKey];
    if (!history) {
        history = [NSMutableArray arrayWithCapacity:32];
        [_sessionHistory setObject:history forKey:sessionKey];
    }
    [history addObject:@{@"role": role, @"content": content ?: @"", @"timestamp": @(now * 1000)}];
    /* the in-memory copy only feeds context and history requests, so it stays bounded */
    if ([history count] > 200) [history removeObjectsInRange:NSMakeRange(0, [history count] - 200)];
    [_store execute:@"INSERT INTO gw_messages (session_key, role, content, timestamp) VALUES (?, ?, ?, ?)"
             params:@[sessionKey, role, content ?: @"", @(now)] error:nil];
}

- (void)sendMessage:(NSString *)message
          sessionKey:(NSString *)sessionKey
          fromClient:(OCGatewayWSClient *)client
              runId:(NSString *)runId {

    /* earlier turns only; the new message goes in through processMessage */
    NSArray *history = [_sessionHistory objectForKey:sessionKey];
    NSMutableArray *context = [NSMutableArray array];
    NSUInteger startIdx = [history count] > 20 ? [history count] - 20 : 0;
    for (NSUInteger i = startIdx; i < [history count]; i++) {
        NSDictionary *msg = [history objectAtIndex:i];
        NSString *role = [msg objectForKey:@"role"];
        OCAgentMessageRole r;
        if ([role isEqualToString:@"user"]) r = OCAgentRoleUser;
        else if ([role isEqualToString:@"assistant"]) r = OCAgentRoleAssistant;
        else continue;
        [context addObject:[OCAgentMessage messageWithRole:r content:[msg objectForKey:@"content"]]];
    }
    [self _appendMessage:message role:@"user" toSession:sessionKey];

    /* one agent per run, so each reply is routed to the run and session that asked for it */
    OCAgent *agent = [[[OCAgent alloc] init] autorelease];
    agent.maxContextTokens = 4096;
    agent.maxResponseTokens = 2048;
    OCModelConfig *mc = [[[OCModelConfig alloc] init] autorelease];
    mc.providerId = _config.defaultProviderId;
    mc.modelId = _config.defaultModelId;
    mc.apiKey = _config.defaultApiKey;
    mc.baseURL = _config.defaultBaseURL;
    mc.maxTokens = 2048;
    agent.modelConfig = mc;
    agent.systemPrompt = @"You are Molty, a helpful AI assistant powered by LegacyPodClaw, "
        @"running on an iPod Touch. Be concise and helpful.";
    agent.toolCaller = OCToolCallerRemote;
    for (OCToolDefinition *tool in _tools) [agent registerTool:tool];
    [agent loadHistory:context];
    agent.delegate = self;

    NSDictionary *runInfo = @{
        @"sessionKey": sessionKey,
        @"runId": runId,
        @"clientConnId": client.connectionId ?: @"",
        @"agent": agent
    };
    [_activeRuns setObject:runInfo forKey:runId];
    [agent processMessage:message];
}

- (void)abortSession:(NSString *)sessionKey {
    NSDictionary *run;
    while ((run = [self _runForSession:sessionKey])) {
        OCAgent *agent = [run objectForKey:@"agent"];
        agent.delegate = nil;
        [agent abort];
        [_activeRuns removeObjectForKey:[run objectForKey:@"runId"]];
    }
}

#pragma mark - OCAgentDelegate

- (void)agent:(OCAgent *)agent didProduceText:(NSString *)text isFinal:(BOOL)isFinal {
    NSDictionary *info = [[[self _runForAgent:agent] retain] autorelease];
    if (!info) return;
    NSString *runId = [info objectForKey:@"runId"];
    NSString *sessionKey = [info objectForKey:@"sessionKey"];

    NSDictionary *chatEvent = @{
        @"runId": runId,
        @"sessionKey": sessionKey ?: @"",
        @"state": isFinal ? @"final" : @"delta",
        @"message": @{
            @"role": @"assistant",
            @"content": text ?: @""
        },
        @"seq": @(++_seqCounter)
    };
    [self broadcastEvent:@"chat.event" payload:chatEvent toSession:sessionKey];
    if (!isFinal) return;

    [self _appendMessage:text role:@"assistant" toSession:sessionKey];
    OCGatewaySessionEntry *entry = [_sessionEntries objectForKey:sessionKey];
    if (entry) {
        entry.updatedAt = [NSDate date];
        [self _persistSessions];
    }
    /* the agent is still inside its callback; the autoreleased info keeps it alive until it returns */
    agent.delegate = nil;
    [_activeRuns removeObjectForKey:runId];
    [self broadcastEvent:@"sessions.changed" payload:@{@"action": @"updated", @"key": sessionKey}];
}

- (void)agent:(OCAgent *)agent didFailWithError:(NSError *)error {
    NSDictionary *info = [[[self _runForAgent:agent] retain] autorelease];
    if (!info) return;
    NSString *runId = [info objectForKey:@"runId"];
    NSString *sessionKey = [info objectForKey:@"sessionKey"];
    [self broadcastEvent:@"chat.event" payload:@{
        @"runId": runId,
        @"sessionKey": sessionKey ?: @"",
        @"state": @"error",
        @"message": @{
            @"role": @"assistant",
            @"content": [NSString stringWithFormat:@"Error: %@", [error localizedDescription]]
        }
    } toSession:sessionKey];
    agent.delegate = nil;
    [_activeRuns removeObjectForKey:runId];
}

#pragma mark - History

- (NSArray *)historyForSession:(NSString *)sessionKey limit:(NSUInteger)limit {
    NSArray *history = [_sessionHistory objectForKey:sessionKey];
    if (!history) return @[];
    if ([history count] <= limit) return history;
    return [history subarrayWithRange:NSMakeRange([history count] - limit, limit)];
}

#pragma mark - Broadcasting

- (void)broadcastEvent:(NSString *)event payload:(id)payload {
    for (OCGatewayWSClient *client in [_clients allValues]) {
        if (!client.authenticated) continue;
        [client sendEvent:event payload:payload];
    }
}

- (void)broadcastEvent:(NSString *)event payload:(id)payload toSession:(NSString *)sessionKey {
    for (OCGatewayWSClient *client in [_clients allValues]) {
        if (!client.authenticated) continue;
        if ([client.subscribedSessions containsObject:sessionKey] ||
            [client.subscribedSessions count] == 0) { /* Broadcast to all if no specific subscriptions */
            [client sendEvent:event payload:payload];
        }
    }
}

#pragma mark - Tick

- (void)_sendTicks {
    NSDictionary *tick = @{@"ts": @((NSUInteger)([[NSDate date] timeIntervalSince1970] * 1000))};
    for (OCGatewayWSClient *client in [_clients allValues]) {
        if (client.authenticated) {
            [client sendEvent:@"tick" payload:tick];
        }
    }
}

#pragma mark - Cron

- (void)addCronJob:(OCCronJob *)job {
    if (!job.jobId) job.jobId = GWGenerateUUID();
    [_cronJobs addObject:job];
}

- (void)removeCronJob:(NSString *)jobId {
    for (NSUInteger i = 0; i < [_cronJobs count]; i++) {
        if ([[[_cronJobs objectAtIndex:i] jobId] isEqualToString:jobId]) {
            [_cronJobs removeObjectAtIndex:i];
            return;
        }
    }
}

- (NSArray *)cronJobs { return [[_cronJobs copy] autorelease]; }

- (void)_checkCron {
    /* Simple minute-based cron check */
    for (OCCronJob *job in _cronJobs) {
        if (!job.enabled) continue;
        /* TODO: Full cron expression parsing */
        /* For now, just check if it's time based on interval */
    }
}

#pragma mark - Health

- (NSDictionary *)healthStatus {
    return @{
        @"ok": @YES,
        @"status": @"live",
        @"version": @"0.4.2-ios6",
        @"platform": @"ipod-touch-4",
        @"uptime": @([self uptime]),
        @"connectedClients": @([_clients count]),
        @"activeSessions": @([_sessionEntries count]),
        @"memoryMB": @([OCMemoryMonitor sharedMonitor].appMemoryBytes / (1024 * 1024))
    };
}

- (NSUInteger)uptime {
    if (!_startedAt) return 0;
    return (NSUInteger)(-[_startedAt timeIntervalSinceNow]);
}

- (NSArray *)connectedClients { return [_clients allValues]; }
- (NSArray *)sessions { return [_sessionEntries allValues]; }

#pragma mark - Persistence

- (void)_setupSchema {
    [_store execute:@"CREATE TABLE IF NOT EXISTS gw_sessions ("
     @"key TEXT PRIMARY KEY, display_name TEXT, status TEXT, "
     @"model TEXT, total_tokens INTEGER, started_at REAL, updated_at REAL)" error:nil];

    [_store execute:@"CREATE TABLE IF NOT EXISTS gw_messages ("
     @"id INTEGER PRIMARY KEY AUTOINCREMENT, session_key TEXT, "
     @"role TEXT, content TEXT, timestamp REAL, "
     @"FOREIGN KEY(session_key) REFERENCES gw_sessions(key))" error:nil];

    [_store execute:@"CREATE INDEX IF NOT EXISTS idx_gw_msg_session "
     @"ON gw_messages(session_key, timestamp)" error:nil];
}

- (void)_loadSessions {
    [_store query:@"SELECT * FROM gw_sessions ORDER BY updated_at DESC"
           params:nil enumerate:^(OCStoreRow *row, BOOL *stop) {
        OCGatewaySessionEntry *e = [[OCGatewaySessionEntry alloc] init];
        e.sessionKey = [row stringForColumn:@"key"];
        e.displayName = [row stringForColumn:@"display_name"];
        e.status = [row stringForColumn:@"status"];
        e.totalTokens = [row integerForColumn:@"total_tokens"];
        e.startedAt = [NSDate dateWithTimeIntervalSince1970:[row doubleForColumn:@"started_at"]];
        e.updatedAt = [NSDate dateWithTimeIntervalSince1970:[row doubleForColumn:@"updated_at"]];
        [_sessionEntries setObject:e forKey:e.sessionKey];
        [e release];
    } error:nil];

    /* Load message history for each session */
    for (NSString *key in _sessionEntries) {
        NSMutableArray *msgs = [NSMutableArray array];
        /* the same 200-message bound as the live copy; the table keeps every message */
        [_store query:@"SELECT role, content, timestamp FROM gw_messages "
         @"WHERE session_key = ? ORDER BY timestamp DESC LIMIT 200"
               params:@[key] enumerate:^(OCStoreRow *row, BOOL *stop) {
            /* the table stores seconds and the live copy milliseconds */
            [msgs insertObject:@{
                @"role": [row stringForColumn:@"role"] ?: @"",
                @"content": [row stringForColumn:@"content"] ?: @"",
                @"timestamp": @([row doubleForColumn:@"timestamp"] * 1000)
            } atIndex:0];
        } error:nil];
        [_sessionHistory setObject:msgs forKey:key];
    }
}

- (void)_persistSessions {
    for (OCGatewaySessionEntry *e in [_sessionEntries allValues]) {
        [_store execute:@"INSERT OR REPLACE INTO gw_sessions "
         @"(key, display_name, status, model, total_tokens, started_at, updated_at) "
         @"VALUES (?, ?, ?, ?, ?, ?, ?)"
                 params:@[
                     e.sessionKey ?: @"",
                     e.displayName ?: @"",
                     e.status ?: @"active",
                     e.model ?: @"",
                     @(e.totalTokens),
                     @([e.startedAt timeIntervalSince1970]),
                     @([e.updatedAt timeIntervalSince1970])
                 ] error:nil];
    }
}

#pragma mark - Response Helpers

- (void)_sendOk:(NSString *)reqId payload:(id)payload client:(OCGatewayWSClient *)client {
    [client sendJSON:@{
        @"type": @"res",
        @"id": reqId,
        @"ok": @YES,
        @"payload": payload ?: @{}
    }];
}

- (void)_sendError:(NSString *)reqId code:(NSString *)code message:(NSString *)msg client:(OCGatewayWSClient *)client {
    [client sendJSON:@{
        @"type": @"res",
        @"id": reqId,
        @"ok": @NO,
        @"error": @{
            @"code": code,
            @"message": msg
        }
    }];
}

#pragma mark - HTTPServerDelegate

- (void)httpServerDidStart:(id)server port:(uint16_t)port {
    NSLog(@"[Gateway] HTTP server listening on port %d", port);
}

- (void)httpServer:(id)server didFailWithError:(NSError *)error {
    NSLog(@"[Gateway] HTTP server error: %@", error);
}

#pragma mark - OCServerWebSocketDelegate

- (OCGatewayWSClient *)_clientForSocket:(OCServerWebSocket *)ws {
    for (OCGatewayWSClient *client in [_clients allValues]) {
        if (client.webSocket == ws) return client;
    }
    return nil;
}

- (void)serverWebSocket:(OCServerWebSocket *)ws didReceiveText:(NSString *)text {
    OCGatewayWSClient *client = [self _clientForSocket:ws];
    if (client) [self _handleWSMessage:text fromClient:client];
}

- (void)serverWebSocketDidClose:(OCServerWebSocket *)ws {
    OCGatewayWSClient *client = [[[self _clientForSocket:ws] retain] autorelease];
    ws.delegate = nil;
    if (!client) return;
    NSLog(@"[Gateway] Client disconnected: %@", client.displayName);
    [_clients removeObjectForKey:client.connectionId];
    if (!client.authenticated) return;
    [client retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([_delegate respondsToSelector:@selector(gatewayServer:didDisconnectClient:)]) {
            [_delegate gatewayServer:self didDisconnectClient:client];
        }
        [client release];
    });
}

@end
