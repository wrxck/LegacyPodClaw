/*
 * clawpodd
 * LegacyPodClaw - read-only system info service
 *
 * Answers a fixed set of read-only questions over CPDistributedMessagingCenter:
 * ping, status, battery, processes, crashes and an allow-listed sysctl.
 * It also holds API keys and tokens in the keychain (see SecretServer.m).
 * It registers its mach services as root, then drops to mobile.
 *
 * Installed to: /usr/bin/clawpodd
 * LaunchDaemon: /Library/LaunchDaemons/pro.matthesketh.legacypodclaw.daemon.plist
 */

#import <Foundation/Foundation.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <notify.h>
#import <signal.h>
#import <sys/sysctl.h>
#import <unistd.h>
#import <string.h>
#import <errno.h>
#import <dlfcn.h>
#import <objc/message.h>
#import "SecretServer.h"

#define DAEMON_VERSION @"0.4.0"
#define DAEMON_SERVICE @"pro.matthesketh.legacypodclaw.daemon"
#define MOBILE_UID 501
#define MOBILE_GID 501
#define CRASH_DIR @"/var/mobile/Library/Logs/CrashReporter"
#define MAX_CRASHES 20

#pragma mark - Battery

static NSDictionary *CopyBatteryInfo(void) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    CFTypeRef blob = IOPSCopyPowerSourcesInfo();
    if (!blob) return info;
    CFArrayRef sources = IOPSCopyPowerSourcesList(blob);
    if (!sources) { CFRelease(blob); return info; }

    if (CFArrayGetCount(sources) > 0) {
        CFDictionaryRef src = IOPSGetPowerSourceDescription(blob, CFArrayGetValueAtIndex(sources, 0));
        if (src) {
            CFNumberRef curCap = CFDictionaryGetValue(src, CFSTR(kIOPSCurrentCapacityKey));
            CFNumberRef maxCap = CFDictionaryGetValue(src, CFSTR(kIOPSMaxCapacityKey));
            CFStringRef state = CFDictionaryGetValue(src, CFSTR(kIOPSPowerSourceStateKey));
            CFBooleanRef charging = CFDictionaryGetValue(src, CFSTR(kIOPSIsChargingKey));
            int cur = 0, max = 0;
            if (curCap) CFNumberGetValue(curCap, kCFNumberIntType, &cur);
            if (maxCap) CFNumberGetValue(maxCap, kCFNumberIntType, &max);
            [info setObject:@(max > 0 ? (cur * 100 / max) : 0) forKey:@"percent"];
            [info setObject:@(charging == kCFBooleanTrue) forKey:@"charging"];
            if (state) [info setObject:(NSString *)state forKey:@"powerSource"];
        }
    }
    CFRelease(sources);
    CFRelease(blob);
    return info;
}

#pragma mark - Processes

static NSArray *CopyProcessList(void) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    struct kinfo_proc *procs = NULL;
    size_t size = 0;

    /* the table can grow between the size query and the read, so retry with headroom */
    for (int attempt = 0; attempt < 3; attempt++) {
        if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0) return @[];
        size += size / 4;
        procs = malloc(size);
        if (!procs) return @[];
        if (sysctl(mib, 4, procs, &size, NULL, 0) == 0) break;
        free(procs);
        procs = NULL;
    }
    if (!procs) return @[];

    size_t count = size / sizeof(struct kinfo_proc);
    NSMutableArray *list = [NSMutableArray arrayWithCapacity:count];
    for (size_t i = 0; i < count; i++) {
        char comm[MAXCOMLEN + 1];
        strlcpy(comm, procs[i].kp_proc.p_comm, sizeof(comm));
        NSString *name = [NSString stringWithCString:comm encoding:NSUTF8StringEncoding] ?: @"?";
        [list addObject:@{@"pid": @(procs[i].kp_proc.p_pid), @"name": name}];
    }
    free(procs);
    return list;
}

