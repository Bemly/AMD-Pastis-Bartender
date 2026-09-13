#import "AMDConfig.h"
#import "OBStrings.h"
#import "AMDDebug.h"

static NSString *const kPfx = @"AMD-Pastis-Bartender.";

@implementation AMDConfig

+ (instancetype)shared {
    static AMDConfig *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[AMDConfig alloc] init]; [s load]; });
    return s;
}

- (void)restoreDefaults {
    self.adbPath = @"/opt/homebrew/bin/adb";
    self.adbHost = @"";
    self.adbPort = @"";
    self.serial = @"";
    self.tcpPort = @"17001";
    self.lanIp = @"";
    self.scriptDir = @"/Users/bemly/Projects/amd";
    self.outDir = @"/Users/bemly/Projects/amd/downloads";
    self.useTcp = YES;
    self.mergeMode = @"mac";
    self.lyricMode = @"embed";
    self.lyricEncoding = @"UTF-8";
    self.lyricLayout = @"stagger";
    self.lyricMergeSep = @" / ";
    self.lyricUseNE = YES;
    self.lyricUseQQ = YES;
}

- (void)load {
    [self restoreDefaults];
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    BOOL hasSaved = [d objectForKey:[kPfx stringByAppendingString:@"adbPath"]] != nil;
    AMDDBG(@"config: load hasSaved=%d", hasSaved);
    if (hasSaved) {
        self.adbPath = [d stringForKey:[kPfx stringByAppendingString:@"adbPath"]];
        self.adbHost = [d stringForKey:[kPfx stringByAppendingString:@"adbHost"]] ?: @"";
        self.adbPort = [d stringForKey:[kPfx stringByAppendingString:@"adbPort"]] ?: @"";
        self.serial = [d stringForKey:[kPfx stringByAppendingString:@"serial"]] ?: @"";
        self.tcpPort = [d stringForKey:[kPfx stringByAppendingString:@"tcpPort"]] ?: @"17001";
        self.lanIp = [d stringForKey:[kPfx stringByAppendingString:@"lanIp"]] ?: @"";
        self.scriptDir = [d stringForKey:[kPfx stringByAppendingString:@"scriptDir"]] ?: self.scriptDir;
        self.outDir = [d stringForKey:[kPfx stringByAppendingString:@"outDir"]] ?: self.outDir;
        self.useTcp = [d boolForKey:[kPfx stringByAppendingString:@"useTcp"]];
        self.mergeMode = [d stringForKey:[kPfx stringByAppendingString:@"mergeMode"]] ?: @"mac";
        self.lyricMode = [d stringForKey:[kPfx stringByAppendingString:@"lyricMode"]] ?: @"embed";
        self.lyricEncoding = [d stringForKey:[kPfx stringByAppendingString:@"lyricEncoding"]] ?: @"UTF-8";
        self.lyricLayout = [d stringForKey:[kPfx stringByAppendingString:@"lyricLayout"]] ?: @"stagger";
        self.lyricMergeSep = [d stringForKey:[kPfx stringByAppendingString:@"lyricMergeSep"]] ?: @" / ";
        // BOOL 无“是否存过”标记:与 useTcp 同策略,首次走 restoreDefaults(见上)
        if ([d objectForKey:[kPfx stringByAppendingString:@"lyricUseNE"]] != nil) {
            self.lyricUseNE = [d boolForKey:[kPfx stringByAppendingString:@"lyricUseNE"]];
            self.lyricUseQQ = [d boolForKey:[kPfx stringByAppendingString:@"lyricUseQQ"]];
        }
    } else {
        // 首次启动:探测 adb 路径
        NSString *found = [self detectAdbPath];
        if (found) self.adbPath = found;
        if (![[NSFileManager defaultManager] fileExistsAtPath:self.adbPath]) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:@"/usr/local/bin/adb"])
                self.adbPath = @"/usr/local/bin/adb";
            else
                self.adbPath = @"adb";
        }
        [self save];
    }
    // 测试覆盖:AMD_MERGE=phone/mac 直接管合并方式(验收入 CLI 时不改已存设置)
    NSString *ev = [[NSProcessInfo processInfo].environment objectForKey:@"AMD_MERGE"];
    if (ev.length) self.mergeMode = ev;
}

