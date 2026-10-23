/*
 * OCWebSocket.m
 * LegacyPodClaw - RFC 6455 WebSocket Client Implementation
 *
 * Uses CFStream for raw TCP + TLS. Implements:
 * - HTTP upgrade handshake with Sec-WebSocket-Key
 * - Frame encoding with masking (client MUST mask per RFC)
 * - Frame decoding with streaming parser (no large allocs)
 * - Ping/pong keepalive
 * - Close handshake
 * - Fragmented message reassembly
 */

#import "WebSocket.h"
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
/* Note: Using __sync builtins instead of deprecated OSAtomic for forward compatibility */

NSString *const OCWSErrorDomain = @"OCWebSocketError";
const NSInteger OCWSErrorHandshakeFailed  = 1001;
const NSInteger OCWSErrorConnectionFailed = 1002;
const NSInteger OCWSErrorFrameInvalid     = 1003;
const NSInteger OCWSErrorPayloadTooLarge  = 1004;

static const NSUInteger kDefaultReadBufferSize  = 4096;
static const NSUInteger kDefaultMaxFrameSize    = 1 * 1024 * 1024;  // 1MB
static const NSUInteger kDefaultMaxMessageSize  = 4 * 1024 * 1024;  // 4MB
static const NSTimeInterval kDefaultPingInterval = 30.0;
static const NSString *kWebSocketGUID = @"258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

static int32_t sActiveConnections = 0;

/* rfc 6455 7.4: 1004-1006, 1015 and unassigned codes must not go on the wire, so answer them with 1002 */
static uint16_t WSEchoCode(uint16_t c) {
    return ((c >= 1000 && c <= 1003) || (c >= 1007 && c <= 1014) || (c >= 3000 && c <= 4999)) ? c : 1002;
}

/* Base64 encoder for iOS 6 (NSData base64EncodedStringWithOptions: is iOS 7+) */
static NSString *OCBase64Encode(NSData *data) {
    static const char table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    const uint8_t *input = [data bytes];
    NSUInteger length = [data length];
    NSMutableString *result = [NSMutableString stringWithCapacity:((length + 2) / 3) * 4];

    for (NSUInteger i = 0; i < length; i += 3) {
        uint32_t val = (uint32_t)input[i] << 16;
        if (i + 1 < length) val |= (uint32_t)input[i + 1] << 8;
        if (i + 2 < length) val |= (uint32_t)input[i + 2];

        [result appendFormat:@"%c", table[(val >> 18) & 0x3F]];
        [result appendFormat:@"%c", table[(val >> 12) & 0x3F]];
        [result appendFormat:@"%c", (i + 1 < length) ? table[(val >> 6) & 0x3F] : '='];
        [result appendFormat:@"%c", (i + 2 < length) ? table[val & 0x3F] : '='];
    }
    return result;
}
static int64_t sTotalBytesBuffered = 0;

#pragma mark - Frame Parser State

typedef NS_ENUM(NSUInteger, OCWSParserState) {
    OCWSParserStateHeader1,     // Reading first 2 bytes
    OCWSParserStateLength16,    // Reading 2-byte extended length
    OCWSParserStateLength64,    // Reading 8-byte extended length
    OCWSParserStateMask,        // Reading 4-byte mask (server frames, unlikely)
    OCWSParserStatePayload,     // Reading payload data
    OCWSParserStateComplete     // Frame complete
};

@interface OCWSFrameParser : NSObject {
    @public
    OCWSParserState state;
    BOOL fin;
    BOOL masked;
    OCWSOpcode opcode;
    uint64_t payloadLength;
    uint64_t payloadRead;
    uint8_t maskKey[4];
    NSMutableData *payload;
    NSUInteger headerBytesRead;
    uint8_t headerBuffer[8];
}
- (void)reset;
@end

@implementation OCWSFrameParser

- (instancetype)init {
    if ((self = [super init])) {
        [self reset];
    }
    return self;
}

- (void)reset {
    state = OCWSParserStateHeader1;
    fin = NO;
    masked = NO;
    opcode = OCWSOpcContinuation;
    payloadLength = 0;
    payloadRead = 0;
    memset(maskKey, 0, 4);
    /* the parser owns the payload; a delivered message holds its own reference */
    [payload release];
    payload = nil;
    headerBytesRead = 0;
    memset(headerBuffer, 0, 8);
}

- (void)dealloc {
    [payload release];
    [super dealloc];
}

@end

#pragma mark - OCWebSocket Private

@interface OCWebSocket () {
    NSInputStream  *_inputStream;
    NSOutputStream *_outputStream;

    NSMutableData  *_readBuffer;
    NSMutableData  *_writeBuffer;
    NSMutableArray *_writeQueue;
    BOOL            _isWriting;

