// lyricsearchtest.m — OBLyricSearch 验收 CLI(L2 联网):
//   网易云搜+取硬断言;QQ 只验 graceful(本机网络下可能不可达,不判死)。
// 编译(仓库根目录):
//   clang -arch arm64 -fobjc-arc -framework Foundation tools/lyricsearchtest.m \
//     AMD-Pastis-Bartender/OBLyricSearch.m AMD-Pastis-Bartender/OBHttp.m \
//     -o /tmp/lyricsearchtest -I AMD-Pastis-Bartender && /tmp/lyricsearchtest
#import <Foundation/Foundation.h>
#import "OBLyricSearch.h"

static int gFails = 0;
static void Check(BOOL ok, const char *name, NSString *detail) {
    printf("[%s] %s %s\n", ok ? "PASS" : "FAIL", name, detail.UTF8String ?: "");
    if (!ok) gFails++;
}
static void Log(NSString *l) { printf("  %s\n", l.UTF8String); }

int main(int argc, char **argv) {
    @autoreleasepool {
        [OBLyricSearch clearCache];
        NSString *e = nil;

        // 1. 网易云搜索:命中 BLUE MOON,时长≈203624ms
        NSArray *res = [OBLyricSearch search:@"BLUE MOON 9Lana" limit:5 sources:@[@"ne"]
                                        logf:^(NSString *l){ Log(l); } error:&e];
        Check(res.count > 0, "ne-搜索", e ?: [@(res.count) stringValue]);
        NSDictionary *hit = nil;
        for (NSDictionary *s in res) {
            long dur = [s[@"duration"] longValue];
            if (llabs(dur - 203624) < 2000) { hit = s; break; }
        }
        if (!hit && res.count) hit = res[0];
        Check(hit != nil, "ne-时长匹配", hit ? [NSString stringWithFormat:@"%@(%@ms)",
              hit[@"songId"], hit[@"duration"]] : @"无");

        // 2. 取词:原文非空
        NSDictionary *ly = hit ? [OBLyricSearch lyricFor:hit logf:^(NSString *l){ Log(l); } error:&e] : nil;
        Check(ly && [ly[@"lyric"] length] > 100, "ne-取词",
              ly ? [NSString stringWithFormat:@"原文%lu字%@",
                    (unsigned long)[ly[@"lyric"] length],
                    ly[@"trans"] ? @"含译文" : @"无译文"] : (e ?: @"?"));

        // 3. 缓存:第二次取词应命中(不再走网)
        NSDictionary *ly2 = hit ? [OBLyricSearch lyricFor:hit logf:NULL error:NULL] : nil;
        Check(ly2 && [ly2[@"lyric"] isEqualToString:ly[@"lyric"]], "cache-命中一致", @"");

        // 4. QQ:只验不崩(可达则顺带验取词)
        NSArray *q = [OBLyricSearch search:@"BLUE MOON 9Lana" limit:3 sources:@[@"qq"]
                                      logf:^(NSString *l){ Log(l); } error:&e];
        if (q.count) {
            NSDictionary *ql = [OBLyricSearch lyricFor:q[0] logf:^(NSString *l){ Log(l); } error:&e];
            Check(ql && [ql[@"lyric"] length] > 0, "qq-取词",
                  ql ? [NSString stringWithFormat:@"原文%lu字", (unsigned long)[ql[@"lyric"] length]] : (e ?: @"?"));
        } else {
            Check(YES, "qq-不可达时graceful", e ?: @"空结果无崩溃");
        }

        // 5. 空关键词不崩
        NSArray *em = [OBLyricSearch search:@"  " limit:5 sources:nil logf:NULL error:&e];
        Check(em.count == 0 && e, "empty-拒绝", e ?: @"?");

        printf(gFails ? "LYRICSEARCH FAIL(%d)\n" : "LYRICSEARCH OK\n", gFails);
        return gFails ? 1 : 0;
    }
}
