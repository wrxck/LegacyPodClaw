/*
 * OCAgent.m
 * LegacyPodClaw - Lightweight Local Agent Runtime Implementation
 *
 * Inspired by PicoClaw: single-process, <10MB memory footprint.
 * Model calls go through OCProviderClient; every tool call goes through the dispatcher.
 */

#import "Agent.h"
#import "HTTPFetch.h"
#import "ToolDispatcher.h"
#import "ToolInputCheck.h"
#import "ProviderRegistry.h"
#import <UIKit/UIKit.h>

static const NSUInteger kDefaultMaxContext  = 4096;
static const NSUInteger kDefaultMaxResponse = 1024;

#pragma mark - OCModelConfig

@implementation OCModelConfig

- (instancetype)init {
    if ((self = [super init])) {
        _providerId = [@"anthropic" copy];
        _maxTokens = kDefaultMaxResponse;
        _contextWindow = kDefaultMaxContext;
    }
    return self;
}

- (void)dealloc {
    [_providerId release]; [_modelId release]; [_apiKey release]; [_baseURL release];
    [super dealloc];
}

@end

#pragma mark - OCToolDefinition

@implementation OCToolDefinition

- (instancetype)init {
    if ((self = [super init])) {
        _timeout = 30.0;
    }
    return self;
}

- (void)dealloc {
    [_name release]; [_toolDescription release];
    [_inputSchema release]; [_handler release]; [_prepare release];
    [super dealloc];
}

@end

#pragma mark - OCAgentMessage

@implementation OCAgentMessage

+ (OCAgentMessage *)messageWithRole:(OCAgentMessageRole)role content:(NSString *)content {
    OCAgentMessage *m = [[[OCAgentMessage alloc] init] autorelease];
    m.role = role;
    m.content = content;
    return m;
}

- (void)dealloc {
    [_content release]; [_toolName release]; [_toolCallId release];
    [_toolInput release]; [_toolResult release]; [_toolCalls release]; [_rawContent release];
    [super dealloc];
}

- (NSUInteger)estimatedTokens {
    if (_estimatedTokens > 0) return _estimatedTokens;
    NSUInteger n = [OCAgent estimateTokens:_content];
    for (OCProviderToolCall *c in _toolCalls) n += 16 + [[c.input description] length] / 4;
    return n;
}

@end

#pragma mark - OCMCPClient

@interface OCMCPClient () {
    NSMutableArray *_tools;
}
@end

@implementation OCMCPClient

@synthesize availableTools = _tools;

- (instancetype)initWithURL:(NSString *)url name:(NSString *)name {
    if ((self = [super init])) {
        _serverURL = [url copy];
        _serverName = [name copy];
        _tools = [[NSMutableArray alloc] init];
    }
    return self;
}

- (void)dealloc {
    [_serverURL release]; [_serverName release]; [_tools release];
    [super dealloc];
}

/* json-rpc over http or https; the reply's error member becomes an NSError */
- (void)_rpc:(NSString *)method params:(NSDictionary *)params rpcId:(NSInteger)rpcId
    completion:(void(^)(NSDictionary *result, NSError *error))completion {
    NSDictionary *body = @{@"jsonrpc": @"2.0", @"method": method, @"params": params ?: @{}, @"id": @(rpcId)};
    void (^done)(NSDictionary *, NSError *) = [[completion copy] autorelease];
    CPFetchJSON(_serverURL, nil, body, 30, ^(id json, NSInteger status, NSError *error) {
        if (error) { done(nil, error); return; }
        NSDictionary *rpcError = [json isKindOfClass:[NSDictionary class]] ? [json objectForKey:@"error"] : nil;
        if ([rpcError isKindOfClass:[NSDictionary class]]) {
            NSString *message = [[rpcError objectForKey:@"message"] description] ?: @"MCP error";
            done(nil, [NSError errorWithDomain:@"OCMCPClient" code:1 userInfo:@{NSLocalizedDescriptionKey: message}]);
            return;
        }
        id result = [json isKindOfClass:[NSDictionary class]] ? [json objectForKey:@"result"] : nil;
        done([result isKindOfClass:[NSDictionary class]] ? result : @{}, nil);
    });
}

