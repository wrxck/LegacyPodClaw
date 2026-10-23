/*
 * LegacyPodClawPrefsRootListController.m
 * LegacyPodClaw - Settings.app PreferenceBundle Implementation
 *
 * Adds LegacyPodClaw settings to the stock Settings.app via PreferenceLoader.
 * Posts Darwin notifications when settings change so the app can reload.
 */

#import "SharedFiles.h"
#import "LegacyPodClawPrefsRootListController.h"
#import <notify.h>
#import <objc/message.h>
#import <sqlite3.h>
#import <AudioToolbox/AudioToolbox.h>
#import <sys/sysctl.h>
#import <signal.h>
#import "SecretStore.h"

#define PREFS_DOMAIN @"pro.matthesketh.legacypodclaw"
#define PREFS_CHANGED_NOTIFICATION "pro.matthesketh.legacypodclaw/prefsChanged"
#define PREFS_PATH @"/var/mobile/Library/Preferences/pro.matthesketh.legacypodclaw.plist"

/* secrets live in the keychain through clawpodd, never in the plist */
static id ReadSecretOrPreference(PSListController *self, SEL superSel, PSSpecifier *specifier) {
    NSString *key = [specifier propertyForKey:@"key"];
    if ([CPSecretStore isSecretKey:key]) return [CPSecretStore secretForKey:key];
    struct objc_super sup = {self, [PSListController class]};
    return ((id (*)(struct objc_super *, SEL, PSSpecifier *))objc_msgSendSuper)(&sup, superSel, specifier);
}

static BOOL WriteSecret(id value, PSSpecifier *specifier) {
    NSString *key = [specifier propertyForKey:@"key"];
    if (![CPSecretStore isSecretKey:key]) return NO;
    if (![CPSecretStore setSecret:value forKey:key]) {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Not Saved"
            message:@"clawpodd did not store the value. Unlock the device and check that clawpodd runs."
            delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
        [alert show]; [alert release];
    }
    notify_post(PREFS_CHANGED_NOTIFICATION);
    return YES;
}

@implementation LegacyPodClawPrefsRootListController

- (id)specifiers {
    if (!_specifiers) {
        _specifiers = [[self loadSpecifiersFromPlistName:@"Root" target:self] retain];
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"LegacyPodClaw";
}

- (void)_notifyPrefsChanged {
    notify_post(PREFS_CHANGED_NOTIFICATION);
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    return ReadSecretOrPreference(self, _cmd, specifier);
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    if (WriteSecret(value, specifier)) return;
    [super setPreferenceValue:value specifier:specifier];
    [self _notifyPrefsChanged];
}

#pragma mark - Actions

- (void)connectToGateway {
    /* Post connect notification to the running app */
    notify_post("pro.matthesketh.legacypodclaw/connect");

    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Connecting"
                                                    message:@"Sending connect signal to LegacyPodClaw..."
                                                   delegate:nil
                                          cancelButtonTitle:@"OK"
                                          otherButtonTitles:nil];
    [alert show];
    [alert release];
}

- (void)disconnectFromGateway {
    notify_post("pro.matthesketh.legacypodclaw/disconnect");

    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Disconnecting"
                                                    message:@"Sent disconnect signal."
                                                   delegate:nil
                                          cancelButtonTitle:@"OK"
                                          otherButtonTitles:nil];
    [alert show];
    [alert release];
}

- (void)testConnection {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    NSString *host = [prefs objectForKey:@"gatewayHost"] ?: @"(not set)";
    NSString *port = [prefs objectForKey:@"gatewayPort"] ?: @"18789";

    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Connection Info"
                                                    message:[NSString stringWithFormat:
                                                             @"Host: %@\nPort: %@",
                                                             host, port]
                                                   delegate:nil
                                          cancelButtonTitle:@"OK"
                                          otherButtonTitles:nil];
    [alert show];
    [alert release];
}

