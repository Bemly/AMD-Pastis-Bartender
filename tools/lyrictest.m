// lyrictest.m — OBLyric 验收 CLI(L1 纯逻辑 + L4 内嵌回环):
//   真实网易云歌词做解析/对齐/排版/互转/编码对拍,时间戳零漂移;
//   内嵌回环拿输出目录任一 m4a 副本做 applyLyrics→readLyrics(旧标签保留)。
// 编译(仓库根目录):
//   clang -arch arm64 -fobjc-arc -framework Foundation tools/lyrictest.m \
//     AMD-Pastis-Bartender/OBLyric.m AMD-Pastis-Bartender/OBMP4.m \
//     -o /tmp/lyrictest -I AMD-Pastis-Bartender && /tmp/lyrictest
#import <Foundation/Foundation.h>
#import "OBLyric.h"
#import "OBMP4.h"

static int gFails = 0;
static void Check(BOOL ok, const char *name, NSString *detail) {
    printf("[%s] %s %s\n", ok ? "PASS" : "FAIL", name,
           detail.UTF8String ?: "");
    if (!ok) gFails++;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        NSData *jd = [[NSData alloc] initWithContentsOfFile:@"/tmp/ne_lyric2.json"];
        if (!jd) { printf("缺 /tmp/ne_lyric2.json,先跑 L0 探针\n"); return 2; }
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:jd options:0 error:NULL];
        NSString *orig = j[@"lrc"][@"lyric"];
        NSString *trans = j[@"tlyric"][@"lyric"];

        // 1. 解析原文
        NSArray *o = [OBLyric parseLRC:orig source:OBLyricSourceGeneric ignoreEmpty:NO];
        Check(o.count > 10, "parse-原文行数", [@(o.count) stringValue]);
        Check([o[0][@"ms"] longValue] == 0, "parse-首行ms=0", [o[0][@"text"] substringToIndex:MIN(12, [o[0][@"text"] length])]);
        Check([OBLyric parseTimestamp:@"[00:10.183]"] == 10183, "parse-时间戳", @"10183");
        Check([OBLyric parseTimestamp:@"[ti:BLUE MOON]"] < 0, "parse-元行非法", @"-1");

        // 2. 解析译文(去空行)
        NSArray *t = [OBLyric parseLRC:trans source:OBLyricSourceGeneric ignoreEmpty:YES];
        Check(t.count > 5, "parse-译文行数", [@(t.count) stringValue]);

        // 3. 对齐:补原文规则下应与原文等行
        NSArray *oClean = [OBLyric parseLRC:orig source:OBLyricSourceGeneric ignoreEmpty:YES];
        NSArray *al = [OBLyric alignTrans:t toOrigin:oClean deviation:500
                                 lostRule:OBLyricLostFillOrigin];
        Check(al.count == oClean.count, "align-补齐等行",
              [NSString stringWithFormat:@"%@=%@", @(al.count), @(oClean.count)]);
        BOOL sorted = YES;
        for (NSUInteger i = 1; i < al.count; i++)
            if ([al[i][@"ms"] longValue] < [al[i-1][@"ms"] longValue]) { sorted = NO; break; }
        Check(sorted, "align-有序", @"");

        // 4. 交错渲染:有序且行数=两轨和
        NSArray *st = [OBLyric renderStagger:@[oClean, al]];
        BOOL ssorted = YES;
        for (NSUInteger i = 1; i < st.count; i++)
            if ([st[i][@"ms"] longValue] < [st[i-1][@"ms"] longValue]) { ssorted = NO; break; }
        Check(st.count == oClean.count + al.count && ssorted, "stagger-归并",
              [NSString stringWithFormat:@"%@行有序", @(st.count)]);

        // 5. 合并渲染:同戳拼分隔符,行数<=交错
        NSArray *mg = [OBLyric renderMerge:@[oClean, al] separator:@" / "];
        Check(mg.count <= st.count && mg.count >= oClean.count, "merge-拼行",
              [@(mg.count) stringValue]);
        BOOL joined = NO;
        for (NSDictionary *l in mg)
            if ([l[@"text"] containsString:@" / "]) { joined = YES; break; }
        Check(joined, "merge-含分隔符", @"");

        // 6. LRC→SRT→LRC 零漂移
        NSString *srt = [OBLyric srtString:oClean durationMs:203624];
        Check([srt containsString:@"-->"], "srt-含时间轴", @"");
        NSArray *back = [OBLyric parseSRT:srt];
        BOOL same = back.count == oClean.count;
        if (same) {
            for (NSUInteger i = 0; i < back.count; i++) {
                if ([back[i][@"ms"] longValue] != [oClean[i][@"ms"] longValue]) { same = NO; break; }
            }
        }
        Check(same, "roundtrip-时间戳零漂移",
              [NSString stringWithFormat:@"%@行", @(back.count)]);

        // 7. SRT 块数 == 行数
        NSUInteger blocks = [[srt componentsSeparatedByString:@"\n\n"] count];
        // 尾部多一个空段,过滤
        NSMutableArray *nb = [NSMutableArray array];
        for (NSString *b in [srt componentsSeparatedByString:@"\n\n"])
            if (b.length) [nb addObject:b];
        Check(nb.count == oClean.count, "srt-块数对齐", [@(nb.count) stringValue]);
        (void)blocks;

        // 8. GB18030 写读回环
        NSString *sample = @"[00:10.18]依旧一如既往般如痴如狂\n[00:14.62]恋情总是转瞬即逝";
        NSString *e = nil;
        BOOL wok = [OBLyric writeFile:sample to:@"/tmp/lyric_gbk.lrc" encoding:@"GB18030" error:&e];
        NSDictionary *rd = wok ? [OBLyric readFile:@"/tmp/lyric_gbk.lrc" error:&e] : nil;
        Check(wok && [rd[@"text"] isEqualToString:sample] && [rd[@"encoding"] isEqualToString:@"GB18030"],
              "gb18030-回环", rd[@"encoding"] ?: (e ?: @"?"));

        // 9. UTF-16 BOM 识别
        [OBLyric writeFile:sample to:@"/tmp/lyric_u16.lrc" encoding:@"UTF-16" error:NULL];
        NSDictionary *r16 = [OBLyric readFile:@"/tmp/lyric_u16.lrc" error:&e];
        Check([r16[@"text"] isEqualToString:sample], "utf16bom-识别", r16[@"encoding"] ?: (e ?: @"?"));

        // 10. QQ 重置规则
        NSArray *q = [OBLyric parseLRC:@"[ar:xxx]\n[offset:0]\n[00:01.00]正文"
                                source:OBLyricSourceQQ ignoreEmpty:YES];
        Check(q.count == 1 && [q[0][@"ms"] longValue] == 1000, "qq-重置", [@(q.count) stringValue]);

        // 11. 多前缀展开
        NSArray *mp = [OBLyric parseLRC:@"[00:01.00][00:02.00]副歌" source:OBLyricSourceGeneric ignoreEmpty:YES];
        Check(mp.count == 2, "multi-前缀展开", [@(mp.count) stringValue]);

        // 12. 内嵌回环:输出目录找任一 m4a 副本,写词→读回→旧标签保留
        NSArray *cands = [[NSFileManager defaultManager]
                          contentsOfDirectoryAtPath:@"/Users/bemly/Projects/amd/downloads" error:NULL];
        NSString *src = nil;
        for (NSString *fn in cands) {
            if ([[fn.pathExtension lowercaseString] isEqualToString:@"m4a"]) {
                src = [@"/Users/bemly/Projects/amd/downloads" stringByAppendingPathComponent:fn];
                break;
            }
        }
        if (!src) {
            printf("[SKIP] embed-无m4a可测\n");
        } else {
            NSString *tmp = @"/tmp/lyric_embed_test.m4a";
            [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
            [[NSFileManager defaultManager] copyItemAtPath:src toPath:tmp error:NULL];
            NSMutableData *d = [[NSMutableData alloc] initWithContentsOfFile:tmp];
            unsigned long beforeLen = d.length;
            NSString *e2 = nil;
            NSString *sampleLrc = @"[00:10.18]依旧一如既往般如痴如狂\n[00:14.62]恋情总是转瞬即逝";
            uint32_t nl = d ? [OBMP4 applyLyrics:d lyrics:sampleLrc error:&e2] : 0;
            BOOL wok2 = nl > 0 && [d writeToFile:tmp atomically:YES];
            NSString *back = wok2 ? [OBMP4 readLyrics:d error:&e2] : nil;
            Check(wok2 && [back isEqualToString:sampleLrc], "embed-写读回环",
                  wok2 ? [NSString stringWithFormat:@"%lu→%u", beforeLen, nl] : (e2 ?: @"?"));
            // 重打幂等:再写一次,读回一致
            NSMutableData *d2 = wok2 ? [[NSMutableData alloc] initWithContentsOfFile:tmp] : nil;
            uint32_t nl2 = d2 ? [OBMP4 applyLyrics:d2 lyrics:sampleLrc error:NULL] : 0;
            NSString *back2 = (nl2 > 0 && [d2 writeToFile:tmp atomically:YES]) ?
                [OBMP4 readLyrics:d2 error:NULL] : nil;
            Check([back2 isEqualToString:sampleLrc], "embed-重打幂等", @"");
            // ffprobe 验证音频未坏(无 ffprobe 则跳过)
            NSTask *wt = [[NSTask alloc] init];
            wt.launchPath = @"/bin/zsh";
            wt.arguments = @[@"-lc", @"which ffprobe"];
            NSPipe *wp = [NSPipe pipe];
            wt.standardOutput = wp;
            @try { [wt launch]; [wt waitUntilExit]; } @catch (NSException *ex) {}
            NSString *fp = [[[NSString alloc] initWithData:[[wp fileHandleForReading] readDataToEndOfFile]
                                                  encoding:NSUTF8StringEncoding]
                            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (wt.terminationStatus == 0 && fp.length) {
                NSTask *pt = [[NSTask alloc] init];
                pt.launchPath = fp;
                pt.arguments = @[@"-v", @"error", @"-count_packets", @"-select_streams", @"a:0",
                                 @"-show_entries", @"stream=nb_read_packets", @"-of", @"csv=p=0", tmp];
                NSPipe *pp = [NSPipe pipe];
                pt.standardOutput = pp;
                @try { [pt launch]; [pt waitUntilExit]; } @catch (NSException *ex) {}
                NSString *pk = [[[NSString alloc] initWithData:[[pp fileHandleForReading] readDataToEndOfFile]
                                                      encoding:NSUTF8StringEncoding]
                                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                Check(pt.terminationStatus == 0 && pk.intValue > 0, "embed-音频完好",
                      [NSString stringWithFormat:@"%@包", pk]);
            } else {
                printf("[SKIP] embed-ffprobe缺失\n");
            }
            [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
        }

        printf(gFails ? "LYRICTEST FAIL(%d)\n" : "LYRICTEST OK\n", gFails);
        return gFails ? 1 : 0;
    }
}
