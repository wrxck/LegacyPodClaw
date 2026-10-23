/* table of fields for one channel; every change is saved at once and the app reloads its channels */

#import "ChannelSettingsViewController.h"
#import "AppDelegate.h"
#import "SecretStore.h"
#import "ChannelManager.h"
#import <sys/stat.h>
#import <notify.h>

static NSString *const kPrefsPath = @"/var/mobile/Library/Preferences/pro.matthesketh.legacypodclaw.plist";

static NSDictionary *Field(NSString *label, NSString *key, NSString *type, NSString *placeholder) {
    return @{@"label": label, @"key": key, @"type": type, @"placeholder": placeholder ?: @""};
}

@interface OCChannelSettingsViewController () {
    NSArray *_fields;
    NSString *_footer;
    NSString *_editingKey;
}
@end

@implementation OCChannelSettingsViewController

+ (NSArray *)channelIds { return @[@"telegram", @"discord", @"slack", @"irc", @"webhook"]; }

+ (NSString *)titleForChannel:(NSString *)cid {
    return [@{@"telegram": @"Telegram", @"discord": @"Discord", @"slack": @"Slack", @"irc": @"IRC",
              @"webhook": @"Webhook"} objectForKey:cid] ?: cid;
}

+ (NSArray *)fieldsForChannel:(NSString *)cid {
    NSString *enabled = [cid stringByAppendingString:@"Enabled"];
    NSString *allowed = [cid stringByAppendingString:@"AllowedIds"];
    if ([cid isEqualToString:@"telegram"]) return @[
        Field(@"Enabled", enabled, @"switch", nil),
        Field(@"Bot Token", @"telegramBotToken", @"secret", @"123456:ABC..."),
        Field(@"Allowed IDs", allowed, @"text", @"user or chat IDs, comma separated")];
    if ([cid isEqualToString:@"discord"]) return @[
        Field(@"Enabled", enabled, @"switch", nil),
        Field(@"Bot Token", @"discordBotToken", @"secret", @"Bot token"),
        Field(@"Allowed IDs", allowed, @"text", @"user or channel IDs")];
    if ([cid isEqualToString:@"slack"]) return @[
        Field(@"Enabled", enabled, @"switch", nil),
        Field(@"App Token", @"slackAppToken", @"secret", @"xapp-..."),
        Field(@"Bot Token", @"slackBotToken", @"secret", @"xoxb-..."),
        Field(@"Allowed IDs", allowed, @"text", @"member or channel IDs")];
    if ([cid isEqualToString:@"irc"]) return @[
        Field(@"Enabled", enabled, @"switch", nil),
        Field(@"Server", @"ircServer", @"text", @"irc.libera.chat"),
        Field(@"Port", @"ircPort", @"number", @"6697"),
        Field(@"Use TLS", @"ircTLS", @"switch", nil),
        Field(@"Nickname", @"ircNick", @"text", @"podclaw"),
        Field(@"Password", @"ircPassword", @"secret", @"Server or NickServ password"),
        Field(@"Channels", @"ircChannels", @"text", @"#one, #two"),
        Field(@"Allowed", allowed, @"text", @"nick!user@host masks or nicks")];
    if ([cid isEqualToString:@"webhook"]) return @[
        Field(@"Enabled", enabled, @"switch", nil),
        Field(@"Callback URL", @"webhookCallbackURL", @"text", @"https://example.com/hook"),
        Field(@"Callback Token", @"webhookCallbackToken", @"secret", @"Sent as a bearer token"),
        Field(@"Allowed Senders", allowed, @"text", @"senderId values")];
    return @[];
}

+ (NSString *)footerForChannel:(NSString *)cid {
    NSString *common = @"Messages from anyone not on the allow list are ignored. An empty list ignores everyone.";
    NSDictionary *notes = @{
        @"telegram": @"Create a bot with @BotFather. Your user ID is the number in the chat ID of a private chat with the bot.",
        @"discord": @"Turn on the Message Content intent for the bot. In servers the bot answers only when it is mentioned.",
        @"slack": @"Use Socket Mode: an app-level token with connections:write, and a bot token with chat:write, "
                  @"app_mentions:read and im:history. In channels the app answers only when it is mentioned.",
        @"irc": @"In a channel the bot answers lines that start with its nick. Match on the full nick!user@host mask where "
                @"you can, because a bare nick can be taken by anyone.",
        @"webhook": @"Send POST /webhook/incoming to the gateway server on this device with the gateway access token and "
                    @"{\"text\", \"senderId\", \"chatId\"}. Replies are posted to the callback URL. The gateway server must run."};
    return [NSString stringWithFormat:@"%@\n\n%@", [notes objectForKey:cid] ?: @"", common];
}

+ (NSString *)stateTextForChannel:(NSString *)cid {
    NSDictionary *status = [[[AppDelegate shared].channelManager allChannelStatus] objectForKey:cid];
    if (!status) return @"Off";
    if ([[status objectForKey:@"connected"] boolValue]) return @"Connected";
    if ([[status objectForKey:@"state"] isEqual:@"stopped"]) return @"Stopped";
    return [[status objectForKey:@"lastError"] length] ? @"Retrying" : @"Connecting…";
}

