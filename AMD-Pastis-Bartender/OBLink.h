#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 注入引擎会话层:连接(设备→进程→attach)→ 装脚本 → RPC(按 id 配对请求/应答)。
// 纪律(docs/03):按需短连接,用完 disconnect,空闲零注入。
// 线程:方法线程安全;RPC 内部用信号量等待;回调在 kit 线程→后台队列。

@interface OBLink : NSObject

+ (instancetype)shared;

// 全链路连接:设备(USB 失败退远程 27042,调用方负责 adb forward)→ 按名找进程 → attach。
// procName = 手机端播放器进程名。成功返回 YES。
- (BOOL)connectToProcess:(NSString *)procName error:(NSString * _Nullable * _Nullable)err;

// 装脚本(可多次调用=替换;旧的先卸)
- (BOOL)loadScriptSource:(NSString *)source error:(NSString * _Nullable * _Nullable)err;

// 通用消息监听(非 RPC 应答的事件流,如脚本主动 send 的进度);在后台队列回调
- (void)onEvent:(void (^)(NSString *json, NSData * _Nullable data))block;

// 同步 RPC:post {"id":N,"op":op,"args":{...}}(args 里的 string 字段直接转 JSON);
// data 非空时作为二进制附件(脚本侧 recv 收 ArrayBuffer)。
// 返回应答 JSON 原文;超时/失败返回 nil 并带 *err。
- (nullable NSString *)rpc:(NSString *)op
                      args:(nullable NSDictionary *)args
                      data:(nullable NSData *)data
                   timeout:(NSTimeInterval)secs
                     error:(NSString * _Nullable * _Nullable)err;

- (void)disconnect;

@property (nonatomic, readonly, getter=isConnected) BOOL connected;
@property (nonatomic, readonly) unsigned pid;

@end

NS_ASSUME_NONNULL_END
