// oblinkstress.m — OBLink 并发锁结构风暴测试(2026-09-18 ABBA 死锁回归)。
//   多 worker 并发跑 连接→装脚本→refresh→断开 循环(共用单例,复刻 GUI 并发下载),
//   内置"拆台线程"周期性强停+拉起手机播放器,让 detached 信号高频砸进 connect/disconnect
//   窗口——旧结构(持锁跑 kit 同步调用 + kit 回调阻塞等锁)在此场景下全体 worker 停摆
//   (2026-09-18 实录);新结构必须全程可进可出:报错可以,挂死不行。
// 判定:每 2s 查进度,45s 无任何轮次完成即 HANG(exit 3);全部轮次跑完 → PASS(exit 0)。
// 用法: oblinkstress [轮数=5] [worker 数=4]
// 编译(仓库根目录;与 obdltest 同链接模式):
//   clang -arch arm64 -fobjc-arc -framework Cocoa tools/oblinkstress.m \
//     AMD-Pastis-Bartender/{OBDL,OBLink,OBKit,OBScript,OBMP4,OBPlaylist,OBHttp,OBADB,AMDConfig,TaskRunner}.m \
//     Vendor/mac-dual-pipe/build/Release/libmac-dual-pipe.a \
//     -o /tmp/oblinkstress -I AMD-Pastis-Bartender -I Vendor/mac-dual-pipe/src -I "$HOME/.obkit/16.7.19" \
//     -Wl,-force_load,"$HOME/.obkit/16.7.19/libobcore.a" -Wl,-export_dynamic \
//     -lbsm -ldl -lresolv -Wl,-framework,Foundation,-framework,AppKit,-framework,IOKit,-framework,Security
#import <Foundation/Foundation.h>
#import "OBLink.h"
#import "OBScript.h"
#import "OBADB.h"
#import "OBStrings.h"
#import "AMDConfig.h"

static NSLock *gStatLock;
static int gOk = 0, gFail = 0;

static void Stat(BOOL ok) {
    [gStatLock lock];
    if (ok) gOk++; else gFail++;
    fprintf(stderr, "    [进度 ok=%d fail=%d]\n", gOk, gFail);
    [gStatLock unlock];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        int rounds = argc > 1 ? atoi(argv[1]) : 5;
        int workers = argc > 2 ? atoi(argv[2]) : 4;
        [[AMDConfig shared] load];
        gStatLock = [NSLock new];

        // 前置:forward 一次(各入口按需自建也行,这里统一做)
        [OBADB shellRetry:@[@"forward", @"tcp:27042", @"tcp:27042"] timeout:20 error:nil];

        NSString *src = [OBScript agentSource];
        OBLink *link = [OBLink shared];

        // 预热:主线程单线程完成首次 boot(复刻 GUI 实际时序:自检先于一切并发;
        // 同时避开套件首次 init 的内部竞态——多线程同时涌入首次 bootstrap 时,
        // 套件内部的 glib/gum 线程状态表会边建边读而崩(2026-09-18 crash 实录),
        // 与本测要验的锁结构无关,真实流程 GUI/obcli 均先单线程首连)
        BOOL warmed = NO;
        for (int i = 0; i < 8 && !warmed; i++) {
            NSString *e = nil;
            if ([link connectToProcess:OB_PROC_NAME error:&e]) {
                NSString *e2 = nil;
                warmed = [link loadScriptSource:src error:&e2];
                [link disconnect];
            }
            if (!warmed) [NSThread sleepForTimeInterval:1.0];
        }
        if (!warmed) { fprintf(stderr, "== 预热失败:手机/引擎不可达 ==\n"); return 2; }
        fprintf(stderr, "[预热] 首连+装脚本 OK,开拆台与风暴\n");

        // 拆台线程:强停 → 停 1.5s → 拉起 → 停 5s(留足可连接窗口),循环直到收尾
        __block volatile BOOL chaosOn = YES;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            int n = 0;
            while (chaosOn) {
                [OBADB shellRetry:@[@"shell",
                    [NSString stringWithFormat:@"am force-stop %@", OB_PHONE_PKG]] timeout:20 error:nil];
                [NSThread sleepForTimeInterval:1.5];
                if (!chaosOn) break;
                [OBADB shellRetry:@[@"shell",
                    [NSString stringWithFormat:@"am start -n %@/.onboarding.activities.SplashActivity",
                     OB_PHONE_PKG]] timeout:20 error:nil];
                n++;
                [NSThread sleepForTimeInterval:5.0 + (n % 2)];
            }
        });

        dispatch_group_t grp = dispatch_group_create();
        dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
        NSDate *t0 = [NSDate date];
        for (int w = 0; w < workers; w++) {
            dispatch_group_async(grp, q, ^{
                for (int r = 0; r < rounds; r++) {
                    NSString *e = nil;
                    BOOL ok = NO;
                    // 轮内重试到连上为止(有限次):确保出现大量"活会话",拆台线程的强停
                    // 才会砸出 detached,与并发重连撞出实录现场(首轮全 fail 教训:全撞停机窗)
                    for (int att = 0; att < 10 && !ok; att++) {
                        ok = [link connectToProcess:OB_PROC_NAME error:&e];
                        if (!ok) [NSThread sleepForTimeInterval:0.8];
                    }
                    if (ok) {
                        NSString *e2 = nil;
                        if ([link loadScriptSource:src error:&e2]) {
                            [link rpc:@"refresh" args:nil data:nil timeout:6 error:nil];
                            [NSThread sleepForTimeInterval:1.5];   // 持活会话,等强停砸进来
                        } else {
                            ok = NO;
                        }
                        [link disconnect];
                    }
                    Stat(ok);
                }
            });
        }

        // 进度看门狗:45s 无任何轮次完成 = 有 worker 挂死(正常一轮含全部超时也 ≤25s)
        int goal = rounds * workers, lastTotal = -1;
        NSDate *lastProgress = [NSDate date];
        for (;;) {
            [NSThread sleepForTimeInterval:2];
            [gStatLock lock];
            int total = gOk + gFail;
            [gStatLock unlock];
            if (total >= goal) break;
            if (total > lastTotal) { lastTotal = total; lastProgress = [NSDate date]; }
            else if (-[lastProgress timeIntervalSinceNow] > 45) {
                chaosOn = NO;
                fprintf(stderr, "== HANG: 45s 无进度 (ok=%d fail=%d / 目标 %d) ==\n",
                        gOk, gFail, goal);
                return 3;
            }
        }
        chaosOn = NO;
        // 收尾:拆台线程可能停在停止态,把播放器拉回来
        [OBADB shellRetry:@[@"shell",
            [NSString stringWithFormat:@"am start -n %@/.onboarding.activities.SplashActivity",
             OB_PHONE_PKG]] timeout:20 error:nil];
        fprintf(stderr, "== PASS: %d workers x %d rounds, ok=%d fail=%d, 用时 %.1fs ==\n",
                workers, rounds, gOk, gFail, -[t0 timeIntervalSinceNow]);
        return 0;
    }
}
