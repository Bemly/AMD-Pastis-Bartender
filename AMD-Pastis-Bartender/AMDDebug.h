#import <Foundation/Foundation.h>

// Debug 开关:环境变量 AMD_DEBUG=1 或启动参数 --debug。
// 约定:排查问题/改 UI 时必须开;新增操作入口必须补 AMDDBG 打点(见 AGENTS.md)。
// 输出双路: NSLog(stderr / Console.app) + 追加落盘(见 AMDDBGLogPath),
// 前缀 [DBG <uptime>]。经 open/launchd 启动时 stderr 丢失,落盘文件是唯一排障依据。
// 未捕获异常无条件落盘(即使 debug 未开),走同步写(崩溃路径下 async 写刷不出来)。

static inline NSString *AMDDBGLogPath(void) {
    const char *p = getenv("AMD_DEBUG_FILE");
    if (p && p[0]) return [NSString stringWithUTF8String:p];
    return @"/tmp/amd_dbg.log";
}

static inline dispatch_queue_t AMDDBGFileQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("bemly.amd-dbg-file", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

// 同步落盘一行(调用方保证已带换行);异常处理路径用,平时走异步版。
static inline void AMDDBGWriteFileSync(NSString *line) {
    if (!line.length) return;
    NSString *path = AMDDBGLogPath();
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!d) return;
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:path])
            [fm createFileAtPath:path contents:nil attributes:nil];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) return;
        @try { [fh seekToEndOfFile]; [fh writeData:d]; } @finally { [fh closeFile]; }
    } @catch (NSException *e) {}
}

static inline void AMDDBGWriteFile(NSString *line) {
    if (!line.length) return;
    NSString *s = [line copy];
    dispatch_async(AMDDBGFileQueue(), ^{ AMDDBGWriteFileSync(s); });
}

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
    NSString *line = [NSString stringWithFormat:@"[DBG %010.3f] %@\n",
                      [NSProcessInfo processInfo].systemUptime, s];
    NSLog(@"%@", [line stringByTrimmingCharactersInSet:
                  [NSCharacterSet whitespaceAndNewlineCharacterSet]]);
    AMDDBGWriteFile(line);
}
