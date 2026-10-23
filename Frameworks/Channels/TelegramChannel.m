/* telegram bot channel over wolfssl https */

#import "TelegramChannel.h"
#import "TLSClient.h"
#import "SharedFiles.h"

static NSString *const kTelegramAPI = @"https://api.telegram.org/bot";
static const int kPollTimeout = 25;
static const NSUInteger kTelegramMaxChars = 4000;
/* the last confirmed update id, so a restart does not fetch and answer an update again */
static NSString *const kTelegramStateFile = @"telegram.plist";
/* updates queued while the app was closed are stale; answering them hours later confuses people */
static const NSTimeInterval kMaxMessageAge = 600;

@interface OCTelegramChannel () {
    NSString *_botToken;
    BOOL _running;
    BOOL _connected;
    BOOL _quickPoll;
    BOOL _shownConnected;
    long long _lastUpdateId;
    NSUInteger _pollGeneration;
    NSTimeInterval _backoff;
    NSString *_lastError;
}
@end

/* plain words for the status row; the http code stays so a search finds the cause */
static NSString *TelegramErrorText(NSInteger status, id json) {
    id desc = [json isKindOfClass:[NSDictionary class]] ? [json objectForKey:@"description"] : nil;
    NSString *detail = [desc isKindOfClass:[NSString class]] && [desc length] ? [NSString stringWithFormat:@": %@", desc] : @"";
    switch (status) {
        case 401: return @"Telegram refused the bot token (HTTP 401). Check the Bot Token in Settings.";
        case 404: return @"Telegram does not know this bot token (HTTP 404). Check the Bot Token in Settings.";
        case 409: return [NSString stringWithFormat:@"Telegram refused the poll (HTTP 409)%@. "
                          @"Another client or a webhook uses this bot.", detail];
    }
    return [NSString stringWithFormat:@"Telegram sent an error (HTTP %ld)%@", (long)status, detail];
}

@implementation OCTelegramChannel

@synthesize messageDelegate = _messageDelegate;

- (instancetype)initWithBotToken:(NSString *)token {
    if ((self = [super init])) {
        _botToken = [token copy];
        /* the bot id is the public part of the token; an offset from another bot would skip this bot's updates */
        NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:CPSharedPath(kTelegramStateFile)];
        if ([[state objectForKey:@"bot"] isEqual:[self _botId]])
            _lastUpdateId = [[state objectForKey:@"lastUpdateId"] longLongValue];
    }
    return self;
}

- (NSString *)_botId {
    NSRange colon = [_botToken rangeOfString:@":"];
    return colon.location == NSNotFound ? @"" : [_botToken substringToIndex:colon.location];
}

- (void)_saveOffset {
    if (!CPWriteSharedPlist(kTelegramStateFile, @{@"bot": [self _botId], @"lastUpdateId": @(_lastUpdateId)}))
        NSLog(@"[Telegram] could not save the update offset");
}

- (void)dealloc {
    [_botToken release]; [_lastError release];
    [super dealloc];
}

- (NSString *)channelId { return @"telegram"; }
- (BOOL)isConnected { return _connected; }
- (BOOL)isConfigured { return [_botToken length] > 0; }

- (void)start {
    if (_running || ![self isConfigured]) return;
    _running = YES;
    _backoff = 0;
    /* a long poll can take 25 s to answer, so the first call returns at once to show the link works */
    _quickPoll = YES;
    _shownConnected = NO;
    _pollGeneration++;
    OCChannelStatusChanged(self);
    [self _poll];
}

- (void)stop {
    _running = NO;
    _connected = NO;
    _pollGeneration++;
    OCChannelStatusChanged(self);
}

- (void)_setError:(NSString *)error {
    /* each poll clears the error, so post only a real change or every visible table reloads every 25 s */
    BOOL changed = !(error == _lastError || [error isEqualToString:_lastError]) || _connected != _shownConnected;
    [_lastError release];
    _lastError = [error copy];
    _shownConnected = _connected;
    if (changed) OCChannelStatusChanged(self);
}

