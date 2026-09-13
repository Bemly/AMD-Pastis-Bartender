#import <Foundation/Foundation.h>

/// 设置模型: NSUserDefaults 持久化,首次启动自动探测填写默认值。
@interface AMDConfig : NSObject

@property (copy) NSString *adbPath;    // adb 可执行文件绝对路径
@property (copy) NSString *adbHost;    // adb server host,空=标准
@property (copy) NSString *adbPort;    // adb server port,空=标准5037
@property (copy) NSString *serial;     // 设备序列号,空=自动探测
@property (copy) NSString *tcpPort;    // 起始端口对,默认17001
@property (copy) NSString *lanIp;      // 手机局域网IP,空=自动探测
@property (copy) NSString *scriptDir;  // download_tcp.py 所在目录
@property (copy) NSString *outDir;     // 下载输出目录
@property (assign) BOOL useTcp;        // 默认YES
// 成品组装方式:mac=本机合并(默认,逐碎片解密回拼) phone=手机官方解码器直出
// (整曲在手机端全量解密+组装,Mac 只拉成品;详见 OBDL phoneBuild)
@property (copy) NSString *mergeMode;
// 歌词(⑦页):输出方式 embed=内嵌m4a lrc=外置lrc srt=外置srt;排版 stagger=交错
// isolated=独立 merge=合并;编码 UTF-8/GB18030/UTF-16
@property (copy) NSString *lyricMode;
@property (copy) NSString *lyricEncoding;
@property (copy) NSString *lyricLayout;
@property (copy) NSString *lyricMergeSep;
@property (assign) BOOL lyricUseNE;
@property (assign) BOOL lyricUseQQ;

+ (instancetype)shared;
- (void)load;
- (void)save;
- (void)restoreDefaults;
/// 带 -H/-P 的 adb 基础参数(含 -s,如有 serial)
- (NSArray<NSString *> *)adbBaseArgs;
- (NSString *)resolvedSerial:(NSString *)fallback;
- (NSString *)pythonPath;   // scriptDir/.venv/bin/python,不存在则回退 python3
- (NSString *)downloadScriptPath;

@end
