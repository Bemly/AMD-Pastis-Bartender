#import "AppDelegate.h"
#import "MainWindowController.h"
#import "AMDDebug.h"

static void AMDWalkScrolls(NSView *v, int depth) {
    if ([v isKindOfClass:[NSScrollView class]]) {
        NSScrollView *sv = (NSScrollView *)v;
        AMDDBG(@"geom: scroll d=%d frame=%@ docFrame=%@ clipOrigin=%@ visible=%@",
               depth, NSStringFromRect(sv.frame),
               NSStringFromRect(sv.documentView.frame),
               NSStringFromPoint(sv.contentView.bounds.origin),
               NSStringFromRect(sv.documentVisibleRect));
    }
    for (NSView *c in v.subviews) AMDWalkScrolls(c, depth + 1);
}

@implementation AppDelegate {
    MainWindowController *_mainWC;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    AMDDBG(@"app: didFinishLaunching begin");
    [self buildMenu];
    AMDDBG(@"app: menu built");
    _mainWC = [[MainWindowController alloc] init];
    AMDDBG(@"app: mainWC ready, window=%@", _mainWC.window);
    [_mainWC showWindow:self];
    NSWindow *w = _mainWC.window;
    AMDDBG(@"app: showWindow called, visible=%d frame=%@",
           w.isVisible, NSStringFromRect(w.frame));
    [NSApp activateIgnoringOtherApps:YES];
    NSLog(@"AMD-Pastis-Bartender launched");
    if (AMDDebugEnabled()) {
        NSArray *names = @[NSWindowDidBecomeMainNotification,
                           NSWindowDidBecomeKeyNotification,
                           NSWindowDidResignKeyNotification,
                           NSWindowDidMiniaturizeNotification,
                           NSWindowDidDeminiaturizeNotification,
                           NSWindowDidChangeOcclusionStateNotification];
        for (NSString *n in names) {
            [[NSNotificationCenter defaultCenter]
                addObserverForName:n object:w queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
                    AMDDBG(@"win event: %@ occlusion=%lu", n,
                           (unsigned long)w.occlusionState);
                }];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            AMDDBG(@"app: t+2s visible=%d occlusionVisible=%d frame=%@ mini=%d",
                   w.isVisible,
                   (w.occlusionState & NSWindowOcclusionStateVisible) != 0,
                   NSStringFromRect(w.frame), w.isMiniaturized);
            AMDWalkScrolls(w.contentView, 0);
        });
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)buildMenu {
    NSMenu *mainMenu = [[NSMenu alloc] initWithTitle:@"MainMenu"];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    [mainMenu addItem:appItem];
    [NSApp setMainMenu:mainMenu];
    NSMenu *appMenu = [[NSMenu alloc] initWithTitle:@"AMD-Pastis-Bartender"];
    [appItem setSubmenu:appMenu];
    NSString *quitTitle = [@"Quit AMD-Pastis-Bartender" stringByAppendingString:@"\t"];
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit AMD-Pastis-Bartender"
                                                     action:@selector(terminate:)
                                              keyEquivalent:@"q"];
    [appMenu addItem:quitItem];
    (void)quitTitle;
}

@end
