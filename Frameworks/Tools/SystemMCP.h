/*
 * OCSystemMCP.h
 * LegacyPodClaw - System MCP (Model Context Protocol) Tools
 *
 * Provides AI-invocable system actions:
 * - Send messages via the Messages app (SMS database injection)
 * - Post system notifications
 * - Control device settings (brightness, volume, wifi, bluetooth)
 * - Read contacts, calendar, reminders
 * - Launch apps
 * - Take screenshots
 * - Control media playback
 *
 * Messages appear in the Messages app as from "LegacyPodClaw" - users
 * can reply and the reply is routed back to the relevant session.
 */

#import <Foundation/Foundation.h>
#import <sqlite3.h>
#import "Agent.h"

#pragma mark - Messages Integration

@interface OCSystemMessages : NSObject

/* Send a message that appears in Messages.app from "LegacyPodClaw".
 * Creates a chat thread if one doesn't exist.
 * Returns the message ROWID. */
+ (int64_t)sendMessage:(NSString *)text
             sessionKey:(NSString *)sessionKey;

/* Read replies from the LegacyPodClaw chat thread since a given date */
+ (NSArray *)repliesSince:(NSDate *)date;

/* Get or create the LegacyPodClaw handle and chat in the SMS database */
+ (int64_t)ensureLegacyPodClawHandle;
+ (int64_t)ensureLegacyPodClawChat;

/* Check for new replies and dispatch to sessions */
+ (void)pollForReplies:(void(^)(NSString *text, NSString *sessionKey))handler;

@end

#pragma mark - System Control Tools

@interface OCSystemControl : NSObject

/* Screen brightness (0.0 - 1.0) */
+ (float)getBrightness;
+ (void)setBrightness:(float)level;

/* Volume (0.0 - 1.0) */
+ (float)getVolume;
+ (void)setVolume:(float)level;

/* WiFi */
+ (BOOL)isWiFiEnabled;
+ (void)setWiFiEnabled:(BOOL)enabled;

/* Bluetooth */
+ (BOOL)isBluetoothEnabled;
+ (void)setBluetoothEnabled:(BOOL)enabled;

/* Airplane Mode */
+ (BOOL)isAirplaneModeEnabled;
+ (void)setAirplaneModeEnabled:(BOOL)enabled;

/* Launch an app by bundle ID */
+ (void)launchApp:(NSString *)bundleId;

/* Lock the device */
+ (BOOL)lockDevice;

/* Open a URL */
+ (void)openURL:(NSString *)urlString;

/* Vibrate */
+ (void)vibrate;

/* Play system sound */
+ (void)playSystemSound:(NSString *)soundName;

@end

#pragma mark - System MCP Tool Registration

@interface OCSystemMCPTools : NSObject

/* Returns all system MCP tools as OCToolDefinition array */
+ (NSArray *)allSystemTools;

/* Individual tool factories */
+ (OCToolDefinition *)sendMessageTool;
+ (OCToolDefinition *)readRepliesTool;
+ (OCToolDefinition *)setBrightnessTool;
+ (OCToolDefinition *)setVolumeTool;
+ (OCToolDefinition *)toggleWiFiTool;
+ (OCToolDefinition *)toggleBluetoothTool;
+ (OCToolDefinition *)launchAppTool;
+ (OCToolDefinition *)lockDeviceTool;
+ (OCToolDefinition *)openURLTool;
+ (OCToolDefinition *)vibrateTool;
+ (OCToolDefinition *)postNotificationTool;
+ (OCToolDefinition *)readContactsTool;
+ (OCToolDefinition *)getDeviceStateTool;

@end
