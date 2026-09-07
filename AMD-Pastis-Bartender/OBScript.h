#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 注入 agent 源码池(整体 Base64;见 .m 注释)
@interface OBScript : NSObject
+ (NSString *)agentSource;
@end

NS_ASSUME_NONNULL_END
