#import <Foundation/Foundation.h>

typedef void (^TaskOutputBlock)(NSString *text);
typedef void (^TaskEndBlock)(int status);

/// NSTask 异步封装:输出合并 stdout+stderr,回调回主线程。
@interface TaskRunner : NSObject

- (instancetype)initWithLaunchPath:(NSString *)path
                         arguments:(NSArray<NSString *> *)args
                               cwd:(NSString *)cwd
                               env:(NSDictionary<NSString *, NSString *> *)extraEnv;
@property (copy) TaskOutputBlock onOutput;
@property (copy) TaskEndBlock onEnd;
- (void)launch;
- (void)terminate;
- (BOOL)isRunning;

/// 同步跑一次,返回输出(供短命令用,后台线程调用)
+ (NSString *)runSync:(NSString *)path
            arguments:(NSArray<NSString *> *)args
                  cwd:(NSString *)cwd
                  env:(NSDictionary<NSString *, NSString *> *)extraEnv
               status:(int *)status;

@end