- (void)connect:(void(^)(BOOL, NSError *))callback {
    NSDictionary *params = @{@"protocolVersion": @"2024-11-05", @"capabilities": @{},
                             @"clientInfo": @{@"name": @"LegacyPodClaw", @"version": @"0.4.2"}};
    [self _rpc:@"initialize" params:params rpcId:1 completion:^(NSDictionary *result, NSError *error) {
        if (error) {
            if (callback) callback(NO, error);
            return;
        }
        _isConnected = YES;
        [self listTools:^(NSArray *tools, NSError *err) {
            if (callback) callback(err == nil, err);
        }];
    }];
}

- (void)disconnect {
    _isConnected = NO;
    [_tools removeAllObjects];
}

- (void)callTool:(NSString *)toolName
          params:(NSDictionary *)params
        callback:(OCToolResultBlock)callback {
    [self _rpc:@"tools/call" params:@{@"name": toolName, @"arguments": params ?: @{}} rpcId:2
    completion:^(NSDictionary *result, NSError *error) {
        callback(result, error);
    }];
}

- (void)listTools:(void(^)(NSArray *, NSError *))callback {
    [self _rpc:@"tools/list" params:@{} rpcId:3 completion:^(NSDictionary *result, NSError *error) {
        if (error) { callback(nil, error); return; }
        NSArray *tools = [result objectForKey:@"tools"];
        if (![tools isKindOfClass:[NSArray class]]) tools = @[];
        [_tools removeAllObjects];

        /* the handler must not retain the client, which owns the tool */
        __block OCMCPClient *client = self;
        for (NSDictionary *t in tools) {
            if (![t isKindOfClass:[NSDictionary class]] || ![[t objectForKey:@"name"] isKindOfClass:[NSString class]]) continue;
            OCToolDefinition *tool = [[OCToolDefinition alloc] init];
            tool.name = [t objectForKey:@"name"];
            tool.toolDescription = [t objectForKey:@"description"];
            tool.inputSchema = [t objectForKey:@"inputSchema"];
            /* a remote tool server can do anything, so the user approves each call */
            tool.requiresConfirmation = YES;
            NSString *name = tool.name;
            tool.handler = ^(NSDictionary *params, OCToolResultBlock callback) {
                [client callTool:name params:params callback:callback];
            };
            [_tools addObject:tool];
            [tool release];
        }
        callback(_tools, nil);
    }];
}

@end

#pragma mark - OCAgent

static const NSUInteger kMaxToolRounds = 8;

@interface OCAgent () {
    NSMutableArray *_tools;
    NSMutableArray *_mcpServers;
    NSMutableArray *_contextMessages;
    OCProviderClient *_client;
    NSMutableString *_runText;
    NSUInteger _generation;
    NSUInteger _rounds;
}
@end

@implementation OCAgent

- (instancetype)init {
    if ((self = [super init])) {
        _tools = [[NSMutableArray alloc] initWithCapacity:8];
        _mcpServers = [[NSMutableArray alloc] initWithCapacity:2];
        _contextMessages = [[NSMutableArray alloc] initWithCapacity:32];
        _runText = [[NSMutableString alloc] init];
        _maxContextTokens = kDefaultMaxContext;
        _maxResponseTokens = kDefaultMaxResponse;
        _toolsEnabled = YES;
        _toolCaller = OCToolCallerAgent;
    }
    return self;
}

- (void)dealloc {
    [_client cancel];
    [_tools release]; [_mcpServers release]; [_contextMessages release];
    [_client release]; [_modelConfig release]; [_systemPrompt release]; [_runText release];
    [super dealloc];
}

