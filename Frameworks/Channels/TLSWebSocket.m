/* rfc 6455 client framing over a long-lived wolfssl connection */

#import "TLSWebSocket.h"
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>

static NSString *const kWSGUID = @"258EAFA5-E914-47DA-95CA-5AB5DC11695A";
static const NSUInteger kMaxHandshakeBytes = 16 * 1024;

static NSString *WSBase64(NSData *data) {
    static const char t[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const uint8_t *in = [data bytes];
    NSUInteger len = [data length];
    NSMutableString *r = [NSMutableString stringWithCapacity:((len + 2) / 3) * 4];
    for (NSUInteger i = 0; i < len; i += 3) {
        uint32_t v = (uint32_t)in[i] << 16;
        if (i + 1 < len) v |= (uint32_t)in[i + 1] << 8;
        if (i + 2 < len) v |= (uint32_t)in[i + 2];
        [r appendFormat:@"%c%c%c%c", t[(v >> 18) & 0x3F], t[(v >> 12) & 0x3F],
         (i + 1 < len) ? t[(v >> 6) & 0x3F] : '=', (i + 2 < len) ? t[v & 0x3F] : '='];
    }
    return r;
}

NSString *const OCTLSWebSocketCloseCodeKey = @"OCTLSWebSocketCloseCode";

static NSError *WSError(NSString *message) {
    return [NSError errorWithDomain:@"OCTLSWebSocket" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface OCTLSWebSocket () {
    NSURL *_url;
    CPTLSConnection *_conn;
    NSString *_expectedAccept;
    BOOL _handshakeDone;
    BOOL _closed;
    NSMutableData *_buffer;
    NSMutableData *_message;
    uint8_t _messageOpcode;
}
@end

@implementation OCTLSWebSocket

- (id)initWithURL:(NSURL *)url {
    if ((self = [super init])) {
        _url = [url retain];
        _buffer = [[NSMutableData alloc] init];
        _maxMessageSize = 2 * 1024 * 1024;
    }
    return self;
}

- (void)dealloc {
    [_conn close];
    [_conn release]; [_url release]; [_expectedAccept release];
    [_buffer release]; [_message release];
    [super dealloc];
}

- (BOOL)isOpen { return _handshakeDone && !_closed; }

- (void)open {
    if (_conn) return;
    NSString *scheme = [[_url scheme] lowercaseString];
    BOOL tls = [scheme isEqualToString:@"wss"];
    int port = [_url port] ? [[_url port] intValue] : (tls ? 443 : 80);
    if ([[_url host] length] == 0 || (!tls && ![scheme isEqualToString:@"ws"])) {
        [self _failWith:WSError(@"Invalid websocket URL")];
        return;
    }
    _conn = [[CPTLSConnection alloc] initWithHost:[_url host] port:port useTLS:tls];
    _conn.delegate = self;
    [_conn open];
}

- (void)close {
    if (_closed) return;
    if (_handshakeDone) [self _sendFrame:0x8 payload:[NSData data]];
    _closed = YES;
    _delegate = nil;
    [_conn close];
}

- (void)_failWith:(NSError *)error {
    if (_closed) return;
    _closed = YES;
    [_conn close];
    id<OCTLSWebSocketDelegate> d = _delegate;
    _delegate = nil;
    [[self retain] autorelease];
    [d webSocket:self didCloseWithError:error];
}

#pragma mark - Connection

- (void)connectionDidOpen:(CPTLSConnection *)connection {
    uint8_t nonce[16];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(nonce), nonce) != 0) arc4random_buf(nonce, sizeof(nonce));
    NSString *key = WSBase64([NSData dataWithBytes:nonce length:sizeof(nonce)]);

    NSData *src = [[key stringByAppendingString:kWSGUID] dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t sha[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1([src bytes], (CC_LONG)[src length], sha);
    [_expectedAccept release];
    _expectedAccept = [WSBase64([NSData dataWithBytes:sha length:sizeof(sha)]) retain];

    /* raw path and query: -path drops a trailing slash and decodes escapes, which changes the request */
    NSString *rawPath = [(NSString *)CFURLCopyPath((CFURLRef)_url) autorelease];
    NSString *rawQuery = [(NSString *)CFURLCopyQueryString((CFURLRef)_url, NULL) autorelease];
    NSString *path = [rawPath length] ? rawPath : @"/";
    if (rawQuery) path = [NSString stringWithFormat:@"%@?%@", path, rawQuery];
    NSString *host = [_url port] ? [NSString stringWithFormat:@"%@:%@", [_url host], [_url port]] : [_url host];
    NSString *req = [NSString stringWithFormat:
        @"GET %@ HTTP/1.1\r\nHost: %@\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        @"Sec-WebSocket-Key: %@\r\nSec-WebSocket-Version: 13\r\nUser-Agent: LegacyPodClaw\r\n\r\n", path, host, key];
    [_conn sendData:[req dataUsingEncoding:NSUTF8StringEncoding]];
}

- (void)connection:(CPTLSConnection *)connection didCloseWithError:(NSError *)error {
    [self _failWith:error];
}

- (void)connection:(CPTLSConnection *)connection didReceiveData:(NSData *)data {
    if (_closed) return;
    /* the delegate may drop its last reference while a frame is being handled */
    [[self retain] autorelease];
    [_buffer appendData:data];
    if (!_handshakeDone && ![self _readHandshake]) return;
    [self _readFrames];
}

- (BOOL)_readHandshake {
    const char *p = [_buffer bytes];
    NSUInteger len = [_buffer length], end = NSNotFound;
    for (NSUInteger i = 0; i + 3 < len; i++) {
        if (memcmp(p + i, "\r\n\r\n", 4) == 0) { end = i; break; }
    }
    if (end == NSNotFound) {
        if (len > kMaxHandshakeBytes) [self _failWith:WSError(@"Websocket handshake too large")];
        return NO;
    }
    NSString *head = [[[NSString alloc] initWithBytes:p length:end encoding:NSISOLatin1StringEncoding] autorelease];
    [_buffer replaceBytesInRange:NSMakeRange(0, end + 4) withBytes:NULL length:0];

    NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
    NSString *status = [lines count] ? [lines objectAtIndex:0] : @"";
    if ([status rangeOfString:@" 101"].location == NSNotFound) {
        [self _failWith:WSError([NSString stringWithFormat:@"Websocket upgrade refused: %@", status])];
        return NO;
    }
    BOOL acceptOk = NO;
    for (NSString *line in lines) {
        NSRange c = [line rangeOfString:@":"];
        if (c.location == NSNotFound) continue;
        if ([[[line substringToIndex:c.location] lowercaseString] isEqualToString:@"sec-websocket-accept"]) {
            NSString *v = [[line substringFromIndex:c.location + 1]
                           stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            acceptOk = [v isEqualToString:_expectedAccept];
        }
    }
    if (!acceptOk) {
        [self _failWith:WSError(@"Websocket accept key mismatch")];
        return NO;
    }
    _handshakeDone = YES;
    [_delegate webSocketDidOpen:self];
    return !_closed;
}

- (void)_readFrames {
    while (!_closed) {
        const uint8_t *p = [_buffer bytes];
        NSUInteger len = [_buffer length];
        if (len < 2) return;
        BOOL fin = (p[0] & 0x80) != 0;
        uint8_t opcode = p[0] & 0x0F;
        BOOL masked = (p[1] & 0x80) != 0;
        uint64_t plen = p[1] & 0x7F;
        NSUInteger off = 2;
        if (plen == 126) {
            if (len < 4) return;
            plen = ((uint64_t)p[2] << 8) | p[3];
            off = 4;
        } else if (plen == 127) {
            if (len < 10) return;
            plen = 0;
            for (int i = 0; i < 8; i++) plen = (plen << 8) | p[2 + i];
            off = 10;
        }
        if (masked) { [self _failWith:WSError(@"Server sent a masked frame")]; return; }
        if (plen > _maxMessageSize) { [self _failWith:WSError(@"Websocket message too large")]; return; }
        if (len < off + plen) return;

        NSData *payload = [NSData dataWithBytes:p + off length:(NSUInteger)plen];
        [_buffer replaceBytesInRange:NSMakeRange(0, off + (NSUInteger)plen) withBytes:NULL length:0];
        [self _handleFrame:opcode fin:fin payload:payload];
    }
}

- (void)_handleFrame:(uint8_t)opcode fin:(BOOL)fin payload:(NSData *)payload {
    switch (opcode) {
        case 0x9: [self _sendFrame:0xA payload:payload]; return;
        case 0xA: return;
        case 0x8: {
            /* the close code tells a fatal error (a bad token) from a request to reconnect */
            if ([payload length] < 2) { [self _failWith:WSError(@"Websocket closed by server")]; return; }
            const uint8_t *b = [payload bytes];
            NSInteger code = (b[0] << 8) | b[1];
            NSString *reason = [[[NSString alloc] initWithBytes:b + 2 length:[payload length] - 2
                                                       encoding:NSUTF8StringEncoding] autorelease];
            NSString *message = [reason length]
                ? [NSString stringWithFormat:@"Websocket closed by server (%ld: %@)", (long)code, reason]
                : [NSString stringWithFormat:@"Websocket closed by server (%ld)", (long)code];
            [self _failWith:[NSError errorWithDomain:@"OCTLSWebSocket" code:1 userInfo:@{
                NSLocalizedDescriptionKey: message, OCTLSWebSocketCloseCodeKey: @(code)}]];
            return;
        }
        case 0x1: case 0x2:
            [_message release];
            _message = [payload mutableCopy];
            _messageOpcode = opcode;
            break;
        case 0x0:
            if (!_message) { [self _failWith:WSError(@"Unexpected continuation frame")]; return; }
            if ([_message length] + [payload length] > _maxMessageSize) { [self _failWith:WSError(@"Websocket message too large")]; return; }
            [_message appendData:payload];
            break;
        default:
            [self _failWith:WSError(@"Unknown websocket opcode")];
            return;
    }
    if (!fin) return;
    NSData *done = [_message autorelease];
    _message = nil;
    if (_messageOpcode != 0x1) return;
    NSString *text = [[[NSString alloc] initWithData:done encoding:NSUTF8StringEncoding] autorelease];
    if (text) [_delegate webSocket:self didReceiveText:text];
}

- (void)sendText:(NSString *)text {
    if (![self isOpen]) return;
    [self _sendFrame:0x1 payload:[text dataUsingEncoding:NSUTF8StringEncoding]];
}

- (void)_sendFrame:(uint8_t)opcode payload:(NSData *)payload {
    NSUInteger plen = [payload length];
    NSMutableData *frame = [NSMutableData dataWithCapacity:plen + 14];
    uint8_t head[10];
    NSUInteger hlen = 2;
    head[0] = 0x80 | opcode;
    if (plen < 126) {
        head[1] = 0x80 | (uint8_t)plen;
    } else if (plen < 65536) {
        head[1] = 0x80 | 126;
        head[2] = (uint8_t)(plen >> 8); head[3] = (uint8_t)plen;
        hlen = 4;
    } else {
        head[1] = 0x80 | 127;
        uint64_t l = plen;
        for (int i = 7; i >= 0; i--) { head[2 + i] = (uint8_t)(l & 0xFF); l >>= 8; }
        hlen = 10;
    }
    [frame appendBytes:head length:hlen];
    uint8_t mask[4];
    arc4random_buf(mask, sizeof(mask));
    [frame appendBytes:mask length:4];
    NSUInteger start = [frame length];
    [frame appendData:payload];
    uint8_t *bytes = (uint8_t *)[frame mutableBytes] + start;
    for (NSUInteger i = 0; i < plen; i++) bytes[i] ^= mask[i % 4];
    [_conn sendData:frame];
}

@end
