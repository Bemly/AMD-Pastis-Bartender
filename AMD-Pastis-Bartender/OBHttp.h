#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 同步 HTTP(UA 走 OB 池;音视频清单与成品分段都用它;歌词搜索另需 POST)
@interface OBHttp : NSObject
+ (nullable NSData *)get:(NSString *)url
                   header:(NSString *)headerName
                    value:(NSString *)headerValue
                  timeout:(NSTimeInterval)secs
                    error:(NSString * _Nullable * _Nullable)err;
+ (nullable NSData *)get:(NSString *)url error:(NSString * _Nullable * _Nullable)err;
// POST(JSON 体或表单,contentType 如 application/json);header/value 可附 Referer 等
+ (nullable NSData *)post:(NSString *)url
                     body:(NSData *)body
              contentType:(NSString *)contentType
                   header:(NSString * _Nullable)headerName
                    value:(NSString * _Nullable)headerValue
                  timeout:(NSTimeInterval)secs
                    error:(NSString * _Nullable * _Nullable)err;
@end

NS_ASSUME_NONNULL_END
