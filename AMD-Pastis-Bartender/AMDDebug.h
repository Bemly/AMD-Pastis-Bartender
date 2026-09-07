#import <Foundation/Foundation.h>

// Debug 开关:环境变量 AMD_DEBUG=1 或启动参数 --debug。
// 约定:排查问题/改 UI 时必须开;新增操作入口必须补 AMDDBG 打点(见 AGENTS.md)。
// 输出走 NSLog(stderr / Console.app),前缀 [DBG <uptime>]。

static inline BOOL AMDDebugEnabled(void) {
    static BOOL v;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *e = [NSProcessInfo processInfo].environment[@"AMD_DEBUG"];
        v = (e.length > 0 && ![e isEqualToString:@"0"]) ||
            [[NSProcessInfo processInfo].arguments containsObject:@"--debug"];
    });
    return v;
}

static inline void AMDDBG(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static inline void AMDDBG(NSString *fmt, ...) {
    if (!AMDDebugEnabled()) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[DBG %010.3f] %@", [NSProcessInfo processInfo].systemUptime, s);
}
