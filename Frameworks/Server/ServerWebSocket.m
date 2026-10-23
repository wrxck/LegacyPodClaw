#import "ServerWebSocket.h"

static const NSUInteger kDefaultMaxMessageSize = 256 * 1024;
static const NSUInteger kDefaultMaxPendingWrite = 2 * 1024 * 1024;

/* rfc 6455 7.4: 1004-1006, 1015 and unassigned codes must not go on the wire, so answer them with 1002 */
static uint16_t WSEchoCode(uint16_t c) {
    return ((c >= 1000 && c <= 1003) || (c >= 1007 && c <= 1014) || (c >= 3000 && c <= 4999)) ? c : 1002;
}
enum { kReadChunk = 4096 };

enum {
    kOpContinuation = 0x0,
    kOpText = 0x1,
    kOpBinary = 0x2,
    kOpClose = 0x8,
    kOpPing = 0x9,
    kOpPong = 0xA
};

@interface OCServerWebSocket () {
    NSInputStream *_input;
    NSOutputStream *_output;
    NSMutableData *_readBuffer;
    NSMutableData *_fragment;
    BOOL _inFragment;
    NSMutableArray *_writeQueue;
    NSUInteger _writeOffset;
    NSUInteger _pendingBytes;
    BOOL _closing;
    BOOL _tornDown;
}
@end

@implementation OCServerWebSocket

- (instancetype)initWithInputStream:(NSInputStream *)input
                       outputStream:(NSOutputStream *)output
                        pendingData:(NSData *)pendingData {
    if ((self = [super init])) {
        _input = [input retain];
        _output = [output retain];
        _readBuffer = [[NSMutableData alloc] initWithCapacity:kReadChunk];
        if ([pendingData length]) [_readBuffer appendData:pendingData];
        _writeQueue = [[NSMutableArray alloc] initWithCapacity:4];
        _maxMessageSize = kDefaultMaxMessageSize;
        _maxPendingWriteBytes = kDefaultMaxPendingWrite;
    }
    return self;
}

- (void)dealloc {
    [_input setDelegate:nil];
    [_output setDelegate:nil];
    [_input close];
    [_output close];
    [_input release];
    [_output release];
    [_readBuffer release];
    [_fragment release];
    [_writeQueue release];
    [super dealloc];
}

- (BOOL)isOpen {
    return !_tornDown && !_closing;
}

- (void)startWithHandshakeResponse:(NSData *)handshake {
    [_input setDelegate:self];
    [_output setDelegate:self];
    [_input scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [_output scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    if (handshake) [self _enqueue:handshake];

    // the client may have sent its first frame in the same segment as the upgrade request
    [self retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!_tornDown) {
            [self _parseFrames];
            if ([_input hasBytesAvailable]) [self _readAvailable];
        }
        [self release];
    });
}

- (void)rejectWithResponse:(NSData *)response {
    [_readBuffer setLength:0];
    [_input setDelegate:self];
    [_output setDelegate:self];
    [_input scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [_output scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    if (response) [self _enqueue:response];
    [self _beginClosing];
}

- (void)_beginClosing {
    _closing = YES;
    // a peer that stops reading must not keep the socket alive
    [self retain];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self _teardown];
        [self release];
    });
    [self _flush];
}

#pragma mark - Sending

- (void)sendText:(NSString *)text {
    if (![self isOpen] || !text) return;
    NSData *payload = [text dataUsingEncoding:NSUTF8StringEncoding];
    [self _sendFrame:kOpText payload:payload];
}

- (void)closeWithCode:(uint16_t)code reason:(NSString *)reason {
    if (_tornDown || _closing) return;
    NSMutableData *payload = [NSMutableData dataWithCapacity:2 + [reason length]];
    uint8_t c[2] = { (uint8_t)(code >> 8), (uint8_t)(code & 0xFF) };
    [payload appendBytes:c length:2];
    NSData *r = [reason dataUsingEncoding:NSUTF8StringEncoding];
    // control frames cap at 125 bytes
    if (r && [r length] <= 123) [payload appendData:r];
    [self _sendFrame:kOpClose payload:payload];
    [self _beginClosing];
}

