#import "OBLink.h"
#import "OBKit.h"
#import "AMDDebug.h"

// 远程引擎地址(USB 不可用时的回退;USB 直插场景由调用方先 adb forward tcp:27042)
static NSString * const kRemoteAddr = @"127.0.0.1:27042";

// RAII 递归锁:作用域结束自动解锁(ObjC 没有 defer,早退路径全靠它)
@interface OBUnlocker : NSObject
- (instancetype)initWithLock:(NSRecursiveLock *)lock;
@end
@implementation OBUnlocker {
    NSRecursiveLock *_l;
}
- (instancetype)initWithLock:(NSRecursiveLock *)lock {
    if ((self = [super init])) { _l = lock; [lock lock]; }
    return self;
}
- (void)dealloc { [_l unlock]; }
@end

@interface OBLink ()
@property (nonatomic, assign) void *dev;
@property (nonatomic, assign) void *session;
@property (nonatomic, assign) void *script;
@property (nonatomic, assign) unsigned targetPid;
@property (nonatomic, strong) NSRecursiveLock *lock;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSCondition *> *pending;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSString *> *replies;
@property (nonatomic, assign) NSInteger nextId;
@property (nonatomic, copy) void (^eventBlock)(NSString *, NSData *);
@end

@implementation OBLink

+ (instancetype)shared {
    static OBLink *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[OBLink alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = [NSRecursiveLock new];
        _pending = [NSMutableDictionary new];
        _replies = [NSMutableDictionary new];
    }
    return self;
}

- (BOOL)isConnected { return self.session != NULL && self.script != NULL; }
- (unsigned)pid { return self.targetPid; }

- (BOOL)connectToProcess:(NSString *)procName error:(NSString **)err {
    OBUnlocker *u = [[OBUnlocker alloc] initWithLock:self.lock];
    (void)u;
    AMDDBG(@"kit: connect begin (proc=%@)", procName);
    ob_bootstrap();
    [self disconnect];

    // 设备:USB 先试(macOS 侧对 Android 通常不可用,见冒烟实录),失败退远程——
    // 远程走 adb forward,调用方在连接前保证 forward 存在(自检/下载入口都先跑一条)
    NSString *derr = nil;
    void *dev = ob_device_usb(2, &derr);
    if (dev) {
        AMDDBG(@"kit: usb device");
    } else {
        AMDDBG(@"kit: usb 不可用(%@),退远程", derr ?: @"?");
        dev = ob_device_remote(kRemoteAddr, &derr);
    }
    if (!dev) { if (err) *err = derr ?: @"无设备"; return NO; }
    self.dev = dev;
    AMDDBG(@"kit: device=%@", ob_device_name(dev));

    unsigned pid = ob_pid_by_name(dev, procName, &derr);
    if (!pid) {
        if (err) *err = [NSString stringWithFormat:@"找不到进程 %@: %@", procName, derr ?: @"?"];
        [self disconnect];
        return NO;
    }
    self.targetPid = pid;

    void *session = ob_attach(dev, pid, &derr);
    if (!session) {
        if (err) *err = derr ?: @"attach 失败";
        [self disconnect];
        return NO;
    }
    self.session = session;
    __weak typeof(self) w = self;
    ob_on_detached(session, ^(int reason) {
        AMDDBG(@"kit: detached reason=%d", reason);
        [w hardReset];
    });
    AMDDBG(@"kit: attached pid=%u", pid);
    return YES;
}

- (BOOL)loadScriptSource:(NSString *)source error:(NSString * _Nullable * _Nullable)err {
    OBUnlocker *u = [[OBUnlocker alloc] initWithLock:self.lock];
    (void)u;
    if (!self.session) { if (err) *err = @"未连接"; return NO; }
    if (self.script) {           // 替换:先卸旧的
        ob_script_unload(self.script, NULL);
        ob_release(self.script);
        self.script = NULL;
    }
    NSString *serr = nil;
    void *script = ob_script_new(self.session, source, &serr);
    if (!script) { if (err) *err = serr ?: @"建脚本失败"; return NO; }
    __weak typeof(self) w = self;
    ob_script_on_message(script, ^(NSString *json, NSData *data) { [w handleMessage:json data:data]; });
    if (!ob_script_load(script, &serr)) {
        ob_release(script);
        if (err) *err = serr ?: @"装脚本失败";
        return NO;
    }
    self.script = script;
    AMDDBG(@"kit: script loaded");
    return YES;
}

