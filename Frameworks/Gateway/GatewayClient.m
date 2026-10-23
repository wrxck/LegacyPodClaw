/*
 * OCGatewayClient.m
 * LegacyPodClaw - Gateway Protocol Client Implementation
 *
 * Implements the full LegacyPodClaw gateway WebSocket protocol v3:
 * - Challenge/response handshake
 * - JSON frame multiplexing (req/res/event)
 * - Streaming chat deltas
 * - Heartbeat monitoring
 * - Exponential backoff reconnection
 */

#import "GatewayClient.h"

NSString *const OCGatewayErrorDomain = @"OCGatewayError";
const NSInteger kOCGatewayProtocolVersion = 3;

static NSString *const kFrameTypeReq   = @"req";
static NSString *const kFrameTypeRes   = @"res";
static NSString *const kFrameTypeEvent = @"event";

#pragma mark - Data Model Implementations

@implementation OCGatewayAuthConfig
- (void)dealloc {
    [_token release]; [_password release];
    [_deviceToken release]; [_bootstrapToken release];
    [super dealloc];
}
@end

@implementation OCGatewayServerInfo
- (void)dealloc {
    [_version release]; [_connectionId release];
    [_supportedMethods release]; [_supportedEvents release];
    [super dealloc];
}
@end

@implementation OCGatewayChatEvent
- (void)dealloc {
    [_runId release]; [_sessionKey release]; [_messageText release];
    [_thinkingText release]; [_role release]; [_stopReason release];
    [_rawPayload release];
    [super dealloc];
}
@end

@implementation OCGatewaySession
- (void)dealloc {
    [_key release]; [_displayName release]; [_agentId release];
    [_createdAt release]; [_lastActiveAt release];
    [super dealloc];
}
@end

@implementation OCGatewayMessage
- (void)dealloc {
    [_messageId release]; [_role release]; [_content release];
    [_thinking release]; [_timestamp release]; [_attachments release];
    [_usage release];
    [super dealloc];
}
@end

#pragma mark - Pending Request

@interface _OCPendingRequest : NSObject {
    @public
    NSString *requestId;
    NSString *method;
    OCGatewayResponseBlock callback;
    NSTimer *timeoutTimer;
}
@end

@implementation _OCPendingRequest
- (void)dealloc {
    [requestId release]; [method release];
    [callback release]; [timeoutTimer invalidate];
    [super dealloc];
}
@end

#pragma mark - OCGatewayClient Private

@interface OCGatewayClient () {
    OCWebSocket *_ws;
    NSMutableDictionary *_pendingRequests;   // requestId -> _OCPendingRequest
    NSMutableDictionary *_chatStreamBlocks;  // sessionKey -> OCGatewayChatStreamBlock
    NSUInteger _requestCounter;

    /* Reconnection state */
    NSUInteger _reconnectAttempt;
    NSTimer *_reconnectTimer;

    /* Heartbeat */
    NSDate *_lastTickReceived;
    NSTimer *_tickWatchdog;

    /* Challenge nonce for auth */
    NSString *_challengeNonce;

    dispatch_queue_t _clientQueue;
}
@end

@implementation OCGatewayClient

#pragma mark - Init