- (void)_sendFrame:(uint8_t)opcode payload:(NSData *)payload {
    NSUInteger len = [payload length];
    NSMutableData *frame = [NSMutableData dataWithCapacity:len + 10];
    uint8_t hdr[10];
    NSUInteger hlen = 2;
    hdr[0] = 0x80 | opcode;
    if (len < 126) {
        hdr[1] = (uint8_t)len;
    } else if (len <= 0xFFFF) {
        hdr[1] = 126;
        hdr[2] = (uint8_t)(len >> 8);
        hdr[3] = (uint8_t)(len & 0xFF);
        hlen = 4;
    } else {
        hdr[1] = 127;
        uint64_t l = len;
        for (int i = 0; i < 8; i++) hdr[2 + i] = (uint8_t)(l >> (56 - 8 * i));
        hlen = 10;
    }
    [frame appendBytes:hdr length:hlen];
    if (len) [frame appendData:payload];
    [self _enqueue:frame];
}

- (void)_enqueue:(NSData *)data {
    if (_tornDown) return;
    _pendingBytes += [data length];
    if (_pendingBytes > _maxPendingWriteBytes) {
        [self _teardown];
        return;
    }
    [_writeQueue addObject:data];
    [self _flush];
}

- (void)_flush {
    while (!_tornDown && [_writeQueue count] > 0 && [_output hasSpaceAvailable]) {
        NSData *head = [_writeQueue objectAtIndex:0];
        NSUInteger remaining = [head length] - _writeOffset;
        NSInteger n = [_output write:(const uint8_t *)[head bytes] + _writeOffset maxLength:remaining];
        if (n <= 0) {
            if (n < 0) [self _teardown];
            return;
        }
        _writeOffset += (NSUInteger)n;
        _pendingBytes -= (NSUInteger)n;
        if (_writeOffset >= [head length]) {
            _writeOffset = 0;
            [_writeQueue removeObjectAtIndex:0];
        }
    }
    if (_closing && [_writeQueue count] == 0) [self _teardown];
}

#pragma mark - Reading

- (void)stream:(NSStream *)stream handleEvent:(NSStreamEvent)event {
    switch (event) {
        case NSStreamEventHasBytesAvailable:
            if (stream == _input) [self _readAvailable];
            break;
        case NSStreamEventHasSpaceAvailable:
            if (stream == _output) [self _flush];
            break;
        case NSStreamEventErrorOccurred:
        case NSStreamEventEndEncountered:
            [self _teardown];
            break;
        default:
            break;
    }
}

- (void)_readAvailable {
    uint8_t buf[kReadChunk];
    while (!_tornDown && [_input hasBytesAvailable]) {
        NSInteger n = [_input read:buf maxLength:sizeof(buf)];
        if (n <= 0) {
            if (n < 0) [self _teardown];
            return;
        }
        // after our close frame only the peer's close reply matters, so drop the rest
        if (_closing) continue;
        [_readBuffer appendBytes:buf length:(NSUInteger)n];
        [self _parseFrames];
    }
}

- (void)_failWithCode:(uint16_t)code reason:(NSString *)reason {
    [_readBuffer setLength:0];
    [self closeWithCode:code reason:reason];
}

