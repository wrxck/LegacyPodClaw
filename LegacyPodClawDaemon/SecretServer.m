/*
 * SecretServer.m
 * clawpodd - keychain-backed secret service for the app, tweak and settings
 *
 * Only clawpodd carries the keychain access group, so only it can read the
 * items. It checks each caller's executable path from the mach audit trailer.
 *
 * The path check is defence in depth, not a boundary: on a jailbroken device
 * code can still get into an allowed process (a tweak inside springboard, or
 * a process that queues a request and then execs an allowed binary). The app
 * binary carries a __RESTRICT segment so dyld ignores DYLD_INSERT_LIBRARIES.
 */

#import "SecretServer.h"
#import "SecretProtocol.h"
#import <Security/Security.h>
#import <sys/param.h>
#import <sys/stat.h>
#import <stdlib.h>

#define KEYCHAIN_SERVICE @"pro.matthesketh.legacypodclaw"
#define KEYCHAIN_GROUP @"pro.matthesketh.legacypodclaw.secrets"
#define PREFS_PATH @"/var/mobile/Library/Preferences/pro.matthesketh.legacypodclaw.plist"

#define CALLER_SPRINGBOARD "/System/Library/CoreServices/SpringBoard.app/SpringBoard"
#define CALLER_PREFERENCES "/Applications/Preferences.app/Preferences"
#define CALLER_APP "/Applications/LegacyPodClaw.app/LegacyPodClaw"

/* libproc has no header in the ios sdk */
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
#define CP_PROC_PATH_MAX (4 * MAXPATHLEN)

static mach_port_t _servicePort = MACH_PORT_NULL;
static dispatch_source_t _source = NULL;

static NSArray *SecretKeys(void) {
    return @[@"apiKey", @"authToken", @"authPassword", @"deviceToken",
             @"openaiApiKey", @"googleApiKey", @"groqApiKey", @"togetherApiKey", @"openrouterApiKey",
             @"mistralApiKey", @"deepseekApiKey", @"customApiKey",
             @"telegramBotToken", @"discordBotToken", @"slackBotToken", @"slackAppToken",
             @"ircPassword", @"webhookCallbackToken"];
}

#pragma mark - Keychain

static NSMutableDictionary *BaseQuery(NSString *key) {
    NSMutableDictionary *q = [NSMutableDictionary dictionary];
    [q setObject:(id)kSecClassGenericPassword forKey:(id)kSecClass];
    [q setObject:KEYCHAIN_SERVICE forKey:(id)kSecAttrService];
    [q setObject:key forKey:(id)kSecAttrAccount];
    [q setObject:KEYCHAIN_GROUP forKey:(id)kSecAttrAccessGroup];
    return q;
}

static int32_t StatusFromOSStatus(OSStatus s) {
    if (s == errSecSuccess) return CPSecretStatusOK;
    if (s == errSecItemNotFound) return CPSecretStatusNotFound;
    return CPSecretStatusUnavailable;
}

static int32_t KeychainGet(NSString *key, NSData **out) {
    NSMutableDictionary *q = BaseQuery(key);
    [q setObject:(id)kCFBooleanTrue forKey:(id)kSecReturnData];
    [q setObject:(id)kSecMatchLimitOne forKey:(id)kSecMatchLimit];
    CFTypeRef result = NULL;
    OSStatus s = SecItemCopyMatching((CFDictionaryRef)q, &result);
    if (s == errSecSuccess && result) *out = [(NSData *)result autorelease];
    else if (result) CFRelease(result);
    return StatusFromOSStatus(s);
}

