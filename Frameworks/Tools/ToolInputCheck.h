/*
 * ToolInputCheck.h
 * LegacyPodClaw - pure checks OCToolDispatcher runs before a tool call
 *
 * Foundation only, so the host test target can build them.
 */

#import <Foundation/Foundation.h>

/* a key field longer than this cannot be shown in an alert, so the call is refused */
#define OC_TOOL_KEY_FIELD_MAX 1500

/* other input longer than this shows its start and end and says how much is hidden */
#define OC_TOOL_OTHER_FIELD_SHOWN 900

/* nil when the input fits the json schema's required keys and property types */
NSString *OCToolSchemaProblem(NSDictionary *schema, NSDictionary *input);

/* fields that decide what a call does; the user must see them whole */
NSArray *OCToolApprovalFields(void);

/* spaces, tabs, line breaks and control characters made visible */
NSString *OCToolVisibleText(NSString *value);

/* the approval fields as alert text; sets *tooLong and returns nil when one cannot be shown */
NSString *OCToolApprovalText(NSDictionary *input, BOOL *tooLong);

/* every other input field as alert text, made visible and cut with a note when long */
NSString *OCToolOtherInputText(NSDictionary *rest);

/* the whole approval alert text: intro, key fields, other input and reason, with no empty line inside the input */
NSString *OCToolApprovalMessage(NSString *intro, NSString *keyText, NSString *otherText, NSString *reason);

/* yes when the calculate tool may give the text to nsexpression */
BOOL OCMathExpressionIsSafe(NSString *expression);

/* the largest length <= length that does not end inside a utf-8 sequence */
NSUInteger OCUtf8SafeLength(const uint8_t *bytes, NSUInteger length);

/* a file error with a plain message, because ios 6 shows only "Cocoa error 260" for a missing path */
NSError *OCFileError(NSError *error, NSString *path);
