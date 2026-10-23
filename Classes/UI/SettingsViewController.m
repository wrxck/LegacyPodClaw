/*
 * OCSettingsViewController.m
 * LegacyPodClaw - In-App Settings
 *
 * Reads/writes /var/mobile/Library/Preferences/pro.matthesketh.legacypodclaw.plist
 * Posts Darwin notification so app reloads settings live.
 */

#import "SettingsViewController.h"
#import "ChannelSettingsViewController.h"
#import "AppDelegate.h"
#import "ChannelManager.h"
#import "SecretStore.h"
#import "GatewayToken.h"
#import "ProviderRegistry.h"
#import <sys/stat.h>
#import <notify.h>

#define PREFS_PATH @"/var/mobile/Library/Preferences/pro.matthesketh.legacypodclaw.plist"

typedef NS_ENUM(NSUInteger, SettingsSection) {
    SettingsSectionGateway = 0,
    SettingsSectionAuth,
    SettingsSectionAgent,
    SettingsSectionChannels,
    SettingsSectionServer,
    SettingsSectionActions,
    SettingsSectionAbout,
    SettingsSectionCount
};

enum {
    kTagUseTLS = 1000,
    kTagSelfSigned = 1001,
    kTagServer = 2000,
    kTagChannelTools = 3000,
    kTagAutoStart = 3001,
    kTagTokenAlert = 500,
    kTagTokenConfirm = 501,
    kTagResetConfirm = 502,
    kTagInput = 100,
};

@interface OCSettingsViewController () <UIActionSheetDelegate> {
    NSMutableDictionary *_prefs;
    NSString *_editingKey;
}
@end

@implementation OCSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Settings";
    self.tableView.backgroundColor = [UIColor groupTableViewBackgroundColor];

    self.navigationItem.rightBarButtonItem = [[[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                             target:self
                             action:@selector(_done)] autorelease];
    /* a channel connects or fails long after the setting that caused it, so its row must follow it */
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_channelStatusChanged:)
                                                 name:OCChannelStatusDidChangeNotification object:nil];
}

- (void)_channelStatusChanged:(NSNotification *)note {
    NSUInteger row = [[OCChannelSettingsViewController channelIds] indexOfObject:[note object]];
    if (row == NSNotFound || ![self isViewLoaded]) return;
    NSIndexPath *path = [NSIndexPath indexPathForRow:(NSInteger)row inSection:SettingsSectionChannels];
    [self.tableView reloadRowsAtIndexPaths:@[path] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    /* a channel screen may have written the plist since this one last read it */
    [self _loadPrefs];
    [self.tableView reloadData];
}

- (void)_done {
    [self.navigationController popViewControllerAnimated:YES];
}

- (void)_loadPrefs {
    [_prefs release];
    _prefs = [[NSMutableDictionary dictionaryWithContentsOfFile:PREFS_PATH] retain];
    if (!_prefs) _prefs = [[NSMutableDictionary alloc] init];
}

- (void)_savePrefs {
    /* clawpodd migrates plist secrets at any time, so keep the file's current secret entries, not our stale copy */
    NSDictionary *disk = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
    for (NSString *key in [CPSecretStore allSecretKeys]) {
        id onDisk = [disk objectForKey:key];
        if (onDisk) [_prefs setObject:onDisk forKey:key];
        else [_prefs removeObjectForKey:key];
    }
    /* the plist holds the api base url, so keep it private to mobile */
    if ([_prefs writeToFile:PREFS_PATH atomically:YES]) chmod([PREFS_PATH fileSystemRepresentation], 0600);
    /* the app's own prefsChanged listener reloads the settings; a direct call here would reconnect twice */
    notify_post("pro.matthesketh.legacypodclaw/prefsChanged");
}

- (NSString *)_prefString:(NSString *)key {
    if ([CPSecretStore isSecretKey:key]) return [CPSecretStore secretForKey:key] ?: @"";
    return [[_prefs objectForKey:key] description] ?: @"";
}

- (BOOL)_prefBool:(NSString *)key {
    return [[_prefs objectForKey:key] boolValue];
}

- (OCProviderInfo *)_provider {
    return [OCProviderInfo providerWithId:[_prefs objectForKey:@"modelProvider"]]
        ?: [OCProviderInfo providerWithId:[OCProviderInfo defaultProviderId]];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_prefs release];
    [_editingKey release];
    [super dealloc];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return SettingsSectionCount;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case SettingsSectionGateway:  return @"Gateway Connection";
        case SettingsSectionAuth:     return @"Authentication";
        case SettingsSectionAgent:    return @"Model Provider";
        case SettingsSectionChannels: return @"Chat Channels";
        case SettingsSectionServer:   return @"Gateway Server";
        case SettingsSectionActions:  return @"";
        case SettingsSectionAbout:    return @"About";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    switch (section) {
        case SettingsSectionGateway:
            return @"Connect to a LegacyPodClaw gateway on your network.";
        case SettingsSectionAgent:
            return @"Used when no gateway is connected, by chat channels and by the gateway server.";
        case SettingsSectionChannels:
            return @"Chat messages are untrusted. With tools off, chat replies cannot touch the device. With tools on, "
                   @"every tool call from a chat must be approved on this device. Channels run only while the app runs.";
        case SettingsSectionServer:
            return @"Run the full LegacyPodClaw gateway on this device. Other devices on your network "
                   @"must send the access token as \"Authorization: Bearer <token>\".";
        default: return nil;
    }
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case SettingsSectionGateway:  return 5;
        case SettingsSectionAuth:     return 2;
        case SettingsSectionAgent:    return 4;
        case SettingsSectionChannels: return (NSInteger)[[OCChannelSettingsViewController channelIds] count] + 2;
        case SettingsSectionServer:   return 4;
        case SettingsSectionActions:  return 2;
        case SettingsSectionAbout:    return 2;
        default: return 0;
    }
}

