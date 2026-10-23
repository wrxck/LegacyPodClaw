/*
 * ToolInputCheck.m
 * LegacyPodClaw - pure checks OCToolDispatcher runs before a tool call
 */

#import "ToolInputCheck.h"
#import <errno.h>

static BOOL ValueMatchesType(id value, NSString *type) {
    if (!type) return YES;
    if ([type isEqualToString:@"string"]) return [value isKindOfClass:[NSString class]];
    if ([type isEqualToString:@"object"]) return [value isKindOfClass:[NSDictionary class]];
    if ([type isEqualToString:@"array"]) return [value isKindOfClass:[NSArray class]];
    if ([type isEqualToString:@"number"] || [type isEqualToString:@"integer"] || [type isEqualToString:@"boolean"])
        return [value isKindOfClass:[NSNumber class]];
    return YES;
}

NSString *OCToolSchemaProblem(NSDictionary *schema, NSDictionary *input) {
    if (![schema isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *props = [schema objectForKey:@"properties"];
    for (NSString *key in [schema objectForKey:@"required"]) {
        id value = [input objectForKey:key];
        if (!value || value == [NSNull null]) return [NSString stringWithFormat:@"missing required parameter '%@'", key];
    }
    for (NSString *key in input) {
        NSString *type = [[props objectForKey:key] objectForKey:@"type"];
        if (![type isKindOfClass:[NSString class]]) continue;
        if (!ValueMatchesType([input objectForKey:key], type))
            return [NSString stringWithFormat:@"parameter '%@' must be of type %@", key, type];
    }
    return nil;
}

/* fields that decide what a call does; the user must see them whole */
NSArray *OCToolApprovalFields(void) {
    return @[@"command", @"path", @"url", @"to", @"recipient", @"bundle_id", @"query"];
}

/* bidi overrides, zero-width marks and c1 controls change how text looks without changing what runs */
static BOOL IsHiddenFormatChar(unichar c) {
    return (c >= 0x80 && c <= 0x9f) || (c >= 0x200b && c <= 0x200f) || (c >= 0x202a && c <= 0x202e)
        || (c >= 0x2066 && c <= 0x2069) || c == 0x2028 || c == 0x2029 || c == 0xfeff;
}

/* make spaces, tabs and line breaks visible, so padding cannot hide the rest of a command */
NSString *OCToolVisibleText(NSString *value) {
    NSMutableString *out = [NSMutableString stringWithCapacity:[value length]];
    NSUInteger spaces = 0;
    for (NSUInteger i = 0; i < [value length]; i++) {
        unichar c = [value characterAtIndex:i];
        if (c == ' ') { spaces++; continue; }
        if (spaces > 1) [out appendFormat:@"[%lu spaces]", (unsigned long)spaces];
        else if (spaces == 1) [out appendString:@" "];
        spaces = 0;
        if (c == '\n') [out appendString:@"⏎\n"];
        else if (c == '\t') [out appendString:@"[tab]"];
        else if (c < 0x20 || c == 0x7f) [out appendFormat:@"[0x%02x]", c];
        else if (IsHiddenFormatChar(c)) [out appendFormat:@"[U+%04X]", c];
        else [out appendFormat:@"%C", c];
    }
    if (spaces > 1) [out appendFormat:@"[%lu spaces]", (unsigned long)spaces];
    else if (spaces == 1) [out appendString:@"[space]"];
    return out;
}

NSString *OCToolApprovalText(NSDictionary *input, BOOL *tooLong) {
    NSMutableString *text = [NSMutableString string];
    for (NSString *key in OCToolApprovalFields()) {
        id value = [input objectForKey:key];
        if (!value) continue;
        NSString *str = [value isKindOfClass:[NSString class]] ? value : [value description];
        if ([str length] > OC_TOOL_KEY_FIELD_MAX) { *tooLong = YES; return nil; }
        [text appendFormat:@"%@: %@\n", key, OCToolVisibleText(str)];
    }
    return text;
}

NSString *OCToolOtherInputText(NSDictionary *rest) {
    NSMutableString *text = [NSMutableString string];
    for (NSString *key in [[rest allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        id value = [rest objectForKey:key];
        NSString *str = nil;
        if ([value isKindOfClass:[NSString class]]) {
            str = value;
        } else if ([NSJSONSerialization isValidJSONObject:value]) {
            NSData *json = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
            if (json) str = [[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] autorelease];
        }
        if (!str) str = [value description];
        NSString *visible = OCToolVisibleText(str);
        NSUInteger length = [visible length];
        if (length > OC_TOOL_OTHER_FIELD_SHOWN) {
            /* say how much is hidden, so the user knows the alert does not show it all */
            NSUInteger head = [visible rangeOfComposedCharacterSequenceAtIndex:OC_TOOL_OTHER_FIELD_SHOWN * 2 / 3].location;
            NSUInteger tail = [visible rangeOfComposedCharacterSequenceAtIndex:length - OC_TOOL_OTHER_FIELD_SHOWN / 3].location;
            visible = [NSString stringWithFormat:@"%@\n[%lu characters not shown]\n%@", [visible substringToIndex:head],
                       (unsigned long)(tail - head), [visible substringFromIndex:tail]];
        }
        [text appendFormat:@"%@: %@\n", key, visible];
    }
    return text;
}

NSString *OCToolApprovalMessage(NSString *intro, NSString *keyText, NSString *otherText, NSString *reason) {
    /* each part ends with a line break; trimming it stops a blank line before "Other input:" */
    NSCharacterSet *breaks = [NSCharacterSet newlineCharacterSet];
    NSMutableArray *input = [NSMutableArray array];
    NSString *keys = [keyText stringByTrimmingCharactersInSet:breaks];
    if ([keys length]) [input addObject:keys];
    NSString *other = [otherText stringByTrimmingCharactersInSet:breaks];
    if ([other length]) [input addObject:[@"Other input:\n" stringByAppendingString:other]];
    NSMutableString *message = [NSMutableString stringWithString:intro ?: @""];
    if ([input count]) [message appendFormat:@"\n\n%@", [input componentsJoinedByString:@"\n"]];
    if ([reason length]) [message appendFormat:@"\n\n%@", reason];
    return message;
}

BOOL OCMathExpressionIsSafe(NSString *expression) {
    /* nsexpression runs FUNCTION() and format specifiers, so allow only numbers and arithmetic */
    if ([expression length] == 0 || [expression length] > 500) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789.+-*/() "];
    return [expression rangeOfCharacterFromSet:[allowed invertedSet]].location == NSNotFound;
}

/* cut at a character boundary, so a split multi-byte sequence does not garble the whole output */
NSUInteger OCUtf8SafeLength(const uint8_t *bytes, NSUInteger length) {
    NSUInteger i = length;
    NSUInteger back = 0;
    while (i > 0 && back < 4 && (bytes[i - 1] & 0xC0) == 0x80) { i--; back++; }
    if (i == 0) return length;
    uint8_t lead = bytes[i - 1];
    NSUInteger need = (lead & 0x80) == 0 ? 1 : (lead & 0xE0) == 0xC0 ? 2 : (lead & 0xF0) == 0xE0 ? 3 : (lead & 0xF8) == 0xF0 ? 4 : 1;
    return (back + 1 >= need) ? length : i - 1;
}

NSError *OCFileError(NSError *error, NSString *path) {
    if (!error) return nil;
    NSString *shown = [path length] ? path : @"(no path)";
    NSString *domain = [error domain];
    NSInteger code = [error code];
    BOOL cocoa = [domain isEqualToString:NSCocoaErrorDomain];
    NSError *under = [[error userInfo] objectForKey:NSUnderlyingErrorKey];
    NSInteger errnum = [domain isEqualToString:NSPOSIXErrorDomain] ? code
        : [[under domain] isEqualToString:NSPOSIXErrorDomain] ? [under code] : 0;
    NSString *message;
    if (errnum == ENOTDIR) message = [NSString stringWithFormat:@"Not a folder: %@", shown];
    else if (errnum == EISDIR) message = [NSString stringWithFormat:@"Is a folder, not a file: %@", shown];
    else if (errnum == ENOENT || (cocoa && (code == NSFileNoSuchFileError || code == NSFileReadNoSuchFileError)))
        message = [NSString stringWithFormat:@"No such file or folder: %@", shown];
    else if (errnum == EACCES || errnum == EPERM ||
             (cocoa && (code == NSFileReadNoPermissionError || code == NSFileWriteNoPermissionError)))
        message = [NSString stringWithFormat:@"Permission denied: %@", shown];
    else if (cocoa && code == NSFileReadInapplicableStringEncodingError)
        message = [NSString stringWithFormat:@"Not a UTF-8 text file: %@", shown];
    else if (cocoa && code == NSFileWriteOutOfSpaceError)
        message = [NSString stringWithFormat:@"No space left to write %@", shown];
    else
        message = [NSString stringWithFormat:@"%@ (%@ %ld): %@", [error localizedDescription], domain, (long)code, shown];
    return [NSError errorWithDomain:domain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message, NSUnderlyingErrorKey: error}];
}