- (void)setModelConfig:(OCModelConfig *)config {
    if (config == _modelConfig) return;
    [_modelConfig release];
    _modelConfig = [config retain];
    /* the next round builds a client for the new provider; a reply in flight still finishes on the old one */
    [_client release]; _client = nil;
}

#pragma mark - Tool Management

- (void)registerTool:(OCToolDefinition *)tool {
    if (!tool.name || [OCToolDispatcher toolNamed:tool.name inTools:_tools]) return;
    [_tools addObject:tool];
}

- (void)removeTool:(NSString *)toolName {
    for (NSUInteger i = 0; i < [_tools count]; i++) {
        OCToolDefinition *t = [_tools objectAtIndex:i];
        if ([t.name isEqualToString:toolName]) {
            [_tools removeObjectAtIndex:i];
            return;
        }
    }
}

- (NSArray *)registeredTools {
    return [[_tools copy] autorelease];
}

- (NSArray *)availableTools {
    NSMutableArray *all = [NSMutableArray arrayWithArray:_tools];
    for (OCMCPClient *mcp in _mcpServers) {
        for (OCToolDefinition *t in mcp.availableTools) {
            if (![OCToolDispatcher toolNamed:t.name inTools:all]) [all addObject:t];
        }
    }
    return all;
}

- (void)addMCPServer:(OCMCPClient *)server {
    [_mcpServers addObject:server];
}

- (void)removeMCPServer:(NSString *)serverName {
    for (NSUInteger i = 0; i < [_mcpServers count]; i++) {
        OCMCPClient *s = [_mcpServers objectAtIndex:i];
        if ([s.serverName isEqualToString:serverName]) {
            [_mcpServers removeObjectAtIndex:i];
            return;
        }
    }
}

#pragma mark - Agent Loop

- (void)processMessage:(NSString *)userMessage {
    if (_isProcessing || [userMessage length] == 0) return;
    _isProcessing = YES;
    _generation++;
    _rounds = 0;
    [_runText setString:@""];

    [_contextMessages addObject:[OCAgentMessage messageWithRole:OCAgentRoleUser content:userMessage]];
    [self compactContext];
    [self _runAgentLoop];
}

- (OCProviderClient *)_providerClient {
    if (_client) return _client;
    OCProviderInfo *info = [OCProviderInfo providerWithId:_modelConfig.providerId]
                        ?: [OCProviderInfo providerWithId:[OCProviderInfo defaultProviderId]];
    _client = [[OCProviderClient alloc] initWithInfo:info apiKey:_modelConfig.apiKey baseURL:_modelConfig.baseURL];
    return _client;
}

- (NSArray *)_conversation {
    NSMutableArray *msgs = [NSMutableArray arrayWithCapacity:[_contextMessages count]];
    for (OCAgentMessage *m in _contextMessages) if (m.role != OCAgentRoleSystem) [msgs addObject:m];
    return msgs;
}

- (NSString *)_systemText {
    NSMutableString *sys = [NSMutableString stringWithString:_systemPrompt ?: @""];
    for (OCAgentMessage *m in _contextMessages) {
        if (m.role == OCAgentRoleSystem && [m.content length]) [sys appendFormat:@"\n\n%@", m.content];
    }
    return sys;
}

- (void)_finishWithText:(NSString *)text {
    _isProcessing = NO;
    [_delegate agent:self didProduceText:text ?: @"" isFinal:YES];
}

