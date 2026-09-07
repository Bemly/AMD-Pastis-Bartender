#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// HLS 清单解析(母清单选变体 + 媒体清单分段)。移植自参考脚本,契约逐行对齐:
// 变体优先级 ALAC → ec-3 → 首个;分段 = 单文件 fMP4 + BYTERANGE + 每段 key URI。
@interface OBPlaylist : NSObject

// 母清单选变体。返回 @{ @"url": 媒体清单URL, @"codec": 标签 };无变体返回 nil 带 err
+ (nullable NSDictionary *)pickVariantOfMaster:(NSString *)masterText
                                       baseUrl:(NSString *)baseUrl
                                         error:(NSString * _Nullable * _Nullable)err;

// 媒体清单解析。返回 @{ @"url": 分段文件URL,
//                      @"initLoc": NSValue(NSRange init段), 
//                      @"segments": @[ @{ @"key": keyUri或NSNull, @"loc": NSValue(NSRange) } ] }
+ (nullable NSDictionary *)parseMedia:(NSString *)mediaText
                             mediaUrl:(NSString *)mediaUrl
                                error:(NSString * _Nullable * _Nullable)err;

// key URI 归一化(小写 + 去前缀),配对用
+ (NSString *)normKeyUri:(NSString * _Nullable)u;

@end

NS_ASSUME_NONNULL_END
