/*
 * AppDelegate.m
 * LegacyPodClaw - Main Application Delegate Implementation
 *
 * Initializes all services, manages lifecycle, handles
 * memory warnings aggressively for 256MB device.
 */

#import "AppDelegate.h"
#import "SecretStore.h"
#import "RootViewController.h"
#import "ExtendedTools.h"
#import "SystemMCP.h"
#import "NotesReminders.h"
#import "MusicDownloader.h"
#import "ProviderRegistry.h"
#import "TelegramChannel.h"
#import "DiscordChannel.h"
#import "SlackChannel.h"
#import "IRCChannel.h"
#import "WebhookChannel.h"
#import <notify.h>
#import <sys/stat.h>

static NSString *const LPCPrefsPath = @"/var/mobile/Library/Preferences/pro.matthesketh.legacypodclaw.plist";

@interface AppDelegate () {
    OCChannelRouter *_channelRouter;
    NSDictionary *_channelSettings;
}
- (void)_reloadChannels:(NSDictionary *)prefs;
- (void)_autoStart;
@end

@implementation AppDelegate

@synthesize channelManager = _channelManager, pluginManager = _pluginManager;

static AppDelegate *_shared = nil;

+ (AppDelegate *)shared {
    return _shared;
}

#pragma mark - Application Lifecycle

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    _shared = self;

    /* Initialize memory monitor FIRST */
    OCMemoryMonitor *monitor = [OCMemoryMonitor sharedMonitor];
    monitor.appMemoryBudget = 80 * 1024 * 1024;  /* 80MB budget */
    [monitor startMonitoring];

    /* Register for memory pressure notifications */
    [monitor addPressureHandler:^(OCMemoryPressure pressure) {
        [self _handleMemoryPressure:pressure];
    }];

    /* Initialize SQLite store */
    NSString *docsPath = [NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    NSString *dbPath = [docsPath stringByAppendingPathComponent:@"openclaw.db"];

    _store = [[OCStore alloc] initWithPath:dbPath];
    NSError *dbError = nil;
    if (![_store open:&dbError]) {
        NSLog(@"[LegacyPodClaw] Failed to open database: %@", dbError);
    }

    /* Initialize settings */
    _settings = [[OCKeyValueStore alloc] initWithStore:_store tableName:@"settings"];
    [_settings setup:nil];

    /* Initialize gateway client */
    _gateway = [[OCGatewayClient alloc] init];
    _gateway.delegate = self;
    _gateway.clientDisplayName = [[UIDevice currentDevice] name];
    _gateway.autoReconnect = YES;

    /* Initialize session manager */
    _sessionManager = [[OCSessionManager alloc] initWithStore:_store
                                                gatewayClient:_gateway];
    _sessionManager.delegate = self;
    [_sessionManager setupSchema:nil];

    /* Initialize local agent */
    _localAgent = [[OCAgent alloc] init];
    _localAgent.maxContextTokens = 8192;
    _localAgent.maxResponseTokens = 4096;

    /* Set comprehensive system prompt */
    _localAgent.systemPrompt =
        @"You are LegacyPodClaw (Molty), an AI assistant with FULL system access on a jailbroken iOS 6 device. "
        @"You are like Claude Code but running directly on this device.\n\n"
        @"YOU HAVE TOOLS. Use them. You can:\n"
        @"- Execute ANY shell command (bash tool)\n"
        @"- Read, write, edit, delete files anywhere on the filesystem\n"
        @"- List directory contents\n"
        @"- Search the web\n"
        @"- Fetch URLs\n"
        @"- Create/read/update/delete notes\n"
        @"- Create/complete/list reminders with due dates\n"
        @"- Send messages to the user via Messages.app\n"
        @"- Post system notification banners\n"
        @"- Control brightness, volume, launch apps\n"
        @"- Lock the device, vibrate, open URLs\n"
        @"- Get device state (battery, network, disk)\n"
        @"- Search persistent memory\n"
        @"- Get date/time, clipboard, network info, storage info\n"
        @"- List running processes\n"
        @"- Search YouTube for music (search_music tool)\n"
        @"- Download songs and add to the Music library (download_music tool, requires music proxy)\n"
        @"- List songs in the music library (list_music tool)\n\n"
        @"ALWAYS use tools when the user asks you to do something on the device. "
        @"Don't say you can't — you CAN. You run as the mobile user, not root.\n\n"
        @"Safety: /System, /sbin, /bin, /boot are protected. Check disk space before large writes. "
        @"Destructive commands need confirmation.\n\n"
        @"Be concise but thorough. Show command output when relevant.";

    /* Register ALL tools (deduplicate by name) */
    NSMutableSet *seen = [NSMutableSet setWithCapacity:50];
    NSArray *allSources = @[
        [OCBuiltinTools deviceTools],
        [OCExtendedTools allExtendedTools],
        [OCSystemMCPTools allSystemTools],
        [OCNotesReminders allTools],
        [OCMusicDownloader allTools]
    ];
    for (NSArray *tools in allSources) {
        for (OCToolDefinition *tool in tools) {
            if (tool.name && ![seen containsObject:tool.name]) {
                [_localAgent registerTool:tool];
                [seen addObject:tool.name];
            }
        }
    }
    NSLog(@"[LegacyPodClaw] %lu tools registered", (unsigned long)[seen count]);

    /* plugin tools come last, so a plugin can never replace a built-in tool */
    _pluginManager = [[OCPluginManager alloc] init];
    [_pluginManager loadPluginsFromDirectory:OCPluginDirectory];
    for (OCToolDefinition *tool in [_pluginManager allPluginTools]) [_localAgent registerTool:tool];

    [OCExtendedTools setupMemoryTables:_store];

    /* Load local sessions immediately (don't wait for gateway) */
    [_sessionManager loadSessions];

    /* Load settings from PreferenceLoader shared prefs */
    [self loadConnectionSettings];
    [self _registerPrefsNotifications];

    /* Create UI */
    _window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    _rootViewController = [[OCRootViewController alloc] init];

    UINavigationController *nav = [[UINavigationController alloc]
        initWithRootViewController:_rootViewController];

    /* iOS 6 style navigation bar */
    nav.navigationBar.tintColor = [UIColor colorWithRed:0.18f green:0.20f blue:0.25f alpha:1.0f];

    _window.rootViewController = nav;
    [_window makeKeyAndVisible];
    [nav release];

    /* Auto-connect if we have saved settings */
    if (_gateway.host && [_gateway.host length] > 0) {
        [self connectToGateway];
    }

    /* the server switch is remembered, so a relaunch brings the server back */
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:LPCPrefsPath];
    if ([[prefs objectForKey:@"gatewayServerEnabled"] boolValue]) {
        NSError *err = nil;
        if (![self startGatewayServer:&err]) NSLog(@"[LegacyPodClaw] gateway server did not start: %@", err);
    }

    return YES;
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application {
    NSLog(@"[LegacyPodClaw] System memory warning received!");
    [self _handleMemoryPressure:OCMemoryPressureCritical];
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    /* Save state and reduce memory footprint */
    [_sessionManager trimMessageWindows];
    [_store optimize];
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    /* Reconnect if needed */
    if (_gateway.connectionState == OCGatewayStateDisconnected &&
        _gateway.host && [_gateway.host length] > 0) {
        [self connectToGateway];
    }
}

