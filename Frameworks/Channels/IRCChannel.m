/* irc channel: in a room the bot answers only lines addressed to its nick; replies are paced to avoid flood kicks */

#import "IRCChannel.h"

static const NSUInteger kIRCMaxLine = 2048;
static const NSUInteger kIRCChunkChars = 380;
static const NSUInteger kIRCMaxReplyLines = 15;
static const NSTimeInterval kIRCLineInterval = 1.0;

@interface OCIRCChannel () {
    NSString *_server;
    int _port;
    BOOL _useTLS;
    NSString *_nickname;
    NSString *_currentNick;
    CPTLSConnection *_conn;
    NSMutableData *_readBuf;
    NSMutableArray *_outQueue;
    NSTimer *_sendTimer;
    BOOL _running, _registered;
    NSTimeInterval _backoff;
    NSUInteger _generation;
    NSString *_lastError;
}
@end

@implementation OCIRCChannel

@synthesize messageDelegate = _messageDelegate;

- (instancetype)initWithServer:(NSString *)server port:(int)port useTLS:(BOOL)useTLS nickname:(NSString *)nick {
    if ((self = [super init])) {
        _server = [server copy];
        _port = port > 0 ? port : (useTLS ? 6697 : 6667);
        _useTLS = useTLS;
        _nickname = [nick copy];
        _readBuf = [[NSMutableData alloc] initWithCapacity:1024];
        _outQueue = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc {
    [self _teardown];
    [_server release]; [_nickname release]; [_currentNick release]; [_password release];
    [_channels release]; [_readBuf release]; [_outQueue release]; [_lastError release];
    [super dealloc];
}

- (NSString *)channelId { return @"irc"; }
- (BOOL)isConnected { return _registered; }
- (BOOL)isConfigured { return [_server length] > 0 && [_nickname length] > 0; }

- (void)start {
    if (_running || ![self isConfigured]) return;
    _running = YES;
    _backoff = 0;
    [self _connect];
}

- (void)stop {
    if (_conn && _registered) [_conn sendData:[@"QUIT :bye\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
    _running = NO;
    _generation++;
    [self _teardown];
}

- (void)_teardown {
    _registered = NO;
    OCChannelStatusChanged(self);
    [_sendTimer invalidate]; _sendTimer = nil;
    [_outQueue removeAllObjects];
    _conn.delegate = nil;
    [_conn close];
    [_conn release]; _conn = nil;
    [_readBuf setLength:0];
}

- (void)_connect {
    [self _teardown];
    [_currentNick release];
    _currentNick = [_nickname copy];
    _conn = [[CPTLSConnection alloc] initWithHost:_server port:_port useTLS:_useTLS];
    _conn.delegate = self;
    [_conn open];
}

#pragma mark - Connection

- (void)connectionDidOpen:(CPTLSConnection *)connection {
    if ([_password length]) [self _sendNow:[NSString stringWithFormat:@"PASS %@", _password]];
    [self _sendNow:[NSString stringWithFormat:@"NICK %@", _currentNick]];
    [self _sendNow:[NSString stringWithFormat:@"USER %@ 0 * :LegacyPodClaw", _currentNick]];
}

- (void)connection:(CPTLSConnection *)connection didCloseWithError:(NSError *)error {
    [_lastError release];
    _lastError = [[error localizedDescription] copy];
    [self _teardown];
    OCChannelStatusChanged(self);
    if (!_running) return;
    _backoff = MIN(MAX(_backoff * 2, 5.0), 300.0);
    NSUInteger gen = ++_generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(_backoff * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (gen == _generation && _running) [self _connect];
    });
}

- (void)connection:(CPTLSConnection *)connection didReceiveData:(NSData *)data {
    [_readBuf appendData:data];
    while (YES) {
        const char *p = [_readBuf bytes];
        NSUInteger len = [_readBuf length], eol = NSNotFound;
        for (NSUInteger i = 0; i < len; i++) if (p[i] == '\n') { eol = i; break; }
        if (eol == NSNotFound) {
            if (len > kIRCMaxLine) [_readBuf setLength:0];
            return;
        }
        NSUInteger end = (eol > 0 && p[eol - 1] == '\r') ? eol - 1 : eol;
        NSString *line = [[NSString alloc] initWithBytes:p length:end encoding:NSUTF8StringEncoding];
        if (!line) line = [[NSString alloc] initWithBytes:p length:end encoding:NSISOLatin1StringEncoding];
        [_readBuf replaceBytesInRange:NSMakeRange(0, eol + 1) withBytes:NULL length:0];
        if (end <= kIRCMaxLine) [self _handleLine:line];
        [line release];
        if (!_conn) return;
    }
}

#pragma mark - Protocol

- (void)_handleLine:(NSString *)line {
    NSString *prefix = nil;
    NSString *rest = line;
    if ([rest hasPrefix:@":"]) {
        NSRange sp = [rest rangeOfString:@" "];
        if (sp.location == NSNotFound) return;
        prefix = [rest substringWithRange:NSMakeRange(1, sp.location - 1)];
        rest = [rest substringFromIndex:sp.location + 1];
    }
    NSString *trailing = nil;
    NSRange colon = [rest rangeOfString:@" :"];
    if (colon.location != NSNotFound) {
        trailing = [rest substringFromIndex:colon.location + 2];
        rest = [rest substringToIndex:colon.location];
    } else if ([rest hasPrefix:@":"]) {
        trailing = [rest substringFromIndex:1];
        rest = @"";
    }
    NSArray *parts = [rest componentsSeparatedByString:@" "];
    NSString *command = [[parts objectAtIndex:0] uppercaseString];

    if ([command isEqualToString:@"PING"]) {
        NSString *token = trailing ?: ([parts count] > 1 ? [parts objectAtIndex:1] : @"");
        [self _sendNow:[NSString stringWithFormat:@"PONG :%@", token]];
    } else if ([command isEqualToString:@"001"]) {
        _registered = YES;
        _backoff = 0;
        [_lastError release]; _lastError = nil;
        OCChannelStatusChanged(self);
        if ([parts count] > 1) { [_currentNick release]; _currentNick = [[parts objectAtIndex:1] copy]; }
        for (NSString *ch in _channels) {
            if ([ch hasPrefix:@"#"] || [ch hasPrefix:@"&"]) [self _sendNow:[NSString stringWithFormat:@"JOIN %@", ch]];
        }
    } else if ([command isEqualToString:@"433"] && !_registered) {
        NSString *next = [_currentNick stringByAppendingString:@"_"];
        [_currentNick release];
        _currentNick = [next copy];
        [self _sendNow:[NSString stringWithFormat:@"NICK %@", _currentNick]];
    } else if ([command isEqualToString:@"NICK"] && prefix) {
        /* services can rename the bot after registration; follow it or direct messages look like channel noise */
        NSString *oldNick = [[prefix componentsSeparatedByString:@"!"] objectAtIndex:0];
        NSString *newNick = trailing ?: ([parts count] > 1 ? [parts objectAtIndex:1] : nil);
        if ([newNick length] && [oldNick caseInsensitiveCompare:_currentNick] == NSOrderedSame) {
            [_currentNick release];
            _currentNick = [newNick copy];
        }
    } else if ([command isEqualToString:@"PRIVMSG"] && [parts count] > 1 && prefix && trailing) {
        [self _handlePrivmsg:trailing from:prefix target:[parts objectAtIndex:1]];
    }
}

- (void)_handlePrivmsg:(NSString *)text from:(NSString *)prefix target:(NSString *)target {
    if ([text hasPrefix:@"\x01"]) return;
    NSRange bang = [prefix rangeOfString:@"!"];
    NSString *nick = bang.location != NSNotFound ? [prefix substringToIndex:bang.location] : prefix;
    BOOL direct = [target caseInsensitiveCompare:_currentNick] == NSOrderedSame;

    if (!direct) {
        BOOL addressed = NO;
        for (NSString *sep in @[@":", @","]) {
            NSString *lead = [_currentNick stringByAppendingString:sep];
            if ([text length] >= [lead length] &&
                [[text substringToIndex:[lead length]] caseInsensitiveCompare:lead] == NSOrderedSame) {
                text = [text substringFromIndex:[lead length]];
                addressed = YES;
                break;
            }
        }
        if (!addressed) return;
    }
    text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if ([text length] == 0) return;

    OCChannelMessage *msg = [[[OCChannelMessage alloc] init] autorelease];
    msg.channelId = [self channelId];
    msg.chatId = direct ? nick : target;
    msg.senderId = nick;
    msg.senderAddress = prefix;
    msg.senderName = nick;
    msg.text = text;
    msg.isGroup = !direct;
    [_messageDelegate channel:self didReceiveMessage:msg];
}

#pragma mark - Sending

- (void)_sendNow:(NSString *)line {
    /* a line break inside a parameter would let text inject a second irc command */
    NSString *clean = [[line componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
    [_conn sendData:[[clean stringByAppendingString:@"\r\n"] dataUsingEncoding:NSUTF8StringEncoding]];
}

- (void)sendMessage:(NSString *)text toChatId:(NSString *)chatId threadId:(NSString *)threadId {
    if (!_registered || [chatId length] == 0 || [chatId rangeOfCharacterFromSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].location != NSNotFound) return;
    NSUInteger count = 0;
    for (NSString *raw in [OCStripMarkdown(text) componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([line length] == 0) continue;
        for (NSString *part in OCSplitText(line, kIRCChunkChars)) {
            if (count++ >= kIRCMaxReplyLines) {
                [_outQueue addObject:[NSString stringWithFormat:@"PRIVMSG %@ :[reply cut short]", chatId]];
                [self _pumpQueue];
                return;
            }
            [_outQueue addObject:[NSString stringWithFormat:@"PRIVMSG %@ :%@", chatId, part]];
        }
    }
    [self _pumpQueue];
}

- (void)_pumpQueue {
    if (_sendTimer || [_outQueue count] == 0) return;
    [self _sendNext];
}

- (void)_sendNext {
    _sendTimer = nil;
    if ([_outQueue count] == 0 || !_conn) return;
    [self _sendNow:[_outQueue objectAtIndex:0]];
    [_outQueue removeObjectAtIndex:0];
    if ([_outQueue count]) {
        _sendTimer = [NSTimer scheduledTimerWithTimeInterval:kIRCLineInterval target:self
                                                    selector:@selector(_sendNext) userInfo:nil repeats:NO];
    }
}

- (NSDictionary *)statusInfo {
    return @{@"server": _server ?: @"", @"nick": _currentNick ?: @"",
             @"state": _running ? (_registered ? @"connected" : @"connecting") : @"stopped", @"lastError": _lastError ?: @""};
}

@end