    OCWSFrameParser *_parser;

    /* Fragmented message reassembly */
    NSMutableData  *_fragmentBuffer;
    OCWSOpcode      _fragmentOpcode;

    /* Handshake */
    NSString       *_expectedAcceptKey;
    NSMutableData  *_handshakeBuffer;
    BOOL            _handshakeComplete;

    /* Keepalive */
    NSTimer        *_pingTimer;
    NSDate         *_lastPongReceived;

    /* Thread safety */
    dispatch_queue_t _socketQueue;

    /* Close state */
    BOOL _sentClose;
    BOOL _receivedClose;

    /* the leaf certificate matched the pin; set once per connection */
    BOOL _peerPinned;
}
@end

@implementation OCWebSocket

#pragma mark - Lifecycle

- (instancetype)initWithURL:(NSURL *)url {
    return [self initWithURL:url protocols:nil];
}

- (instancetype)initWithURL:(NSURL *)url protocols:(NSArray *)protocols {
    if ((self = [super init])) {
        _url = [url retain];
        _requestedProtocols = [protocols copy];
        _readyState = OCWSReadyStateClosed;
        _maxFrameSize = kDefaultMaxFrameSize;
        _maxMessageSize = kDefaultMaxMessageSize;
        _readBufferSize = kDefaultReadBufferSize;
        _pingInterval = kDefaultPingInterval;
        _allowSelfSignedCerts = NO;
        _delegateQueue = dispatch_get_main_queue();
        _socketQueue = dispatch_queue_create("pro.matthesketh.legacypodclaw.websocket", DISPATCH_QUEUE_SERIAL);
        _writeQueue = [[NSMutableArray alloc] initWithCapacity:8];
        _parser = [[OCWSFrameParser alloc] init];
    }
    return self;
}

- (void)dealloc {
    [self _teardown];
    [_readBuffer release];
    [_writeBuffer release];
    [_writeQueue release];
    [_handshakeBuffer release];
    [_fragmentBuffer release];
    [_parser release];
    [_url release];
    [_requestedProtocols release];
    [_customHeaders release];
    [_socketQueue release];
    [_delegateQueue release];
    [_lastPongReceived release];
    [_expectedAcceptKey release];
    [_pinnedCertSHA256 release];
    [super dealloc];
}

#pragma mark - Public API

- (void)open {
    dispatch_async(_socketQueue, ^{
        if (_readyState != OCWSReadyStateClosed) return;
        _readyState = OCWSReadyStateConnecting;
        __sync_add_and_fetch(&sActiveConnections, 1);
        [self _connect];
    });
}

- (void)close {
    [self closeWithCode:OCWSCloseNormal reason:nil];
}

- (void)closeWithCode:(OCWSCloseCode)code reason:(NSString *)reason {
    dispatch_async(_socketQueue, ^{
        if (_readyState == OCWSReadyStateClosed || _readyState == OCWSReadyStateClosing) return;
        _readyState = OCWSReadyStateClosing;

        NSMutableData *payload = [[NSMutableData alloc] initWithCapacity:2 + [reason length]];
        uint16_t codeN = CFSwapInt16HostToBig((uint16_t)code);
        [payload appendBytes:&codeN length:2];
        if (reason) {
            [payload appendData:[reason dataUsingEncoding:NSUTF8StringEncoding]];
        }
        [self _sendFrameWithOpcode:OCWSOpcClose payload:payload];
        [payload release];
        _sentClose = YES;

        /* Give server 5s to respond with close frame, then force teardown */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), _socketQueue, ^{
            if (_readyState != OCWSReadyStateClosed) {
                [self _teardownWithCode:code reason:reason wasClean:NO];
            }
        });
    });
}

- (void)sendText:(NSString *)text {
    if (!text) return;
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    dispatch_async(_socketQueue, ^{
        if (_readyState != OCWSReadyStateOpen) return;
        [self _sendFrameWithOpcode:OCWSOpcText payload:data];
    });
}

- (void)sendData:(NSData *)data {
    if (!data) return;
    dispatch_async(_socketQueue, ^{
        if (_readyState != OCWSReadyStateOpen) return;
        [self _sendFrameWithOpcode:OCWSOpcBinary payload:data];
    });
}

- (void)sendPing:(NSData *)payload {
    dispatch_async(_socketQueue, ^{
        if (_readyState != OCWSReadyStateOpen) return;
        [self _sendFrameWithOpcode:OCWSOpcPing payload:payload];
    });
}

+ (NSUInteger)activeConnectionCount {
    return (NSUInteger)sActiveConnections;
}

+ (NSUInteger)totalBytesBuffered {
    return (NSUInteger)sTotalBytesBuffered;
}