- (UITableViewCell *)_switchCell:(NSString *)title on:(BOOL)on tag:(NSInteger)tag {
    UITableViewCell *cell = [[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil] autorelease];
    cell.textLabel.text = title;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UISwitch *sw = [[[UISwitch alloc] init] autorelease];
    sw.on = on;
    sw.tag = tag;
    [sw addTarget:self action:@selector(_switchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[[UITableViewCell alloc]
        initWithStyle:UITableViewCellStyleValue1
      reuseIdentifier:nil] autorelease];
    cell.selectionStyle = UITableViewCellSelectionStyleBlue;
    NSString *const dots = @"•••••";

    switch (indexPath.section) {
        case SettingsSectionGateway: {
            switch (indexPath.row) {
                case 0:
                    cell.textLabel.text = @"Host";
                    cell.detailTextLabel.text = [[self _prefString:@"gatewayHost"] length] > 0
                        ? [self _prefString:@"gatewayHost"] : @"Not set";
                    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                    break;
                case 1:
                    cell.textLabel.text = @"Port";
                    cell.detailTextLabel.text = [[self _prefString:@"gatewayPort"] length] > 0
                        ? [self _prefString:@"gatewayPort"] : @"18789";
                    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                    break;
                case 2: return [self _switchCell:@"Use TLS" on:[self _prefBool:@"useTLS"] tag:kTagUseTLS];
                case 3: return [self _switchCell:@"Self-Signed Certs" on:[self _prefBool:@"allowSelfSigned"] tag:kTagSelfSigned];
                case 4:
                    /* self-signed mode trusts only this certificate */
                    cell.textLabel.text = @"Cert SHA-256";
                    cell.detailTextLabel.text = [[self _prefString:@"gatewayCertSHA256"] length] > 0 ? @"Pinned" : @"Not set";
                    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                    break;
            }
            break;
        }
        case SettingsSectionAuth: {
            NSString *key = indexPath.row == 0 ? @"authToken" : @"authPassword";
            cell.textLabel.text = indexPath.row == 0 ? @"Token" : @"Password";
            cell.detailTextLabel.text = [[self _prefString:key] length] > 0 ? dots : @"Not set";
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        }
        case SettingsSectionAgent: {
            OCProviderInfo *provider = [self _provider];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            switch (indexPath.row) {
                case 0:
                    cell.textLabel.text = @"Provider";
                    cell.detailTextLabel.text = provider.displayName;
                    break;
                case 1:
                    cell.textLabel.text = @"Model";
                    cell.detailTextLabel.text = [[self _prefString:@"modelId"] length] > 0
                        ? [self _prefString:@"modelId"] : (provider.defaultModel ?: @"Not set");
                    break;
                case 2:
                    cell.textLabel.text = @"API Key";
                    if (!provider.secretKey) {
                        cell.detailTextLabel.text = @"Not needed";
                        cell.accessoryType = UITableViewCellAccessoryNone;
                        cell.selectionStyle = UITableViewCellSelectionStyleNone;
                    } else {
                        cell.detailTextLabel.text = [[self _prefString:provider.secretKey] length] > 0 ? dots
                            : (provider.requiresKey ? @"Not set" : @"Optional");
                    }
                    break;
                case 3:
                    cell.textLabel.text = @"Base URL";
                    cell.detailTextLabel.text = [[self _prefString:provider.baseURLPrefKey] length] > 0
                        ? [self _prefString:provider.baseURLPrefKey] : (provider.defaultBaseURL ? @"Default" : @"Not set");
                    break;
            }
            break;
        }
        case SettingsSectionChannels: {
            NSArray *ids = [OCChannelSettingsViewController channelIds];
            if ((NSUInteger)indexPath.row < [ids count]) {
                NSString *cid = [ids objectAtIndex:indexPath.row];
                cell.textLabel.text = [OCChannelSettingsViewController titleForChannel:cid];
                cell.detailTextLabel.text = [OCChannelSettingsViewController stateTextForChannel:cid];
                cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            } else if ((NSUInteger)indexPath.row == [ids count]) {
                return [self _switchCell:@"Tools in Chats" on:[self _prefBool:@"channelToolsEnabled"] tag:kTagChannelTools];
            } else {
                return [self _switchCell:@"Start on Boot" on:[self _prefBool:@"autoStartOnBoot"] tag:kTagAutoStart];
            }
            break;
        }
        case SettingsSectionServer: {
            switch (indexPath.row) {
                case 0:
                    return [self _switchCell:@"Gateway Server" on:[AppDelegate shared].gatewayServer.isRunning tag:kTagServer];
                case 1:
                    cell.textLabel.text = @"Server Port";
                    cell.detailTextLabel.text = [[self _prefString:@"serverPort"] length] > 0
                        ? [self _prefString:@"serverPort"] : @"18789";
                    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                    break;
                case 2: {
                    BOOL running = [AppDelegate shared].gatewayServer.isRunning;
                    cell.textLabel.text = @"Status";
                    cell.selectionStyle = UITableViewCellSelectionStyleNone;
                    if (running) {
                        NSUInteger clients = [[AppDelegate shared].gatewayServer.connectedClients count];
                        cell.detailTextLabel.text = [NSString stringWithFormat:@"Running (%lu clients)",
                                                     (unsigned long)clients];
                        cell.detailTextLabel.textColor = [UIColor colorWithRed:0.2f green:0.7f blue:0.3f alpha:1.0f];
                    } else {
                        cell.detailTextLabel.text = @"Stopped";
                        cell.detailTextLabel.textColor = [UIColor grayColor];
                    }
                    break;
                }
                case 3: {
                    NSString *token = [OCGatewayToken currentToken];
                    cell.textLabel.text = @"Access Token";
                    cell.detailTextLabel.text = token
                        ? [[token substringToIndex:8] stringByAppendingString:@"…"] : @"Unavailable";
                    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
                    break;
                }
            }
            break;
        }
        case SettingsSectionActions: {
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            cell.accessoryType = UITableViewCellAccessoryNone;
            cell.detailTextLabel.text = nil;
            if (indexPath.row == 0) {
                BOOL connected = [AppDelegate shared].gateway.connectionState == OCGatewayStateConnected;
                cell.textLabel.text = connected ? @"Disconnect" : @"Connect to Gateway";
                cell.textLabel.textColor = connected
                    ? [UIColor colorWithRed:0.9f green:0.2f blue:0.2f alpha:1.0f]
                    : [UIColor colorWithRed:0.0f green:0.478f blue:1.0f alpha:1.0f];
            } else {
                cell.textLabel.text = @"Reset All Settings";
                cell.textLabel.textColor = [UIColor colorWithRed:0.9f green:0.2f blue:0.2f alpha:1.0f];
            }
            break;
        }
        case SettingsSectionAbout: {
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.accessoryType = UITableViewCellAccessoryNone;
            if (indexPath.row == 0) {
                cell.textLabel.text = @"Version";
                /* one source for the version: the bundle the package installs */
                cell.detailTextLabel.text = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
            } else {
                cell.textLabel.text = @"Device";
                cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ iOS %@",
                    [[UIDevice currentDevice] model],
                    [[UIDevice currentDevice] systemVersion]];
            }
            break;
        }
    }

    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == SettingsSectionGateway) {
        if (indexPath.row == 0) {
            [self _showInput:@"Gateway Host" key:@"gatewayHost" placeholder:@"192.168.1.x" secure:NO];
        } else if (indexPath.row == 1) {
            [self _showInput:@"Gateway Port" key:@"gatewayPort" placeholder:@"18789" secure:NO];
        } else if (indexPath.row == 4) {
            [self _showInput:@"Certificate SHA-256 (openssl x509 -noout -fingerprint -sha256)" key:@"gatewayCertSHA256"
                 placeholder:@"AB:CD:..." secure:NO];
        }
    } else if (indexPath.section == SettingsSectionAuth) {
        if (indexPath.row == 0) {
            [self _showInput:@"Auth Token" key:@"authToken" placeholder:@"Token" secure:YES];
        } else {
            [self _showInput:@"Password" key:@"authPassword" placeholder:@"Password" secure:YES];
        }
    } else if (indexPath.section == SettingsSectionAgent) {
        OCProviderInfo *provider = [self _provider];
        if (indexPath.row == 0) {
            [self _showProviderPicker];
        } else if (indexPath.row == 1) {
            [self _showInput:@"Model ID" key:@"modelId" placeholder:provider.modelHint ?: @"" secure:NO];
        } else if (indexPath.row == 2 && provider.secretKey) {
            [self _showInput:[NSString stringWithFormat:@"%@ API Key", provider.displayName]
                         key:provider.secretKey placeholder:@"API key" secure:YES];
        } else if (indexPath.row == 3) {
            [self _showInput:[NSString stringWithFormat:@"%@ Base URL", provider.displayName] key:provider.baseURLPrefKey
                 placeholder:provider.defaultBaseURL ?: @"http://192.168.1.x:11434/v1" secure:NO];
        }
    } else if (indexPath.section == SettingsSectionChannels) {
        NSArray *ids = [OCChannelSettingsViewController channelIds];
        if ((NSUInteger)indexPath.row >= [ids count]) return;
        NSString *cid = [ids objectAtIndex:indexPath.row];
        OCChannelSettingsViewController *vc = [[[OCChannelSettingsViewController alloc]
            initWithTitle:[OCChannelSettingsViewController titleForChannel:cid]
                   fields:[OCChannelSettingsViewController fieldsForChannel:cid]
                   footer:[OCChannelSettingsViewController footerForChannel:cid]] autorelease];
        [self.navigationController pushViewController:vc animated:YES];
    } else if (indexPath.section == SettingsSectionServer) {
        if (indexPath.row == 1) {
            [self _showInput:@"Server Port" key:@"serverPort" placeholder:@"18789" secure:NO];
        } else if (indexPath.row == 3) {
            [self _showAccessToken];
        }
    } else if (indexPath.section == SettingsSectionActions) {
        if (indexPath.row == 0) {
            BOOL connected = [AppDelegate shared].gateway.connectionState == OCGatewayStateConnected;
            if (connected) {
                [[AppDelegate shared] disconnectFromGateway];
            } else {
                [[AppDelegate shared] connectToGateway];
            }
            [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
        } else {
            UIAlertView *confirm = [[UIAlertView alloc] initWithTitle:@"Reset All Settings"
                message:@"This deletes every setting, API key and token." delegate:self
                cancelButtonTitle:@"Cancel" otherButtonTitles:@"Reset", nil];
            confirm.tag = kTagResetConfirm;
            [confirm show];
            [confirm release];
        }
    }
}

