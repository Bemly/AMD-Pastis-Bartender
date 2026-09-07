// obdltest.m — 原生下载引擎验收 CLI(Phase 1):
//   用一条曲目与参考 python 脚本双跑,对比 验证三元组(包数/ffmpeg错误/时长)。
// 前置:先编直传静态库(./tools/build_dualpipe.sh)。
// 编译(仓库根目录):
//   clang -arch arm64 -fobjc-arc -framework Cocoa \
//     tools/obdltest.m \
//     AMD-Pastis-Bartender/{OBDL,OBLink,OBKit,OBScript,OBMP4,OBPlaylist,OBHttp,OBADB,AMDConfig,TaskRunner}.m \
//     Vendor/mac-dual-pipe/build/Release/libmac-dual-pipe.a \
//     -o /tmp/obdltest -I AMD-Pastis-Bartender -I Vendor/mac-dual-pipe/src -I "$HOME/.obkit/16.7.19" \
//     -Wl,-force_load,"$HOME/.obkit/16.7.19/libobcore.a" -Wl,-export_dynamic \
//     -lbsm -ldl -lresolv -Wl,-framework,Foundation,-framework,AppKit,-framework,IOKit,-framework,Security
#import <Foundation/Foundation.h>
#import "OBDL.h"
#import "AMDConfig.h"

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 3) {
            printf("usage: obdltest [cache] <adamId> <outDir> [serial] [adbPort]\n");
            return 2;
        }
        BOOL cacheMode = strcmp(argv[1], "cache") == 0;
        const char *adamArg = cacheMode ? argv[2] : argv[1];
        const char *dirArg  = cacheMode ? argv[3] : argv[2];
        int si = cacheMode ? 4 : 3, pi = cacheMode ? 5 : 4;
        if ((int)argc > si && strlen(argv[si])) [AMDConfig shared].serial = @(argv[si]);
        if ((int)argc > pi && strlen(argv[pi])) [AMDConfig shared].adbPort = @(argv[pi]);
        NSString *err = nil;
        volatile BOOL cancelled = NO;
        NSDictionary *meta = cacheMode
            ? [OBDLJob runFromCache:@(adamArg) outDir:@(dirArg) force:NO
                               logf:^(NSString *l) { printf("%s\n", l.UTF8String); }
                             cancel:&cancelled error:&err]
            : [OBDLJob runAdam:@(adamArg) outDir:@(dirArg) force:NO
                          logf:^(NSString *l) { printf("%s\n", l.UTF8String); }
                        cancel:&cancelled error:&err];
        if (!meta) { printf("FAIL: %s\n", err.UTF8String); return 1; }
        NSDictionary *v = meta[@"verify"];
        // 值可能是字符串也可能是数字,一律 description 打印(NSString 没有 stringValue,会抛异常)
        printf("OK: %s - %s | packets=%s expect=%s duration=%s fferr=%s waived=%s\n",
               [meta[@"artist"] UTF8String] ?: "?", [meta[@"title"] UTF8String] ?: "?",
               [[v[@"packets"] description] UTF8String] ?: "?",
               [[v[@"expect_samples"] description] UTF8String] ?: "?",
               [[v[@"duration"] description] UTF8String] ?: "?",
               [[v[@"ffmpeg_errors"] description] UTF8String] ?: "?",
               [[v[@"waived"] description] UTF8String] ?: "-");
        return 0;
    }
}