#pragma mark - Connection Setup

- (void)_connect {
    NSString *host = [_url host];
    BOOL useTLS = [[_url scheme] isEqualToString:@"wss"];
    NSInteger port = [[_url port] integerValue];
    if (port == 0) port = useTLS ? 443 : 80;

    CFReadStreamRef readStream;
    CFWriteStreamRef writeStream;
    CFStreamCreatePairWithSocketToHost(kCFAllocatorDefault,
                                       (__bridge CFStringRef)host,
                                       (UInt32)port,
                                       &readStream,
                                       &writeStream);

    _inputStream  = (NSInputStream *)readStream;
    _outputStream = (NSOutputStream *)writeStream;

    if (useTLS) {
        NSDictionary *tlsSettings;
        if (_allowSelfSignedCerts) {
            tlsSettings = @{
                (id)kCFStreamSSLLevel: (id)kCFStreamSocketSecurityLevelNegotiatedSSL,
                (id)kCFStreamSSLValidatesCertificateChain: @NO
            };
        } else {
            tlsSettings = @{
                (id)kCFStreamSSLLevel: (id)kCFStreamSocketSecurityLevelNegotiatedSSL,
                (id)kCFStreamSSLPeerName: host
            };
        }
        [_inputStream  setProperty:tlsSettings forKey:(id)kCFStreamPropertySSLSettings];
        [_outputStream setProperty:tlsSettings forKey:(id)kCFStreamPropertySSLSettings];
    }

    [_inputStream  setDelegate:self];
    [_outputStream setDelegate:self];

    /* Schedule on a dedicated runloop thread for iOS 6 compatibility */
    [_inputStream  scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [_outputStream scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

    _readBuffer = [[NSMutableData alloc] initWithCapacity:_readBufferSize];
    _writeBuffer = [[NSMutableData alloc] initWithCapacity:_readBufferSize];
    _handshakeBuffer = [[NSMutableData alloc] initWithCapacity:1024];
    _handshakeComplete = NO;
    _sentClose = NO;
    _receivedClose = NO;

    [_inputStream open];
    [_outputStream open];
}

#pragma mark - NSStreamDelegate

- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode {
    dispatch_async(_socketQueue, ^{
        if (aStream == _inputStream) {
            switch (eventCode) {
                case NSStreamEventOpenCompleted:
                    /* Input stream open - wait for output too */
                    break;
                case NSStreamEventHasBytesAvailable:
                    [self _readAvailableBytes];
                    break;
                case NSStreamEventErrorOccurred:
                    [self _handleStreamError:[aStream streamError]];
                    break;
                case NSStreamEventEndEncountered:
                    [self _handleStreamEnd];
                    break;
                default:
                    break;
            }
        } else if (aStream == _outputStream) {
            switch (eventCode) {
                case NSStreamEventOpenCompleted:
                    /* Both streams open - send HTTP upgrade handshake */
                    if (!_handshakeComplete && ![self _needsPinCheck]) {
                        [self _sendHandshake];
                    }
                    break;
                case NSStreamEventHasSpaceAvailable:
                    /* the tls handshake is done by the first space event, so the peer certificate exists now */
                    if ([self _needsPinCheck] && !_peerPinned) {
                        if (![self _peerMatchesPin]) {
                            [self _failWithCode:OCWSErrorHandshakeFailed
                                        message:@"The gateway certificate does not match the pinned SHA-256 fingerprint"];
                            break;
                        }
                        _peerPinned = YES;
                        if (!_handshakeComplete) [self _sendHandshake];
                        break;
                    }
                    [self _flushWriteBuffer];
                    break;
                case NSStreamEventErrorOccurred:
                    [self _handleStreamError:[aStream streamError]];
                    break;
                default:
                    break;
            }
        }
    });
}

#pragma mark - Certificate Pin

- (BOOL)_needsPinCheck {
    return _allowSelfSignedCerts && [[[_url scheme] lowercaseString] isEqualToString:@"wss"];
}

static NSString *NormalizedHex(NSString *s) {
    NSCharacterSet *hex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];
    NSMutableString *out = [NSMutableString stringWithCapacity:64];
    NSString *lower = [s lowercaseString];
    for (NSUInteger i = 0; i < [lower length]; i++) {
        unichar c = [lower characterAtIndex:i];
        if ([hex characterIsMember:c]) [out appendFormat:@"%C", c];
    }
    return out;
}

- (BOOL)_peerMatchesPin {
    NSString *pin = NormalizedHex(_pinnedCertSHA256 ?: @"");
    /* no pin means no check at all, so refuse rather than trust any certificate */
    if ([pin length] != CC_SHA256_DIGEST_LENGTH * 2) return NO;
    SecTrustRef trust = (SecTrustRef)[_outputStream propertyForKey:(id)kCFStreamPropertySSLPeerTrust];
    if (!trust || SecTrustGetCertificateCount(trust) < 1) return NO;
    SecCertificateRef leaf = SecTrustGetCertificateAtIndex(trust, 0);
    CFDataRef der = SecCertificateCopyData(leaf);
    if (!der) return NO;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(CFDataGetBytePtr(der), (CC_LONG)CFDataGetLength(der), digest);
    CFRelease(der);
    NSMutableString *got = [NSMutableString stringWithCapacity:64];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [got appendFormat:@"%02x", digest[i]];
    return [got isEqualToString:pin];
}

#pragma mark - HTTP Upgrade Handshake

- (void)_sendHandshake {
    /* Generate random 16-byte key, base64 encode it */
    uint8_t keyBytes[16];
    (void)SecRandomCopyBytes(kSecRandomDefault, 16, keyBytes);
    NSData *keyData = [NSData dataWithBytes:keyBytes length:16];
    NSString *key = OCBase64Encode(keyData);

    /* Compute expected accept = base64(SHA1(key + GUID)) */
    NSString *acceptSource = [NSString stringWithFormat:@"%@%@", key, kWebSocketGUID];
    NSData *acceptData = [acceptSource dataUsingEncoding:NSUTF8StringEncoding];
    uint8_t sha1[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1([acceptData bytes], (CC_LONG)[acceptData length], sha1);
    NSData *sha1Data = [NSData dataWithBytes:sha1 length:CC_SHA1_DIGEST_LENGTH];
    [_expectedAcceptKey release];
    _expectedAcceptKey = [OCBase64Encode(sha1Data) retain];

    /* Build HTTP request */
    NSString *path = [_url path];
    if (!path || [path length] == 0) path = @"/";
    NSString *query = [_url query];
    if (query) path = [NSString stringWithFormat:@"%@?%@", path, query];

    NSString *host = [_url host];
    NSInteger port = [[_url port] integerValue];
    BOOL useTLS = [[_url scheme] isEqualToString:@"wss"];
    if (port != 0 && port != (useTLS ? 443 : 80)) {
        host = [NSString stringWithFormat:@"%@:%ld", host, (long)port];
    }

    NSMutableString *request = [NSMutableString stringWithCapacity:512];
    [request appendFormat:@"GET %@ HTTP/1.1\r\n", path];
    [request appendFormat:@"Host: %@\r\n", host];
    [request appendString:@"Upgrade: websocket\r\n"];
    [request appendString:@"Connection: Upgrade\r\n"];
    [request appendFormat:@"Sec-WebSocket-Key: %@\r\n", key];
    [request appendString:@"Sec-WebSocket-Version: 13\r\n"];

    if (_requestedProtocols && [_requestedProtocols count] > 0) {
        [request appendFormat:@"Sec-WebSocket-Protocol: %@\r\n",
         [_requestedProtocols componentsJoinedByString:@", "]];
    }

    if (_customHeaders) {
        for (NSString *headerKey in _customHeaders) {
            [request appendFormat:@"%@: %@\r\n", headerKey, _customHeaders[headerKey]];
        }
    }

    [request appendString:@"\r\n"];

    NSData *requestData = [request dataUsingEncoding:NSUTF8StringEncoding];
    [self _enqueueWrite:requestData];
}

- (void)_processHandshakeData {
    /* Look for \r\n\r\n in handshake buffer */
    const uint8_t *bytes = [_handshakeBuffer bytes];
    NSUInteger length = [_handshakeBuffer length];

    NSUInteger headerEnd = 0;
    for (NSUInteger i = 0; i + 3 < length; i++) {
        if (bytes[i] == '\r' && bytes[i+1] == '\n' &&
            bytes[i+2] == '\r' && bytes[i+3] == '\n') {
            headerEnd = i + 4;
            break;
        }
    }

    if (headerEnd == 0) {
        /* Haven't received full headers yet */
        if (length > 8192) {
            /* Headers too large - abort */
            [self _failWithCode:OCWSErrorHandshakeFailed
                        message:@"Handshake response headers too large"];
        }
        return;
    }

    NSString *response = [[NSString alloc] initWithBytes:bytes
                                                  length:headerEnd
                                                encoding:NSUTF8StringEncoding];

    /* Validate 101 status */
    if (![response hasPrefix:@"HTTP/1.1 101"]) {
        [response release];
        [self _failWithCode:OCWSErrorHandshakeFailed
                    message:@"Server did not return 101 Switching Protocols"];
        return;
    }

    /* Validate Sec-WebSocket-Accept */
    NSRange acceptRange = [response rangeOfString:@"Sec-WebSocket-Accept: "
                                          options:NSCaseInsensitiveSearch];
    if (acceptRange.location == NSNotFound) {
        [response release];
        [self _failWithCode:OCWSErrorHandshakeFailed
                    message:@"Missing Sec-WebSocket-Accept header"];
        return;
    }

    NSUInteger valueStart = acceptRange.location + acceptRange.length;
    NSRange lineEnd = [response rangeOfString:@"\r\n"
                                      options:0
                                        range:NSMakeRange(valueStart, [response length] - valueStart)];
    NSString *acceptValue = [response substringWithRange:
                             NSMakeRange(valueStart, lineEnd.location - valueStart)];

    if (![acceptValue isEqualToString:_expectedAcceptKey]) {
        [response release];
        [self _failWithCode:OCWSErrorHandshakeFailed
                    message:@"Sec-WebSocket-Accept mismatch"];
        return;
    }

    [response release];

    /* Handshake complete! */
    _handshakeComplete = YES;
    _readyState = OCWSReadyStateOpen;

    /* Any remaining data after headers is WebSocket frame data */
    if (headerEnd < length) {
        NSData *remaining = [NSData dataWithBytes:bytes + headerEnd
                                           length:length - headerEnd];
        [_handshakeBuffer setLength:0];
        [self _processFrameData:remaining];
    } else {
        [_handshakeBuffer setLength:0];
    }

    /* Start ping timer */
    if (_pingInterval > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            _pingTimer = [NSTimer scheduledTimerWithTimeInterval:_pingInterval
                                                         target:self
                                                       selector:@selector(_sendKeepAlivePing)
                                                       userInfo:nil
                                                        repeats:YES];
        });
    }

    /* Notify delegate */
    dispatch_async(_delegateQueue, ^{
        if ([_delegate respondsToSelector:@selector(webSocketDidOpen:)]) {
            [_delegate webSocketDidOpen:self];
        }
    });
}