- (void)applicationWillTerminate:(UIApplication *)application {
    [self saveConnectionSettings];
    [_store close];
}

#pragma mark - Memory Management

- (void)_handleMemoryPressure:(OCMemoryPressure)pressure {
    switch (pressure) {
        case OCMemoryPressureWarning:
            NSLog(@"[LegacyPodClaw] Memory pressure: WARNING");
            [_sessionManager trimMessageWindows];
            break;

        case OCMemoryPressureCritical:
            NSLog(@"[LegacyPodClaw] Memory pressure: CRITICAL");
            [_sessionManager trimMessageWindows];
            [_store vacuum];
            [[NSURLCache sharedURLCache] removeAllCachedResponses];
            break;

        case OCMemoryPressureTerminal:
            NSLog(@"[LegacyPodClaw] Memory pressure: TERMINAL - shedding everything");
            [_sessionManager trimMessageWindows];
            [_localAgent clearContext];
            [_channelRouter reset];
            [_store vacuum];
            [[NSURLCache sharedURLCache] removeAllCachedResponses];
            break;

        default:
            break;
    }
}

#pragma mark - Connection

- (void)connectToGateway {
    if (_gateway.connectionState != OCGatewayStateDisconnected) return;
    [_gateway connect];
}

- (void)disconnectFromGateway {
    [_gateway disconnect];
}

