/*
 * AppDelegate.h
 * LegacyPodClaw - Main Application Delegate
 */

#import <UIKit/UIKit.h>
#import "GatewayClient.h"
#import "ChatSession.h"
#import "Store.h"
#import "MemoryPool.h"
#import "Agent.h"
#import "GatewayServer.h"
#import "ChannelManager.h"
#import "ChannelRouter.h"
#import "PluginSDK.h"

@class OCRootViewController;

@interface AppDelegate : UIResponder <UIApplicationDelegate,
                                       OCGatewayClientDelegate,
                                       OCSessionManagerDelegate,
                                       UIAlertViewDelegate>

@property (nonatomic, retain) UIWindow *window;
@property (nonatomic, retain) OCRootViewController *rootViewController;

/* Core services */
@property (nonatomic, retain) OCGatewayClient *gateway;
@property (nonatomic, retain) OCStore *store;
@property (nonatomic, retain) OCSessionManager *sessionManager;
@property (nonatomic, retain) OCKeyValueStore *settings;
@property (nonatomic, retain) OCAgent *localAgent;
@property (nonatomic, retain) OCGatewayServer *gatewayServer;
@property (nonatomic, readonly) OCChannelManager *channelManager;
@property (nonatomic, readonly) OCPluginManager *pluginManager;

/* Singleton access */
+ (AppDelegate *)shared;

/* Gateway server on this device */
- (BOOL)startGatewayServer:(NSError **)error;
- (void)stopGatewayServer;

/* Connection */
- (void)connectToGateway;
- (void)disconnectFromGateway;

/* Settings persistence */
- (void)saveConnectionSettings;
- (void)loadConnectionSettings;

@end