- (NSString *)detectAdbPath {
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/bin/zsh";
    t.arguments = @[@"-lc", @"which adb"];
    t.standardInput = [NSFileHandle fileHandleWithNullDevice];  // 防 EXC_GUARD DUP fd 0(见 TaskRunner)
    NSPipe *p = [NSPipe pipe];
    t.standardOutput = p;
    @try {
        [t launch]; [t waitUntilExit];
        NSString *out = [[[NSString alloc] initWithData:[[p fileHandleForReading] readDataToEndOfFile]
                                               encoding:NSUTF8StringEncoding]
                         stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.terminationStatus == 0 && out.length > 0) return out;
    } @catch (NSException *e) {}
    return nil;
}

- (void)save {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:self.adbPath forKey:[kPfx stringByAppendingString:@"adbPath"]];
    [d setObject:self.adbHost forKey:[kPfx stringByAppendingString:@"adbHost"]];
    [d setObject:self.adbPort forKey:[kPfx stringByAppendingString:@"adbPort"]];
    [d setObject:self.serial forKey:[kPfx stringByAppendingString:@"serial"]];
    [d setObject:self.tcpPort forKey:[kPfx stringByAppendingString:@"tcpPort"]];
    [d setObject:self.lanIp forKey:[kPfx stringByAppendingString:@"lanIp"]];
    [d setObject:self.scriptDir forKey:[kPfx stringByAppendingString:@"scriptDir"]];
    [d setObject:self.outDir forKey:[kPfx stringByAppendingString:@"outDir"]];
    [d setBool:self.useTcp forKey:[kPfx stringByAppendingString:@"useTcp"]];
    [d setObject:self.mergeMode forKey:[kPfx stringByAppendingString:@"mergeMode"]];
    [d setObject:self.lyricMode forKey:[kPfx stringByAppendingString:@"lyricMode"]];
    [d setObject:self.lyricEncoding forKey:[kPfx stringByAppendingString:@"lyricEncoding"]];
    [d setObject:self.lyricLayout forKey:[kPfx stringByAppendingString:@"lyricLayout"]];
    [d setObject:self.lyricMergeSep forKey:[kPfx stringByAppendingString:@"lyricMergeSep"]];
    [d setBool:self.lyricUseNE forKey:[kPfx stringByAppendingString:@"lyricUseNE"]];
    [d setBool:self.lyricUseQQ forKey:[kPfx stringByAppendingString:@"lyricUseQQ"]];
    [d synchronize];
    AMDDBG(@"config: saved adb=%@ serial=%@ tcp=%@ useTcp=%d",
           self.adbPath, self.serial, self.tcpPort, self.useTcp);
}

- (NSArray<NSString *> *)adbBaseArgs {
    NSMutableArray *a = [NSMutableArray array];
    if (self.adbHost.length > 0) { [a addObject:@"-H"]; [a addObject:self.adbHost]; }
    if (self.adbPort.length > 0) { [a addObject:@"-P"]; [a addObject:self.adbPort]; }
    if (self.serial.length > 0) { [a addObject:@"-s"]; [a addObject:self.serial]; }
    return a;
}

- (NSString *)resolvedSerial:(NSString *)fallback {
    if (self.serial.length > 0) return self.serial;
    return fallback ?: @"";
}

- (NSString *)pythonPath {
    NSString *p = [self.scriptDir stringByAppendingPathComponent:@".venv/bin/python"];
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:p]) return p;
    return @"python3";
}

- (NSString *)downloadScriptPath {
    return [self.scriptDir stringByAppendingPathComponent:@"download_tcp.py"];
}

@end
