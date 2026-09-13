#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// adb 粘合层:路径解析 / 参数组装 / su 读取 / 拉取 / 深链 / 媒体键。
// 纪律:大文件一律 cp→chmod→pull(adb shell 传二进制会坏);su -c 整段命令一个参数。
@interface OBADB : NSObject

// 解析 adb 可执行绝对路径(配置里没有 / 时 which)
+ (NSString *)resolvedAdbPath;

// adb 公共参数(-H/-P/-s);serial 空且唯一设备时自动采用
+ (NSMutableArray<NSString *> *)baseArgs;

// 同步跑一条 adb;返回 stdout;transport 错抛(重试由调用方 retryShell 包)
+ (NSString *)shell:(NSArray<NSString *> *)tail timeout:(NSTimeInterval)secs error:(NSString * _Nullable * _Nullable)err;
+ (NSString *)shellRetry:(NSArray<NSString *> *)tail timeout:(NSTimeInterval)secs error:(NSString * _Nullable * _Nullable)err;

// su 读小文本文件(磁盘元数据);失败/不存在返回 nil
+ (nullable NSString *)suCat:(NSString *)path;

// su cp → /data/local/tmp/dlstage → adb pull(二进制安全);成功返回 YES
+ (BOOL)pull:(NSString *)remotePath to:(NSString *)localPath error:(NSString * _Nullable * _Nullable)err;

// adb push 到手机(对称 pull;多用于 /data/local/tmp 暂存);成功返回 YES
+ (BOOL)push:(NSString *)localPath to:(NSString *)remotePath error:(NSString * _Nullable * _Nullable)err;

+ (void)deeplinkSong:(NSString *)adam;
+ (void)mediaKeyPlay;
+ (void)mediaKeyNext;

// which 一个工具名(brew PATH 补齐,GUI 环境无 shell PATH)
+ (nullable NSString *)which:(NSString *)tool;

@end

NS_ASSUME_NONNULL_END