- (void)resetAllSettings {
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Reset Settings"
                                                    message:@"Are you sure? This will clear all LegacyPodClaw settings."
                                                   delegate:self
                                          cancelButtonTitle:@"Cancel"
                                          otherButtonTitles:@"Reset", nil];
    [alert show];
    [alert release];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (buttonIndex == 1) {
        [[NSFileManager defaultManager] removeItemAtPath:PREFS_PATH error:nil];
        for (NSString *key in [CPSecretStore allSecretKeys])
            [CPSecretStore setSecret:nil forKey:key];
        [self reloadSpecifiers];
        [self _notifyPrefsChanged];
    }
}

@end

#pragma mark - Agent Settings Sub-pane

@implementation LegacyPodClawPrefsAgentController

- (id)specifiers {
    if (!_specifiers) {
        _specifiers = [[self loadSpecifiersFromPlistName:@"Agent" target:self] retain];
    }
    return _specifiers;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    return ReadSecretOrPreference(self, _cmd, specifier);
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    if (WriteSecret(value, specifier)) return;
    [super setPreferenceValue:value specifier:specifier];
    notify_post(PREFS_CHANGED_NOTIFICATION);
}

@end

#pragma mark - Diagnostics Sub-pane

@implementation LegacyPodClawPrefsDiagnosticsController

- (id)specifiers {
    if (!_specifiers) {
        _specifiers = [[self loadSpecifiersFromPlistName:@"Diagnostics" target:self] retain];
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSpecifiers];
}

@end

#pragma mark - Developer Options Sub-pane

@implementation LegacyPodClawPrefsDevController

- (id)specifiers {
    if (!_specifiers) {
        _specifiers = [[self loadSpecifiersFromPlistName:@"Developer" target:self] retain];
    }
    return _specifiers;
}

- (void)testBanner {
    NSDictionary *data = @{@"title": @"LegacyPodClaw", @"message": @"This is a test notification banner!"};
    CPWriteSharedPlist(CP_BANNER_FILE, data);
    notify_post("pro.matthesketh.legacypodclaw/showBanner");
}