#pragma mark - Settings (read from PreferenceLoader shared prefs)

- (void)saveConnectionSettings {
    /* device token is the only thing the app writes back */
    if (_gateway.authConfig.deviceToken)
        [CPSecretStore setSecret:_gateway.authConfig.deviceToken forKey:@"deviceToken"];
}

- (void)loadConnectionSettings {
    /* Read from shared preferences file (written by Settings.app PreferenceBundle) */
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:LPCPrefsPath];

    _gateway.host = [prefs objectForKey:@"gatewayHost"];
    NSString *portStr = [prefs objectForKey:@"gatewayPort"];
    _gateway.port = portStr ? [portStr integerValue] : 18789;
    if (_gateway.port == 0) _gateway.port = 18789;
    _gateway.useTLS = [[prefs objectForKey:@"useTLS"] boolValue];
    _gateway.allowSelfSignedCerts = [[prefs objectForKey:@"allowSelfSigned"] boolValue];
    _gateway.pinnedCertSHA256 = [prefs objectForKey:@"gatewayCertSHA256"];

    OCGatewayAuthConfig *auth = [[OCGatewayAuthConfig alloc] init];
    auth.token = [CPSecretStore secretForKey:@"authToken"];
    auth.password = [CPSecretStore secretForKey:@"authPassword"];
    auth.deviceToken = [CPSecretStore secretForKey:@"deviceToken"];
    _gateway.authConfig = auth;
    [auth release];

    /* Local agent config: the provider chosen in Settings, with its own key and base url */
    OCProviderInfo *provider = [OCProviderInfo providerWithId:[prefs objectForKey:@"modelProvider"]]
                            ?: [OCProviderInfo providerWithId:[OCProviderInfo defaultProviderId]];
    OCModelConfig *modelCfg = [[OCModelConfig alloc] init];
    modelCfg.providerId = provider.providerId;
    modelCfg.apiKey = provider.secretKey ? [CPSecretStore secretForKey:provider.secretKey] : nil;
    NSString *modelId = [prefs objectForKey:@"modelId"];
    modelCfg.modelId = [modelId length] ? modelId : provider.defaultModel;
    modelCfg.baseURL = [prefs objectForKey:provider.baseURLPrefKey];
    modelCfg.maxTokens = [[prefs objectForKey:@"maxResponseTokens"] intValue] ?: 512;
    modelCfg.contextWindow = [[prefs objectForKey:@"maxContextTokens"] intValue] ?: 2048;
    _localAgent.modelConfig = modelCfg;
    _localAgent.maxContextTokens = modelCfg.contextWindow;
    [modelCfg release];

    /* MCP servers */
    /* a reload must not stack a second client for the same server */
    [_localAgent removeMCPServer:@"MCP1"];
    [_localAgent removeMCPServer:@"MCP2"];
    NSString *mcp1 = [prefs objectForKey:@"mcpServer1"];
    if (mcp1 && [mcp1 length] > 0) {
        OCMCPClient *client = [[[OCMCPClient alloc] initWithURL:mcp1 name:@"MCP1"] autorelease];
        [_localAgent addMCPServer:client];
        [client connect:nil];
    }
    NSString *mcp2 = [prefs objectForKey:@"mcpServer2"];
    if (mcp2 && [mcp2 length] > 0) {
        OCMCPClient *client = [[[OCMCPClient alloc] initWithURL:mcp2 name:@"MCP2"] autorelease];
        [_localAgent addMCPServer:client];
        [client connect:nil];
    }

    [self _reloadChannels:prefs];
}

