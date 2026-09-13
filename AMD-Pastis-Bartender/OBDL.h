#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 原生下载引擎(网络路线):adamId → 磁盘元数据配对 → 清单 → 拉整文件 → 批量解密
// (直传双链 8MB/包,失败回退引擎通道 1.5MB/包)→ 重建 → 验证(ffprobe/ffmpeg)→ sidecar。
// 纪律:key 全由手机端自己抓好落盘,我们只读;连接按需短连;直传服务用完即关(tcpStop 先于断连)。
@interface OBDLJob : NSObject

// 日志行(worker 线程回调;GUI 侧自行转主队列)
@property (copy) void (^logf)(NSString *line);
// 状态行(下载中/空闲)
@property (copy) void (^statusf)(NSString *line);
// 置 YES 后在碎片间与网络间隙退出(结果带 cancelled)
@property (nonatomic, assign) BOOL cancelled;   // 引擎在碎片间/网络间隙轮询

// 单曲下载(网络路线)。返回 sidecar 字典(含 verify);失败 nil 带 err。
+ (nullable NSDictionary *)runAdam:(NSString *)adam
                            outDir:(NSString *)dir
                             force:(BOOL)force
                              logf:(void (^)(NSString *))logf
                            cancel:(volatile BOOL *)cancelFlag
                             error:(NSString * _Nullable * _Nullable)err;

// 缓存直解(手机 no_backup 里的成品 fMP4 + 自带 key;key 先探针,失效即报可重试)。
// key 全由 App 原生路径抓取,零网络 key 请求。
+ (nullable NSDictionary *)runFromCache:(NSString *)adam
                                 outDir:(NSString *)dir
                                  force:(BOOL)force
                                   logf:(void (^)(NSString *))logf
                                 cancel:(volatile BOOL *)cancelFlag
                                  error:(NSString * _Nullable * _Nullable)err;

// 环境自检(原生):forward → 连接 → 装脚本 → refresh/echo。返回可读结果行数组。
// 配置开直传时追加双链自检(回环 + 引擎通道/直传解密对拍)。
+ (NSArray<NSString *> *)selfTest;

// 跟随收割 v2(等价参考脚本 --follow-cache 的内存轮询形态):
//   启动先存量收割(磁盘 key 批量探针,有效的逐首缓存直解);之后循环三路抓新鲜 key——
//   App 内存批量 sweep(getexistingmany 纯读)+ 当前播放曲 + 磁盘重读(内容比对,非 mtime),
//   命中即缓存直解。失败进 _failed.json 隔离(key 过期=可重试,不隔离);autoNext=收割成功后切下一首
//   (发媒体键前必查前台包名)。断点续传:输出已存在/sidecar 绿即跳过。cancel 置 YES 后在间隙退出。
+ (void)followCache:(NSString *)dir
           interval:(NSTimeInterval)secs
           autoNext:(BOOL)autoNext
               logf:(void (^)(NSString *))logf
            statusf:(void (^)(NSString *))statusf
             cancel:(volatile BOOL *)cancelFlag;

// 一键安装手机端引擎服务(在线下载,不打包本体):
//   已存在则跳过下载 → 拉 .xz → 本机解压 → push → chmod → 杀旧重启 → 引擎自检验证。
// 返回可读日志行(GUI 逐行上屏)。
+ (NSArray<NSString *> *)installEngineService;

// 取消:对在跑的手机直出组装(mpbuild)发中止旗标,碎片间隙退出;未在跑时空转无害
+ (void)abortPhoneBuild;

@end

NS_ASSUME_NONNULL_END