- (void)testMessage {
    /* Write to SMS DB with READWRITE access */
    sqlite3 *db = NULL;
    int rc = sqlite3_open_v2("/var/mobile/Library/SMS/sms.db", &db,
        SQLITE_OPEN_READWRITE, NULL);
    if (rc != SQLITE_OK) {
        NSLog(@"[LegacyPodClaw Dev] SMS DB open failed: %d", rc);
        return;
    }

    /* Disable WAL journaling temporarily for simple writes */
    sqlite3_exec(db, "PRAGMA journal_mode=DELETE", NULL, NULL, NULL);

    char *errMsg = NULL;

    /* Ensure handle */
    sqlite3_exec(db, "INSERT OR IGNORE INTO handle (id, country, service, uncanonicalized_id) "
        "VALUES ('LegacyPodClaw', 'us', 'SMS', 'LegacyPodClaw')", NULL, NULL, &errMsg);
    if (errMsg) { NSLog(@"[LegacyPodClaw Dev] handle: %s", errMsg); sqlite3_free(errMsg); errMsg = NULL; }

    /* Get handle ID */
    sqlite3_stmt *stmt;
    int64_t handleId = -1;
    if (sqlite3_prepare_v2(db, "SELECT ROWID FROM handle WHERE id='LegacyPodClaw'", -1, &stmt, NULL) == SQLITE_OK) {
        if (sqlite3_step(stmt) == SQLITE_ROW) handleId = sqlite3_column_int64(stmt, 0);
        sqlite3_finalize(stmt);
    }

    /* Ensure chat */
    sqlite3_exec(db, "INSERT OR IGNORE INTO chat (guid, style, state, chat_identifier, service_name, display_name) "
        "VALUES ('SMS;-;clawpod-ai', 45, 3, 'clawpod-ai', 'SMS', 'LegacyPodClaw')", NULL, NULL, &errMsg);
    if (errMsg) { NSLog(@"[LegacyPodClaw Dev] chat: %s", errMsg); sqlite3_free(errMsg); errMsg = NULL; }

    int64_t chatId = -1;
    if (sqlite3_prepare_v2(db, "SELECT ROWID FROM chat WHERE chat_identifier='clawpod-ai'", -1, &stmt, NULL) == SQLITE_OK) {
        if (sqlite3_step(stmt) == SQLITE_ROW) chatId = sqlite3_column_int64(stmt, 0);
        sqlite3_finalize(stmt);
    }

    /* Join handle to chat */
    if (handleId >= 0 && chatId >= 0) {
        if (sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO chat_handle_join (chat_id, handle_id) VALUES (?,?)", -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_int64(stmt, 1, chatId);
            sqlite3_bind_int64(stmt, 2, handleId);
            sqlite3_step(stmt);
            sqlite3_finalize(stmt);
        }
    }

    /* Insert message */
    NSTimeInterval ts = [[NSDate date] timeIntervalSinceReferenceDate];
    if (handleId >= 0 && sqlite3_prepare_v2(db,
        "INSERT INTO message (guid, text, handle_id, country, service, date, date_delivered, "
        "is_delivered, is_finished, is_from_me, is_read, is_sent) "
        "VALUES (?,?,?,'us','SMS',?,?,1,1,0,0,0)", -1, &stmt, NULL) == SQLITE_OK) {
        NSString *guid = [NSString stringWithFormat:@"cp-test-%f", ts];
        NSString *text = @"Hello from LegacyPodClaw! This is a test message. You can reply and LegacyPodClaw will receive it.";
        sqlite3_bind_text(stmt, 1, [guid UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 2, [text UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(stmt, 3, handleId);
        sqlite3_bind_int64(stmt, 4, (int64_t)ts);
        sqlite3_bind_int64(stmt, 5, (int64_t)ts);
        rc = sqlite3_step(stmt);
        int64_t msgId = sqlite3_last_insert_rowid(db);
        sqlite3_finalize(stmt);
        NSLog(@"[LegacyPodClaw Dev] Message insert rc=%d msgId=%lld", rc, msgId);

        if (msgId > 0 && chatId >= 0) {
            if (sqlite3_prepare_v2(db, "INSERT INTO chat_message_join (chat_id, message_id) VALUES (?,?)", -1, &stmt, NULL) == SQLITE_OK) {
                sqlite3_bind_int64(stmt, 1, chatId);
                sqlite3_bind_int64(stmt, 2, msgId);
                sqlite3_step(stmt);
                sqlite3_finalize(stmt);
            }
        }
    }

    /* Restore WAL mode */
    sqlite3_exec(db, "PRAGMA journal_mode=WAL", NULL, NULL, NULL);
    sqlite3_close(db);

    /* Tell Messages to refresh */
    notify_post("com.apple.MobileSMS.dirtyConversationList");
    NSLog(@"[LegacyPodClaw Dev] Test message sent");
}

- (void)testVibrate {
    dispatch_async(dispatch_get_main_queue(), ^{
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);
        AudioServicesPlayAlertSound(1007); /* Also play a sound as fallback */
    });
}

- (void)testLockLabel {
    /* Force the lock screen to update by posting a notification */
    notify_post("pro.matthesketh.legacypodclaw/prefsChanged");
}

- (void)testOverlay {
    /* the tweak listens for this and opens the panel over the current screen */
    notify_post("pro.matthesketh.legacypodclaw/showOverlay");
}

- (void)testBrightness {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/pro.matthesketh.legacypodclaw.plist"];
    float level = [[prefs objectForKey:@"devBrightness"] floatValue];
    if (level <= 0) level = 0.5f;
    [[UIScreen mainScreen] setBrightness:level];

    UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"Brightness"
        message:[NSString stringWithFormat:@"Set to %.0f%%", level * 100]
        delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
    [a show]; [a release];
}

- (void)testBadge {
    NSDictionary *data = @{@"count": @5};
    CPWriteSharedPlist(CP_BADGE_FILE, data);
    notify_post("pro.matthesketh.legacypodclaw/updateBadge");

    UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"Badge"
        message:@"LegacyPodClaw app icon should now show badge '5'."
        delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
    [a show]; [a release];
}

- (void)testClearBadge {
    NSDictionary *data = @{@"count": @0};
    CPWriteSharedPlist(CP_BADGE_FILE, data);
    notify_post("pro.matthesketh.legacypodclaw/updateBadge");
}

- (void)testRespring {
    UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"Respring"
        message:@"This will restart SpringBoard. Continue?"
        delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Respring", nil];
    a.tag = 999;
    [a show]; [a release];
}

- (void)testClearSMS {
    UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"Clear LegacyPodClaw Messages"
        message:@"Remove all LegacyPodClaw messages from the SMS database?"
        delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Clear", nil];
    a.tag = 998;
    [a show]; [a release];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (buttonIndex == 0) return;

    if (alertView.tag == 999) {
        /* Respring */
        notify_post("pro.matthesketh.legacypodclaw/respring");
        /* Also try direct kill via signal */
        pid_t sbPid = 0;
        int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
        size_t sz;
        sysctl(mib, 4, NULL, &sz, NULL, 0);
        struct kinfo_proc *procs = malloc(sz);
        sysctl(mib, 4, procs, &sz, NULL, 0);
        int cnt = (int)(sz / sizeof(struct kinfo_proc));
        for (int i = 0; i < cnt; i++) {
            if (strcmp(procs[i].kp_proc.p_comm, "SpringBoard") == 0) {
                sbPid = procs[i].kp_proc.p_pid;
                break;
            }
        }
        free(procs);
        if (sbPid > 0) kill(sbPid, SIGTERM);
    } else if (alertView.tag == 998) {
        /* Clear LegacyPodClaw SMS entries */
        sqlite3 *db = NULL;
        if (sqlite3_open("/var/mobile/Library/SMS/sms.db", &db) == SQLITE_OK) {
            sqlite3_exec(db,
                "DELETE FROM message WHERE handle_id IN (SELECT ROWID FROM handle WHERE id = 'LegacyPodClaw')",
                NULL, NULL, NULL);
            sqlite3_exec(db,
                "DELETE FROM chat_message_join WHERE chat_id IN (SELECT ROWID FROM chat WHERE chat_identifier = 'clawpod-ai')",
                NULL, NULL, NULL);
            sqlite3_exec(db, "DELETE FROM chat WHERE chat_identifier = 'clawpod-ai'", NULL, NULL, NULL);
            sqlite3_exec(db, "DELETE FROM chat_handle_join WHERE handle_id IN (SELECT ROWID FROM handle WHERE id = 'LegacyPodClaw')", NULL, NULL, NULL);
            sqlite3_exec(db, "DELETE FROM handle WHERE id = 'LegacyPodClaw'", NULL, NULL, NULL);
            sqlite3_close(db);
            notify_post("com.apple.MobileSMS.dirtyConversationList");

            UIAlertView *a2 = [[UIAlertView alloc] initWithTitle:@"Cleared"
                message:@"LegacyPodClaw messages removed from SMS database."
                delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
            [a2 show]; [a2 release];
        }
    }
}

#pragma mark - API Debug

- (void)testAPIConnection {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    NSString *apiKey = [CPSecretStore secretForKey:@"apiKey"];
    if (!apiKey || [apiKey length] == 0) {
        UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"No API Key"
            message:@"Set an API key first." delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
        [a show]; [a release]; return;
    }
    NSString *model = [prefs objectForKey:@"modelId"] ?: @"claude-sonnet-5-5";
    UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"API Config"
        message:[NSString stringWithFormat:@"Key: %@...%@\nModel: %@\n\nUse the home-hold overlay or in-app chat to test.",
            [apiKey substringToIndex:MIN(10, [apiKey length])],
            [apiKey substringFromIndex:MAX(0, (NSInteger)[apiKey length] - 4)],
            model]
        delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
    [a show]; [a release];
}

@end