- (void)_registerPrefsNotifications {
    /* Listen for Darwin notifications from Settings.app PreferenceBundle */
    int token;
    notify_register_dispatch("pro.matthesketh.legacypodclaw/prefsChanged", &token,
        dispatch_get_main_queue(), ^(int t) {
            NSLog(@"[LegacyPodClaw] Preferences changed, reloading...");
            [self loadConnectionSettings];
        });
    notify_register_dispatch("pro.matthesketh.legacypodclaw/connect", &token,
        dispatch_get_main_queue(), ^(int t) {
            [self connectToGateway];
        });
    notify_register_dispatch("pro.matthesketh.legacypodclaw/disconnect", &token,
        dispatch_get_main_queue(), ^(int t) {
            [self disconnectFromGateway];
        });
    /* the tweak posts this after springboard boots; it acts only if the user turned auto-start on */
    notify_register_dispatch("pro.matthesketh.legacypodclaw/autoStart", &token,
        dispatch_get_main_queue(), ^(int t) {
            [self _autoStart];
        });
}

#pragma mark - URL Scheme

static const NSInteger kTagStartGateway = 8101;

/* any app can open a url, so openclaw://gateway only asks; the user starts the server */
- (BOOL)application:(UIApplication *)application openURL:(NSURL *)url
  sourceApplication:(NSString *)sourceApplication annotation:(id)annotation {
    if (![[[url scheme] lowercaseString] isEqualToString:@"openclaw"]) return NO;
    if ([[url host] isEqualToString:@"gateway"] && !_gatewayServer.isRunning) {
        UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Start Gateway Server?"
            message:@"Other devices on this network can then connect with the access token."
            delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Start", nil];
        alert.tag = kTagStartGateway;
        [alert show];
        [alert release];
    }
    return YES;
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alertView.tag != kTagStartGateway || buttonIndex != 1) return;
    NSError *err = nil;
    if (![self startGatewayServer:&err]) {
        UIAlertView *fail = [[UIAlertView alloc] initWithTitle:@"Gateway Not Started"
            message:[err localizedDescription] ?: @"The server did not start."
            delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
        [fail show];
        [fail release];
        return;
    }
    /* remember the choice the same way the settings switch does */
    NSMutableDictionary *prefs = [NSMutableDictionary dictionaryWithContentsOfFile:LPCPrefsPath] ?: [NSMutableDictionary dictionary];
    [prefs setObject:@YES forKey:@"gatewayServerEnabled"];
    if ([prefs writeToFile:LPCPrefsPath atomically:YES]) chmod([LPCPrefsPath fileSystemRepresentation], 0600);
}

#pragma mark - Gateway Server

- (BOOL)startGatewayServer:(NSError **)error {
    if (_gatewayServer.isRunning) return YES;
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:LPCPrefsPath];
    OCModelConfig *mc = _localAgent.modelConfig;
    OCGatewayConfig *cfg = [[[OCGatewayConfig alloc] init] autorelease];
    NSString *portStr = [prefs objectForKey:@"serverPort"];
    cfg.port = [portStr intValue] > 0 ? (uint16_t)[portStr intValue] : 18789;
    cfg.defaultProviderId = mc.providerId;
    cfg.defaultModelId = mc.modelId;
    cfg.defaultApiKey = mc.apiKey;
    cfg.defaultBaseURL = mc.baseURL;

    OCGatewayServer *server = [[[OCGatewayServer alloc] initWithConfig:cfg] autorelease];
    OCChannelManager *channels = _channelManager;
    server.webhookHandler = ^NSString *(NSDictionary *payload) {
        id<OCChannel> ch = [channels channelForId:@"webhook"];
        if (![(id)ch isKindOfClass:[OCWebhookChannel class]]) return @"The webhook channel is not enabled";
        return [(OCWebhookChannel *)ch handleInboundPayload:payload];
    };
    if (![server start:error]) return NO;
    self.gatewayServer = server;
    return YES;
}

- (void)stopGatewayServer {
    [_gatewayServer stop];
    self.gatewayServer = nil;
}

#pragma mark - Channels

