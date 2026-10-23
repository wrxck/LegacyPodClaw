/*
 * OCGatewayClient.h
 * LegacyPodClaw - Gateway Protocol Client (Protocol v3)
 *
 * Full implementation of LegacyPodClaw gateway WebSocket protocol:
 * - Challenge/response authentication
 * - Request/response/event frame multiplexing
 * - Chat send with streaming deltas
 * - Session management
 * - Heartbeat monitoring
 * - Auto-reconnection with exponential backoff
 */

#import <Foundation/Foundation.h>
#import "WebSocket.h"

#pragma mark - Protocol Types

extern NSString *const OCGatewayErrorDomain;
extern const NSInteger kOCGatewayProtocolVersion;

typedef NS_ENUM(NSUInteger, OCGatewayConnectionState) {
    OCGatewayStateDisconnected = 0,
    OCGatewayStateConnecting,
    OCGatewayStateAuthenticating,
    OCGatewayStateConnected,
    OCGatewayStateReconnecting
};

typedef NS_ENUM(NSUInteger, OCGatewayAuthMethod) {
    OCGatewayAuthToken = 0,
    OCGatewayAuthPassword,
    OCGatewayAuthDeviceToken,
    OCGatewayAuthBootstrap
};

typedef NS_ENUM(NSUInteger, OCGatewayChatState) {
    OCGatewayChatStateDelta = 0,   // Streaming chunk
    OCGatewayChatStateFinal,       // Complete response
    OCGatewayChatStateAborted,
    OCGatewayChatStateError
};

#pragma mark - Data Models

@interface OCGatewayAuthConfig : NSObject
@property (nonatomic, copy) NSString *token;
@property (nonatomic, copy) NSString *password;
@property (nonatomic, copy) NSString *deviceToken;
@property (nonatomic, copy) NSString *bootstrapToken;
@property (nonatomic, assign) OCGatewayAuthMethod preferredMethod;
@end

@interface OCGatewayServerInfo : NSObject
@property (nonatomic, copy) NSString *version;
@property (nonatomic, copy) NSString *connectionId;
@property (nonatomic, assign) NSUInteger maxPayload;
@property (nonatomic, assign) NSTimeInterval tickInterval;
@property (nonatomic, copy) NSArray *supportedMethods;
@property (nonatomic, copy) NSArray *supportedEvents;
@end

@interface OCGatewayChatEvent : NSObject
@property (nonatomic, copy) NSString *runId;
@property (nonatomic, copy) NSString *sessionKey;
@property (nonatomic, assign) NSUInteger seq;
@property (nonatomic, assign) OCGatewayChatState state;
@property (nonatomic, copy) NSString *messageText;       // Delta or full text
@property (nonatomic, copy) NSString *thinkingText;      // Thinking content
@property (nonatomic, copy) NSString *role;               // "assistant", "user", "system"
@property (nonatomic, assign) NSUInteger inputTokens;
@property (nonatomic, assign) NSUInteger outputTokens;
@property (nonatomic, copy) NSString *stopReason;
@property (nonatomic, copy) NSDictionary *rawPayload;
@end

@interface OCGatewaySession : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) NSString *agentId;
@property (nonatomic, copy) NSDate *createdAt;
@property (nonatomic, copy) NSDate *lastActiveAt;
@property (nonatomic, assign) NSUInteger messageCount;
@end

@interface OCGatewayMessage : NSObject
@property (nonatomic, copy) NSString *messageId;
@property (nonatomic, copy) NSString *role;
@property (nonatomic, copy) NSString *content;
@property (nonatomic, copy) NSString *thinking;
@property (nonatomic, copy) NSDate *timestamp;
@property (nonatomic, copy) NSArray *attachments;
@property (nonatomic, copy) NSDictionary *usage;
@end

#pragma mark - Delegate Protocol

@class OCGatewayClient;

@protocol OCGatewayClientDelegate <NSObject>
@required
- (void)gatewayClient:(OCGatewayClient *)client
   didChangeState:(OCGatewayConnectionState)state;
- (void)gatewayClient:(OCGatewayClient *)client
   didReceiveChatEvent:(OCGatewayChatEvent *)event;
- (void)gatewayClient:(OCGatewayClient *)client
   didFailWithError:(NSError *)error;

