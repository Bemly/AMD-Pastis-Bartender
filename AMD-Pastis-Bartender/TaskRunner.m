#import "TaskRunner.h"
#import "AMDDebug.h"

@implementation TaskRunner {
    NSTask *_task;
    NSString *_path;
    NSArray<NSString *> *_args;
    NSString *_cwd;
    NSDictionary<NSString *, NSString *> *_extraEnv;
}

- (instancetype)initWithLaunchPath:(NSString *)path
                         arguments:(NSArray<NSString *> *)args
                               cwd:(NSString *)cwd
                               env:(NSDictionary<NSString *, NSString *> *)extraEnv {
    if ((self = [super init])) {
        _path = [path copy];
        _args = [args copy];
        _cwd = [cwd copy];
        _extraEnv = [extraEnv copy];
    }
    return self;
}

- (NSDictionary *)mergedEnv {
    NSMutableDictionary *e = [[[NSProcessInfo processInfo] environment] mutableCopy];
    if (!e) e = [NSMutableDictionary dictionary];
    // GUI 默认 PATH 没有 homebrew,补上(ffprobe/ffmpeg 靠它)
    NSString *path = e[@"PATH"] ?: @"/usr/bin:/bin:/usr/sbin:/sbin";
    if ([path rangeOfString:@"/opt/homebrew/bin"].location == NSNotFound)
        path = [@"/opt/homebrew/bin:/usr/local/bin:" stringByAppendingString:path];
    e[@"PATH"] = path;
    e[@"PYTHONUNBUFFERED"] = @"1";
    for (NSString *k in _extraEnv) e[k] = _extraEnv[k];
    return e;
}

- (void)launch {
    AMDDBG(@"task: launch %@ %@", _path, [_args componentsJoinedByString:@" "]);
    _task = [[NSTask alloc] init];
    _task.launchPath = _path;
    _task.arguments = _args;
    if (_cwd.length > 0) _task.currentDirectoryPath = _cwd;
    _task.environment = [self mergedEnv];
    NSPipe *pipe = [NSPipe pipe];
    _task.standardOutput = pipe;
    _task.standardError = pipe;
    __weak typeof(self) weakSelf = self;
    pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) {
        NSData *d = h.availableData;
        if (d.length == 0) return;
        NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        if (!s) s = [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
        if (s && weakSelf.onOutput) {
            NSString *cap = [s copy];
            dispatch_async(dispatch_get_main_queue(), ^{ weakSelf.onOutput(cap); });
        }
    };
    _task.terminationHandler = ^(NSTask *t) {
        __strong typeof(weakSelf) strong = weakSelf;
        int st = t.terminationStatus;
        AMDDBG(@"task: exit=%d %@", st, t.launchPath);
        if (strong && strong.onEnd) {
            dispatch_async(dispatch_get_main_queue(), ^{ strong.onEnd(st); });
        }
    };
    @try {
        [_task launch];
    } @catch (NSException *e) {
        if (self.onOutput) {
            NSString *msg = [NSString stringWithFormat:@"启动失败 %@: %@\n", _path, e.reason];
            dispatch_async(dispatch_get_main_queue(), ^{ self.onOutput(msg); });
        }
        if (self.onEnd) {
            dispatch_async(dispatch_get_main_queue(), ^{ self.onEnd(-1); });
        }
    }
}

- (void)terminate {
    if ([self isRunning]) {
        @try { [_task terminate]; } @catch (NSException *e) {}
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if ([self isRunning]) {
                @try { [self->_task interrupt]; } @catch (NSException *e) {}
            }
        });
    }
}

- (BOOL)isRunning {
    return _task && [_task isRunning];
}

+ (NSString *)runSync:(NSString *)path
            arguments:(NSArray<NSString *> *)args
                  cwd:(NSString *)cwd
                  env:(NSDictionary<NSString *, NSString *> *)extraEnv
               status:(int *)status {
    AMDDBG(@"runSync: %@ %@", path, [args componentsJoinedByString:@" "]);
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = path;
    t.arguments = args;
    if (cwd.length > 0) t.currentDirectoryPath = cwd;
    NSMutableDictionary *e = [[[NSProcessInfo processInfo] environment] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSString *p = e[@"PATH"] ?: @"/usr/bin:/bin:/usr/sbin:/sbin";
    if ([p rangeOfString:@"/opt/homebrew/bin"].location == NSNotFound)
        p = [@"/opt/homebrew/bin:/usr/local/bin:" stringByAppendingString:p];
    e[@"PATH"] = p;
    e[@"PYTHONUNBUFFERED"] = @"1";
    for (NSString *k in extraEnv) e[k] = extraEnv[k];
    t.environment = e;
    NSPipe *pipe = [NSPipe pipe];
    t.standardOutput = pipe;
    t.standardError = pipe;
    // 后台线程先排空管道再等退出:反着来(先 waitUntilExit)时子进程写满
    // 64KB 管道缓冲会双向卡死(实测 ffmpeg 对坏文件刷错误行触发)
    __block NSData *collected = nil;
    dispatch_semaphore_t drained = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        collected = [[pipe fileHandleForReading] readDataToEndOfFile];
        dispatch_semaphore_signal(drained);
    });
    NSString *out = @"";
    @try {
        [t launch]; [t waitUntilExit];
        dispatch_semaphore_wait(drained, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
        NSData *d = collected;
        out = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
        if (status) *status = t.terminationStatus;
        AMDDBG(@"runSync: done exit=%d outLen=%lu", t.terminationStatus, (unsigned long)out.length);
    } @catch (NSException *ex) {
        AMDDBG(@"runSync: exception %@", ex);
        out = [NSString stringWithFormat:@"启动失败: %@", ex.reason];
        if (status) *status = -1;
    }
    return out;
}

@end
