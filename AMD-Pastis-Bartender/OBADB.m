#import "OBADB.h"
#import "AMDConfig.h"
#import "OBStrings.h"
#import "TaskRunner.h"
#import "AMDDebug.h"

@implementation OBADB

+ (NSString *)resolvedAdbPath {
    AMDConfig *c = [AMDConfig shared];
    NSString *p = c.adbPath.length ? c.adbPath : @"adb";
    if ([p containsString:@"/"]) return p;
    NSString *w = [self which:p];
    return w ?: p;
}

+ (NSString *)which:(NSString *)tool {
    int st = 0;
    NSString *out = [TaskRunner runSync:@"/bin/zsh"
                              arguments:@[@"-lc", [@"which " stringByAppendingString:tool]]
                                    cwd:nil env:nil status:&st];
    NSString *t = [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (st == 0 && t.length > 0 && [t hasPrefix:@"/"]) return [t componentsSeparatedByString:@"\n"][0];
    return nil;
}

+ (NSMutableArray<NSString *> *)baseArgs {
    AMDConfig *c = [AMDConfig shared];
    NSMutableArray *a = [NSMutableArray array];
    if (c.adbHost.length) { [a addObject:@"-H"]; [a addObject:c.adbHost]; }
    if (c.adbPort.length) { [a addObject:@"-P"]; [a addObject:c.adbPort]; }
    if (c.serial.length) { [a addObject:@"-s"]; [a addObject:c.serial]; }
    return a;
}

+ (NSString *)shell:(NSArray<NSString *> *)tail timeout:(NSTimeInterval)secs error:(NSString ** _Nullable)err {
    NSMutableArray *args = [self baseArgs];
    [args addObjectsFromArray:tail];
    int st = 0;
    NSString *out = [TaskRunner runSync:[self resolvedAdbPath] arguments:args cwd:nil env:nil status:&st];
    if (st < 0) { if (err) *err = out.length ? out : @"adb 启动失败"; return @""; }
    return out;
}

+ (NSString *)shellRetry:(NSArray<NSString *> *)tail timeout:(NSTimeInterval)secs error:(NSString ** _Nullable)err {
    NSString *last = nil;
    for (int i = 0; i < 3; i++) {
        NSString *r = [self shell:tail timeout:secs error:&last];
        if (last == nil) return r;
        [NSThread sleepForTimeInterval:1.0 * (i + 1)];
    }
    if (err) *err = last;
    return @"";
}

+ (nullable NSString *)suCat:(NSString *)path {
    NSString *cmd = [NSString stringWithFormat:@"su -c 'cat \"%@\"'", path];
    NSString *out = [self shellRetry:@[@"shell", cmd] timeout:40 error:nil];
    if ([out containsString:@"No such file"] || [out containsString:@"Permission denied"]) return nil;
    NSString *t = [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return t.length ? t : nil;
}

+ (BOOL)pull:(NSString *)remotePath to:(NSString *)localPath error:(NSString ** _Nullable)err {
    NSString *base = remotePath.lastPathComponent;
    NSString *up = [NSString stringWithFormat:
        @"su -c 'mkdir -p \"/data/local/tmp/dlstage\" && cp \"%@\" \"/data/local/tmp/dlstage/%@\" && chmod 644 \"/data/local/tmp/dlstage/%@\"'",
        remotePath, base, base];
    [self shellRetry:@[@"shell", up] timeout:60 error:nil];
    BOOL ok = NO;
    NSString *last = nil;
    for (int i = 0; i < 3; i++) {
        NSMutableArray *args = [self baseArgs];
        [args addObjectsFromArray:@[@"pull", [NSString stringWithFormat:@"/data/local/tmp/dlstage/%@", base], localPath]];
        int st = 0;
        [TaskRunner runSync:[self resolvedAdbPath] arguments:args cwd:nil env:nil status:&st];
        if (st == 0) { ok = YES; break; }
        last = @"adb pull 失败";
        [NSThread sleepForTimeInterval:1.0 * (i + 1)];
    }
    NSString *rm = [NSString stringWithFormat:@"su -c 'rm -f \"/data/local/tmp/dlstage/%@\"'", base];
    [self shellRetry:@[@"shell", rm] timeout:30 error:nil];
    if (!ok && err) *err = last ?: @"pull 失败";
    return ok;
}

+ (void)deeplinkSong:(NSString *)adam {
    NSString *cmd = [NSString stringWithFormat:
        @"am start -a android.intent.action.VIEW -d https://%@/song/%@ -p %@",
        OB_MUSIC_HOST, adam, OB_PHONE_PKG];
    [self shellRetry:@[@"shell", cmd] timeout:40 error:nil];
}

+ (void)mediaKeyPlay { [self shellRetry:@[@"shell", @"input keyevent 126"] timeout:30 error:nil]; }
+ (void)mediaKeyNext { [self shellRetry:@[@"shell", @"input keyevent 87"] timeout:30 error:nil]; }

@end