- (id)initWithTitle:(NSString *)title fields:(NSArray *)fields footer:(NSString *)footer {
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        self.title = title;
        _fields = [fields copy];
        _footer = [footer copy];
        /* the channel changes state long after the setting that caused it, so the status row must follow it */
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_channelStatusChanged:)
                                                     name:OCChannelStatusDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_fields release]; [_footer release]; [_editingKey release];
    [super dealloc];
}

#pragma mark - Preferences

- (NSMutableDictionary *)_prefs {
    return [NSMutableDictionary dictionaryWithContentsOfFile:kPrefsPath] ?: [NSMutableDictionary dictionary];
}

- (void)_setPref:(id)value forKey:(NSString *)key {
    /* read, change, write: the main settings screen writes the same file */
    NSMutableDictionary *prefs = [self _prefs];
    if (value) [prefs setObject:value forKey:key]; else [prefs removeObjectForKey:key];
    if ([prefs writeToFile:kPrefsPath atomically:YES]) chmod([kPrefsPath fileSystemRepresentation], 0600);
    [self _changed];
}

- (void)_changed {
    /* the app's own prefsChanged listener reloads the settings; a direct call here would reconnect twice */
    notify_post("pro.matthesketh.legacypodclaw/prefsChanged");
    [self.tableView reloadData];
}

- (NSString *)_displayValue:(NSDictionary *)field {
    NSString *key = [field objectForKey:@"key"];
    if ([[field objectForKey:@"type"] isEqualToString:@"secret"])
        return [[CPSecretStore secretForKey:key] length] ? @"•••••" : @"Not set";
    id v = [[self _prefs] objectForKey:key];
    NSString *s = [v description];
    return [s length] ? s : @"Not set";
}

- (NSString *)_channelId {
    /* the first field is always the channel's enable switch, named after the channel id */
    return [[[_fields objectAtIndex:0] objectForKey:@"key"] stringByReplacingOccurrencesOfString:@"Enabled" withString:@""];
}

- (void)_channelStatusChanged:(NSNotification *)note {
    if (![self isViewLoaded] || ![[note object] isEqual:[self _channelId]]) return;
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == 0 ? (NSInteger)[_fields count] : 1;
}

- (NSDictionary *)_status {
    return [[[AppDelegate shared].channelManager allChannelStatus] objectForKey:[self _channelId]];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return _footer;
    /* a footer wraps, so a long error such as discord's intent advice can be read in full */
    NSString *err = [[self _status] objectForKey:@"lastError"];
    return [err isKindOfClass:[NSString class]] && [err length] ? err : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil] autorelease];
    if (indexPath.section == 1) {
        cell.textLabel.text = @"Status";
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        /* the full error is in the footer below the row */
        cell.detailTextLabel.text = [OCChannelSettingsViewController stateTextForChannel:[self _channelId]];
        return cell;
    }
    NSDictionary *field = [_fields objectAtIndex:indexPath.row];
    NSString *key = [field objectForKey:@"key"];
    cell.textLabel.text = [field objectForKey:@"label"];
    if ([[field objectForKey:@"type"] isEqualToString:@"switch"]) {
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        UISwitch *sw = [[[UISwitch alloc] init] autorelease];
        sw.on = [[[self _prefs] objectForKey:key] boolValue];
        sw.tag = indexPath.row;
        [sw addTarget:self action:@selector(_switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = sw;
    } else {
        cell.detailTextLabel.text = [self _displayValue:field];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)_switchChanged:(UISwitch *)sw {
    NSDictionary *field = [_fields objectAtIndex:(NSUInteger)sw.tag];
    [self _setPref:@(sw.on) forKey:[field objectForKey:@"key"]];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 0) return;
    NSDictionary *field = [_fields objectAtIndex:indexPath.row];
    NSString *type = [field objectForKey:@"type"];
    if ([type isEqualToString:@"switch"]) return;

    [_editingKey release];
    _editingKey = [[field objectForKey:@"key"] copy];
    BOOL secret = [type isEqualToString:@"secret"];
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:[field objectForKey:@"label"] message:nil delegate:self
                                          cancelButtonTitle:@"Cancel" otherButtonTitles:@"Save", nil];
    alert.alertViewStyle = secret ? UIAlertViewStyleSecureTextInput : UIAlertViewStylePlainTextInput;
    UITextField *tf = [alert textFieldAtIndex:0];
    tf.placeholder = [field objectForKey:@"placeholder"];
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;
    if ([type isEqualToString:@"number"]) tf.keyboardType = UIKeyboardTypeNumberPad;
    if (!secret) tf.text = [[[self _prefs] objectForKey:_editingKey] description];
    [alert show];
    [alert release];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (buttonIndex != 1 || !_editingKey) return;
    NSString *value = [[[alertView textFieldAtIndex:0] text]
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([CPSecretStore isSecretKey:_editingKey]) {
        if (![CPSecretStore setSecret:value forKey:_editingKey]) {
            UIAlertView *a = [[UIAlertView alloc] initWithTitle:@"Not Saved"
                message:@"clawpodd did not store the value. Unlock the device and check that clawpodd runs."
                delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
            [a show]; [a release];
        }
        [self _changed];
        return;
    }
    [self _setPref:[value length] ? value : nil forKey:_editingKey];
}

@end