#pragma mark - Reading

- (void)_readAvailableBytes {
    uint8_t buffer[_readBufferSize];

    while ([_inputStream hasBytesAvailable]) {
        NSInteger bytesRead = [_inputStream read:buffer maxLength:_readBufferSize];
        if (bytesRead <= 0) break;

        __sync_add_and_fetch(&sTotalBytesBuffered, bytesRead);

        if (!_handshakeComplete) {
            [_handshakeBuffer appendBytes:buffer length:bytesRead];
            [self _processHandshakeData];
        } else {
            NSData *data = [[NSData alloc] initWithBytesNoCopy:buffer
                                                        length:bytesRead
                                                  freeWhenDone:NO];
            [self _processFrameData:data];
            [data release];
        }
    }
}

#pragma mark - Frame Parsing

- (void)_processFrameData:(NSData *)data {
    const uint8_t *bytes = [data bytes];
    NSUInteger length = [data length];
    NSUInteger offset = 0;

    while (offset < length) {
        switch (_parser->state) {
            case OCWSParserStateHeader1: {
                if (_parser->headerBytesRead < 2) {
                    NSUInteger needed = 2 - _parser->headerBytesRead;
                    NSUInteger available = length - offset;
                    NSUInteger consume = MIN(needed, available);
                    memcpy(_parser->headerBuffer + _parser->headerBytesRead,
                           bytes + offset, consume);
                    _parser->headerBytesRead += consume;
                    offset += consume;
                }
                if (_parser->headerBytesRead >= 2) {
                    _parser->fin = (_parser->headerBuffer[0] & 0x80) != 0;
                    _parser->opcode = (OCWSOpcode)(_parser->headerBuffer[0] & 0x0F);
                    _parser->masked = (_parser->headerBuffer[1] & 0x80) != 0;
                    uint8_t lenByte = _parser->headerBuffer[1] & 0x7F;

                    if (lenByte < 126) {
                        _parser->payloadLength = lenByte;
                        _parser->state = _parser->masked ? OCWSParserStateMask : OCWSParserStatePayload;
                        _parser->headerBytesRead = 0;
                        if (_parser->payloadLength == 0 && !_parser->masked) {
                            _parser->state = OCWSParserStateComplete;
                        }
                    } else if (lenByte == 126) {
                        _parser->state = OCWSParserStateLength16;
                        _parser->headerBytesRead = 0;
                    } else {
                        _parser->state = OCWSParserStateLength64;
                        _parser->headerBytesRead = 0;
                    }
                }
                break;
            }

            case OCWSParserStateLength16: {
                NSUInteger needed = 2 - _parser->headerBytesRead;
                NSUInteger available = length - offset;
                NSUInteger consume = MIN(needed, available);
                memcpy(_parser->headerBuffer + _parser->headerBytesRead,
                       bytes + offset, consume);
                _parser->headerBytesRead += consume;
                offset += consume;

                if (_parser->headerBytesRead >= 2) {
                    _parser->payloadLength = ((uint16_t)_parser->headerBuffer[0] << 8) |
                                              (uint16_t)_parser->headerBuffer[1];
                    
                    /* SECURITY: Validate frame size even for 16-bit lengths */
                    if (_parser->payloadLength > _maxFrameSize) {
                        [self _failWithCode:OCWSErrorPayloadTooLarge
                                    message:@"Frame payload exceeds maximum size"];
                        return;
                    }
                    
                    _parser->state = _parser->masked ? OCWSParserStateMask : OCWSParserStatePayload;
                    _parser->headerBytesRead = 0;
                    if (_parser->payloadLength == 0 && !_parser->masked) {
                        _parser->state = OCWSParserStateComplete;
                    }
                }
                break;
            }

            case OCWSParserStateLength64: {
                NSUInteger needed = 8 - _parser->headerBytesRead;
                NSUInteger available = length - offset;
                NSUInteger consume = MIN(needed, available);
                memcpy(_parser->headerBuffer + _parser->headerBytesRead,
                       bytes + offset, consume);
                _parser->headerBytesRead += consume;
                offset += consume;

                if (_parser->headerBytesRead >= 8) {
                    _parser->payloadLength = 0;
                    for (int i = 0; i < 8; i++) {
                        _parser->payloadLength = (_parser->payloadLength << 8) |
                                                  _parser->headerBuffer[i];
                    }

                    if (_parser->payloadLength > _maxFrameSize) {
                        [self _failWithCode:OCWSErrorPayloadTooLarge
                                    message:@"Frame payload exceeds maximum size"];
                        return;
                    }

                    _parser->state = _parser->masked ? OCWSParserStateMask : OCWSParserStatePayload;
                    _parser->headerBytesRead = 0;
                }
                break;
            }

            case OCWSParserStateMask: {
                NSUInteger needed = 4 - _parser->headerBytesRead;
                NSUInteger available = length - offset;
                NSUInteger consume = MIN(needed, available);
                memcpy(_parser->maskKey + _parser->headerBytesRead,
                       bytes + offset, consume);
                _parser->headerBytesRead += consume;
                offset += consume;

                if (_parser->headerBytesRead >= 4) {
                    _parser->state = OCWSParserStatePayload;
                    _parser->headerBytesRead = 0;
                    if (_parser->payloadLength == 0) {
                        _parser->state = OCWSParserStateComplete;
                    }
                }
                break;
            }

            case OCWSParserStatePayload: {
                if (!_parser->payload) {
                    /* Allocate payload buffer - cap initial allocation */
                    NSUInteger allocSize = MIN((NSUInteger)_parser->payloadLength, 65536u);
                    _parser->payload = [[NSMutableData alloc] initWithCapacity:allocSize];
                }

                uint64_t remaining = _parser->payloadLength - _parser->payloadRead;
                NSUInteger available = length - offset;
                NSUInteger consume = MIN((NSUInteger)remaining, available);

                [_parser->payload appendBytes:bytes + offset length:consume];

                /* Unmask in-place if needed */
                if (_parser->masked) {
                    uint8_t *pBytes = (uint8_t *)[_parser->payload mutableBytes];
                    NSUInteger start = (NSUInteger)_parser->payloadRead;
                    for (NSUInteger i = 0; i < consume; i++) {
                        pBytes[start + i] ^= _parser->maskKey[(start + i) % 4];
                    }
                }

                _parser->payloadRead += consume;
                offset += consume;

                if (_parser->payloadRead >= _parser->payloadLength) {
                    _parser->state = OCWSParserStateComplete;
                }
                break;
            }

            case OCWSParserStateComplete:
                break;
        }

        if (_parser->state == OCWSParserStateComplete) {
            [self _handleCompletedFrame];
            [_parser reset];
        }
    }
}

