/*
 * ToolDispatcher.m
 * LegacyPodClaw - the one path every tool call takes
 */

#import "ToolDispatcher.h"
#import "Guardrails.h"
#import "ToolInputCheck.h"
#import <UIKit/UIKit.h>

#define TOOL_DEFAULT_TIMEOUT 30.0
#define CONFIRM_TIMEOUT 60.0
#define RESULT_MAX_CHARS 16384

static NSString *const OCToolErrorDomain = @"OCToolDispatcher";

static NSError *ToolError(NSString *message) {
    return [NSError errorWithDomain:OCToolErrorDomain code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - Confirmation

@interface _OCToolConfirmation : NSObject <UIAlertViewDelegate> {
    UIAlertView *_alert;
    void (^_decision)(BOOL allowed);
}
- (instancetype)initWithTitle:(NSString *)title message:(NSString *)message decision:(void(^)(BOOL))decision;
- (void)show;
@end

@implementation _OCToolConfirmation

- (instancetype)initWithTitle:(NSString *)title message:(NSString *)message decision:(void(^)(BOOL))decision {
    if ((self = [super init])) {
        _decision = [decision copy];
        _alert = [[UIAlertView alloc] initWithTitle:title message:message delegate:self
                                  cancelButtonTitle:@"Deny" otherButtonTitles:@"Allow", nil];
    }
    return self;
}

- (void)show {
    /* the alert does not retain its delegate, so keep self alive until a decision */
    [self retain];
    [_alert show];
    [self performSelector:@selector(_expire) withObject:nil afterDelay:CONFIRM_TIMEOUT];
}

- (void)_finish:(BOOL)allowed {
    if (!_decision) return;
    void (^decision)(BOOL) = [_decision autorelease];
    _decision = nil;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_expire) object:nil];
    _alert.delegate = nil;
    decision(allowed);
    [self autorelease];
}

- (void)_expire {
    [_alert dismissWithClickedButtonIndex:_alert.cancelButtonIndex animated:YES];
    [self _finish:NO];
}

- (void)alertView:(UIAlertView *)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    [self _finish:buttonIndex != alertView.cancelButtonIndex];
}

- (void)dealloc {
    [_alert release];
    [_decision release];
    [super dealloc];
}

@end

#pragma mark - Dispatcher

@implementation OCToolDispatcher

+ (instancetype)shared {
    static OCToolDispatcher *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}

+ (OCToolDefinition *)toolNamed:(NSString *)name inTools:(NSArray *)tools {
    if (![name isKindOfClass:[NSString class]]) return nil;
    for (OCToolDefinition *t in tools)
        if ([t.name isEqualToString:name]) return t;
    return nil;
}

/* file tools whose path argument the guardrails must see first */
static BOOL PathCheckForTool(NSString *name, OCFileOp *op) {
    static NSDictionary *ops;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ops = [@{@"write_file": @(OCFileOpWrite), @"edit_file": @(OCFileOpEdit),
                 @"delete_file": @(OCFileOpDelete), @"list_files": @(OCFileOpRead),
                 @"read_file": @(OCFileOpRead)} retain];
    });
    NSNumber *n = [ops objectForKey:name];
    if (!n) return NO;
    *op = (OCFileOp)[n unsignedIntegerValue];
    return YES;
}

static NSString *ResultString(id result) {
    NSString *s;
    if (!result || result == [NSNull null]) s = @"";
    else if ([result isKindOfClass:[NSString class]]) s = result;
    else if ([NSJSONSerialization isValidJSONObject:result]) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        s = [[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] autorelease] ?: @"";
    } else s = [result description];
    if ([s length] > RESULT_MAX_CHARS)
        s = [[s substringToIndex:RESULT_MAX_CHARS] stringByAppendingString:@"\n[result truncated]"];
    return s;
}

static NSString *CallerText(OCToolCaller caller) {
    switch (caller) {
        case OCToolCallerRemote: return @"A remote gateway client";
        case OCToolCallerChannel: return @"A chat channel message";
        case OCToolCallerAgent: return @"The background agent";
        default: return @"The assistant";
    }
}

