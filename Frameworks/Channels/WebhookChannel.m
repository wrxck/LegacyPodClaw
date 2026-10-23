/* webhook channel; https callbacks go through wolfssl, plain http is for the local network only */

#import "HTTPFetch.h"
#import "WebhookChannel.h"
#import "TLSClient.h"

static const NSUInteger kWebhookMaxText = 8000;

@interface OCWebhookChannel () {
    NSString *_callbackURL;
    NSString *_token;
    BOOL _running;
}
@end

@implementation OCWebhookChannel

@synthesize messageDelegate = _messageDelegate;

- (instancetype)initWithCallbackURL:(NSString *)callbackURL bearerToken:(NSString *)token {
    if ((self = [super init])) {
        _callbackURL = [callbackURL copy];
        _token = [token copy];
    }
    return self;
}

- (void)dealloc { [_callbackURL release]; [_token release]; [super dealloc]; }

- (NSString *)channelId { return @"webhook"; }
- (BOOL)isConnected { return _running; }
- (BOOL)isConfigured {
    NSString *scheme = [[[NSURL URLWithString:_callbackURL] scheme] lowercaseString];
    return [scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"];
}
- (void)start { _running = [self isConfigured]; OCChannelStatusChanged(self); }
- (void)stop { _running = NO; OCChannelStatusChanged(self); }

static NSString *StringField(NSDictionary *d, NSString *key) {
    id v = [d objectForKey:key];
    if ([v isKindOfClass:[NSNumber class]]) v = [v description];
    return [v isKindOfClass:[NSString class]] && [v length] && [v length] <= 256 ? v : nil;
}

- (NSString *)handleInboundPayload:(NSDictionary *)payload {
    if (!_running) return @"The webhook channel is off";
    if (![payload isKindOfClass:[NSDictionary class]]) return @"Body must be a JSON object";
    id text = [payload objectForKey:@"text"];
    if (![text isKindOfClass:[NSString class]] || [text length] == 0) return @"Missing 'text'";
    if ([text length] > kWebhookMaxText) return @"'text' is too long";

    OCChannelMessage *msg = [[[OCChannelMessage alloc] init] autorelease];
    msg.channelId = [self channelId];
    msg.chatId = StringField(payload, @"chatId") ?: @"default";
    msg.senderId = StringField(payload, @"senderId") ?: @"webhook";
    msg.senderName = StringField(payload, @"senderName") ?: msg.senderId;
    msg.text = text;
    [_messageDelegate channel:self didReceiveMessage:msg];
    return nil;
}

- (void)sendMessage:(NSString *)text toChatId:(NSString *)chatId threadId:(NSString *)threadId {
    if (!_running || [text length] == 0) return;
    NSDictionary *body = @{@"text": text, @"chatId": chatId ?: @"default"};
    NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    NSMutableDictionary *headers = [NSMutableDictionary dictionaryWithObject:@"application/json" forKey:@"Content-Type"];
    if ([_token length]) [headers setObject:[@"Bearer " stringByAppendingString:_token] forKey:@"Authorization"];

    CPFetch(_callbackURL, @"POST", headers, data, 20, ^(NSData *resp, NSInteger status, NSError *error) {
        if (error || status >= 300) NSLog(@"[Webhook] callback failed: %@", error ? [error localizedDescription] : @(status));
    });
}

- (NSDictionary *)statusInfo {
    /* a callback url that is not http or https never starts, so say so instead of connecting for ever */
    if (![self isConfigured])
        return @{@"callback": @"", @"state": @"stopped", @"lastError": @"The callback URL must start with http:// or https://."};
    return @{@"callback": [[NSURL URLWithString:_callbackURL] host] ?: @"", @"state": _running ? @"connected" : @"stopped"};
}

@end
