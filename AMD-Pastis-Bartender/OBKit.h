#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 注入引擎 C 套件的薄封装(符号层)。
// 设计约束:本文件族源码零明文引擎标识——函数指针经 dlsym 装载,符号名一律 base64;
// 链接侧 -Wl,-force_load + -Wl,-export_dynamic 保证符号进二进制且可被 dlsym 命中。
// 仅 OBLink 允许 import 本头文件;错误一律转 NSString 返回。

// 幂等:启动专用 loop 线程(运行默认主循环,承载信号回调)。所有其他调用前必须先过这里。
void ob_bootstrap(void);

// 设备管理器(引擎全局单例语义;引用计数归 kit 管,调用方不 unref)
void *ob_manager(void);

// USB 设备(timeout 秒);失败返回 NULL 并带 *outErr
void *ob_device_usb(int timeout, NSString * _Nullable * _Nullable outErr);
// 远程设备(host:port);失败返回 NULL 并带 *outErr
void *ob_device_remote(NSString *addr, NSString * _Nullable * _Nullable outErr);
NSString *ob_device_name(void *dev);

// 按进程名找 pid;失败返回 0 并带 *outErr
unsigned ob_pid_by_name(void *dev, NSString *procName, NSString * _Nullable * _Nullable outErr);

// attach;失败返回 NULL 并带 *outErr
void *ob_attach(void *dev, unsigned pid, NSString * _Nullable * _Nullable outErr);
// detached 信号(在 kit 线程回调,block 会被拷贝并在信号到达时异步触发)
void ob_on_detached(void *session, void (^block)(int reason));

// 建脚本/装脚本;message 信号(json 文本 + 可选二进制附件,异步回调)
void *ob_script_new(void *session, NSString *source, NSString * _Nullable * _Nullable outErr);
void ob_script_on_message(void *script, void (^block)(NSString * _Nullable json, NSData * _Nullable data));
BOOL ob_script_load(void *script, NSString * _Nullable * _Nullable outErr);
BOOL ob_script_unload(void *script, NSString * _Nullable * _Nullable outErr);
// 发消息:json 文本 + 可选二进制附件(GBytes 通道,密文免 base64)
void ob_script_post(void *script, NSString *json, NSData * _Nullable data);

BOOL ob_detach(void *session, NSString * _Nullable * _Nullable outErr);
void ob_close_manager(void);
// 引擎对象的引用计数 -1(g_object_unref 转发;调用方不接触 glib 类型)
void ob_release(void *gobject);

NS_ASSUME_NONNULL_END
