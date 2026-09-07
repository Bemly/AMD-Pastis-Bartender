#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 同步 HTTP GET(UA 走 OB 池;音视频清单与成品分段都用它)
@interface OBHttp : NSObject
+ (nullable NSData *)get:(NSString *)url
                  header:(NSString *)headerName
                   value:(NSString *)headerValue
                 timeout:(NSTimeInterval)secs
                   error:(NSString * _Nullable * _Nullable)err;
+ (nullable NSData *)get:(NSString *)url error:(NSString * _Nullable * _Nullable)err;
@end

NS_ASSUME_NONNULL_END
