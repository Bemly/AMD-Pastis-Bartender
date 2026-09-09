#import "OBHttp.h"
#import "OBStrings.h"

@implementation OBHttp

+ (nullable NSData *)get:(NSString *)url error:(NSString * _Nullable * _Nullable)err {
    return [self get:url header:@"User-Agent" value:OB_UA timeout:120 error:err];
}

+ (nullable NSData *)get:(NSString *)url
                  header:(NSString *)headerName
                   value:(NSString *)headerValue
                 timeout:(NSTimeInterval)secs
                   error:(NSString * _Nullable * _Nullable)err {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:secs];
    if (headerName.length) [req setValue:headerValue forHTTPHeaderField:headerName];
    __block NSData *data = nil;
    __block NSInteger status = 0;
    __block NSString *fail = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                     completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        data = d;
        status = [(NSHTTPURLResponse *)r statusCode];
        fail = e.localizedDescription;
        dispatch_semaphore_signal(sem);
    }] resume];
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((secs + 10) * NSEC_PER_SEC))) != 0) {
        if (err) *err = @"请求超时";
        return nil;
    }
    if (fail.length) { if (err) *err = fail; return nil; }
    if (status >= 400) { if (err) *err = [NSString stringWithFormat:@"HTTP %ld", (long)status]; return nil; }
    return data;
}

+ (nullable NSData *)post:(NSString *)url
                     body:(NSData *)body
              contentType:(NSString *)contentType
                   header:(NSString *)headerName
                    value:(NSString *)headerValue
                  timeout:(NSTimeInterval)secs
                    error:(NSString * _Nullable * _Nullable)err {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:secs];
    req.HTTPMethod = @"POST";
    if (contentType.length) [req setValue:contentType forHTTPHeaderField:@"Content-Type"];
    if (headerName.length) [req setValue:headerValue forHTTPHeaderField:headerName];
    req.HTTPBody = body;
    __block NSData *data = nil;
    __block NSInteger status = 0;
    __block NSString *fail = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                     completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        data = d;
        status = [(NSHTTPURLResponse *)r statusCode];
        fail = e.localizedDescription;
        dispatch_semaphore_signal(sem);
    }] resume];
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((secs + 10) * NSEC_PER_SEC))) != 0) {
        if (err) *err = @"请求超时";
        return nil;
    }
    if (fail.length) { if (err) *err = fail; return nil; }
    if (status >= 400) { if (err) *err = [NSString stringWithFormat:@"HTTP %ld", (long)status]; return nil; }
    return data;
}

@end