- (void)_handleCompletedFrame {
    OCWSOpcode opcode = _parser->opcode;
    NSData *payload = _parser->payload;
    BOOL fin = _parser->fin;

    __sync_sub_and_fetch(&sTotalBytesBuffered, (int64_t)[payload length]);

    switch (opcode) {
        case OCWSOpcText:
        case OCWSOpcBinary: {
            if (fin) {
                /* Complete single-frame message */
                [self _deliverMessage:payload opcode:opcode];
            } else {
                /* Start of fragmented message */
                [_fragmentBuffer release];
                _fragmentBuffer = [payload mutableCopy];
                _fragmentOpcode = opcode;
            }
            break;
        }

        case OCWSOpcContinuation: {
            if (_fragmentBuffer) {
                [_fragmentBuffer appendData:payload];

                if ([_fragmentBuffer length] > _maxMessageSize) {
                    [self _failWithCode:OCWSErrorPayloadTooLarge
                                message:@"Fragmented message exceeds max size"];
                    return;
                }

                if (fin) {
                    [self _deliverMessage:_fragmentBuffer opcode:_fragmentOpcode];
                    [_fragmentBuffer release];
                    _fragmentBuffer = nil;
                }
            }
            break;
        }

        case OCWSOpcClose: {
            _receivedClose = YES;
            OCWSCloseCode code = OCWSCloseNoStatus;
            NSString *reason = nil;

            if ([payload length] >= 2) {
                const uint8_t *b = [payload bytes];
                code = (OCWSCloseCode)((b[0] << 8) | b[1]);
                if ([payload length] > 2) {
                    reason = [[[NSString alloc] initWithBytes:b + 2
                                                      length:[payload length] - 2
                                                    encoding:NSUTF8StringEncoding] autorelease];
                }
            }

            if (!_sentClose) {
                /* rfc 6455 5.5.1: echo the status code now; closeWithCode: is async and would run after the teardown below */
                NSData *echo = [NSData data];
                if ([payload length] >= 2) {
                    const uint8_t *b = [payload bytes];
                    uint16_t c = WSEchoCode((uint16_t)((b[0] << 8) | b[1]));
                    uint8_t e[2] = { (uint8_t)(c >> 8), (uint8_t)(c & 0xFF) };
                    echo = [NSData dataWithBytes:e length:2];
                }
                [self _sendFrameWithOpcode:OCWSOpcClose payload:echo];
                _sentClose = YES;
            }

            [self _teardownWithCode:code reason:reason wasClean:YES];
            break;
        }

        case OCWSOpcPing: {
            /* Respond with pong containing same payload */
            [self _sendFrameWithOpcode:OCWSOpcPong payload:payload];
            break;
        }

        case OCWSOpcPong: {
            [_lastPongReceived release];
            _lastPongReceived = [[NSDate date] retain];
            dispatch_async(_delegateQueue, ^{
                if ([_delegate respondsToSelector:@selector(webSocket:didReceivePong:)]) {
                    [_delegate webSocket:self didReceivePong:payload];
                }
            });
            break;
        }

        default:
            break;
    }
}

