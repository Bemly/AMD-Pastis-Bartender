#import <Foundation/Foundation.h>

// 运行时常量池:集中存放少量必须与外部约定逐字节一致的字符串。
// 一律 Base64 存放、运行时还原;本文件禁止出现任何明文,新增常量也照此办理。
static inline NSString *OBS(NSString *encoded) {
    NSData *d = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
    return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"";
}

// 手机端目标 App 的包名(am start / force-stop / pidof / 会话解析共用)
#define OB_PHONE_PKG OBS(@"Y29tLmFwcGxlLmFuZHJvaWQubXVzaWM=")

// 手机端播放器进程名(attach 按名找 pid 用)
#define OB_PROC_NAME      OBS(@"QXBwbGUgTXVzaWM=")

// 引擎套件用的零散敏感串:磁盘元数据扩展名 / 深链主机 / 拉流 UA / keyUri 前缀
#define OB_META_EXT       OBS(@"Lm5mbw==")
#define OB_MUSIC_HOST     OBS(@"bXVzaWMuYXBwbGUuY29t")
#define OB_UA             OBS(@"TXVzaWMvNi41LjIgQW5kcm9pZC8xNCBtb2RlbC9NT09ORFJPUE1EUEgwMDEgYnVpbGQvMTU4NiAoZHQ6NjYp")
#define OB_SKD_PREFIX     OBS(@"c2tkOi8vaXR1bmVzLmFwcGxlLmNvbS8=")

// 曲库检索服务主机名(https://<host>/search)
#define OB_STORE_HOST OBS(@"aXR1bmVzLmFwcGxlLmNvbQ==")

// attach 引擎相关(标签/进程名/脚本参数/存储键)
#define OB_AGENT_TAG      OBS(@"ZnJpZGE=")
#define OB_AGENT_SRV      OBS(@"ZnJpZGEtc2VydmVy")
#define OB_AGENT_SRV16    OBS(@"ZnJpZGEtc2VydmVyMTY=")
#define OB_AGENT_FLAG     OBS(@"LS1mcmlkYQ==")
#define OB_PREF_AGENT     OBS(@"ZnJpZGE=")

// 引擎服务安装包直链(双架构取 arm64;版本锁 16.7.19 与手机端服务/套件三方一致)
#define OB_KIT_URL        OBS(@"aHR0cHM6Ly9naXRodWIuY29tL2ZyaWRhL2ZyaWRhL3JlbGVhc2VzL2Rvd25sb2FkLzE2LjcuMTkvZnJpZGEtc2VydmVyLTE2LjcuMTktYW5kcm9pZC1hcm02NC54eg==")

// 界面/日志文案(不含末尾换行,调用处自行补 \n)
#define OB_UI_TITLE        OBS(@"QXBwbGUgTXVzaWMgRG93bmxvYWRlciDvo78g5LiL5bS95Zmo")
#define OB_UI_LAUNCH_BTN   OBS(@"5ZCv5YqoIEFwcGxlIE11c2lj")
#define OB_UI_LAUNCH_LOG   OBS(@"W+iuvuWkh10g5ZCv5YqoIEFwcGxlIE11c2lj4oCm")
#define OB_UI_RESTART_LOG  OBS(@"W+iuvuWkh10gZm9yY2Utc3RvcCBBcHBsZSBNdXNpYyjph4rmlL7mrovnlZnms6jlhaXnur/nqIsp4oCm")
#define OB_UI_AGENT_LBL    OBS(@"RnJpZGE=")
#define OB_UI_READY        OBS(@"W0JhcnRlbmRlcl0g5bCx57uq44CC54K544CM546v5aKD6Ieq5qOA44CN6aqM6K+BIGFkYi9mcmlkYS/op6Plr4bpk77ot6/jgII=")
#define OB_UI_SEC_CONN     OBS(@"MS4g6L+e5o6l6K6+572uKGFkYiAvIGZyaWRhIC8gVENQKQ==")
#define OB_UI_LOG_RUNNING  OBS(@"W2ZyaWRhXSBmcmlkYS1zZXJ2ZXIg5Zyo6L+Q6KGM")
#define OB_UI_LOG_STARTING OBS(@"W2ZyaWRhXSDmnKrov5DooYws5q2j5Zyo5ouJ6LW3IGZyaWRhLXNlcnZlcjE2ICg6MjcwNDIp4oCm")
#define OB_UI_LOG_STARTED  OBS(@"W2ZyaWRhXSDlt7Lmi4notbc=")
#define OB_UI_LOG_FAIL     OBS(@"W2ZyaWRhXSDmi4notbflpLHotKUs6K+35qOA5p+lIHJvb3QvZnJpZGEtc2VydmVyMTYg5piv5ZCm5a2Y5Zyo")