- (void)_resetAllSettings {
    [_prefs removeAllObjects];
    /* secrets live in the keychain, so clearing the plist alone would keep them */
    for (NSString *key in [CPSecretStore allSecretKeys]) [CPSecretStore setSecret:nil forKey:key];
    [self _savePrefs];
    [self.tableView reloadData];
}

#pragma mark - Provider Picker

- (void)_showProviderPicker {
    UIActionSheet *sheet = [[UIActionSheet alloc] initWithTitle:@"Model Provider" delegate:self
                                              cancelButtonTitle:nil destructiveButtonTitle:nil otherButtonTitles:nil];
    for (OCProviderInfo *p in [OCProviderInfo allProviders]) [sheet addButtonWithTitle:p.displayName];
    sheet.cancelButtonIndex = [sheet addButtonWithTitle:@"Cancel"];
    [sheet showInView:self.view];
    [sheet release];
}

- (void)actionSheet:(UIActionSheet *)sheet clickedButtonAtIndex:(NSInteger)buttonIndex {
    NSArray *all = [OCProviderInfo allProviders];
    if (buttonIndex < 0 || (NSUInteger)buttonIndex >= [all count]) return;
    OCProviderInfo *chosen = [all objectAtIndex:buttonIndex];
    if ([chosen.providerId isEqualToString:[self _provider].providerId]) return;
    [_prefs setObject:chosen.providerId forKey:@"modelProvider"];
    /* a model id belongs to one provider, so it does not carry over */
    [_prefs removeObjectForKey:@"modelId"];
    [self _savePrefs];
    [self.tableView reloadData];
}