- (void)_runAgentLoop {
    if (!_isProcessing) return;
    NSUInteger gen = _generation;
    OCProviderClient *client = [self _providerClient];
    NSUInteger maxTokens = _modelConfig.maxTokens ?: _maxResponseTokens;

    [client streamWithModel:_modelConfig.modelId
                     system:[self _systemText]
                   messages:[self _conversation]
                      tools:_toolsEnabled ? [self availableTools] : nil
                  maxTokens:maxTokens
                     onText:^(NSString *delta) {
        if (gen == _generation) [_delegate agent:self didProduceText:delta isFinal:NO];
    }
                 completion:^(OCProviderResult *result, NSError *error) {
        if (gen != _generation) return;
        if (error) {
            _isProcessing = NO;
            [_delegate agent:self didFailWithError:error];
            return;
        }
        if ([_delegate respondsToSelector:@selector(agent:tokenUsage:output:)])
            [_delegate agent:self tokenUsage:result.inputTokens output:result.outputTokens];

        if ([result.text length] || [result.toolCalls count]) {
            OCAgentMessage *assistant = [OCAgentMessage messageWithRole:OCAgentRoleAssistant content:result.text];
            assistant.toolCalls = result.toolCalls;
            if (client.info.format == OCProviderFormatAnthropic) assistant.rawContent = result.rawContent;
            [_contextMessages addObject:assistant];
        }
        if ([result.text length]) {
            if ([_runText length]) [_runText appendString:@"\n\n"];
            [_runText appendString:result.text];
        }

        NSString *stop = result.stopReason;
        BOOL cutOff = [stop isEqualToString:@"max_tokens"] || [stop isEqualToString:@"length"];
        if ([result.toolCalls count] && !cutOff && _rounds < kMaxToolRounds) {
            _rounds++;
            [self _executeToolCalls:result.toolCalls index:0 generation:gen];
            return;
        }
        if ([result.toolCalls count]) {
            /* every tool call needs a result before the next user turn, or the provider rejects the history */
            for (OCProviderToolCall *call in result.toolCalls)
                [self _addToolResult:@"Not run: the turn ended first." isError:YES call:call];
            [_runText appendString:cutOff ? @"\n\n[The reply hit the token limit before its tool calls could run.]"
                                          : @"\n\n[Stopped after too many tool rounds.]"];
        }
        if ([stop isEqualToString:@"refusal"] && [_runText length] == 0)
            [_runText setString:@"The model declined this request."];
        [self _finishWithText:[[_runText copy] autorelease]];
    }];
}

/* runs calls one at a time, so two confirmation dialogs never stack */
- (void)_executeToolCalls:(NSArray *)calls index:(NSUInteger)index generation:(NSUInteger)gen {
    if (gen != _generation) return;
    if (index >= [calls count]) { [self _runAgentLoop]; return; }

    OCProviderToolCall *call = [calls objectAtIndex:index];
    void (^next)(void) = ^{ [self _executeToolCalls:calls index:index + 1 generation:gen]; };

    if (!call.input) {
        [self _addToolResult:@"Error: the tool arguments were not a valid JSON object." isError:YES call:call];
        next();
        return;
    }
    OCToolDefinition *tool = [OCToolDispatcher toolNamed:call.name inTools:[self availableTools]];
    if (!tool) {
        [self _addToolResult:[NSString stringWithFormat:@"Error: no tool named %@.", call.name] isError:YES call:call];
        next();
        return;
    }
    if ([_delegate respondsToSelector:@selector(agent:willInvokeTool:withParams:)])
        [_delegate agent:self willInvokeTool:call.name withParams:call.input];

    [[OCToolDispatcher shared] runTool:tool input:call.input caller:_toolCaller
                            completion:^(NSString *result, NSError *error) {
        if (gen != _generation) return;
        NSString *text = error ? [NSString stringWithFormat:@"Error: %@", [error localizedDescription]] : result;
        [self _addToolResult:text isError:error != nil call:call];
        if ([_delegate respondsToSelector:@selector(agent:didInvokeTool:result:)])
            [_delegate agent:self didInvokeTool:call.name result:text];
        next();
    }];
}

