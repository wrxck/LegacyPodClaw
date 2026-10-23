/* channel registry and the text helpers the channels share */

#import "ChannelManager.h"

NSString *const OCChannelStatusDidChangeNotification = @"OCChannelStatusDidChangeNotification";

void OCChannelStatusChanged(id<OCChannel> channel) {
    NSString *cid = [[[channel channelId] copy] autorelease];
    /* async, so an observer never runs inside the channel's own state change */
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:OCChannelStatusDidChangeNotification object:cid];
    });
}

@implementation OCChannelMessage

- (instancetype)init {
    if ((self = [super init])) { _timestamp = [[NSDate date] retain]; }
    return self;
}

- (void)dealloc {
    [_channelId release]; [_chatId release]; [_threadId release];
    [_senderId release]; [_senderAddress release]; [_senderName release];
    [_text release]; [_messageId release]; [_timestamp release];
    [super dealloc];
}

@end

@interface OCChannelManager () {
    NSMutableDictionary *_channelMap;
}
@end

@implementation OCChannelManager

- (instancetype)init {
    if ((self = [super init])) {
        _channelMap = [[NSMutableDictionary alloc] initWithCapacity:8];
    }
    return self;
}

- (void)dealloc {
    [self removeAllChannels];
    [_channelMap release];
    [super dealloc];
}

- (BOOL)registerChannel:(id<OCChannel>)channel {
    NSString *cid = [channel channelId];
    if ([cid length] == 0 || [_channelMap objectForKey:cid]) return NO;
    channel.messageDelegate = self;
    [_channelMap setObject:channel forKey:cid];
    OCChannelStatusChanged(channel);
    return YES;
}

- (void)removeChannel:(NSString *)channelId {
    id<OCChannel> ch = [_channelMap objectForKey:channelId];
    if (!ch) return;
    [ch stop];
    ch.messageDelegate = nil;
    OCChannelStatusChanged(ch);
    [_channelMap removeObjectForKey:channelId];
}

- (void)removeAllChannels {
    for (NSString *cid in [_channelMap allKeys]) [self removeChannel:cid];
}

- (id<OCChannel>)channelForId:(NSString *)channelId { return [_channelMap objectForKey:channelId]; }
- (NSArray *)channels { return [_channelMap allValues]; }

- (void)startAll {
    for (id<OCChannel> ch in [_channelMap allValues]) if ([ch isConfigured]) [ch start];
}

- (void)stopAll {
    for (id<OCChannel> ch in [_channelMap allValues]) [ch stop];
}

- (void)sendMessage:(NSString *)text channelId:(NSString *)channelId
             chatId:(NSString *)chatId threadId:(NSString *)threadId {
    if ([text length] == 0 || [chatId length] == 0) return;
    [[_channelMap objectForKey:channelId] sendMessage:text toChatId:chatId threadId:threadId];
}

- (void)sendTypingIndicator:(NSString *)channelId chatId:(NSString *)chatId {
    id<OCChannel> ch = [_channelMap objectForKey:channelId];
    if ([ch respondsToSelector:@selector(sendTypingIndicator:)]) [ch sendTypingIndicator:chatId];
}

- (void)channel:(id<OCChannel>)channel didReceiveMessage:(OCChannelMessage *)message {
    /* a plugin channel must not speak for another channel id */
    if (![message.channelId isEqualToString:[channel channelId]]) message.channelId = [channel channelId];
    [_delegate channelManager:self didReceiveMessage:message];
}

- (NSDictionary *)allChannelStatus {
    NSMutableDictionary *status = [NSMutableDictionary dictionary];
    for (id<OCChannel> ch in [_channelMap allValues]) {
        NSMutableDictionary *s = [NSMutableDictionary dictionary];
        [s setObject:@([ch isConnected]) forKey:@"connected"];
        [s setObject:@([ch isConfigured]) forKey:@"configured"];
        if ([ch respondsToSelector:@selector(statusInfo)]) {
            NSDictionary *extra = [ch statusInfo];
            if ([extra isKindOfClass:[NSDictionary class]]) [s addEntriesFromDictionary:extra];
        }
        [status setObject:s forKey:[ch channelId]];
    }
    return status;
}

@end

#pragma mark - Text helpers

NSString *OCStripMarkdown(NSString *md) {
    if (!md) return @"";
    NSMutableString *r = [[md mutableCopy] autorelease];
    for (NSString *mark in @[@"```", @"**", @"__", @"`"])
        [r replaceOccurrencesOfString:mark withString:@"" options:0 range:NSMakeRange(0, [r length])];
    NSMutableArray *lines = [NSMutableArray array];
    for (NSString *line in [r componentsSeparatedByString:@"\n"]) {
        NSString *l = line;
        while ([l hasPrefix:@"#"]) l = [l substringFromIndex:1];
        [lines addObject:[l length] < [line length] ? [l stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] : l];
    }
    return [lines componentsJoinedByString:@"\n"];
}

static void SendPartFrom(NSArray *parts, NSUInteger index, OCPartSender send) {
    if (index >= [parts count]) return;
    send([parts objectAtIndex:index], ^{ SendPartFrom(parts, index + 1, send); });
}

void OCSendPartsInOrder(NSArray *parts, OCPartSender send) {
    /* each request opens its own connection, so parts sent together can arrive in any order */
    SendPartFrom(parts, 0, [[send copy] autorelease]);
}

NSArray *OCSplitText(NSString *text, NSUInteger maxChars) {
    NSMutableArray *parts = [NSMutableArray array];
    if (maxChars == 0) maxChars = 1;
    NSString *rest = text ?: @"";
    while ([rest length] > maxChars) {
        NSRange window = NSMakeRange(0, maxChars);
        NSRange cut = [rest rangeOfString:@"\n" options:NSBackwardsSearch range:window];
        if (cut.location == NSNotFound || cut.location < maxChars / 2)
            cut = [rest rangeOfString:@" " options:NSBackwardsSearch range:window];
        NSUInteger at = (cut.location == NSNotFound || cut.location == 0) ? maxChars : cut.location;
        /* never split a surrogate pair */
        at = [rest rangeOfComposedCharacterSequenceAtIndex:at].location ?: at;
        [parts addObject:[rest substringToIndex:at]];
        rest = [[rest substringFromIndex:at] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    if ([rest length]) [parts addObject:rest];
    return parts;
}

NSArray *OCListFromString(NSString *value) {
    if (![value isKindOfClass:[NSString class]]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    NSCharacterSet *seps = [NSCharacterSet characterSetWithCharactersInString:@", \n\t;"];
    for (NSString *item in [value componentsSeparatedByCharactersInSet:seps]) {
        if ([item length]) [out addObject:item];
    }
    return out;
}
