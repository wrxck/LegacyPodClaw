/*
 * HTTPFetch.m
 * LegacyPodClaw - one entry point for http and https requests
 */

#import "HTTPFetch.h"
#import "TLSClient.h"

static NSError *FetchError(NSString *message) {
    return [NSError errorWithDomain:CPTLSErrorDomain code:CPTLSErrorBadRequest
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

void CPFetch(NSString *urlString, NSString *method, NSDictionary *headers, NSData *body,
             NSTimeInterval timeout, CPFetchCompletion completion) {
    CPFetchCompletion done = [[completion copy] autorelease];
    NSURL *url = [urlString isKindOfClass:[NSString class]] ? [NSURL URLWithString:urlString] : nil;
    NSString *scheme = [[url scheme] lowercaseString];

    if ([scheme isEqualToString:@"https"]) {
        [CPTLSClient request:urlString method:method ?: @"GET" headers:headers body:body timeout:timeout
                  completion:^(NSData *data, NSInteger status, NSError *error) { done(data, status, error); }];
        return;
    }
    if (![scheme isEqualToString:@"http"] || ![url host]) {
        NSError *error = FetchError(@"Only http and https URLs are allowed");
        dispatch_async(dispatch_get_main_queue(), ^{ done(nil, 0, error); });
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringCacheData
                                                   timeoutInterval:timeout > 0 ? timeout : 30];
    [req setHTTPMethod:method ?: @"GET"];
    for (NSString *key in headers) [req setValue:[headers objectForKey:key] forHTTPHeaderField:key];
    if (body) [req setHTTPBody:body];
    [NSURLConnection sendAsynchronousRequest:req queue:[NSOperationQueue mainQueue]
                           completionHandler:^(NSURLResponse *resp, NSData *data, NSError *error) {
        NSInteger status = [resp isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)resp statusCode] : 0;
        done(data, status, error);
    }];
}

void CPFetchJSON(NSString *urlString, NSDictionary *headers, id jsonBody, NSTimeInterval timeout,
                 void (^completion)(id json, NSInteger status, NSError *error)) {
    void (^done)(id, NSInteger, NSError *) = [[completion copy] autorelease];
    /* dataWithJSONObject: throws on invalid input instead of returning nil */
    if (![NSJSONSerialization isValidJSONObject:jsonBody]) {
        NSError *error = FetchError(@"Request body is not valid JSON");
        dispatch_async(dispatch_get_main_queue(), ^{ done(nil, 0, error); });
        return;
    }
    NSData *body = [NSJSONSerialization dataWithJSONObject:jsonBody options:0 error:NULL];
    NSMutableDictionary *hdrs = [NSMutableDictionary dictionaryWithDictionary:headers ?: @{}];
    [hdrs setObject:@"application/json" forKey:@"Content-Type"];
    CPFetch(urlString, @"POST", hdrs, body, timeout, ^(NSData *data, NSInteger status, NSError *error) {
        if (error) { done(nil, status, error); return; }
        id json = [data length] ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        done(json, status, json ? nil : FetchError([NSString stringWithFormat:@"Reply is not JSON (HTTP %ld)", (long)status]));
    });
}

void CPFetchRequest(NSURLRequest *request, CPFetchCompletion completion) {
    CPFetch([[request URL] absoluteString], [request HTTPMethod], [request allHTTPHeaderFields],
            [request HTTPBody], [request timeoutInterval], completion);
}