- (void)_poll {
    if (!_running) return;
    NSUInteger gen = _pollGeneration;
    NSString *url = [NSString stringWithFormat:@"%@%@/getUpdates?timeout=%d&offset=%lld&allowed_updates=%%5B%%22message%%22%%5D",
                     kTelegramAPI, _botToken, _quickPoll ? 0 : kPollTimeout, _lastUpdateId + 1];
    [CPTLSClient request:url method:@"GET" headers:nil body:nil
              completion:^(NSData *data, NSInteger status, NSError *error) {
        if (gen != _pollGeneration || !_running) return;
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        BOOL ok = !error && status == 200 && [json isKindOfClass:[NSDictionary class]] && [[json objectForKey:@"ok"] boolValue];
        if (!ok) {
            _connected = NO;
            [self _setError:error ? [error localizedDescription] : TelegramErrorText(status, json)];
            if (status == 401 || status == 404) {
                /* the token is wrong; polling again would only repeat the failure */
                NSLog(@"[Telegram] the bot token was rejected, stopping");
                _running = NO;
                return;
            }
            _backoff = MIN(MAX(_backoff * 2, 5.0), 120.0);
            /* a quick first poll shows the link as connected again without a full long poll wait */
            _quickPoll = YES;
            [self _pollAfter:_backoff];
            return;
        }
        _connected = YES;
        _quickPoll = NO;
        _backoff = 0;
        [self _setError:nil];
        NSArray *updates = [json objectForKey:@"result"];
        long long before = _lastUpdateId;
        if ([updates isKindOfClass:[NSArray class]]) {
            for (NSDictionary *update in updates) {
                if (![update isKindOfClass:[NSDictionary class]]) continue;
                long long uid = [[update objectForKey:@"update_id"] longLongValue];
                if (uid > _lastUpdateId) _lastUpdateId = uid;
                NSDictionary *msg = [update objectForKey:@"message"];
                if ([msg isKindOfClass:[NSDictionary class]]) [self _processMessage:msg];
            }
        }
        if (_lastUpdateId != before) [self _saveOffset];
        [self _pollAfter:0.2];
    }];
}

- (void)_pollAfter:(NSTimeInterval)delay {
    NSUInteger gen = _pollGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen == _pollGeneration) [self _poll];
    });
}

- (void)_processMessage:(NSDictionary *)msg {
    NSString *text = [msg objectForKey:@"text"];
    if (![text isKindOfClass:[NSString class]] || [text length] == 0) return;
    NSTimeInterval sent = [[msg objectForKey:@"date"] doubleValue];
    if (sent > 0 && [[NSDate date] timeIntervalSince1970] - sent > kMaxMessageAge) return;

    NSDictionary *chat = [msg objectForKey:@"chat"];
    NSDictionary *from = [msg objectForKey:@"from"];
    if (![chat isKindOfClass:[NSDictionary class]] || ![from isKindOfClass:[NSDictionary class]]) return;
    if ([[from objectForKey:@"is_bot"] boolValue]) return;

    OCChannelMessage *cmsg = [[[OCChannelMessage alloc] init] autorelease];
    cmsg.channelId = [self channelId];
    cmsg.chatId = [[chat objectForKey:@"id"] description];
    cmsg.senderId = [[from objectForKey:@"id"] description];
    cmsg.senderName = [from objectForKey:@"first_name"] ?: [from objectForKey:@"username"];
    cmsg.text = text;
    cmsg.messageId = [[msg objectForKey:@"message_id"] description];
    cmsg.isGroup = ![[chat objectForKey:@"type"] isEqualToString:@"private"];
    id thread = [msg objectForKey:@"message_thread_id"];
    if (thread && [[msg objectForKey:@"is_topic_message"] boolValue]) cmsg.threadId = [thread description];
    [_messageDelegate channel:self didReceiveMessage:cmsg];
}

#pragma mark - Sending

- (void)sendMessage:(NSString *)text toChatId:(NSString *)chatId threadId:(NSString *)threadId {
    if ([chatId length] == 0 || [text length] == 0) return;
    /* plain text: model markdown often breaks telegram's parser and the whole send fails */
    OCSendPartsInOrder(OCSplitText(text, kTelegramMaxChars), ^(NSString *part, dispatch_block_t done) {
        NSMutableDictionary *body = [NSMutableDictionary dictionaryWithObjectsAndKeys:chatId, @"chat_id", part, @"text", nil];
        if (threadId) [body setObject:threadId forKey:@"message_thread_id"];
        [self _apiCall:@"sendMessage" body:body done:done];
    });
}

- (void)sendTypingIndicator:(NSString *)chatId {
    if ([chatId length]) [self _apiCall:@"sendChatAction" body:@{@"chat_id": chatId, @"action": @"typing"} done:nil];
}

- (NSDictionary *)statusInfo {
    return @{@"polling": @(_running), @"state": _running ? (_connected ? @"connected" : @"connecting") : @"stopped", @"lastError": _lastError ?: @""};
}

- (void)_apiCall:(NSString *)method body:(NSDictionary *)body done:(dispatch_block_t)done {
    NSString *url = [NSString stringWithFormat:@"%@%@/%@", kTelegramAPI, _botToken, method];
    [CPTLSClient postJSON:url headers:nil body:body completion:^(NSDictionary *json, NSError *error) {
        if (error || ![[json objectForKey:@"ok"] boolValue])
            NSLog(@"[Telegram] %@ failed: %@", method, error ? [error localizedDescription] : [json objectForKey:@"description"]);
        if (done) done();
    }];
}

@end