#pragma mark - Crash reports

static NSArray *CopyRecentCrashes(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *crashes = [NSMutableArray array];
    for (NSString *file in [fm contentsOfDirectoryAtPath:CRASH_DIR error:nil]) {
        if (![file hasSuffix:@".plist"] && ![file hasSuffix:@".ips"]) continue;
        NSString *path = [CRASH_DIR stringByAppendingPathComponent:file];
        NSDate *modified = [[fm attributesOfItemAtPath:path error:nil] fileModificationDate];
        if (!modified) continue;
        [crashes addObject:@{@"file": file, @"date": modified}];
    }
    [crashes sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [[b objectForKey:@"date"] compare:[a objectForKey:@"date"]];
    }];
    if ([crashes count] > MAX_CRASHES)
        [crashes removeObjectsInRange:NSMakeRange(MAX_CRASHES, [crashes count] - MAX_CRASHES)];
    return crashes;
}

#pragma mark - Sysctl

typedef NS_ENUM(NSInteger, CPSysctlType) { CPSysctlString, CPSysctlInt, CPSysctlInt64 };

static NSDictionary *SysctlAllowList(void) {
    static NSDictionary *allow;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allow = [@{
            @"hw.machine": @(CPSysctlString),
            @"hw.model": @(CPSysctlString),
            @"hw.ncpu": @(CPSysctlInt),
            @"hw.physicalcpu": @(CPSysctlInt),
            @"hw.cpufrequency": @(CPSysctlInt64),
            @"hw.memsize": @(CPSysctlInt64),
            @"hw.pagesize": @(CPSysctlInt64),
            @"kern.osversion": @(CPSysctlString),
            @"kern.osrelease": @(CPSysctlString),
            @"kern.ostype": @(CPSysctlString),
            @"kern.maxproc": @(CPSysctlInt),
            @"kern.maxfiles": @(CPSysctlInt),
        } retain];
    });
    return allow;
}

static NSDictionary *ReadSysctl(NSString *key) {
    NSNumber *type = [key isKindOfClass:[NSString class]] ? [SysctlAllowList() objectForKey:key] : nil;
    if (!type) return @{@"error": @"key not allowed"};

    const char *ckey = [key UTF8String];
    switch ([type integerValue]) {
        case CPSysctlInt: {
            int v = 0; size_t len = sizeof(v);
            if (sysctlbyname(ckey, &v, &len, NULL, 0) != 0) break;
            return @{@"value": @(v)};
        }
        case CPSysctlInt64: {
            int64_t v = 0; size_t len = sizeof(v);
            if (sysctlbyname(ckey, &v, &len, NULL, 0) != 0) break;
            /* some keys are 32-bit on armv7, so honour the length the kernel returned */
            return @{@"value": len == sizeof(int32_t) ? @(*(int32_t *)&v) : @(v)};
        }
        default: {
            char buf[256]; size_t len = sizeof(buf);
            if (sysctlbyname(ckey, buf, &len, NULL, 0) != 0 || len == 0) break;
            buf[MIN(len, sizeof(buf) - 1)] = '\0';
            return @{@"value": [NSString stringWithUTF8String:buf] ?: @""};
        }
    }
    return @{@"error": @"sysctl failed"};
}

static NSTimeInterval Uptime(void) {
    struct timeval boottime;
    size_t size = sizeof(boottime);
    int mib[2] = {CTL_KERN, KERN_BOOTTIME};
    if (sysctl(mib, 2, &boottime, &size, NULL, 0) != 0) return 0;
    return [[NSDate date] timeIntervalSince1970] - boottime.tv_sec;
}

#pragma mark - IPC server

@interface CPDaemonServer : NSObject {
    id _center;
}
- (BOOL)start;
@end

@implementation CPDaemonServer