- (void)_addToolResult:(NSString *)text isError:(BOOL)isError call:(OCProviderToolCall *)call {
    OCAgentMessage *msg = [OCAgentMessage messageWithRole:OCAgentRoleTool content:text ?: @""];
    msg.toolCallId = call.callId;
    msg.toolName = call.name;
    msg.isError = isError;
    [_contextMessages addObject:msg];
}

- (void)abort {
    _generation++;
    [_client cancel];
    _isProcessing = NO;
}

#pragma mark - Context Management

- (void)clearContext {
    [_contextMessages removeAllObjects];
    _currentContextTokens = 0;
}

- (void)loadHistory:(NSArray *)messages {
    [_contextMessages removeAllObjects];
    for (id m in messages) if ([m isKindOfClass:[OCAgentMessage class]]) [_contextMessages addObject:m];
    [self compactContext];
}

- (void)addSystemMessage:(NSString *)message {
    [_contextMessages insertObject:[OCAgentMessage messageWithRole:OCAgentRoleSystem content:message] atIndex:0];
}

- (NSArray *)contextMessages {
    return [[_contextMessages copy] autorelease];
}

- (NSUInteger)_firstTurnIndex {
    NSUInteger i = 0;
    while (i < [_contextMessages count] && [(OCAgentMessage *)[_contextMessages objectAtIndex:i] role] == OCAgentRoleSystem) i++;
    return i;
}

- (void)compactContext {
    NSUInteger total = 0;
    for (OCAgentMessage *msg in _contextMessages) total += [msg estimatedTokens];
    _currentContextTokens = total;

    NSUInteger budget = _maxContextTokens ?: kDefaultMaxContext;
    BOOL trimmed = NO;
    while (_currentContextTokens > budget) {
        NSUInteger i = [self _firstTurnIndex];
        /* always keep the newest message, the turn being answered */
        if (i + 1 >= [_contextMessages count]) break;
        _currentContextTokens -= MIN(_currentContextTokens, [(OCAgentMessage *)[_contextMessages objectAtIndex:i] estimatedTokens]);
        [_contextMessages removeObjectAtIndex:i];
        trimmed = YES;
    }
    if (!trimmed) return;
    /* the history must open on a user turn, never on an orphaned tool result or reply */
    while (YES) {
        NSUInteger i = [self _firstTurnIndex];
        if (i + 1 >= [_contextMessages count]) break;
        OCAgentMessage *first = [_contextMessages objectAtIndex:i];
        if (first.role == OCAgentRoleUser) break;
        _currentContextTokens -= MIN(_currentContextTokens, [first estimatedTokens]);
        [_contextMessages removeObjectAtIndex:i];
    }
}

#pragma mark - Token Estimation

+ (NSUInteger)estimateTokens:(NSString *)text {
    if (!text) return 0;
    /* Rough estimate: ~4 characters per token for English */
    return ([text length] + 3) / 4;
}

@end

#pragma mark - OCBuiltinTools

@implementation OCBuiltinTools

+ (NSArray *)deviceTools {
    return @[
        [self dateTimeTool],
        [self deviceInfoTool],
        [self clipboardTool],
        [self httpFetchTool],
        [self mathTool],
        [self timerTool],
        [self fileReadTool]
    ];
}

+ (OCToolDefinition *)dateTimeTool {
    OCToolDefinition *tool = [[[OCToolDefinition alloc] init] autorelease];
    tool.name = @"get_datetime";
    tool.toolDescription = @"Get the current date and time";
    tool.inputSchema = @{@"type": @"object", @"properties": @{}};
    tool.handler = ^(NSDictionary *params, OCToolResultBlock callback) {
        NSDateFormatter *fmt = [[[NSDateFormatter alloc] init] autorelease];
        [fmt setDateFormat:@"yyyy-MM-dd HH:mm:ss Z"];
        callback([fmt stringFromDate:[NSDate date]], nil);
    };
    return tool;
}

