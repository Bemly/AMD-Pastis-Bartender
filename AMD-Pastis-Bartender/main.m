#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"
#import "AMDDebug.h"

static void AMDUncaughtHandler(NSException *e) {
    AMDDBG(@"UNCAUGHT EXCEPTION %@: %@\n%@", e.name, e.reason, e.callStackSymbols);
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        AMDDBG(@"main: start, args=%@", [NSProcessInfo processInfo].arguments);
        NSSetUncaughtExceptionHandler(&AMDUncaughtHandler);
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        return NSApplicationMain(argc, argv);
    }
}