static BOOL PrefOn(NSDictionary *prefs, NSString *key) { return [[prefs objectForKey:key] boolValue]; }
static NSString *PrefString(NSDictionary *prefs, NSString *key) {
    id v = [prefs objectForKey:key];
    if ([v isKindOfClass:[NSNumber class]]) v = [v description];
    return [v isKindOfClass:[NSString class]] ? [v stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
}

/* everything a channel is built from; a restart happens only when this changes */
- (NSDictionary *)_channelSettings:(NSDictionary *)prefs {
    NSMutableDictionary *cfg = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"telegramEnabled", @"discordEnabled", @"slackEnabled", @"ircEnabled", @"webhookEnabled",
                            @"ircServer", @"ircPort", @"ircTLS", @"ircNick", @"ircChannels", @"webhookCallbackURL"]) {
        id v = [prefs objectForKey:key];
        if (v) [cfg setObject:v forKey:key];
    }
    NSArray *secrets = @[];
    if (PrefOn(prefs, @"telegramEnabled")) secrets = [secrets arrayByAddingObject:@"telegramBotToken"];
    if (PrefOn(prefs, @"discordEnabled")) secrets = [secrets arrayByAddingObject:@"discordBotToken"];
    if (PrefOn(prefs, @"slackEnabled")) secrets = [secrets arrayByAddingObjectsFromArray:@[@"slackAppToken", @"slackBotToken"]];
    if (PrefOn(prefs, @"ircEnabled")) secrets = [secrets arrayByAddingObject:@"ircPassword"];
    if (PrefOn(prefs, @"webhookEnabled")) secrets = [secrets arrayByAddingObject:@"webhookCallbackToken"];
    for (NSString *key in secrets) {
        NSString *v = [CPSecretStore secretForKey:key];
        if (v) [cfg setObject:v forKey:key];
    }
    return cfg;
}

- (void)_reloadChannels:(NSDictionary *)prefs {
    if (!_channelManager) {
        _channelManager = [[OCChannelManager alloc] init];
        _channelRouter = [[OCChannelRouter alloc] init];
        _channelRouter.manager = _channelManager;
        _channelRouter.toolSource = _localAgent;
    }

    _channelRouter.modelConfig = _localAgent.modelConfig;
    _channelRouter.systemPrompt = _localAgent.systemPrompt;
    _channelRouter.maxContextTokens = MIN(_localAgent.modelConfig.contextWindow ?: 2048, (NSUInteger)4096);
    _channelRouter.toolsEnabled = PrefOn(prefs, @"channelToolsEnabled");

    NSDictionary *cfg = [self _channelSettings:prefs];
    NSMutableArray *ids = [NSMutableArray arrayWithObjects:@"telegram", @"discord", @"slack", @"irc", @"webhook", nil];
    for (id<OCChannel> ch in [_pluginManager allPluginChannels]) [ids addObject:[ch channelId]];
    for (NSString *cid in ids) {
        [_channelRouter setAllowedSenders:OCListFromString(PrefString(prefs, [cid stringByAppendingString:@"AllowedIds"]))
                               forChannel:cid];
    }

    if (_channelSettings && [_channelSettings isEqualToDictionary:cfg]) return;
    [_channelSettings release];
    _channelSettings = [cfg retain];

    [_channelManager removeAllChannels];
    [_channelRouter reset];

    NSString *tg = [cfg objectForKey:@"telegramBotToken"];
    if (PrefOn(prefs, @"telegramEnabled") && [tg length])
        [_channelManager registerChannel:[[[OCTelegramChannel alloc] initWithBotToken:tg] autorelease]];
    NSString *dc = [cfg objectForKey:@"discordBotToken"];
    if (PrefOn(prefs, @"discordEnabled") && [dc length])
        [_channelManager registerChannel:[[[OCDiscordChannel alloc] initWithBotToken:dc] autorelease]];
    NSString *slackApp = [cfg objectForKey:@"slackAppToken"], *slackBot = [cfg objectForKey:@"slackBotToken"];
    if (PrefOn(prefs, @"slackEnabled") && [slackApp length] && [slackBot length])
        [_channelManager registerChannel:[[[OCSlackChannel alloc] initWithAppToken:slackApp botToken:slackBot] autorelease]];
    NSString *server = PrefString(prefs, @"ircServer"), *nick = PrefString(prefs, @"ircNick");
    if (PrefOn(prefs, @"ircEnabled") && [server length] && [nick length]) {
        OCIRCChannel *irc = [[[OCIRCChannel alloc] initWithServer:server port:[PrefString(prefs, @"ircPort") intValue]
                                                           useTLS:PrefOn(prefs, @"ircTLS") nickname:nick] autorelease];
        irc.password = [cfg objectForKey:@"ircPassword"];
        irc.channels = OCListFromString(PrefString(prefs, @"ircChannels"));
        [_channelManager registerChannel:irc];
    }
    NSString *callback = PrefString(prefs, @"webhookCallbackURL");
    if (PrefOn(prefs, @"webhookEnabled") && [callback length]) {
        [_channelManager registerChannel:[[[OCWebhookChannel alloc] initWithCallbackURL:callback
                                                                            bearerToken:[cfg objectForKey:@"webhookCallbackToken"]] autorelease]];
    }
    for (id<OCChannel> ch in [_pluginManager allPluginChannels]) {
        if (![_channelManager registerChannel:ch]) NSLog(@"[LegacyPodClaw] plugin channel %@ clashes with another channel", [ch channelId]);
    }
    [_channelManager startAll];
    NSLog(@"[LegacyPodClaw] %lu channels configured", (unsigned long)[[_channelManager channels] count]);
}

