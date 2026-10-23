/*
 * OCWebSocket.h
 * LegacyPodClaw - Lightweight WebSocket Client (RFC 6455)
 *
 * Custom framework for iOS 6.1 on iPod Touch 4th gen (ARMv7, 256MB RAM).
 * Uses CFStream/NSStream for socket I/O - no third-party dependencies.
 * Memory-conservative: pooled read buffers, streaming frame parser.
 */

#import <Foundation/Foundation.h>
#import <Security/Security.h>

#pragma mark - Constants

typedef NS_ENUM(NSUInteger, OCWSReadyState) {
    OCWSReadyStateConnecting = 0,
    OCWSReadyStateOpen       = 1,
    OCWSReadyStateClosing    = 2,
    OCWSReadyStateClosed     = 3
};

typedef NS_ENUM(NSUInteger, OCWSOpcode) {
    OCWSOpcContinuation = 0x0,
    OCWSOpcText         = 0x1,
    OCWSOpcBinary       = 0x2,
    OCWSOpcClose        = 0x8,
    OCWSOpcPing         = 0x9,
    OCWSOpcPong         = 0xA
};

typedef NS_ENUM(NSInteger, OCWSCloseCode) {
    OCWSCloseNormal           = 1000,
    OCWSCloseGoingAway        = 1001,
    OCWSCloseProtocolError    = 1002,
    OCWSCloseUnsupported      = 1003,
    OCWSCloseNoStatus         = 1005,
    OCWSCloseAbnormal         = 1006,
    OCWSCloseInvalidPayload   = 1007,
    OCWSClosePolicyViolation  = 1008,
    OCWSCloseMessageTooBig    = 1009,
    OCWSCloseMissingExtension = 1010,
    OCWSCloseInternalError    = 1011
};

extern NSString *const OCWSErrorDomain;
extern const NSInteger OCWSErrorHandshakeFailed;
extern const NSInteger OCWSErrorConnectionFailed;
extern const NSInteger OCWSErrorFrameInvalid;
extern const NSInteger OCWSErrorPayloadTooLarge;

#pragma mark - Delegate Protocol

@class OCWebSocket;

@protocol OCWebSocketDelegate <NSObject>
@required
- (void)webSocketDidOpen:(OCWebSocket *)ws;
- (void)webSocket:(OCWebSocket *)ws didReceiveMessage:(NSString *)message;
- (void)webSocket:(OCWebSocket *)ws didCloseWithCode:(OCWSCloseCode)code
           reason:(NSString *)reason wasClean:(BOOL)wasClean;
- (void)webSocket:(OCWebSocket *)ws didFailWithError:(NSError *)error;

@optional
- (void)webSocket:(OCWebSocket *)ws didReceiveData:(NSData *)data;
- (void)webSocket:(OCWebSocket *)ws didReceivePong:(NSData *)payload;
- (void)webSocketDidStartTLSHandshake:(OCWebSocket *)ws;
- (void)webSocket:(OCWebSocket *)ws didValidateTLSWithTrust:(SecTrustRef)trust;
@end

#pragma mark - OCWebSocket Interface

@interface OCWebSocket : NSObject <NSStreamDelegate>

@property (nonatomic, assign) id<OCWebSocketDelegate> delegate;
@property (nonatomic, readonly) OCWSReadyState readyState;
@property (nonatomic, readonly) NSURL *url;
@property (nonatomic, assign) NSUInteger maxFrameSize;       // Default 1MB
@property (nonatomic, assign) NSUInteger maxMessageSize;     // Default 4MB
@property (nonatomic, assign) NSUInteger readBufferSize;     // Default 4KB (conservative)
@property (nonatomic, assign) NSTimeInterval pingInterval;   // Default 30s, 0 to disable
/* with allowSelfSignedCerts the chain is not checked, so the leaf must match this sha-256 (hex, colons allowed) */
@property (nonatomic, assign) BOOL allowSelfSignedCerts;
@property (nonatomic, copy)   NSString *pinnedCertSHA256;
@property (nonatomic, copy)   NSDictionary *customHeaders;
@property (nonatomic, copy)   NSArray *requestedProtocols;

/* Dispatch queue for delegate callbacks. Defaults to main queue. */
@property (nonatomic, retain) dispatch_queue_t delegateQueue;

- (instancetype)initWithURL:(NSURL *)url;
- (instancetype)initWithURL:(NSURL *)url protocols:(NSArray *)protocols;

- (void)open;
- (void)close;
- (void)closeWithCode:(OCWSCloseCode)code reason:(NSString *)reason;

- (void)sendText:(NSString *)text;
- (void)sendData:(NSData *)data;
- (void)sendPing:(NSData *)payload;

/* Memory diagnostics */
+ (NSUInteger)activeConnectionCount;
+ (NSUInteger)totalBytesBuffered;

@end
