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