+ (OCToolDefinition *)deviceInfoTool {
    OCToolDefinition *tool = [[[OCToolDefinition alloc] init] autorelease];
    tool.name = @"device_info";
    tool.toolDescription = @"Get device information (model, OS, memory)";
    tool.inputSchema = @{@"type": @"object", @"properties": @{}};
    tool.handler = ^(NSDictionary *params, OCToolResultBlock callback) {
        OCMemoryMonitor *mon = [OCMemoryMonitor sharedMonitor];
        [mon checkNow];
        NSDictionary *info = @{
            @"device": [[UIDevice currentDevice] model],
            @"systemName": [[UIDevice currentDevice] systemName],
            @"systemVersion": [[UIDevice currentDevice] systemVersion],
            @"name": [[UIDevice currentDevice] name],
            @"freeMemoryMB": @(mon.freeMemoryBytes / (1024 * 1024)),
            @"appMemoryMB": @(mon.appMemoryBytes / (1024 * 1024))
        };
        callback(info, nil);
    };
    return tool;
}

+ (OCToolDefinition *)clipboardTool {
    OCToolDefinition *tool = [[[OCToolDefinition alloc] init] autorelease];
    tool.name = @"clipboard";
    tool.toolDescription = @"Read or write the device clipboard";
    tool.inputSchema = @{
        @"type": @"object",
        @"properties": @{
            @"action": @{@"type": @"string", @"enum": @[@"read", @"write"]},
            @"text": @{@"type": @"string"}
        },
        @"required": @[@"action"]
    };
    tool.handler = ^(NSDictionary *params, OCToolResultBlock callback) {
        NSString *action = [params objectForKey:@"action"];
        if ([action isEqualToString:@"read"]) {
            NSString *text = [[UIPasteboard generalPasteboard] string] ?: @"";
            callback(text, nil);
        } else if ([action isEqualToString:@"write"]) {
            [[UIPasteboard generalPasteboard] setString:[params objectForKey:@"text"] ?: @""];
            callback(@"Copied to clipboard", nil);
        } else {
            callback(nil, [NSError errorWithDomain:@"OCAgent" code:1
                userInfo:@{NSLocalizedDescriptionKey: @"action must be read or write"}]);
        }
    };
    return tool;
}

+ (OCToolDefinition *)httpFetchTool {
    OCToolDefinition *tool = [[[OCToolDefinition alloc] init] autorelease];
    tool.name = @"http_fetch";
    tool.toolDescription = @"Fetch content from a URL via HTTP GET";
    tool.inputSchema = @{
        @"type": @"object",
        @"properties": @{
            @"url": @{@"type": @"string"}
        },
        @"required": @[@"url"]
    };
    tool.timeout = 30.0;
    tool.handler = ^(NSDictionary *params, OCToolResultBlock callback) {
        NSString *urlStr = [params objectForKey:@"url"];
        CPFetch(urlStr, @"GET", nil, nil, 30, ^(NSData *data, NSInteger status, NSError *err) {
            if (err) { callback(nil, err); return; }

            /* limit the reply to 32KB to conserve memory */
            NSUInteger maxLen = 32768;
            NSData *truncated = [data length] > maxLen ? [data subdataWithRange:NSMakeRange(0, maxLen)] : data;
            NSString *text = [[NSString alloc] initWithData:truncated encoding:NSUTF8StringEncoding];
            callback([NSString stringWithFormat:@"HTTP %ld\n%@", (long)status, text ?: @"[Binary data]"], nil);
            [text release];
        });
    };
    return tool;
}