- (void)_deliverMessage:(NSData *)payload opcode:(OCWSOpcode)opcode {
    if (opcode == OCWSOpcText) {
        NSString *text = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding];
        if (text) {
            dispatch_async(_delegateQueue, ^{
                [_delegate webSocket:self didReceiveMessage:text];
                [text release];
            });
        }
    } else if (opcode == OCWSOpcBinary) {
        NSData *copy = [payload copy];
        dispatch_async(_delegateQueue, ^{
            if ([_delegate respondsToSelector:@selector(webSocket:didReceiveData:)]) {
                [_delegate webSocket:self didReceiveData:copy];
            }
            [copy release];
        });
    }
}

#pragma mark - Frame Writing

- (void)_sendFrameWithOpcode:(OCWSOpcode)opcode payload:(NSData *)payload {
    NSUInteger payloadLen = [payload length];

    /* Calculate frame size: 2 (header) + ext length + 4 (mask) + payload */
    NSUInteger frameSize = 2 + 4 + payloadLen;
    if (payloadLen >= 126 && payloadLen <= 65535) frameSize += 2;
    else if (payloadLen > 65535) frameSize += 8;

    NSMutableData *frame = [[NSMutableData alloc] initWithCapacity:frameSize];

    /* First byte: FIN + opcode */
    uint8_t byte0 = 0x80 | (uint8_t)opcode;  /* FIN = 1 */
    [frame appendBytes:&byte0 length:1];

    /* Second byte: MASK + length */
    /* Client MUST mask all frames per RFC 6455 */
    if (payloadLen < 126) {
        uint8_t byte1 = 0x80 | (uint8_t)payloadLen;
        [frame appendBytes:&byte1 length:1];
    } else if (payloadLen <= 65535) {
        uint8_t byte1 = 0x80 | 126;
        [frame appendBytes:&byte1 length:1];
        uint16_t len16 = CFSwapInt16HostToBig((uint16_t)payloadLen);
        [frame appendBytes:&len16 length:2];
    } else {
        uint8_t byte1 = 0x80 | 127;
        [frame appendBytes:&byte1 length:1];
        uint64_t len64 = CFSwapInt64HostToBig((uint64_t)payloadLen);
        [frame appendBytes:&len64 length:8];
    }

    /* Masking key - 4 random bytes */
    uint8_t mask[4];
    (void)SecRandomCopyBytes(kSecRandomDefault, 4, mask);
    [frame appendBytes:mask length:4];

    /* Masked payload */
    if (payloadLen > 0) {
        const uint8_t *src = [payload bytes];
        uint8_t *masked = (uint8_t *)malloc(payloadLen);
        for (NSUInteger i = 0; i < payloadLen; i++) {
            masked[i] = src[i] ^ mask[i % 4];
        }
        [frame appendBytes:masked length:payloadLen];
        free(masked);
    }

    [self _enqueueWrite:frame];
    [frame release];
}

