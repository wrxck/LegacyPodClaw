/* discord gateway v10 client; guild messages are answered only when the bot is mentioned */

#import "DiscordChannel.h"
#import "TLSClient.h"

static NSString *const kDiscordGateway = @"wss://gateway.discord.gg/?v=10&encoding=json";
static NSString *const kDiscordAPI = @"https://discord.com/api/v10";
static const NSUInteger kDiscordMaxChars = 1900;
/* guilds, guild messages, direct messages and message content */
static const NSUInteger kDiscordIntents = (1 << 0) | (1 << 9) | (1 << 12) | (1 << 15);

@interface OCDiscordChannel () {
    NSString *_botToken;
    OCTLSWebSocket *_ws;
    BOOL _running, _connected, _awaitingAck;
    NSTimer *_heartbeatTimer;
    NSTimeInterval _heartbeatInterval;
    NSInteger _lastSequence;
    NSString *_botUserId;
    NSString *_lastError;
    NSTimeInterval _backoff;
    NSUInteger _connectGeneration;
}
@end

@implementation OCDiscordChannel

@synthesize messageDelegate = _messageDelegate;

- (instancetype)initWithBotToken:(NSString *)token {
    if ((self = [super init])) {
        _botToken = [token copy];
        _lastSequence = -1;
    }
    return self;
}

- (void)dealloc {
    [self _teardown];
    [_botToken release]; [_botUserId release]; [_lastError release];
    [super dealloc];
}

- (NSString *)channelId { return @"discord"; }
- (BOOL)isConnected { return _connected; }
- (BOOL)isConfigured { return [_botToken length] > 0; }

- (void)start {
    if (_running || ![self isConfigured]) return;
    _running = YES;
    _backoff = 0;
    [self _connect];
}

- (void)stop {
    _running = NO;
    _connectGeneration++;
    [self _teardown];
    OCChannelStatusChanged(self);
}

- (void)_teardown {
    _connected = NO;
    _awaitingAck = NO;
    [_heartbeatTimer invalidate]; _heartbeatTimer = nil;
    _ws.delegate = nil;
    [_ws close];
    [_ws release]; _ws = nil;
}

- (void)_connect {
    [self _teardown];
    _lastSequence = -1;
    _ws = [[OCTLSWebSocket alloc] initWithURL:[NSURL URLWithString:kDiscordGateway]];
    _ws.delegate = self;
    [_ws open];
}

- (void)_reconnectWithReason:(NSString *)reason {
    [self _teardown];
    if (!_running) return;
    [_lastError release]; _lastError = [reason copy];
    OCChannelStatusChanged(self);
    _backoff = MIN(MAX(_backoff * 2, 2.0), 120.0);
    NSUInteger gen = ++_connectGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_backoff * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen == _connectGeneration && _running) [self _connect];
    });
}

#pragma mark - Websocket

- (void)webSocketDidOpen:(OCTLSWebSocket *)ws {}

- (void)webSocket:(OCTLSWebSocket *)ws didCloseWithError:(NSError *)error {
    /* these codes fail the same way on every retry, so stop and show why */
    NSInteger code = [[[error userInfo] objectForKey:OCTLSWebSocketCloseCodeKey] integerValue];
    NSString *fatal = nil;
    switch (code) {
        case 4004: fatal = @"Discord refused the bot token (4004). Check the token in Settings."; break;
        case 4010: case 4011: fatal = [NSString stringWithFormat:@"Discord refused the shard settings (%ld).", (long)code]; break;
        case 4012: fatal = @"Discord refused the gateway version (4012)."; break;
        case 4013: case 4014: fatal = [NSString stringWithFormat:@"Discord refused the intents (%ld). "
            @"Turn on Message Content Intent in the developer portal.", (long)code]; break;
    }
    if (fatal) {
        [self stop];
        [_lastError release]; _lastError = [fatal copy];
        OCChannelStatusChanged(self);
        NSLog(@"[Discord] %@", fatal);
        return;
    }
    [self _reconnectWithReason:[error localizedDescription]];
}

- (void)webSocket:(OCTLSWebSocket *)ws didReceiveText:(NSString *)text {
    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![payload isKindOfClass:[NSDictionary class]]) return;
    NSInteger op = [[payload objectForKey:@"op"] integerValue];
    id seq = [payload objectForKey:@"s"];
    if ([seq isKindOfClass:[NSNumber class]]) _lastSequence = [seq integerValue];

    switch (op) {
        case 10: {
            NSDictionary *hello = [payload objectForKey:@"d"];
            NSTimeInterval interval = [hello isKindOfClass:[NSDictionary class]]
                ? [[hello objectForKey:@"heartbeat_interval"] doubleValue] / 1000.0 : 0;
            if (interval < 1) interval = 41.25;
            _heartbeatInterval = interval;
            [_heartbeatTimer invalidate];
            /* discord asks for a random first delay, so many clients that reconnect at once do not beat together */
            double jitter = arc4random_uniform(10001) / 10000.0;
            _heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:interval * jitter target:self
                                                             selector:@selector(_firstHeartbeat) userInfo:nil repeats:NO];
            [self _sendIdentify];
            break;
        }
        case 11: _awaitingAck = NO; break;
        case 1: [self _sendOp:1 data:_lastSequence >= 0 ? @(_lastSequence) : (id)[NSNull null]]; break;
        case 7: [self _reconnectWithReason:@"Discord asked for a reconnect"]; break;
        case 9: [self _reconnectWithReason:@"Discord invalidated the session"]; break;
        case 0: [self _dispatch:[payload objectForKey:@"t"] data:[payload objectForKey:@"d"]]; break;
    }
}