- (void)onEvent:(void (^)(NSString *, NSData *))block {
    OBUnlocker *u = [[OBUnlocker alloc] initWithLock:self.lock];
    (void)u;
    self.eventBlock = block;
}

// 应答帧:{"type":"send","payload":{"id":N,...}};非应答帧转事件流。
// 加锁序:self.lock 保护 pending/replies;cond 只做唤醒(等端先持 cond 再查表,漏信号靠重查兜底)。
- (void)handleMessage:(NSString *)json data:(NSData *)data {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ re = [NSRegularExpression regularExpressionWithPattern:@"\"id\"\\s*:\\s*(\\d+)" options:0 error:NULL]; });
    NSTextCheckingResult *m = [re firstMatchInString:json options:0 range:NSMakeRange(0, json.length)];
    if (m && m.numberOfRanges >= 2) {
        NSNumber *id = @([json substringWithRange:[m rangeAtIndex:1]].integerValue);
        NSCondition *cond = nil;
        [self.lock lock];
        self.replies[id] = json;
        cond = self.pending[id];
        [self.lock unlock];
        if (cond) {
            [cond lock]; [cond signal]; [cond unlock];
            return;
        }
    }
    if (self.eventBlock) self.eventBlock(json, data);
}

- (nullable NSString *)rpc:(NSString *)op
                      args:(nullable NSDictionary *)args
                      data:(nullable NSData *)data
                   timeout:(NSTimeInterval)secs
                     error:(NSString **)err {
    [self.lock lock];
    if (!self.script) {
        [self.lock unlock];
        if (err) *err = @"未连接";
        return nil;
    }
    NSInteger id = ++self.nextId;
    NSMutableDictionary *frame = [NSMutableDictionary dictionary];
    frame[@"id"] = @(id);
    frame[@"op"] = op;
    // agent 侧统一从 m.args 取参,必须嵌在 args 键下(平铺会导致 agent 读 undefined → TypeError)
    if (args) frame[@"args"] = args;
    NSData *jd = [NSJSONSerialization dataWithJSONObject:frame options:0 error:NULL];
    void *script = self.script;
    NSCondition *cond = [NSCondition new];
    self.pending[@(id)] = cond;
    [self.lock unlock];
    if (!jd) {
        [self.lock lock]; [self.pending removeObjectForKey:@(id)]; [self.lock unlock];
        if (err) *err = @"请求序列化失败";
        return nil;
    }
    NSString *json = [[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding];
    AMDDBG(@"kit: rpc #%lld %@", (long long)id, op);
    ob_script_post(script, json, data);   // script 用局部副本,避免与 disconnect 竞态解引用

    NSString *out = nil;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:secs];
    [cond lock];
    for (;;) {
        [self.lock lock];
        out = self.replies[@(id)];
        [self.lock unlock];
        if (out || [deadline timeIntervalSinceNow] <= 0) break;
        [cond waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:MIN(1.0, [deadline timeIntervalSinceNow])]];
    }
    [cond unlock];

    [self.lock lock];
    [self.pending removeObjectForKey:@(id)];
    [self.replies removeObjectForKey:@(id)];
    [self.lock unlock];
    if (!out) { if (err) *err = @"RPC 超时"; return nil; }
    return out;
}

- (void)disconnect {
    void *script = self.script, *session = self.session;
    [self.lock lock];
    script = self.script; session = self.session;
    self.script = NULL; self.session = NULL; self.targetPid = 0;
    [self.lock unlock];
    // kit 同步调用(unload/detach)必须在锁外:kit 线程的 message 回调要拿这把锁,
    // 持锁等待套件完成 = ABBA 死锁(实测 detach 永久挂起)。先清指针,并发 rpc 会因"未连接"快速失败。
    if (script) { ob_script_unload(script, NULL); ob_release(script); }
    if (session) { ob_detach(session, NULL); ob_release(session); }
}

// detached 信号路径(可能已在 kit 线程):只清状态 + unref,不做 kit 同步调用(同线程死锁)
- (void)hardReset {
    [self.lock lock];
    void *script = self.script, *session = self.session;
    self.script = NULL; self.session = NULL; self.targetPid = 0;
    [self.lock unlock];
    if (script) ob_release(script);
    if (session) ob_release(session);
}

@end
