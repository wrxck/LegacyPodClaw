/*
 * TLSClient.h
 * LegacyPodClaw - HTTPS client on wolfSSL (TLS 1.2/1.3)
 */

#import <Foundation/Foundation.h>

extern NSString *const CPTLSErrorDomain;

enum {
    CPTLSErrorSetup = -1,
    CPTLSErrorDNS = -2,
    CPTLSErrorConnect = -3,
    CPTLSErrorHandshake = -4,
    CPTLSErrorPinning = -5,
    CPTLSErrorIO = -6,
    CPTLSErrorProtocol = -7,
    CPTLSErrorTooLarge = -8,
    CPTLSErrorBadRequest = -9,
};

typedef void(^CPHTTPSCompletion)(NSData *data, NSInteger statusCode, NSError *error);
typedef void(^CPHTTPSStreamChunk)(NSData *chunk);

@interface CPTLSClient : NSObject

+ (void)request:(NSString *)urlString
         method:(NSString *)method
        headers:(NSDictionary *)headers
           body:(NSData *)body
     completion:(CPHTTPSCompletion)completion;

/* timeout bounds the whole request; 0 means the default budget of 600 s */
+ (void)request:(NSString *)urlString
         method:(NSString *)method
        headers:(NSDictionary *)headers
           body:(NSData *)body
        timeout:(NSTimeInterval)timeout
     completion:(CPHTTPSCompletion)completion;

/* onChunk receives decoded body bytes on the main queue as they arrive; completion gets the body only for a non-2xx status */
+ (void)streamRequest:(NSString *)urlString
               method:(NSString *)method
              headers:(NSDictionary *)headers
                 body:(NSData *)body
              onChunk:(CPHTTPSStreamChunk)onChunk
           completion:(CPHTTPSCompletion)completion;

+ (void)postJSON:(NSString *)urlString
         headers:(NSDictionary *)headers
            body:(NSDictionary *)jsonBody
      completion:(void(^)(NSDictionary *json, NSError *error))completion;

/* base64 sha-256 spki hashes of the leaf key; only the leaf is checked, so pin a key the server keeps across renewals */
+ (void)setPinnedSPKIHashes:(NSArray *)hashes forHost:(NSString *)host;

@end

@class CPTLSConnection;

/* all callbacks arrive on the main queue */
@protocol CPTLSConnectionDelegate <NSObject>
- (void)connectionDidOpen:(CPTLSConnection *)connection;
- (void)connection:(CPTLSConnection *)connection didReceiveData:(NSData *)data;
- (void)connection:(CPTLSConnection *)connection didCloseWithError:(NSError *)error;
@end

/* a long-lived socket for irc and websockets; tls uses the same ca bundle and host check as requests */
@interface CPTLSConnection : NSObject

@property (nonatomic, assign) id<CPTLSConnectionDelegate> delegate;
@property (nonatomic, readonly) NSString *host;
@property (nonatomic, readonly) int port;
@property (nonatomic, readonly) BOOL useTLS;

- (id)initWithHost:(NSString *)host port:(int)port useTLS:(BOOL)useTLS;
- (void)open;
- (void)sendData:(NSData *)data;
/* no delegate callback follows a close the owner asked for */
- (void)close;

@end