- (void)_enqueueWrite:(NSData *)data {
    [_writeQueue addObject:data];
    [self _flushWriteBuffer];
}

- (void)_flushWriteBuffer {
    if (_isWriting || [_writeQueue count] == 0) return;
    if (![_outputStream hasSpaceAvailable]) return;

    _isWriting = YES;

    while ([_writeQueue count] > 0 && [_outputStream hasSpaceAvailable]) {
        NSData *data = [_writeQueue objectAtIndex:0];

        if ([_writeBuffer length] == 0) {
            [_writeBuffer setData:data];
        }

        NSInteger written = [_outputStream write:[_writeBuffer bytes]
                                       maxLength:[_writeBuffer length]];

        if (written > 0) {
            __sync_sub_and_fetch(&sTotalBytesBuffered, written);
            if ((NSUInteger)written < [_writeBuffer length]) {
                /* Partial write - keep remainder */
                NSData *remainder = [NSData dataWithBytes:[_writeBuffer bytes] + written
                                                   length:[_writeBuffer length] - written];
                [_writeBuffer setData:remainder];
            } else {
                [_writeBuffer setLength:0];
                [_writeQueue removeObjectAtIndex:0];
            }
        } else if (written < 0) {
            break;
        }
    }

    _isWriting = NO;
}