- (void)_parseFrames {
    // the delegate may release us while handling a message
    [[self retain] autorelease];

    NSUInteger offset = 0;
    while (!_tornDown && !_closing) {
        const uint8_t *bytes = (const uint8_t *)[_readBuffer bytes] + offset;
        NSUInteger avail = [_readBuffer length] - offset;
        if (avail < 2) break;

        BOOL fin = (bytes[0] & 0x80) != 0;
        uint8_t rsv = bytes[0] & 0x70;
        uint8_t opcode = bytes[0] & 0x0F;
        BOOL masked = (bytes[1] & 0x80) != 0;
        uint64_t len = bytes[1] & 0x7F;
        NSUInteger hlen = 2;

        if (rsv) { [self _failWithCode:1002 reason:@"reserved bits set"]; return; }
        if (!masked) { [self _failWithCode:1002 reason:@"client frames must be masked"]; return; }

        if (len == 126) {
            if (avail < 4) break;
            len = ((uint64_t)bytes[2] << 8) | bytes[3];
            hlen = 4;
        } else if (len == 127) {
            if (avail < 10) break;
            len = 0;
            for (int i = 0; i < 8; i++) len = (len << 8) | bytes[2 + i];
            hlen = 10;
        }

        BOOL control = (opcode & 0x08) != 0;
        if (control && (!fin || len > 125)) {
            [self _failWithCode:1002 reason:@"bad control frame"];
            return;
        }
        if (len > _maxMessageSize) {
            [self _failWithCode:1009 reason:@"message too big"];
            return;
        }
        if (avail < hlen + 4) break;
        const uint8_t *maskKey = bytes + hlen;
        hlen += 4;
        if (avail - hlen < len) break;

        NSMutableData *payload = [NSMutableData dataWithBytes:bytes + hlen length:(NSUInteger)len];
        uint8_t *p = [payload mutableBytes];
        for (NSUInteger i = 0; i < (NSUInteger)len; i++) p[i] ^= maskKey[i & 3];
        offset += hlen + (NSUInteger)len;

        if (![self _handleFrame:opcode fin:fin payload:payload]) return;
    }

    if (_tornDown) return;
    if (offset >= [_readBuffer length]) {
        [_readBuffer setLength:0];
    } else if (offset > 0) {
        [_readBuffer replaceBytesInRange:NSMakeRange(0, offset) withBytes:NULL length:0];
    }
}

- (BOOL)_handleFrame:(uint8_t)opcode fin:(BOOL)fin payload:(NSData *)payload {
    switch (opcode) {
        case kOpText:
            if (_inFragment) { [self _failWithCode:1002 reason:@"unexpected text frame"]; return NO; }
            if (fin) return [self _deliver:payload];
            _inFragment = YES;
            [_fragment release];
            _fragment = [payload mutableCopy];
            return YES;
        case kOpContinuation:
            if (!_inFragment) { [self _failWithCode:1002 reason:@"unexpected continuation"]; return NO; }
            if ([_fragment length] + [payload length] > _maxMessageSize) {
                [self _failWithCode:1009 reason:@"message too big"];
                return NO;
            }
            [_fragment appendData:payload];
            if (!fin) return YES;
            _inFragment = NO;
            {
                NSData *whole = [[_fragment retain] autorelease];
                [_fragment release];
                _fragment = nil;
                return [self _deliver:whole];
            }
        case kOpBinary:
            [self _failWithCode:1003 reason:@"binary frames not supported"];
            return NO;
        case kOpClose:
            /* rfc 6455 5.5.1: echo the peer's status code; a close with no code gets a close with no code */
            if ([payload length] >= 2) {
                const uint8_t *b = [payload bytes];
                [self closeWithCode:WSEchoCode((uint16_t)((b[0] << 8) | b[1])) reason:nil];
            } else {
                [self _sendFrame:kOpClose payload:[NSData data]];
                [self _beginClosing];
            }
            return NO;
        case kOpPing:
            [self _sendFrame:kOpPong payload:payload];
            return YES;
        case kOpPong:
            return YES;
        default:
            [self _failWithCode:1002 reason:@"unknown opcode"];
            return NO;
    }
}

- (BOOL)_deliver:(NSData *)payload {
    NSString *text = [[[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding] autorelease];
    if (!text) { [self _failWithCode:1007 reason:@"invalid utf-8"]; return NO; }
    [_delegate serverWebSocket:self didReceiveText:text];
    return !_tornDown && !_closing;
}

#pragma mark - Teardown

- (void)_teardown {
    if (_tornDown) return;
    _tornDown = YES;
    [[self retain] autorelease];
    [_input setDelegate:nil];
    [_output setDelegate:nil];
    [_input removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [_output removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [_input close];
    [_output close];
    [_writeQueue removeAllObjects];
    _pendingBytes = 0;
    [_delegate serverWebSocketDidClose:self];
}

@end
