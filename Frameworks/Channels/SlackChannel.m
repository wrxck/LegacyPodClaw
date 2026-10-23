/* slack socket mode client; channel messages are answered only when the app is mentioned */

#import "SlackChannel.h"
#import "TLSClient.h"

static NSString *const kSlackAPI = @"https://slack.com/api";
static const NSUInteger kSlackMaxChars = 3500;

@interface OCSlackChannel () {
    NSString *_appToken;
    NSString *_botToken;
    NSString *_botUserId;
    OCTLSWebSocket *_ws;
    BOOL _running, _connected;
    NSUInteger _generation;
    NSTimeInterval _backoff;
    NSString *_lastError;
}
@end

@implementation OCSlackChannel

@synthesize messageDelegate = _messageDelegate;

- (instancetype)initWithAppToken:(NSString *)appToken botToken:(NSString *)botToken {
    if ((self = [super init])) {
        _appToken = [appToken copy];
        _botToken = [botToken copy];
    }
    return self;
}

- (void)dealloc {
    [self _teardown];
    [_appToken release]; [_botToken release]; [_botUserId release]; [_lastError release];
    [super dealloc];
}

- (NSString *)channelId { return @"slack"; }
- (BOOL)isConnected { return _connected; }
- (BOOL)isConfigured { return [_appToken length] > 0 && [_botToken length] > 0; }

- (void)start {
    if (_running || ![self isConfigured]) return;
    _running = YES;
    _backoff = 0;
    [self _connect];
}

- (void)stop {
    _running = NO;
    _generation++;
    [self _teardown];
    OCChannelStatusChanged(self);
}

- (void)_teardown {
    _connected = NO;
    _ws.delegate = nil;
    [_ws close];
    [_ws release]; _ws = nil;
}

- (void)_setError:(NSString *)error {
    [_lastError release];
    _lastError = [error copy];
    OCChannelStatusChanged(self);
}

- (void)_retry:(NSString *)reason {
    [self _teardown];
    [self _setError:reason];
    if (!_running) return;
    _backoff = MIN(MAX(_backoff * 2, 3.0), 120.0);
    NSUInteger gen = ++_generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_backoff * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen == _generation && _running) [self _connect];
    });
}

/* slack answers these on every retry, so retrying only repeats the failure */
static BOOL SlackTokenRefused(NSString *error) {
    return [@[@"invalid_auth", @"not_authed", @"not_allowed_token_type", @"account_inactive", @"token_revoked",
              @"token_expired"] containsObject:error ?: @""];
}

- (void)_stopWithError:(NSString *)reason {
    [self stop];
    [self _setError:reason];
    NSLog(@"[Slack] %@", reason);
}

- (void)_connect {
    [self _teardown];
    NSUInteger gen = ++_generation;
    NSDictionary *botAuth = @{@"Authorization": [@"Bearer " stringByAppendingString:_botToken]};
    [CPTLSClient postJSON:[kSlackAPI stringByAppendingString:@"/auth.test"] headers:botAuth body:@{}
               completion:^(NSDictionary *json, NSError *error) {
        if (gen != _generation) return;
        if (error || ![[json objectForKey:@"ok"] boolValue]) {
            NSString *code = [[json objectForKey:@"error"] description];
            if (!error && SlackTokenRefused(code)) {
                [self _stopWithError:[NSString stringWithFormat:@"Slack refused the bot token (%@). Check the Bot Token in Settings.", code]];
                return;
            }
            [self _retry:error ? [error localizedDescription] : [NSString stringWithFormat:@"Slack did not accept the bot token check (%@)", code]];
            return;
        }
        [_botUserId release];
        _botUserId = [[[json objectForKey:@"user_id"] description] copy];
        [self _openSocket:gen];
    }];
}

- (void)_openSocket:(NSUInteger)gen {
    NSDictionary *appAuth = @{@"Authorization": [@"Bearer " stringByAppendingString:_appToken]};
    [CPTLSClient postJSON:[kSlackAPI stringByAppendingString:@"/apps.connections.open"] headers:appAuth body:@{}
               completion:^(NSDictionary *json, NSError *error) {
        if (gen != _generation) return;
        NSString *url = [json objectForKey:@"url"];
        if (error || ![[json objectForKey:@"ok"] boolValue] || ![url isKindOfClass:[NSString class]]) {
            NSString *code = [[json objectForKey:@"error"] description];
            if (!error && SlackTokenRefused(code)) {
                [self _stopWithError:[NSString stringWithFormat:@"Slack refused the app token (%@). Check the App Token in Settings.", code]];
                return;
            }
            [self _retry:error ? [error localizedDescription] : [NSString stringWithFormat:@"Slack did not open a socket (%@)", code]];
            return;
        }
        _ws = [[OCTLSWebSocket alloc] initWithURL:[NSURL URLWithString:url]];
        _ws.delegate = self;
        [_ws open];
    }];
}