- (void)_sendOp:(NSInteger)op data:(id)data {
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"op": @(op), @"d": data ?: [NSNull null]} options:0 error:nil];
    if (!json) return;
    NSString *s = [[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] autorelease];
    [_ws sendText:s];
}

- (void)_firstHeartbeat {
    _heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:_heartbeatInterval target:self
                                                     selector:@selector(_heartbeat) userInfo:nil repeats:YES];
    [self _heartbeat];
}

- (void)_heartbeat {
    /* a beat that was never acknowledged means the link is dead */
    if (_awaitingAck) { [self _reconnectWithReason:@"Heartbeat not acknowledged"]; return; }
    _awaitingAck = YES;
    [self _sendOp:1 data:_lastSequence >= 0 ? @(_lastSequence) : (id)[NSNull null]];
}

- (void)_sendIdentify {
    [self _sendOp:2 data:@{
        @"token": _botToken,
        @"intents": @(kDiscordIntents),
        @"properties": @{@"os": @"ios", @"browser": @"legacypodclaw", @"device": @"legacypodclaw"}
    }];
}

- (void)_dispatch:(NSString *)event data:(NSDictionary *)d {
    if (![d isKindOfClass:[NSDictionary class]] || ![event isKindOfClass:[NSString class]]) return;
    if ([event isEqualToString:@"READY"]) {
        _connected = YES;
        _backoff = 0;
        [_lastError release]; _lastError = nil;
        OCChannelStatusChanged(self);
        [_botUserId release];
        _botUserId = [[[[d objectForKey:@"user"] objectForKey:@"id"] description] copy];
    } else if ([event isEqualToString:@"MESSAGE_CREATE"]) {
        [self _handleMessage:d];
    }
}

- (void)_handleMessage:(NSDictionary *)d {
    NSDictionary *author = [d objectForKey:@"author"];
    if (![author isKindOfClass:[NSDictionary class]] || [[author objectForKey:@"bot"] boolValue]) return;
    NSString *authorId = [[author objectForKey:@"id"] description];
    if ([authorId isEqualToString:_botUserId]) return;
    NSString *text = [d objectForKey:@"content"];
    if (![text isKindOfClass:[NSString class]]) return;

    BOOL inGuild = [d objectForKey:@"guild_id"] != nil && [d objectForKey:@"guild_id"] != [NSNull null];
    if (inGuild) {
        BOOL mentioned = NO;
        for (NSDictionary *m in [d objectForKey:@"mentions"])
            if ([m isKindOfClass:[NSDictionary class]] && [[[m objectForKey:@"id"] description] isEqualToString:_botUserId]) mentioned = YES;
        if (!mentioned) return;
        for (NSString *tag in @[[NSString stringWithFormat:@"<@%@>", _botUserId], [NSString stringWithFormat:@"<@!%@>", _botUserId]])
            text = [text stringByReplacingOccurrencesOfString:tag withString:@""];
    }
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([text length] == 0) return;

    OCChannelMessage *msg = [[[OCChannelMessage alloc] init] autorelease];
    msg.channelId = [self channelId];
    msg.chatId = [[d objectForKey:@"channel_id"] description];
    msg.senderId = authorId;
    msg.senderName = [author objectForKey:@"username"];
    msg.text = text;
    msg.messageId = [[d objectForKey:@"id"] description];
    msg.isGroup = inGuild;
    [_messageDelegate channel:self didReceiveMessage:msg];
}

#pragma mark - Sending

- (NSDictionary *)_headers {
    /* discord wants "DiscordBot (url, version)"; the bundle version keeps it current at each release */
    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (![version isKindOfClass:[NSString class]] || [version length] == 0) version = @"0";
    NSString *agent = [NSString stringWithFormat:@"DiscordBot (https://github.com/wrxck/LegacyPodClaw, %@)", version];
    return @{@"Authorization": [@"Bot " stringByAppendingString:_botToken], @"User-Agent": agent};
}

- (void)sendMessage:(NSString *)text toChatId:(NSString *)chatId threadId:(NSString *)threadId {
    if ([chatId length] == 0 || [text length] == 0) return;
    NSString *url = [NSString stringWithFormat:@"%@/channels/%@/messages", kDiscordAPI, chatId];
    NSDictionary *headers = [self _headers];
    OCSendPartsInOrder(OCSplitText(text, kDiscordMaxChars), ^(NSString *part, dispatch_block_t done) {
        /* model output must never ping everyone or a role */
        NSDictionary *body = @{@"content": part, @"allowed_mentions": @{@"parse": @[]}};
        [CPTLSClient postJSON:url headers:headers body:body completion:^(NSDictionary *json, NSError *error) {
            if (error || [json objectForKey:@"code"]) NSLog(@"[Discord] send failed: %@", error ? [error localizedDescription] : [json objectForKey:@"message"]);
            done();
        }];
    });
}

- (void)sendTypingIndicator:(NSString *)chatId {
    if ([chatId length] == 0) return;
    NSString *url = [NSString stringWithFormat:@"%@/channels/%@/typing", kDiscordAPI, chatId];
    [CPTLSClient request:url method:@"POST" headers:[self _headers] body:[NSData data] completion:nil];
}

- (NSDictionary *)statusInfo {
    return @{@"botUserId": _botUserId ?: @"", @"state": _running ? (_connected ? @"connected" : @"connecting") : @"stopped", @"lastError": _lastError ?: @""};
}

@end