- (BOOL)start {
    dlopen("/System/Library/PrivateFrameworks/AppSupport.framework/AppSupport", RTLD_NOW);
    Class centerClass = NSClassFromString(@"CPDistributedMessagingCenter");
    if (!centerClass) {
        NSLog(@"[clawpodd] CPDistributedMessagingCenter is not available");
        return NO;
    }
    _center = [[centerClass performSelector:@selector(centerNamed:) withObject:DAEMON_SERVICE] retain];
    [_center performSelector:@selector(runServerOnCurrentThread)];

    typedef void (*RegisterFn)(id, SEL, NSString *, id, SEL);
    RegisterFn reg = (RegisterFn)objc_msgSend;
    SEL regSel = @selector(registerForMessageName:target:selector:);
    reg(_center, regSel, @"ping", self, @selector(handlePing:userInfo:));
    reg(_center, regSel, @"status", self, @selector(handleStatus:userInfo:));
    reg(_center, regSel, @"battery", self, @selector(handleBattery:userInfo:));
    reg(_center, regSel, @"processes", self, @selector(handleProcesses:userInfo:));
    reg(_center, regSel, @"crashes", self, @selector(handleCrashes:userInfo:));
    reg(_center, regSel, @"sysctl", self, @selector(handleSysctl:userInfo:));
    return YES;
}

- (NSDictionary *)handlePing:(NSString *)name userInfo:(NSDictionary *)info {
    return @{@"pong": @YES, @"version": DAEMON_VERSION};
}

- (NSDictionary *)handleStatus:(NSString *)name userInfo:(NSDictionary *)info {
    return @{@"running": @YES, @"version": DAEMON_VERSION, @"uptime": @(Uptime()),
             @"pid": @(getpid()), @"uid": @(getuid())};
}

- (NSDictionary *)handleBattery:(NSString *)name userInfo:(NSDictionary *)info {
    return CopyBatteryInfo();
}

- (NSDictionary *)handleProcesses:(NSString *)name userInfo:(NSDictionary *)info {
    return @{@"processes": CopyProcessList()};
}

- (NSDictionary *)handleCrashes:(NSString *)name userInfo:(NSDictionary *)info {
    return @{@"crashes": CopyRecentCrashes()};
}

- (NSDictionary *)handleSysctl:(NSString *)name userInfo:(NSDictionary *)info {
    return ReadSysctl([info objectForKey:@"key"]);
}

- (void)dealloc {
    [_center release];
    [super dealloc];
}

@end

#pragma mark - Main

static void DropToMobile(void) {
    if (getuid() != 0) return;
    if (setgid(MOBILE_GID) != 0 || setuid(MOBILE_UID) != 0) {
        /* refuse to keep serving as root if the drop fails */
        NSLog(@"[clawpodd] cannot drop to mobile: %s", strerror(errno));
        exit(1);
    }
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        /* only this binary carries the keychain group, so the package scripts ask it to clear the secrets */
        if (argc == 2 && strcmp(argv[1], "--purge-secrets") == 0) return CPSecretServerDeleteAll() ? 0 : 1;

        signal(SIGPIPE, SIG_IGN);
        signal(SIGTERM, SIG_IGN);
        dispatch_source_t term = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0,
                                                        dispatch_get_main_queue());
        dispatch_source_set_event_handler(term, ^{ CFRunLoopStop(CFRunLoopGetMain()); });
        dispatch_resume(term);

        CPDaemonServer *server = [[CPDaemonServer alloc] init];
        if (![server start]) return 1;
        BOOL secrets = CPSecretServerStart();
        DropToMobile();
        if (secrets) CPSecretServerMigrate();

        NSLog(@"[clawpodd] %@ serving %@ as uid %d", DAEMON_VERSION, DAEMON_SERVICE, getuid());
        notify_post("pro.matthesketh.legacypodclaw/daemonReady");
        CFRunLoopRun();

        [server release];
        dispatch_release(term);
    }
    return 0;
}