#pragma mark - Input Dialog

- (void)_showInput:(NSString *)title key:(NSString *)key placeholder:(NSString *)placeholder secure:(BOOL)secure {
    [_editingKey release];
    _editingKey = [key copy];

    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:title
                                                    message:nil
                                                   delegate:self
                                          cancelButtonTitle:@"Cancel"
                                          otherButtonTitles:@"Save", nil];
    alert.alertViewStyle = secure ? UIAlertViewStyleSecureTextInput : UIAlertViewStylePlainTextInput;
    alert.tag = kTagInput;

    UITextField *tf = [alert textFieldAtIndex:0];
    tf.placeholder = placeholder;
    tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    tf.autocorrectionType = UITextAutocorrectionTypeNo;

    /* Pre-fill current value (except secure fields) */
    if (!secure) {
        tf.text = [self _prefString:key];
    }

    [alert show];
    [alert release];
}

- (void)_showAccessToken {
    NSString *token = [OCGatewayToken currentToken];
    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Gateway Access Token"
        message:token ?: @"The token file could not be created."
        delegate:self cancelButtonTitle:@"Close" otherButtonTitles:@"Copy", @"Regenerate", nil];
    alert.tag = kTagTokenAlert;
    [alert show];
    [alert release];
}

- (void)_handleTokenAlert:(UIAlertView *)alertView button:(NSInteger)buttonIndex {
    if (alertView.tag == kTagTokenAlert && buttonIndex == 1) {
        NSString *token = [OCGatewayToken currentToken];
        if (token) [[UIPasteboard generalPasteboard] setString:token];
    } else if (alertView.tag == kTagTokenAlert && buttonIndex == 2) {
        UIAlertView *confirm = [[UIAlertView alloc] initWithTitle:@"Regenerate Token?"
            message:@"Every client must be updated with the new token. Connected clients are disconnected."
            delegate:self cancelButtonTitle:@"Cancel" otherButtonTitles:@"Regenerate", nil];
        confirm.tag = kTagTokenConfirm;
        [confirm show];
        [confirm release];
    } else if (alertView.tag == kTagTokenConfirm && buttonIndex == 1) {
        OCGatewayServer *server = [AppDelegate shared].gatewayServer;
        NSString *token = server.isRunning ? [server regenerateAccessToken] : [OCGatewayToken regenerateToken];
        [self.tableView reloadData];
        if (token) [self _showAccessToken];
    }
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    if (alertView.tag == kTagResetConfirm) {
        if (buttonIndex == 1) [self _resetAllSettings];
        return;
    }
    if (alertView.tag == kTagTokenAlert || alertView.tag == kTagTokenConfirm) {
        [self _handleTokenAlert:alertView button:buttonIndex];
        return;
    }
    if (buttonIndex != 1 || alertView.tag != kTagInput || !_editingKey) return;

    NSString *key = _editingKey;
    NSString *value = [[[alertView textFieldAtIndex:0] text]
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    if ([CPSecretStore isSecretKey:key]) {
        if (![CPSecretStore setSecret:value forKey:key]) {
            UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Not Saved"
                message:@"clawpodd did not store the value. Unlock the device and check that clawpodd runs."
                delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil];
            [alert show]; [alert release];
        }
    } else if ([value length] > 0) {
        [_prefs setObject:value forKey:key];
    } else {
        [_prefs removeObjectForKey:key];
    }
    [self _savePrefs];
    [self.tableView reloadData];
}