#pragma mark - Websocket

- (void)webSocketDidOpen:(OCTLSWebSocket *)ws {}

- (void)webSocket:(OCTLSWebSocket *)ws didCloseWithError:(NSError *)error {
    [self _retry:[error localizedDescription]];
}

- (void)webSocket:(OCTLSWebSocket *)ws didReceiveText:(NSString *)text {
    NSDictionary *env = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![env isKindOfClass:[NSDictionary class]]) return;
    NSString *envelopeId = [env objectForKey:@"envelope_id"];
    /* slack resends any envelope that is not acknowledged within a few seconds */
    if ([envelopeId isKindOfClass:[NSString class]]) {
        NSData *ack = [NSJSONSerialization dataWithJSONObject:@{@"envelope_id": envelopeId} options:0 error:nil];
        [_ws sendText:[[[NSString alloc] initWithData:ack encoding:NSUTF8StringEncoding] autorelease]];
    }
    NSString *type = [env objectForKey:@"type"];
    if ([type isEqualToString:@"hello"]) {
        _connected = YES;
        _backoff = 0;
        [self _setError:nil];
    } else if ([type isEqualToString:@"disconnect"]) {
        _backoff = 0;
        [self _retry:@"Slack asked for a reconnect"];
    } else if ([type isEqualToString:@"events_api"]) {
        NSDictionary *payload = [env objectForKey:@"payload"];
        NSDictionary *event = [payload isKindOfClass:[NSDictionary class]] ? [payload objectForKey:@"event"] : nil;
        if ([event isKindOfClass:[NSDictionary class]]) [self _handleEvent:event];
    }
}

- (void)_handleEvent:(NSDictionary *)event {
    NSString *type = [event objectForKey:@"type"];
    if ([event objectForKey:@"bot_id"] || [event objectForKey:@"subtype"]) return;
    NSString *user = [[event objectForKey:@"user"] description];
    if ([user length] == 0 || [user isEqualToString:_botUserId]) return;

    BOOL direct = [[event objectForKey:@"channel_type"] isEqual:@"im"];
    /* a mention in a channel arrives as app_mention; plain message events are used only for direct messages */
    if (!([type isEqualToString:@"app_mention"] || ([type isEqualToString:@"message"] && direct))) return;

    NSString *text = [event objectForKey:@"text"];
    if (![text isKindOfClass:[NSString class]]) return;
    if (_botUserId) text = [text stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"<@%@>", _botUserId] withString:@""];
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([text length] == 0) return;

    OCChannelMessage *msg = [[[OCChannelMessage alloc] init] autorelease];
    msg.channelId = [self channelId];
    msg.chatId = [[event objectForKey:@"channel"] description];
    msg.senderId = user;
    msg.text = text;
    msg.messageId = [event objectForKey:@"ts"];
    msg.threadId = [event objectForKey:@"thread_ts"] ?: (direct ? nil : [event objectForKey:@"ts"]);
    msg.isGroup = !direct;
    [_messageDelegate channel:self didReceiveMessage:msg];
}

#pragma mark - Sending

- (void)sendMessage:(NSString *)text toChatId:(NSString *)chatId threadId:(NSString *)threadId {
    if ([chatId length] == 0 || [text length] == 0) return;
    NSDictionary *auth = @{@"Authorization": [@"Bearer " stringByAppendingString:_botToken]};
    OCSendPartsInOrder(OCSplitText(text, kSlackMaxChars), ^(NSString *part, dispatch_block_t done) {
        NSMutableDictionary *body = [NSMutableDictionary dictionaryWithObjectsAndKeys:chatId, @"channel", part, @"text", nil];
        if (threadId) [body setObject:threadId forKey:@"thread_ts"];
        [CPTLSClient postJSON:[kSlackAPI stringByAppendingString:@"/chat.postMessage"] headers:auth body:body
                   completion:^(NSDictionary *json, NSError *error) {
            if (error || ![[json objectForKey:@"ok"] boolValue])
                NSLog(@"[Slack] send failed: %@", error ? [error localizedDescription] : [json objectForKey:@"error"]);
            done();
        }];
    });
}

- (NSDictionary *)statusInfo {
    return @{@"botUserId": _botUserId ?: @"", @"state": _running ? (_connected ? @"connected" : @"connecting") : @"stopped", @"lastError": _lastError ?: @""};
}

@end