@optional
- (void)gatewayClient:(OCGatewayClient *)client
   didConnectWithServerInfo:(OCGatewayServerInfo *)info;
- (void)gatewayClient:(OCGatewayClient *)client
   didReceiveEvent:(NSString *)eventName payload:(NSDictionary *)payload;
- (void)gatewayClientDidReceiveTick:(OCGatewayClient *)client;
- (void)gatewayClient:(OCGatewayClient *)client
   willReconnectAfterDelay:(NSTimeInterval)delay attempt:(NSUInteger)attempt;
@end

#pragma mark - Client Interface

typedef void(^OCGatewayResponseBlock)(NSDictionary *result, NSError *error);
typedef void(^OCGatewayChatStreamBlock)(OCGatewayChatEvent *event);
typedef void(^OCGatewaySessionsBlock)(NSArray *sessions, NSError *error);
typedef void(^OCGatewayHistoryBlock)(NSArray *messages, NSError *error);

@interface OCGatewayClient : NSObject <OCWebSocketDelegate>

@property (nonatomic, assign) id<OCGatewayClientDelegate> delegate;
@property (nonatomic, readonly) OCGatewayConnectionState connectionState;
@property (nonatomic, readonly) OCGatewayServerInfo *serverInfo;
@property (nonatomic, retain) OCGatewayAuthConfig *authConfig;

/* Connection settings */
@property (nonatomic, copy) NSString *host;
@property (nonatomic, assign) NSUInteger port;
@property (nonatomic, assign) BOOL useTLS;
@property (nonatomic, assign) BOOL allowSelfSignedCerts;
/* required with allowSelfSignedCerts: sha-256 of the gateway's certificate */
@property (nonatomic, copy) NSString *pinnedCertSHA256;

/* Client identity */
@property (nonatomic, copy) NSString *clientId;
@property (nonatomic, copy) NSString *clientDisplayName;
@property (nonatomic, copy) NSString *clientVersion;
@property (nonatomic, copy) NSString *deviceId;

/* Reconnection settings */
@property (nonatomic, assign) BOOL autoReconnect;
@property (nonatomic, assign) NSTimeInterval initialReconnectDelay;  // Default 1s
@property (nonatomic, assign) NSTimeInterval maxReconnectDelay;      // Default 60s
@property (nonatomic, assign) NSUInteger maxReconnectAttempts;       // Default 20, 0=unlimited

/* Dispatch queue for delegate callbacks */
@property (nonatomic, retain) dispatch_queue_t delegateQueue;

- (instancetype)init;

/* Connection */
- (void)connect;
- (void)disconnect;

/* Generic RPC */
- (void)request:(NSString *)method
         params:(NSDictionary *)params
       callback:(OCGatewayResponseBlock)callback;

- (void)request:(NSString *)method
         params:(NSDictionary *)params
        timeout:(NSTimeInterval)timeout
       callback:(OCGatewayResponseBlock)callback;

/* Chat */
- (void)sendMessage:(NSString *)message
         sessionKey:(NSString *)sessionKey
           thinking:(NSString *)thinking
        attachments:(NSArray *)attachments
     idempotencyKey:(NSString *)idempotencyKey
       streamBlock:(OCGatewayChatStreamBlock)streamBlock
        completion:(OCGatewayResponseBlock)completion;

- (void)abortChat:(NSString *)sessionKey runId:(NSString *)runId;

/* Sessions */
- (void)listSessions:(OCGatewaySessionsBlock)callback;
- (void)createSession:(NSString *)displayName callback:(OCGatewayResponseBlock)callback;
- (void)deleteSession:(NSString *)sessionKey callback:(OCGatewayResponseBlock)callback;
- (void)resetSession:(NSString *)sessionKey callback:(OCGatewayResponseBlock)callback;

/* History */
- (void)getHistory:(NSString *)sessionKey
             limit:(NSUInteger)limit
          callback:(OCGatewayHistoryBlock)callback;

/* Health */
- (void)checkHealth:(OCGatewayResponseBlock)callback;

/* Subscribe to session events */
- (void)subscribeSession:(NSString *)sessionKey;
- (void)unsubscribeSession:(NSString *)sessionKey;

@end
