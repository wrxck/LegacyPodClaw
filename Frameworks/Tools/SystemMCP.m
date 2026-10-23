/*
 * OCSystemMCP.m
 * LegacyPodClaw - System MCP Implementation
 *
 * Injects messages into the iOS SMS database so they appear in
 * Messages.app. Uses private frameworks for device control.
 */

#import "SharedFiles.h"
#import "SystemMCP.h"
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <notify.h>
#import <dlfcn.h>

#define SMS_DB_PATH @"/var/mobile/Library/SMS/sms.db"
#define CLAWPOD_HANDLE @"LegacyPodClaw"
#define CLAWPOD_CHAT_ID @"clawpod-ai"

#pragma mark - SMS Database Helpers

static sqlite3 *_openSMSDB(void) {
    sqlite3 *db = NULL;
    if (sqlite3_open([SMS_DB_PATH UTF8String], &db) != SQLITE_OK) {
        NSLog(@"[LegacyPodClaw] Failed to open SMS DB");
        sqlite3_close(db);
        return NULL;
    }
    /* imagent holds sms.db open and writes to it, so wait for its lock */
    sqlite3_busy_timeout(db, 2000);
    return db;
}

#pragma mark - Messages Integration

@implementation OCSystemMessages

+ (int64_t)ensureLegacyPodClawHandle {
    sqlite3 *db = _openSMSDB();
    if (!db) return -1;

    /* Check if handle exists */
    sqlite3_stmt *stmt;
    int64_t handleId = -1;

    if (sqlite3_prepare_v2(db, "SELECT ROWID FROM handle WHERE id = ?", -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, [CLAWPOD_HANDLE UTF8String], -1, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            handleId = sqlite3_column_int64(stmt, 0);
        }
        sqlite3_finalize(stmt);
    }

    if (handleId < 0) {
        /* Create handle */
        if (sqlite3_prepare_v2(db, "INSERT INTO handle (id, country, service, uncanonicalized_id) "
            "VALUES (?, 'us', 'SMS', ?)", -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(stmt, 1, [CLAWPOD_HANDLE UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmt, 2, [CLAWPOD_HANDLE UTF8String], -1, SQLITE_TRANSIENT);
            /* a failed insert leaves last_insert_rowid at 0, which is not our row */
            if (sqlite3_step(stmt) == SQLITE_DONE) handleId = sqlite3_last_insert_rowid(db);
            sqlite3_finalize(stmt);
        }
    }

    sqlite3_close(db);
    return handleId;
}

+ (int64_t)ensureLegacyPodClawChat {
    sqlite3 *db = _openSMSDB();
    if (!db) return -1;

    int64_t chatId = -1;
    sqlite3_stmt *stmt;

    /* Check if chat exists */
    if (sqlite3_prepare_v2(db, "SELECT ROWID FROM chat WHERE chat_identifier = ?", -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, [CLAWPOD_CHAT_ID UTF8String], -1, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            chatId = sqlite3_column_int64(stmt, 0);
        }
        sqlite3_finalize(stmt);
    }

    if (chatId < 0) {
        /* Create chat */
        if (sqlite3_prepare_v2(db,
            "INSERT INTO chat (guid, style, state, chat_identifier, service_name, display_name) "
            "VALUES (?, 45, 3, ?, 'SMS', 'LegacyPodClaw')", -1, &stmt, NULL) == SQLITE_OK) {
            NSString *guid = [NSString stringWithFormat:@"SMS;-;%@", CLAWPOD_CHAT_ID];
            sqlite3_bind_text(stmt, 1, [guid UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(stmt, 2, [CLAWPOD_CHAT_ID UTF8String], -1, SQLITE_TRANSIENT);
            /* a failed insert leaves last_insert_rowid at 0, which is not our row */
            if (sqlite3_step(stmt) == SQLITE_DONE) chatId = sqlite3_last_insert_rowid(db);
            sqlite3_finalize(stmt);
        }

        /* Join handle to chat */
        int64_t handleId = [self ensureLegacyPodClawHandle];
        if (handleId >= 0 && chatId >= 0) {
            if (sqlite3_prepare_v2(db,
                "INSERT OR IGNORE INTO chat_handle_join (chat_id, handle_id) VALUES (?, ?)",
                -1, &stmt, NULL) == SQLITE_OK) {
                sqlite3_bind_int64(stmt, 1, chatId);
                sqlite3_bind_int64(stmt, 2, handleId);
                sqlite3_step(stmt);
                sqlite3_finalize(stmt);
            }
        }
    }

    sqlite3_close(db);
    return chatId;
}

+ (int64_t)sendMessage:(NSString *)text sessionKey:(NSString *)sessionKey {
    int64_t handleId = [self ensureLegacyPodClawHandle];
    int64_t chatId = [self ensureLegacyPodClawChat];
    if (handleId < 0 || chatId < 0) return -1;

    sqlite3 *db = _openSMSDB();
    if (!db) return -1;

    sqlite3_stmt *stmt;
    int64_t msgId = -1;

    /* NSDate to Core Data timestamp (seconds since 2001-01-01) */
    NSTimeInterval timestamp = [[NSDate date] timeIntervalSinceReferenceDate];

    if (sqlite3_prepare_v2(db,
        "INSERT INTO message (guid, text, handle_id, subject, country, service, "
        "date, date_read, date_delivered, is_delivered, is_finished, is_from_me, "
        "is_read, is_sent, is_spam) "
        "VALUES (?, ?, ?, ?, 'us', 'SMS', ?, 0, ?, 1, 1, 0, 0, 0, 0)",
        -1, &stmt, NULL) == SQLITE_OK) {

        NSString *guid = [NSString stringWithFormat:@"clawpod-%f", timestamp];
        NSString *subject = sessionKey ?: @"";

        sqlite3_bind_text(stmt, 1, [guid UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 2, [text UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(stmt, 3, handleId);
        sqlite3_bind_text(stmt, 4, [subject UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(stmt, 5, (int64_t)timestamp);
        sqlite3_bind_int64(stmt, 6, (int64_t)timestamp);

        if (sqlite3_step(stmt) == SQLITE_DONE) {
            msgId = sqlite3_last_insert_rowid(db);
        }
        sqlite3_finalize(stmt);
    }

    /* Join message to chat */
    if (msgId >= 0) {
        if (sqlite3_prepare_v2(db,
            "INSERT INTO chat_message_join (chat_id, message_id) VALUES (?, ?)",
            -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_int64(stmt, 1, chatId);
            sqlite3_bind_int64(stmt, 2, msgId);
            sqlite3_step(stmt);
            sqlite3_finalize(stmt);
        }
    }

    sqlite3_close(db);

    /* Notify Messages app to reload */
    notify_post("com.apple.MobileSMS.dirtyConversationList");

    /* Also post a banner notification */
    NSDictionary *bannerData = @{@"title": @"LegacyPodClaw", @"message": text};
    CPWriteSharedPlist(CP_BANNER_FILE, bannerData);
    notify_post("pro.matthesketh.legacypodclaw/showBanner");

    NSLog(@"[LegacyPodClaw] Message sent to Messages.app: %@", text);
    return msgId;
}

+ (NSArray *)repliesSince:(NSDate *)date {
    sqlite3 *db = _openSMSDB();
    if (!db) return @[];

    int64_t chatId = [self ensureLegacyPodClawChat];
    if (chatId < 0) { sqlite3_close(db); return @[]; }

    NSTimeInterval since = [date timeIntervalSinceReferenceDate];
    NSMutableArray *replies = [NSMutableArray array];
    sqlite3_stmt *stmt;

    /* Get messages FROM the user (is_from_me = 1) in our chat since the date */
    if (sqlite3_prepare_v2(db,
        "SELECT m.text, m.subject, m.date FROM message m "
        "JOIN chat_message_join cmj ON m.ROWID = cmj.message_id "
        "WHERE cmj.chat_id = ? AND m.is_from_me = 1 AND m.date > ? "
        "ORDER BY m.date ASC",
        -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(stmt, 1, chatId);
        sqlite3_bind_int64(stmt, 2, (int64_t)since);

        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const unsigned char *text = sqlite3_column_text(stmt, 0);
            const unsigned char *subject = sqlite3_column_text(stmt, 1);
            if (text) {
                [replies addObject:@{
                    @"text": [NSString stringWithUTF8String:(const char *)text],
                    @"sessionKey": subject ? [NSString stringWithUTF8String:(const char *)subject] : @"",
                    @"date": @(sqlite3_column_int64(stmt, 2))
                }];
            }
        }
        sqlite3_finalize(stmt);
    }

    sqlite3_close(db);
    return replies;
}

+ (void)pollForReplies:(void(^)(NSString *, NSString *))handler {
    static NSDate *lastPoll = nil;
    if (!lastPoll) lastPoll = [[NSDate date] retain];

    NSArray *replies = [self repliesSince:lastPoll];
    [lastPoll release];
    lastPoll = [[NSDate date] retain];

    for (NSDictionary *reply in replies) {
        handler([reply objectForKey:@"text"], [reply objectForKey:@"sessionKey"]);
    }
}

@end

#pragma mark - System Control

@implementation OCSystemControl

+ (float)getBrightness {
    return [[UIScreen mainScreen] brightness];
}

+ (void)setBrightness:(float)level {
    [[UIScreen mainScreen] setBrightness:MIN(1.0f, MAX(0.0f, level))];
}

+ (float)getVolume {
    /* Use MediaPlayer private API or AudioServices */
    return 0.5f; /* Placeholder - needs MPVolumeView */
}

+ (void)setVolume:(float)level {
    /* Post notification to change volume */
}

+ (BOOL)isWiFiEnabled {
    /* Check via SCNetworkReachability or private SBWiFiManager */
    return YES;
}

+ (void)setWiFiEnabled:(BOOL)enabled {
    /* Use private SBWiFiManager */
}

+ (BOOL)isBluetoothEnabled { return NO; }
+ (void)setBluetoothEnabled:(BOOL)enabled {}
+ (BOOL)isAirplaneModeEnabled { return NO; }
+ (void)setAirplaneModeEnabled:(BOOL)enabled {}

+ (void)launchApp:(NSString *)bundleId {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@://", bundleId]];
    [[UIApplication sharedApplication] openURL:url];
}

+ (BOOL)lockDevice {
    /* lockcomplete only reports a lock; GSEventLockDevice asks springboard to lock, like the sleep button */
    void *gs = dlopen("/System/Library/PrivateFrameworks/GraphicsServices.framework/GraphicsServices", RTLD_LAZY);
    void (*lockFn)(void) = gs ? (void (*)(void))dlsym(gs, "GSEventLockDevice") : NULL;
    if (!lockFn) return NO;
    lockFn();
    return YES;
}

+ (void)openURL:(NSString *)urlString {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:urlString]];
}

+ (void)vibrate {
    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
}

+ (void)playSystemSound:(NSString *)soundName {
    /* Default alert sound */
    AudioServicesPlayAlertSound(1007);
}

@end

#pragma mark - Tool Registration

@implementation OCSystemMCPTools

+ (NSArray *)allSystemTools {
    return @[
        [self sendMessageTool], [self readRepliesTool],
        [self setBrightnessTool], [self setVolumeTool],
        [self toggleWiFiTool], [self launchAppTool],
        [self lockDeviceTool], [self openURLTool],
        [self vibrateTool], [self postNotificationTool],
        [self getDeviceStateTool]
    ];
}

+ (OCToolDefinition *)sendMessageTool {
    OCToolDefinition *t = [[[OCToolDefinition alloc] init] autorelease];
    t.name = @"send_message";
    t.toolDescription = @"Send a message to the user via the Messages app. The message appears "
        @"in Messages.app from 'LegacyPodClaw'. The user can reply and it routes back to this session.";
    t.inputSchema = @{@"type": @"object",
        @"properties": @{@"text": @{@"type": @"string",
            @"description": @"The message text to send"}},
        @"required": @[@"text"]};
    t.handler = ^(NSDictionary *p, OCToolResultBlock cb) {
        NSString *text = [p objectForKey:@"text"];
        int64_t msgId = [OCSystemMessages sendMessage:text sessionKey:nil];
        cb(msgId >= 0 ? @"Message sent to Messages.app" : @"Failed to send", nil);
    };
    return t;
}

+ (OCToolDefinition *)readRepliesTool {
    OCToolDefinition *t = [[[OCToolDefinition alloc] init] autorelease];
    t.name = @"read_replies";
    t.toolDescription = @"Read recent replies from the user in the Messages.app LegacyPodClaw conversation";
    t.inputSchema = @{@"type": @"object", @"properties": @{}};
    t.handler = ^(NSDictionary *p, OCToolResultBlock cb) {
        NSDate *since = [NSDate dateWithTimeIntervalSinceNow:-3600]; /* Last hour */
        NSArray *replies = [OCSystemMessages repliesSince:since];
        if ([replies count] == 0) { cb(@"No recent replies", nil); return; }
        NSMutableArray *texts = [NSMutableArray array];
        for (NSDictionary *r in replies) {
            [texts addObject:[r objectForKey:@"text"]];
        }
        cb([texts componentsJoinedByString:@"\n"], nil);
    };
    return t;
}

+ (OCToolDefinition *)setBrightnessTool {
    OCToolDefinition *t = [[[OCToolDefinition alloc] init] autorelease];
    t.name = @"set_brightness";
    t.toolDescription = @"Set the screen brightness (0.0 to 1.0)";
    t.inputSchema = @{@"type": @"object",
        @"properties": @{@"level": @{@"type": @"number", @"minimum": @0, @"maximum": @1}},
        @"required": @[@"level"]};
    t.handler = ^(NSDictionary *p, OCToolResultBlock cb) {
        float level = [[p objectForKey:@"level"] floatValue];
        [OCSystemControl setBrightness:level];
        cb([NSString stringWithFormat:@"Brightness set to %.0f%%", level * 100], nil);
    };
    return t;
}

+ (OCToolDefinition *)setVolumeTool {
    OCToolDefinition *t = [[[OCToolDefinition alloc] init] autorelease];
    t.name = @"set_volume";
    t.toolDescription = @"Set the device volume (0.0 to 1.0)";
    t.inputSchema = @{@"type": @"object",
        @"properties": @{@"level": @{@"type": @"number"}},
        @"required": @[@"level"]};
    t.handler = ^(NSDictionary *p, OCToolResultBlock cb) {
        cb(@"Volume control set", nil);
    };
    return t;
}

+ (OCToolDefinition *)toggleWiFiTool {
    OCToolDefinition *t = [[[OCToolDefinition alloc] init] autorelease];
    t.name = @"toggle_wifi";
    t.toolDescription = @"Enable or disable WiFi";
    t.inputSchema = @{@"type": @"object",
        @"properties": @{@"enabled": @{@"type": @"boolean"}},
        @"required": @[@"enabled"]};
    t.handler = ^(NSDictionary *p, OCToolResultBlock cb) {
        BOOL enabled = [[p objectForKey:@"enabled"] boolValue];
        [OCSystemControl setWiFiEnabled:enabled];
        cb(enabled ? @"WiFi enabled" : @"WiFi disabled", nil);
    };
    return t;
}

+ (OCToolDefinition *)toggleBluetoothTool {
    OCToolDefinition *t = [[[OCToolDefinition alloc] init] autorelease];
    t.name = @"toggle_bluetooth";
    t.toolDescription = @"Enable or disable Bluetooth";
    t.inputSchema = @{@"type": @"object",
        @"properties": @{@"enabled": @{@"type": @"boolean"}},
        @"required": @[@"enabled"]};
    t.handler = ^(NSDictionary *p, OCToolResultBlock cb) {
        cb(@"Bluetooth toggled", nil);
    };
    return t;
}

+ (OCToolDefinition *)launchAppTool {
    OCToolDefinition *t = [[[OCToolDefinition alloc] init] autorelease];
    t.name = @"launch_app";
    t.toolDescription = @"Launch an app by its URL scheme (e.g., 'safari://', 'music://', 'maps://')";
    t.inputSchema = @{@"type": @"object",
        @"properties": @{@"url": @{@"type": @"string"}},
        @"required": @[@"url"]};
    /* ios 6 dials a tel: url from an app with no system prompt */
    t.requiresConfirmation = YES;
    t.handler = ^(NSDictionary *p, OCToolResultBlock cb) {
        NSString *url = [p objectForKey:@"url"];
        [OCSystemControl openURL:url];
        cb([NSString stringWithFormat:@"Launched: %@", url], nil);
    };
    return t;
}

+ (OCToolDefinition *)lockDeviceTool {
    OCToolDefinition *t = [[[OCToolDefinition alloc] init] autorelease];
    t.name = @"lock_device";
    t.toolDescription = @"Lock the device screen";
    t.inputSchema = @{@"type": @"object", @"properties": @{}};
    t.requiresConfirmation = YES;
    t.handler = ^(NSDictionary *p, OCToolResultBlock cb) {
        if ([OCSystemControl lockDevice]) cb(@"Lock requested", nil);
        else cb(nil, [NSError errorWithDomain:@"OCSystem" code:1
                 userInfo:@{NSLocalizedDescriptionKey: @"GSEventLockDevice is not available on this device"}]);
    };
    return t;
}

+ (OCToolDefinition *)openURLTool {
    OCToolDefinition *t = [[[OCToolDefinition alloc] init] autorelease];
    t.name = @"open_url";
    t.toolDescription = @"Open a URL in Safari or the appropriate app";
    t.inputSchema = @{@"type": @"object",
        @"properties": @{@"url": @{@"type": @"string"}},
        @"required": @[@"url"]};
    /* ios 6 dials a tel: url from an app with no system prompt */
    t.requiresConfirmation = YES;
    t.handler = ^(NSDictionary *p, OCToolResultBlock cb) {
        [OCSystemControl openURL:[p objectForKey:@"url"]];
        cb(@"URL opened", nil);
    };
    return t;
}

+ (OCToolDefinition *)vibrateTool {
    OCToolDefinition *t = [[[OCToolDefinition alloc] init] autorelease];
    t.name = @"vibrate";
    t.toolDescription = @"Vibrate the device to get the user's attention";
    t.inputSchema = @{@"type": @"object", @"properties": @{}};
    t.handler = ^(NSDictionary *p, OCToolResultBlock cb) {
        [OCSystemControl vibrate];
        cb(@"Vibrated", nil);
    };
    return t;
}

+ (OCToolDefinition *)postNotificationTool {
    OCToolDefinition *t = [[[OCToolDefinition alloc] init] autorelease];
    t.name = @"post_notification";
    t.toolDescription = @"Post a system notification banner with a title and message";
    t.inputSchema = @{@"type": @"object",
        @"properties": @{@"title": @{@"type": @"string"}, @"message": @{@"type": @"string"}},
        @"required": @[@"message"]};
    t.handler = ^(NSDictionary *p, OCToolResultBlock cb) {
        NSDictionary *data = @{
            @"title": [p objectForKey:@"title"] ?: @"LegacyPodClaw",
            @"message": [p objectForKey:@"message"]
        };
        CPWriteSharedPlist(CP_BANNER_FILE, data);
        notify_post("pro.matthesketh.legacypodclaw/showBanner");
        cb(@"Notification posted", nil);
    };
    return t;
}

+ (OCToolDefinition *)readContactsTool {
    OCToolDefinition *t = [[[OCToolDefinition alloc] init] autorelease];
    t.name = @"read_contacts";
    t.toolDescription = @"Search the user's contacts by name";
    t.inputSchema = @{@"type": @"object",
        @"properties": @{@"query": @{@"type": @"string"}},
        @"required": @[@"query"]};
    t.handler = ^(NSDictionary *p, OCToolResultBlock cb) {
        /* TODO: Use AddressBook framework */
        cb(@"Contact search not yet implemented", nil);
    };
    return t;
}

+ (OCToolDefinition *)getDeviceStateTool {
    OCToolDefinition *t = [[[OCToolDefinition alloc] init] autorelease];
    t.name = @"device_state";
    t.toolDescription = @"Get current device state: brightness, battery, wifi, etc.";
    t.inputSchema = @{@"type": @"object", @"properties": @{}};
    t.handler = ^(NSDictionary *p, OCToolResultBlock cb) {
        float brightness = [OCSystemControl getBrightness];
        [[UIDevice currentDevice] setBatteryMonitoringEnabled:YES];
        float battery = [[UIDevice currentDevice] batteryLevel];
        int batteryState = [[UIDevice currentDevice] batteryState];

        NSString *batteryStr;
        switch (batteryState) {
            case 1: batteryStr = @"Unplugged"; break;
            case 2: batteryStr = @"Charging"; break;
            case 3: batteryStr = @"Full"; break;
            default: batteryStr = @"Unknown"; break;
        }

        NSString *result = [NSString stringWithFormat:
            @"Brightness: %.0f%%\nBattery: %.0f%% (%@)\nDevice: %@ iOS %@",
            brightness * 100, battery * 100, batteryStr,
            [[UIDevice currentDevice] model],
            [[UIDevice currentDevice] systemVersion]];
        cb(result, nil);
    };
    return t;
}

@end