static int32_t KeychainSet(NSString *key, NSData *value) {
    NSMutableDictionary *q = BaseQuery(key);
    NSDictionary *update = @{(id)kSecValueData: value,
                             (id)kSecAttrAccessible: (id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly};
    OSStatus s = SecItemUpdate((CFDictionaryRef)q, (CFDictionaryRef)update);
    if (s == errSecItemNotFound) {
        [q addEntriesFromDictionary:update];
        s = SecItemAdd((CFDictionaryRef)q, NULL);
    }
    return StatusFromOSStatus(s);
}

static int32_t KeychainDelete(NSString *key) {
    OSStatus s = SecItemDelete((CFDictionaryRef)BaseQuery(key));
    return s == errSecItemNotFound ? CPSecretStatusOK : StatusFromOSStatus(s);
}

BOOL CPSecretServerDeleteAll(void) {
    BOOL ok = YES;
    for (NSString *key in SecretKeys()) {
        if (KeychainDelete(key) != CPSecretStatusOK) {
            NSLog(@"[clawpodd] could not delete %@ from the keychain", key);
            ok = NO;
        }
    }
    return ok;
}

#pragma mark - Migration

/* move secrets that older builds left in the plain preferences plist */
static void MigrateFromPrefs(void) {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    if (!prefs) return;
    BOOL changed = NO;
    for (NSString *key in SecretKeys()) {
        id value = [prefs objectForKey:key];
        if (!value) continue;
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
            NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding];
            /* keep the plist copy until the keychain accepts it, for example after first unlock */
            if (KeychainSet(key, data) != CPSecretStatusOK) continue;
        }
        [prefs removeObjectForKey:key];
        changed = YES;
    }
    if (changed && [prefs writeToFile:PREFS_PATH atomically:YES]) {
        chmod([PREFS_PATH fileSystemRepresentation], 0600);
        NSLog(@"[clawpodd] moved secrets from the preferences plist to the keychain");
    }
}

#pragma mark - Callers

typedef NS_ENUM(NSInteger, CPCaller) { CPCallerUnknown, CPCallerSpringBoard, CPCallerPreferences, CPCallerApp };

static BOOL CallerPathIs(const char *path, const char *expected) {
    if (strcmp(path, expected) == 0) return YES;
    /* cydia stashes /Applications behind a symlink and proc_pidpath returns the real path */
    char resolved[MAXPATHLEN];
    return realpath(expected, resolved) != NULL && strcmp(path, resolved) == 0;
}

static CPCaller CallerForAuditToken(audit_token_t token) {
    /* val[5] is the pid in the bsm audit token layout */
    int pid = (int)token.val[5];
    /* val[1] is the effective uid; springboard, settings and the app all run as mobile */
    if (token.val[1] != 501) return CPCallerUnknown;
    char path[CP_PROC_PATH_MAX];
    if (pid <= 0 || proc_pidpath(pid, path, sizeof(path)) <= 0) return CPCallerUnknown;
    if (CallerPathIs(path, CALLER_SPRINGBOARD)) return CPCallerSpringBoard;
    if (CallerPathIs(path, CALLER_PREFERENCES)) return CPCallerPreferences;
    if (CallerPathIs(path, CALLER_APP)) return CPCallerApp;
    return CPCallerUnknown;
}

static BOOL CallerMay(CPCaller caller, uint32_t op) {
    switch (caller) {
        case CPCallerApp:
        case CPCallerPreferences: return op == CPSecretOpGet || op == CPSecretOpSet || op == CPSecretOpDelete;
        case CPCallerSpringBoard: return op == CPSecretOpGet;
        default: return NO;
    }
}

#pragma mark - Requests