#pragma mark - Keepalive

- (void)_sendKeepAlivePing {
    dispatch_async(_socketQueue, ^{
        if (_readyState == OCWSReadyStateOpen) {
            [self _sendFrameWithOpcode:OCWSOpcPing payload:nil];
        }
    });
}

#pragma mark - Error Handling

- (void)_handleStreamError:(NSError *)error {
    if (_readyState == OCWSReadyStateClosed) return;

    NSError *wsError = [NSError errorWithDomain:OCWSErrorDomain
                                           code:OCWSErrorConnectionFailed
                                       userInfo:@{
        NSUnderlyingErrorKey: error ?: [NSNull null],
        NSLocalizedDescriptionKey: @"Stream connection error"
    }];

    [self _teardown];
    _readyState = OCWSReadyStateClosed;

    dispatch_async(_delegateQueue, ^{
        [_delegate webSocket:self didFailWithError:wsError];
    });
}

- (void)_handleStreamEnd {
    if (_readyState == OCWSReadyStateOpen || _readyState == OCWSReadyStateConnecting) {
        [self _teardownWithCode:OCWSCloseAbnormal reason:@"Stream ended unexpectedly" wasClean:NO];
    }
}

- (void)_failWithCode:(NSInteger)code message:(NSString *)message {
    NSError *error = [NSError errorWithDomain:OCWSErrorDomain
                                         code:code
                                     userInfo:@{NSLocalizedDescriptionKey: message}];
    [self _teardown];
    _readyState = OCWSReadyStateClosed;

    dispatch_async(_delegateQueue, ^{
        [_delegate webSocket:self didFailWithError:error];
    });
}

- (void)_teardownWithCode:(OCWSCloseCode)code reason:(NSString *)reason wasClean:(BOOL)wasClean {
    [self _teardown];
    _readyState = OCWSReadyStateClosed;

    dispatch_async(_delegateQueue, ^{
        [_delegate webSocket:self didCloseWithCode:code reason:reason wasClean:wasClean];
    });
}

- (void)_teardown {
    if (_pingTimer) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [_pingTimer invalidate];
            _pingTimer = nil;
        });
    }

    [_inputStream  setDelegate:nil];
    [_outputStream setDelegate:nil];
    [_inputStream  removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [_outputStream removeFromRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    [_inputStream  close];
    [_outputStream close];
    [_inputStream  release]; _inputStream  = nil;
    [_outputStream release]; _outputStream = nil;

    [_handshakeBuffer setLength:0];
    [_writeBuffer setLength:0];
    [_writeQueue removeAllObjects];
    [_fragmentBuffer release]; _fragmentBuffer = nil;
    [_parser reset];

    __sync_sub_and_fetch(&sActiveConnections, 1);
}

@end