- (void)_autoStart {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:LPCPrefsPath];
    if (!PrefOn(prefs, @"autoStartOnBoot")) return;
    NSLog(@"[LegacyPodClaw] auto-start requested");
    [self _reloadChannels:prefs];
    [_channelManager startAll];
    if (PrefOn(prefs, @"gatewayServerEnabled")) {
        NSError *err = nil;
        if (![self startGatewayServer:&err]) NSLog(@"[LegacyPodClaw] gateway server did not start: %@", err);
    }
}


#pragma mark - OCGatewayClientDelegate

- (void)gatewayClient:(OCGatewayClient *)client
       didChangeState:(OCGatewayConnectionState)state {
    [_rootViewController updateConnectionState:state];

    if (state == OCGatewayStateConnected) {
        [_sessionManager loadSessions];
    }
}

- (void)gatewayClient:(OCGatewayClient *)client
   didReceiveChatEvent:(OCGatewayChatEvent *)event {
    [_sessionManager handleChatEvent:event];
}

- (void)gatewayClient:(OCGatewayClient *)client
       didFailWithError:(NSError *)error {
    NSLog(@"[LegacyPodClaw] Gateway error: %@", error);
    [_rootViewController showError:[error localizedDescription]];
}

- (void)gatewayClient:(OCGatewayClient *)client
   didConnectWithServerInfo:(OCGatewayServerInfo *)info {
    NSLog(@"[LegacyPodClaw] Connected to gateway v%@ (conn: %@)",
          info.version, info.connectionId);
    /* Save device token if updated */
    [self saveConnectionSettings];
}

#pragma mark - OCSessionManagerDelegate

- (void)sessionManager:(id)manager didUpdateSession:(OCChatSession *)session {
    [_rootViewController reloadSessions];
}

- (void)sessionManager:(id)manager didReceiveMessage:(OCMessage *)message
             inSession:(OCChatSession *)session {
    [_rootViewController didReceiveMessage:message inSession:session];
}

- (void)sessionManager:(id)manager didUpdateStreamingMessage:(OCMessage *)message
             inSession:(OCChatSession *)session {
    [_rootViewController didUpdateStreamingMessage:message inSession:session];
}

- (void)dealloc {
    [[OCMemoryMonitor sharedMonitor] stopMonitoring];
    [_window release]; [_rootViewController release];
    [_gateway release]; [_store release]; [_sessionManager release];
    [_settings release]; [_localAgent release];
    [_channelRouter release]; [_channelManager release]; [_channelSettings release];
    [_pluginManager release]; [_gatewayServer release];
    [super dealloc];
}

@end