- (void)runTool:(OCToolDefinition *)tool
          input:(id)input
         caller:(OCToolCaller)caller
     completion:(void(^)(NSString *result, NSError *error))completion {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self runTool:tool input:input caller:caller completion:completion];
        });
        return;
    }
    if (!tool || !tool.handler) { completion(nil, ToolError(@"tool not found")); return; }
    if (!input || input == [NSNull null]) input = @{};
    if (![input isKindOfClass:[NSDictionary class]]) {
        completion(nil, ToolError(@"tool input must be a JSON object"));
        return;
    }

    NSString *problem = OCToolSchemaProblem(tool.inputSchema, input);
    if (problem) { completion(nil, ToolError(problem)); return; }

    BOOL confirm = tool.requiresConfirmation || caller == OCToolCallerChannel;
    NSString *reason = nil;
    OCFileOp op;
    if (PathCheckForTool(tool.name, &op)) {
        id path = [input objectForKey:@"path"];
        OCGuardrailVerdict *v = [[OCGuardrails shared] checkPath:[path isKindOfClass:[NSString class]] ? path : nil
                                                    forOperation:op];
        if (v.action == OCGuardrailBlock) { completion(nil, ToolError(v.reason)); return; }
        if (v.action == OCGuardrailConfirm) { confirm = YES; reason = v.reason; }
        /* a remote client could read files and send them out with a web tool, so it always asks */
        if (caller == OCToolCallerRemote) confirm = YES;
    }

    void (^run)(void) = ^{ [self _invoke:tool input:input completion:completion]; };
    if (!confirm) { run(); return; }

    BOOL tooLong = NO;
    NSString *keyText = OCToolApprovalText(input, &tooLong);
    if (tooLong) {
        completion(nil, ToolError(@"a command or path is too long to show for approval, so the call was refused"));
        return;
    }
    NSMutableDictionary *rest = [[input mutableCopy] autorelease];
    [rest removeObjectsForKeys:OCToolApprovalFields()];
    NSString *message = OCToolApprovalMessage([NSString stringWithFormat:@"%@ wants to run \"%@\".", CallerText(caller), tool.name],
                                              keyText, [rest count] ? OCToolOtherInputText(rest) : nil, reason);
    _OCToolConfirmation *c = [[_OCToolConfirmation alloc] initWithTitle:@"Allow Tool?" message:message
        decision:^(BOOL allowed) {
            if (allowed) run();
            else completion(nil, ToolError(@"the user denied this tool call"));
        }];
    [c show];
    [c release];
}

- (void)_invoke:(OCToolDefinition *)tool input:(NSDictionary *)input
     completion:(void(^)(NSString *result, NSError *error))completion {
    if (!tool.prepare) { [self _start:tool input:input completion:completion]; return; }
    /* a buggy prepare must not start the tool twice */
    __block BOOL started = NO;
    void (^done)(NSString *, NSError *) = [[completion copy] autorelease];
    /* copied, so a prepare that keeps the block past this call never holds a stack block */
    void (^ready)(NSError *) = [[^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (started) return;
            started = YES;
            if (error) done(nil, error);
            else [self _start:tool input:input completion:done];
        });
    } copy] autorelease];
    @try {
        tool.prepare(ready);
    } @catch (NSException *e) {
        done(nil, ToolError([NSString stringWithFormat:@"tool raised %@: %@", [e name], [e reason]]));
    }
}

- (void)_start:(OCToolDefinition *)tool input:(NSDictionary *)input
    completion:(void(^)(NSString *result, NSError *error))completion {
    /* the flag lives on the heap so the handler and the timer share it */
    __block BOOL done = NO;
    void (^finish)(NSString *, NSError *) = [[^(NSString *result, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (done) return;
            done = YES;
            completion(result, error);
        });
    } copy] autorelease];

    NSTimeInterval timeout = tool.timeout > 0 ? tool.timeout : TOOL_DEFAULT_TIMEOUT;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        finish(nil, ToolError([NSString stringWithFormat:@"tool timed out after %.0f s; it may still complete", timeout]));
    });

    @try {
        tool.handler(input, ^(id result, NSError *error) {
            if (error) finish(nil, error);
            else finish(ResultString(result), nil);
        });
    } @catch (NSException *e) {
        finish(nil, ToolError([NSString stringWithFormat:@"tool raised %@: %@", [e name], [e reason]]));
    }
}

@end
