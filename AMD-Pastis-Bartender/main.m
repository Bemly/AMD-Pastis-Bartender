#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"
#import "AMDDebug.h"
#include <fcntl.h>
#include <unistd.h>

static void AMDEnsureStdFds(void) {
    // 经 open/launchd 启动时 fd0 被 guard,直接 close(0) 即 EXC_GUARD(2026-09-14 实录)。
    // 更隐蔽的是:若 0/1/2 有一个被关过,后续 socket()/open() 会复用该编号,
    // 之后任何 close 又会打到 guard/标准流上。启动即保证三者都开着,断子仓级联的根。
    for (int i = 0; i <= 2; i++) {
        if (fcntl(i, F_GETFD) == -1) {
            int fd = open("/dev/null", (i == 0) ? O_RDONLY : O_WRONLY);
            if (fd >= 0 && fd != i) { dup2(fd, i); if (fd > 2) close(fd); }
        }
    }
}

static void AMDUncaughtHandler(NSException *e) {
    NSString *line = [NSString stringWithFormat:@"[DBG %010.3f] UNCAUGHT EXCEPTION %@: %@\n%@\n",
                      [NSProcessInfo processInfo].systemUptime, e.name, e.reason, e.callStackSymbols];
    NSLog(@"%@", line);
    AMDDBGWriteFileSync(line);   // 无条件落盘:debug 未开也要留案底
}

int main(int argc, const char * argv[]) {
    AMDEnsureStdFds();
    @autoreleasepool {
        AMDDBG(@"main: start, args=%@", [NSProcessInfo processInfo].arguments);
        NSSetUncaughtExceptionHandler(&AMDUncaughtHandler);
        NSApplication *app = [NSApplication sharedApplication];
        // 固定深色外观(不受系统浅色/深色切换影响;部署目标 14.0,常量长期可用)
        app.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        AMDDBG(@"main: appearance pinned to DarkAqua");
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        return NSApplicationMain(argc, argv);
    }
}