+ (OCToolDefinition *)fileReadTool {
    OCToolDefinition *tool = [[[OCToolDefinition alloc] init] autorelease];
    tool.name = @"read_file";
    tool.toolDescription = @"Read a text file from the device filesystem";
    tool.inputSchema = @{
        @"type": @"object",
        @"properties": @{
            @"path": @{@"type": @"string"}
        },
        @"required": @[@"path"]
    };
    tool.handler = ^(NSDictionary *params, OCToolResultBlock callback) {
        NSString *path = [params objectForKey:@"path"];
        /* read only the first 32 kb, so a large file cannot use up the 80 mb app budget */
        NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
        if (!fh) {
            /* the file handle gives no reason, so name the common ones */
            BOOL isDir = NO;
            BOOL exists = [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir];
            NSString *why = !exists ? @"No such file or folder" : isDir ? @"Is a folder, not a file" : @"Cannot open (permission denied?)";
            callback(nil, [NSError errorWithDomain:@"OCAgent" code:1
                userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", why, path]}]);
            return;
        }
        NSData *data = [fh readDataOfLength:32768];
        BOOL more = [[fh readDataOfLength:1] length] > 0;
        [fh closeFile];
        NSUInteger len = OCUtf8SafeLength([data bytes], [data length]);
        NSString *content = [[[NSString alloc] initWithBytes:[data bytes] length:len
                                                    encoding:NSUTF8StringEncoding] autorelease];
        if (!content) { callback(@"[binary file, not shown]", nil); return; }
        callback(more ? [content stringByAppendingString:@"\n[file cut at 32 KB]"] : content, nil);
    };
    return tool;
}

+ (OCToolDefinition *)mathTool {
    OCToolDefinition *tool = [[[OCToolDefinition alloc] init] autorelease];
    tool.name = @"calculate";
    tool.toolDescription = @"Evaluate a mathematical expression";
    tool.inputSchema = @{
        @"type": @"object",
        @"properties": @{
            @"expression": @{@"type": @"string"}
        },
        @"required": @[@"expression"]
    };
    tool.handler = ^(NSDictionary *params, OCToolResultBlock callback) {
        NSString *expr = [params objectForKey:@"expression"];
        if (!OCMathExpressionIsSafe(expr)) {
            callback(nil, [NSError errorWithDomain:@"OCAgent" code:1
                userInfo:@{NSLocalizedDescriptionKey: @"use only numbers, + - * / ( ) and spaces"}]);
            return;
        }
        @try {
            NSExpression *mathExpr = [NSExpression expressionWithFormat:expr];
            id result = [mathExpr expressionValueWithObject:nil context:nil];
            callback([result description], nil);
        } @catch (NSException *e) {
            callback([NSString stringWithFormat:@"Error: %@", e.reason], nil);
        }
    };
    return tool;
}

+ (OCToolDefinition *)timerTool {
    OCToolDefinition *tool = [[[OCToolDefinition alloc] init] autorelease];
    tool.name = @"set_timer";
    tool.toolDescription = @"Set a timer that fires after N seconds";
    tool.inputSchema = @{
        @"type": @"object",
        @"properties": @{
            @"seconds": @{@"type": @"number"},
            @"label": @{@"type": @"string"}
        },
        @"required": @[@"seconds"]
    };
    tool.handler = ^(NSDictionary *params, OCToolResultBlock callback) {
        NSTimeInterval seconds = [[params objectForKey:@"seconds"] doubleValue];
        NSString *label = [params objectForKey:@"label"] ?: @"Timer";

        /* Schedule local notification via runtime for iOS 6 compat */
        Class notifClass = NSClassFromString(@"UILocalNotification");
        if (notifClass) {
            id notif = [[[notifClass alloc] init] autorelease];
            [notif setValue:[NSDate dateWithTimeIntervalSinceNow:seconds] forKey:@"fireDate"];
            [notif setValue:[NSString stringWithFormat:@"%@: Time's up!", label] forKey:@"alertBody"];
            [notif setValue:@"UILocalNotificationDefaultSoundName" forKey:@"soundName"];
            [[UIApplication sharedApplication] performSelector:@selector(scheduleLocalNotification:)
                                                    withObject:notif];
        }

        callback([NSString stringWithFormat:@"Timer set for %.0f seconds: %@", seconds, label], nil);
    };
    return tool;
}

@end
