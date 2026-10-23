/* a small websocket client on wolfssl, because securetransport on ios 6 cannot reach discord or slack */

#import <Foundation/Foundation.h>
#import "TLSClient.h"

@class OCTLSWebSocket;

/* the userInfo key that holds the server's close code as an NSNumber, when it sent one */
extern NSString *const OCTLSWebSocketCloseCodeKey;

/* all callbacks arrive on the main queue */
@protocol OCTLSWebSocketDelegate <NSObject>
- (void)webSocketDidOpen:(OCTLSWebSocket *)ws;
- (void)webSocket:(OCTLSWebSocket *)ws didReceiveText:(NSString *)text;
- (void)webSocket:(OCTLSWebSocket *)ws didCloseWithError:(NSError *)error;
@end

@interface OCTLSWebSocket : NSObject <CPTLSConnectionDelegate>

@property (nonatomic, assign) id<OCTLSWebSocketDelegate> delegate;
@property (nonatomic, readonly) BOOL isOpen;
/* a larger message closes the socket; default 2 mb */
@property (nonatomic, assign) NSUInteger maxMessageSize;

- (id)initWithURL:(NSURL *)url;
- (void)open;
- (void)sendText:(NSString *)text;
/* no delegate callback follows */
- (void)close;

@end
