#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"
#import "AMDDebug.h"

static void AMDUncaughtHandler(NSException *e) {
    NSString *line = [NSString stringWithFormat:@"[DBG %010.3f] UNCAUGHT EXCEPTION %@: %@\n%@\n",
                      [NSProcessInfo processInfo].systemUptime, e.name, e.reason, e.callStackSymbols];
    NSLog(@"%@", line);
    AMDDBGWriteFileSync(line);   // 无条件落盘:debug 未开也要留案底
}

int main(int argc, const char * argv[]) {
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