- (instancetype)init {
    if ((self = [super init])) {
        _connectionState = OCGatewayStateDisconnected;
        _pendingRequests = [[NSMutableDictionary alloc] initWithCapacity:16];
        _chatStreamBlocks = [[NSMutableDictionary alloc] initWithCapacity:4];
        _requestCounter = 0;
        _autoReconnect = YES;
        _initialReconnectDelay = 1.0;
        _maxReconnectDelay = 60.0;
        _maxReconnectAttempts = 20;
        _reconnectAttempt = 0;
        _clientId = [[self _generateUUID] retain];
        _clientVersion = [@"clawpod-ios6/0.1.0" retain];
        _clientDisplayName = [@"iPod Touch" retain];
        _delegateQueue = dispatch_get_main_queue();
        _clientQueue = dispatch_queue_create("pro.matthesketh.legacypodclaw.gateway", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc {
    [self disconnect];
    [_pendingRequests release];
    [_chatStreamBlocks release];
    [_clientId release]; [_clientDisplayName release]; [_clientVersion release];
    [_deviceId release]; [_host release]; [_authConfig release]; [_pinnedCertSHA256 release];
    [_serverInfo release]; [_challengeNonce release];
    [_lastTickReceived release];
    [_clientQueue release]; [_delegateQueue release];
    [super dealloc];
}

#pragma mark - Connection

- (void)connect {
    dispatch_async(_clientQueue, ^{
        if (_connectionState != OCGatewayStateDisconnected &&
            _connectionState != OCGatewayStateReconnecting) return;

        [self _setConnectionState:OCGatewayStateConnecting];
        _reconnectAttempt = 0;

        [self _createAndOpenWebSocket];
    });
}

- (void)disconnect {
    dispatch_async(_clientQueue, ^{
        _autoReconnect = NO;
        [_reconnectTimer invalidate]; _reconnectTimer = nil;
        [_tickWatchdog invalidate]; _tickWatchdog = nil;

        if (_ws) {
            [_ws close];
            _ws.delegate = nil;
            [_ws release]; _ws = nil;
        }

        /* Fail all pending requests */
        NSError *error = [NSError errorWithDomain:OCGatewayErrorDomain code:-1
                                         userInfo:@{NSLocalizedDescriptionKey: @"Disconnected"}];
        for (_OCPendingRequest *req in [_pendingRequests allValues]) {
            if (req->callback) req->callback(nil, error);
        }
        [_pendingRequests removeAllObjects];
        [_chatStreamBlocks removeAllObjects];

        [self _setConnectionState:OCGatewayStateDisconnected];
    });
}

- (void)_createAndOpenWebSocket {
    NSString *scheme = _useTLS ? @"wss" : @"ws";
    NSString *urlStr = [NSString stringWithFormat:@"%@://%@:%lu/",
                        scheme, _host, (unsigned long)_port];
    NSURL *url = [NSURL URLWithString:urlStr];

    [_ws release];
    _ws = [[OCWebSocket alloc] initWithURL:url];
    _ws.delegate = self;
    _ws.allowSelfSignedCerts = _allowSelfSignedCerts;
    _ws.pinnedCertSHA256 = _pinnedCertSHA256;
    _ws.delegateQueue = _clientQueue;
    _ws.pingInterval = 0;  /* We handle keepalive via gateway ticks */
    [_ws open];
}

#pragma mark - OCWebSocketDelegate

- (void)webSocketDidOpen:(OCWebSocket *)ws {
    /* WebSocket is open, but we wait for connect.challenge event */
    [self _setConnectionState:OCGatewayStateAuthenticating];
}

- (void)webSocket:(OCWebSocket *)ws didReceiveMessage:(NSString *)message {
    [self _handleMessage:message];
}

- (void)webSocket:(OCWebSocket *)ws didCloseWithCode:(OCWSCloseCode)code
           reason:(NSString *)reason wasClean:(BOOL)wasClean {
    [self _setConnectionState:OCGatewayStateDisconnected];
    [self _scheduleReconnectIfNeeded];
}

- (void)webSocket:(OCWebSocket *)ws didFailWithError:(NSError *)error {
    [self _setConnectionState:OCGatewayStateDisconnected];

    dispatch_async(_delegateQueue, ^{
        [_delegate gatewayClient:self didFailWithError:error];
    });

    [self _scheduleReconnectIfNeeded];
}

#pragma mark - Message Handling

- (void)_handleMessage:(NSString *)messageStr {
    NSData *data = [messageStr dataUsingEncoding:NSUTF8StringEncoding];
    NSError *jsonError = nil;
    NSDictionary *frame = [NSJSONSerialization JSONObjectWithData:data
                                                          options:0
                                                            error:&jsonError];
    if (jsonError || ![frame isKindOfClass:[NSDictionary class]]) return;

    NSString *type = [frame objectForKey:@"type"];

    if ([type isEqualToString:kFrameTypeRes]) {
        [self _handleResponse:frame];
    } else if ([type isEqualToString:kFrameTypeEvent]) {
        [self _handleEvent:frame];
    }
}

- (void)_handleResponse:(NSDictionary *)frame {
    NSString *reqId = [frame objectForKey:@"id"];
    if (!reqId) return;

    _OCPendingRequest *pending = [_pendingRequests objectForKey:reqId];
    if (!pending) return;

    [pending->timeoutTimer invalidate];

    BOOL ok = [[frame objectForKey:@"ok"] boolValue];
    if (ok) {
        NSDictionary *payload = [frame objectForKey:@"payload"];

        /* Special handling for connect response */
        if ([pending->method isEqualToString:@"connect"]) {
            [self _handleConnectSuccess:payload];
        }

        if (pending->callback) pending->callback(payload, nil);
    } else {
        NSDictionary *errDict = [frame objectForKey:@"error"];
        NSString *errCode = [errDict objectForKey:@"code"] ?: @"UNKNOWN";
        NSString *errMsg = [errDict objectForKey:@"message"] ?: @"Unknown error";
        NSError *error = [NSError errorWithDomain:OCGatewayErrorDomain
                                             code:-1
                                         userInfo:@{
            NSLocalizedDescriptionKey: errMsg,
            @"code": errCode,
            @"retryable": [errDict objectForKey:@"retryable"] ?: @NO
        }];

        if (pending->callback) pending->callback(nil, error);
    }

    [_pendingRequests removeObjectForKey:reqId];
}

- (void)_handleEvent:(NSDictionary *)frame {
    NSString *event = [frame objectForKey:@"event"];
    NSDictionary *payload = [frame objectForKey:@"payload"];

    if ([event isEqualToString:@"connect.challenge"]) {
        [_challengeNonce release];
        _challengeNonce = [[payload objectForKey:@"nonce"] copy];
        [self _sendConnectRequest];
        return;
    }

    if ([event isEqualToString:@"tick"]) {
        [_lastTickReceived release];
        _lastTickReceived = [[NSDate date] retain];
        dispatch_async(_delegateQueue, ^{
            if ([_delegate respondsToSelector:@selector(gatewayClientDidReceiveTick:)]) {
                [_delegate gatewayClientDidReceiveTick:self];
            }
        });
        return;
    }

    if ([event isEqualToString:@"shutdown"]) {
        /* Server shutting down - will auto-reconnect */
        return;
    }

    if ([event isEqualToString:@"chat.event"] ||
        [event isEqualToString:@"sessions.message"]) {
        [self _handleChatEvent:payload];
        return;
    }

    /* Generic event forwarding */
    dispatch_async(_delegateQueue, ^{
        if ([_delegate respondsToSelector:@selector(gatewayClient:didReceiveEvent:payload:)]) {
            [_delegate gatewayClient:self didReceiveEvent:event payload:payload];
        }
    });
}

#pragma mark - Connect Handshake

- (void)_sendConnectRequest {
    NSMutableDictionary *params = [NSMutableDictionary dictionaryWithCapacity:8];
    [params setObject:@(kOCGatewayProtocolVersion) forKey:@"minProtocol"];
    [params setObject:@(kOCGatewayProtocolVersion) forKey:@"maxProtocol"];

    /* Client info */
    NSDictionary *client = @{
        @"id": _clientId ?: @"",
        @"displayName": _clientDisplayName ?: @"iPod Touch 4",
        @"version": _clientVersion ?: @"0.1.0",
        @"platform": @"ios6",
        @"mode": @"frontend"
    };
    [params setObject:client forKey:@"client"];

    /* Auth */
    NSMutableDictionary *auth = [NSMutableDictionary dictionary];
    if (_authConfig.token)
        [auth setObject:_authConfig.token forKey:@"token"];
    if (_authConfig.password)
        [auth setObject:_authConfig.password forKey:@"password"];
    if (_authConfig.deviceToken)
        [auth setObject:_authConfig.deviceToken forKey:@"deviceToken"];
    if (_authConfig.bootstrapToken)
        [auth setObject:_authConfig.bootstrapToken forKey:@"bootstrapToken"];
    [params setObject:auth forKey:@"auth"];

    /* Device identity */
    if (_deviceId) {
        NSDictionary *device = @{
            @"id": _deviceId,
            @"nonce": _challengeNonce ?: @""
        };
        [params setObject:device forKey:@"device"];
    }

    [params setObject:@"operator" forKey:@"role"];
    [params setObject:@[@"operator.admin"] forKey:@"scopes"];

    [self request:@"connect" params:params timeout:30.0 callback:nil];
}

- (void)_handleConnectSuccess:(NSDictionary *)payload {
    /* Parse server info */
    OCGatewayServerInfo *info = [[OCGatewayServerInfo alloc] init];
    NSDictionary *server = [payload objectForKey:@"server"];
    info.version = [server objectForKey:@"version"];
    info.connectionId = [server objectForKey:@"connId"];

    NSDictionary *policy = [payload objectForKey:@"policy"];
    info.maxPayload = [[policy objectForKey:@"maxPayload"] unsignedIntegerValue];
    info.tickInterval = [[policy objectForKey:@"tickIntervalMs"] doubleValue] / 1000.0;

    NSDictionary *features = [payload objectForKey:@"features"];
    info.supportedMethods = [features objectForKey:@"methods"];
    info.supportedEvents = [features objectForKey:@"events"];

    /* Save device token if server issued one */
    NSDictionary *authResp = [payload objectForKey:@"auth"];
    NSString *newDeviceToken = [authResp objectForKey:@"deviceToken"];
    if (newDeviceToken && _authConfig) {
        _authConfig.deviceToken = newDeviceToken;
    }

    [_serverInfo release];
    _serverInfo = info;

    /* Connected! */
    [self _setConnectionState:OCGatewayStateConnected];
    _reconnectAttempt = 0;

    /* Start tick watchdog */
    NSTimeInterval watchdogInterval = info.tickInterval > 0 ? info.tickInterval * 2.5 : 75.0;
    [_tickWatchdog invalidate];
    _tickWatchdog = [NSTimer scheduledTimerWithTimeInterval:watchdogInterval
                                                    target:self
                                                  selector:@selector(_checkTickHealth)
                                                  userInfo:nil
                                                   repeats:YES];

    dispatch_async(_delegateQueue, ^{
        if ([_delegate respondsToSelector:@selector(gatewayClient:didConnectWithServerInfo:)]) {
            [_delegate gatewayClient:self didConnectWithServerInfo:info];
        }
    });
}

#pragma mark - Chat Events

- (void)_handleChatEvent:(NSDictionary *)payload {
    OCGatewayChatEvent *event = [[OCGatewayChatEvent alloc] init];
    event.runId = [payload objectForKey:@"runId"];
    event.sessionKey = [payload objectForKey:@"sessionKey"];
    event.seq = [[payload objectForKey:@"seq"] unsignedIntegerValue];
    event.rawPayload = payload;

    NSString *stateStr = [payload objectForKey:@"state"];
    if ([stateStr isEqualToString:@"delta"]) {
        event.state = OCGatewayChatStateDelta;
    } else if ([stateStr isEqualToString:@"final"]) {
        event.state = OCGatewayChatStateFinal;
    } else if ([stateStr isEqualToString:@"aborted"]) {
        event.state = OCGatewayChatStateAborted;
    } else {
        event.state = OCGatewayChatStateError;
    }

    /* Extract message content */
    NSDictionary *message = [payload objectForKey:@"message"];
    if (message) {
        event.messageText = [message objectForKey:@"content"];
        event.thinkingText = [message objectForKey:@"thinking"];
        event.role = [message objectForKey:@"role"];
    }

    NSDictionary *usage = [payload objectForKey:@"usage"];
    if (usage) {
        event.inputTokens = [[usage objectForKey:@"inputTokens"] unsignedIntegerValue];
        event.outputTokens = [[usage objectForKey:@"outputTokens"] unsignedIntegerValue];
    }
    event.stopReason = [payload objectForKey:@"stopReason"];

    /* Call stream block if registered for this session */
    OCGatewayChatStreamBlock streamBlock = [_chatStreamBlocks objectForKey:event.sessionKey];
    if (streamBlock) {
        streamBlock(event);
        if (event.state != OCGatewayChatStateDelta) {
            [_chatStreamBlocks removeObjectForKey:event.sessionKey];
        }
    }

    /* Always notify delegate */
    dispatch_async(_delegateQueue, ^{
        [_delegate gatewayClient:self didReceiveChatEvent:event];
        [event release];
    });
}

#pragma mark - RPC

- (void)request:(NSString *)method
         params:(NSDictionary *)params
       callback:(OCGatewayResponseBlock)callback {
    [self request:method params:params timeout:30.0 callback:callback];
}

- (void)request:(NSString *)method
         params:(NSDictionary *)params
        timeout:(NSTimeInterval)timeout
       callback:(OCGatewayResponseBlock)callback {
    dispatch_async(_clientQueue, ^{
        NSString *reqId = [self _generateRequestId];

        NSDictionary *frame = @{
            @"type": kFrameTypeReq,
            @"id": reqId,
            @"method": method,
            @"params": params ?: @{}
        };

        /* Register pending request */
        _OCPendingRequest *pending = [[_OCPendingRequest alloc] init];
        pending->requestId = [reqId retain];
        pending->method = [method retain];
        pending->callback = [callback copy];

        /* Timeout timer */
        pending->timeoutTimer = [NSTimer scheduledTimerWithTimeInterval:timeout
                                                                target:self
                                                              selector:@selector(_requestTimedOut:)
                                                              userInfo:reqId
                                                               repeats:NO];

        [_pendingRequests setObject:pending forKey:reqId];
        [pending release];

        /* Serialize and send */
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:frame options:0 error:nil];
        NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        [_ws sendText:jsonStr];
        [jsonStr release];
    });
}

- (void)_requestTimedOut:(NSTimer *)timer {
    NSString *reqId = [timer userInfo];
    dispatch_async(_clientQueue, ^{
        _OCPendingRequest *pending = [_pendingRequests objectForKey:reqId];
        if (pending && pending->callback) {
            NSError *error = [NSError errorWithDomain:OCGatewayErrorDomain
                                                 code:-2
                                             userInfo:@{NSLocalizedDescriptionKey: @"Request timed out"}];
            pending->callback(nil, error);
        }
        [_pendingRequests removeObjectForKey:reqId];
    });
}

#pragma mark - Chat API

- (void)sendMessage:(NSString *)message
         sessionKey:(NSString *)sessionKey
           thinking:(NSString *)thinking
        attachments:(NSArray *)attachments
     idempotencyKey:(NSString *)idempotencyKey
       streamBlock:(OCGatewayChatStreamBlock)streamBlock
        completion:(OCGatewayResponseBlock)completion {

    if (streamBlock) {
        [_chatStreamBlocks setObject:[[streamBlock copy] autorelease] forKey:sessionKey];
    }

    NSMutableDictionary *params = [NSMutableDictionary dictionaryWithCapacity:6];
    [params setObject:sessionKey forKey:@"key"];
    [params setObject:message forKey:@"message"];
    if (thinking) [params setObject:thinking forKey:@"thinking"];
    if (attachments) [params setObject:attachments forKey:@"attachments"];
    if (idempotencyKey) [params setObject:idempotencyKey forKey:@"idempotencyKey"];

    [self request:@"sessions.send" params:params timeout:300.0 callback:completion];
}

- (void)abortChat:(NSString *)sessionKey runId:(NSString *)runId {
    NSMutableDictionary *params = [NSMutableDictionary dictionary];
    [params setObject:sessionKey forKey:@"sessionKey"];
    if (runId) [params setObject:runId forKey:@"runId"];
    [self request:@"chat.abort" params:params callback:nil];
}

#pragma mark - Sessions API

- (void)listSessions:(OCGatewaySessionsBlock)callback {
    [self request:@"sessions.list" params:nil callback:^(NSDictionary *result, NSError *error) {
        if (error) {
            callback(nil, error);
            return;
        }

        NSArray *sessionDicts = [result objectForKey:@"sessions"];
        NSMutableArray *sessions = [NSMutableArray arrayWithCapacity:[sessionDicts count]];

        for (NSDictionary *dict in sessionDicts) {
            OCGatewaySession *session = [[OCGatewaySession alloc] init];
            session.key = [dict objectForKey:@"key"];
            session.displayName = [dict objectForKey:@"displayName"];
            session.agentId = [dict objectForKey:@"agentId"];
            [sessions addObject:session];
            [session release];
        }

        callback(sessions, nil);
    }];
}

- (void)createSession:(NSString *)displayName callback:(OCGatewayResponseBlock)callback {
    NSDictionary *params = displayName ? @{@"displayName": displayName} : @{};
    [self request:@"sessions.create" params:params callback:callback];
}

- (void)deleteSession:(NSString *)sessionKey callback:(OCGatewayResponseBlock)callback {
    [self request:@"sessions.delete" params:@{@"key": sessionKey} callback:callback];
}

- (void)resetSession:(NSString *)sessionKey callback:(OCGatewayResponseBlock)callback {
    [self request:@"sessions.reset" params:@{@"key": sessionKey} callback:callback];
}

#pragma mark - History

- (void)getHistory:(NSString *)sessionKey
             limit:(NSUInteger)limit
          callback:(OCGatewayHistoryBlock)callback {
    NSDictionary *params = @{
        @"sessionKey": sessionKey,
        @"limit": @(limit)
    };

    [self request:@"chat.history" params:params callback:^(NSDictionary *result, NSError *error) {
        if (error) {
            callback(nil, error);
            return;
        }

        NSArray *msgDicts = [result objectForKey:@"messages"];
        NSMutableArray *messages = [NSMutableArray arrayWithCapacity:[msgDicts count]];

        for (NSDictionary *dict in msgDicts) {
            OCGatewayMessage *msg = [[OCGatewayMessage alloc] init];
            msg.messageId = [dict objectForKey:@"id"];
            msg.role = [dict objectForKey:@"role"];
            msg.content = [dict objectForKey:@"content"];
            msg.thinking = [dict objectForKey:@"thinking"];
            msg.usage = [dict objectForKey:@"usage"];
            [messages addObject:msg];
            [msg release];
        }

        callback(messages, nil);
    }];
}

#pragma mark - Health

- (void)checkHealth:(OCGatewayResponseBlock)callback {
    [self request:@"health" params:nil timeout:10.0 callback:callback];
}

#pragma mark - Subscriptions

- (void)subscribeSession:(NSString *)sessionKey {
    [self request:@"sessions.messages.subscribe"
          params:@{@"sessionKey": sessionKey}
        callback:nil];
}

- (void)unsubscribeSession:(NSString *)sessionKey {
    [self request:@"sessions.messages.unsubscribe"
          params:@{@"sessionKey": sessionKey}
        callback:nil];
}

#pragma mark - Reconnection

- (void)_scheduleReconnectIfNeeded {
    if (!_autoReconnect) return;
    if (_maxReconnectAttempts > 0 && _reconnectAttempt >= _maxReconnectAttempts) return;

    _reconnectAttempt++;
    [self _setConnectionState:OCGatewayStateReconnecting];

    /* Exponential backoff with jitter */
    NSTimeInterval delay = _initialReconnectDelay * pow(2.0, MIN(_reconnectAttempt - 1, 6u));
    delay = MIN(delay, _maxReconnectDelay);
    /* Add 0-25% jitter */
    delay += delay * 0.25 * ((double)arc4random() / UINT32_MAX);

    dispatch_async(_delegateQueue, ^{
        if ([_delegate respondsToSelector:@selector(gatewayClient:willReconnectAfterDelay:attempt:)]) {
            [_delegate gatewayClient:self willReconnectAfterDelay:delay attempt:_reconnectAttempt];
        }
    });

    [_reconnectTimer invalidate];
    _reconnectTimer = [NSTimer scheduledTimerWithTimeInterval:delay
                                                       target:self
                                                     selector:@selector(_doReconnect)
                                                     userInfo:nil
                                                      repeats:NO];
}

- (void)_doReconnect {
    _reconnectTimer = nil;
    dispatch_async(_clientQueue, ^{
        [self _createAndOpenWebSocket];
    });
}

#pragma mark - Heartbeat

- (void)_checkTickHealth {
    if (!_lastTickReceived) return;

    NSTimeInterval elapsed = -[_lastTickReceived timeIntervalSinceNow];
    NSTimeInterval maxInterval = _serverInfo.tickInterval > 0 ? _serverInfo.tickInterval * 2.5 : 75.0;

    if (elapsed > maxInterval) {
        /* Connection stalled - force reconnect */
        [_ws close];
    }
}

#pragma mark - State Management

- (void)_setConnectionState:(OCGatewayConnectionState)state {
    if (_connectionState == state) return;
    _connectionState = state;

    dispatch_async(_delegateQueue, ^{
        [_delegate gatewayClient:self didChangeState:state];
    });
}

#pragma mark - Utilities

- (NSString *)_generateRequestId {
    return [NSString stringWithFormat:@"r%lu", (unsigned long)(++_requestCounter)];
}

- (NSString *)_generateUUID {
    CFUUIDRef uuid = CFUUIDCreate(kCFAllocatorDefault);
    NSString *uuidStr = (NSString *)CFUUIDCreateString(kCFAllocatorDefault, uuid);
    CFRelease(uuid);
    return [uuidStr autorelease];
}

@end