#pragma mark - Switches

- (void)_switchChanged:(UISwitch *)sw {
    switch (sw.tag) {
        case kTagUseTLS:
            [_prefs setObject:@(sw.on) forKey:@"useTLS"];
            break;
        case kTagSelfSigned:
            [_prefs setObject:@(sw.on) forKey:@"allowSelfSigned"];
            break;
        case kTagChannelTools:
            [_prefs setObject:@(sw.on) forKey:@"channelToolsEnabled"];
            break;
        case kTagAutoStart:
            [_prefs setObject:@(sw.on) forKey:@"autoStartOnBoot"];
            break;
        case kTagServer: {
            if (sw.on) {
                NSError *err = nil;
                if (![[AppDelegate shared] startGatewayServer:&err]) {
                    UIAlertView *alert = [[UIAlertView alloc] initWithTitle:@"Server Error"
                        message:[err localizedDescription] delegate:nil
                        cancelButtonTitle:@"OK" otherButtonTitles:nil];
                    [alert show]; [alert release];
                    sw.on = NO;
                }
            } else {
                [[AppDelegate shared] stopGatewayServer];
            }
            [_prefs setObject:@(sw.on) forKey:@"gatewayServerEnabled"];
            [self.tableView reloadData];
            break;
        }
    }
    [self _savePrefs];
}

@end