static void HandleRequest(CPSecretRequest *req, audit_token_t token, CPSecretReply *reply) {
    reply->status = CPSecretStatusBadRequest;

    req->key[CP_SECRET_KEY_MAX - 1] = '\0';
    NSString *key = [NSString stringWithUTF8String:req->key];
    if (!key || ![SecretKeys() containsObject:key] || req->valueLength > CP_SECRET_VALUE_MAX) return;

    CPCaller caller = CallerForAuditToken(token);
    if (!CallerMay(caller, req->op)) {
        NSLog(@"[clawpodd] refused secret op %u on %@ from pid %d", req->op, key, (int)token.val[5]);
        reply->status = CPSecretStatusDenied;
        return;
    }

    MigrateFromPrefs();

    if (req->op == CPSecretOpGet) {
        NSData *data = nil;
        reply->status = KeychainGet(key, &data);
        if (reply->status == CPSecretStatusOK) {
            if ([data length] > CP_SECRET_VALUE_MAX) { reply->status = CPSecretStatusUnavailable; return; }
            memcpy(reply->value, [data bytes], [data length]);
            reply->valueLength = (uint32_t)[data length];
        }
    } else if (req->op == CPSecretOpSet) {
        NSData *data = [NSData dataWithBytes:req->value length:req->valueLength];
        reply->status = req->valueLength == 0 ? KeychainDelete(key) : KeychainSet(key, data);
    } else if (req->op == CPSecretOpDelete) {
        reply->status = KeychainDelete(key);
    }
}

static void ReceiveOne(void) {
    struct {
        CPSecretRequest request;
        mach_msg_audit_trailer_t trailer;
    } in;
    memset(&in, 0, sizeof(in));
    kern_return_t kr = mach_msg(&in.request.header,
                                MACH_RCV_MSG | MACH_RCV_TIMEOUT
                                    | MACH_RCV_TRAILER_TYPE(MACH_MSG_TRAILER_FORMAT_0)
                                    | MACH_RCV_TRAILER_ELEMENTS(MACH_RCV_TRAILER_AUDIT),
                                0, sizeof(in), _servicePort, 0, MACH_PORT_NULL);
    if (kr != KERN_SUCCESS) return;

    mach_msg_header_t *hdr = &in.request.header;
    BOOL wellFormed = hdr->msgh_size == sizeof(CPSecretRequest)
        && hdr->msgh_id == CP_SECRET_MSG_ID
        && !(hdr->msgh_bits & MACH_MSGH_BITS_COMPLEX)
        && hdr->msgh_remote_port != MACH_PORT_NULL;
    if (!wellFormed) {
        mach_msg_destroy(hdr);
        CPSecretWipe(&in, sizeof(in));
        return;
    }

    mach_msg_audit_trailer_t *trailer =
        (mach_msg_audit_trailer_t *)((uint8_t *)hdr + round_msg(hdr->msgh_size));

    CPSecretReply reply;
    memset(&reply, 0, sizeof(reply));
    @autoreleasepool {
        HandleRequest(&in.request, trailer->msgh_audit, &reply);
    }

    reply.header.msgh_bits = MACH_MSGH_BITS(MACH_MSGH_BITS_REMOTE(hdr->msgh_bits), 0);
    reply.header.msgh_size = sizeof(reply);
    reply.header.msgh_remote_port = hdr->msgh_remote_port;
    reply.header.msgh_local_port = MACH_PORT_NULL;
    reply.header.msgh_id = hdr->msgh_id + 100;
    kr = mach_msg(&reply.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, sizeof(reply), 0,
                  MACH_PORT_NULL, 100, MACH_PORT_NULL);
    /* a failed send returns the send-once right to us, so release it */
    if (kr != KERN_SUCCESS) mach_msg_destroy(&reply.header);

    CPSecretWipe(&reply, sizeof(reply));
    CPSecretWipe(&in, sizeof(in));
}

BOOL CPSecretServerStart(void) {
    kern_return_t kr = bootstrap_check_in(bootstrap_port, CP_SECRET_SERVICE, &_servicePort);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[clawpodd] bootstrap_check_in %s failed: %d", CP_SECRET_SERVICE, kr);
        return NO;
    }
    _source = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, _servicePort, 0,
                                     dispatch_get_main_queue());
    dispatch_source_set_event_handler(_source, ^{ ReceiveOne(); });
    dispatch_resume(_source);
    return YES;
}

void CPSecretServerMigrate(void) {
    @autoreleasepool { MigrateFromPrefs(); }
}
