// lyricbatch.m — 批量内嵌歌词 CLI:
//   递归扫目录下全部 .m4a → 文件名搜词(网易云优先+QQ合并,按时长匹配) → 交错排版 → 内嵌歌词原子。
//   已有内嵌词默认跳过(--force 重打);失败只记清单不中断;再次跑即断点续传。
// 编译(仓库根目录):
//   clang -arch arm64 -fobjc-arc -framework Foundation tools/lyricbatch.m \
//     AMD-Pastis-Bartender/OBLyricSearch.m AMD-Pastis-Bartender/OBLyric.m \
//     AMD-Pastis-Bartender/OBHttp.m AMD-Pastis-Bartender/OBMP4.m \
//     -o /tmp/lyricbatch -I AMD-Pastis-Bartender && /tmp/lyricbatch <dir> [--force] [--sleep N]
#import <Foundation/Foundation.h>
#import "OBLyricSearch.h"
#import "OBLyric.h"
#import "OBMP4.h"

static NSString *FFProbe(void) {
    static NSString *fp;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSTask *t = [[NSTask alloc] init];
        t.launchPath = @"/bin/zsh";
        t.arguments = @[@"-lc", @"which ffprobe"];
        NSPipe *p = [NSPipe pipe];
        t.standardOutput = p;
        @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) {}
        NSString *o = [[[NSString alloc] initWithData:[[p fileHandleForReading] readDataToEndOfFile]
                                             encoding:NSUTF8StringEncoding]
                       stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.terminationStatus == 0 && o.length) fp = [o componentsSeparatedByString:@"\n"][0];
    });
    return fp;
}

// 本地音频时长(毫秒);拿不到返回 -1
static long LocalDurationMs(NSString *path) {
    NSString *fp = FFProbe();
    if (!fp) return -1;
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = fp;
    t.arguments = @[@"-v", @"error", @"-show_entries", @"format=duration", @"-of", @"csv=p=0", path];
    NSPipe *p = [NSPipe pipe];
    t.standardOutput = p;
    @try { [t launch]; [t waitUntilExit]; } @catch (NSException *e) { return -1; }
    if (t.terminationStatus != 0) return -1;
    NSString *o = [[[NSString alloc] initWithData:[[p fileHandleForReading] readDataToEndOfFile]
                                         encoding:NSUTF8StringEncoding]
                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    double secs = o.doubleValue;
    return secs > 0 ? (long)(secs * 1000) : -1;
}

// 文件名版本标记 → 期望文字:0 不限,1 假名(日文),2 汉字圈(中文/粤语),3 谚文(韩文),4 纯拉丁(英文版)
static int ExpectedScript(NSString *filename) {
    NSString *fn = filename.lowercaseString;
    if ([fn containsString:@"日文"] || [fn containsString:@"日语"] || [fn containsString:@"日本語"]) return 1;
    if ([fn containsString:@"韩文"] || [fn containsString:@"韩语"]) return 3;
    if ([fn containsString:@"粤语"]) return 2;
    if ([fn containsString:@"中文"] || [fn containsString:@"国语"] || [fn containsString:@"普通话"]) return 2;
    if ([fn containsString:@"英文"] || [fn containsString:@"英语"] || [fn containsString:@"english ver"]) return 4;
    return 0;
}

static BOOL LyricPassesGate(NSString *lyric, int script) {
    if (script == 0) return YES;
    // 先剥 credits/元信息行(作曲/编曲/by:/ti: 等),只看正文字符
    static NSRegularExpression *prefixRe;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefixRe = [NSRegularExpression regularExpressionWithPattern:@"^(\\[[^\\]]*\\])+" options:0 error:NULL];
    });
    NSArray *credits = @[@"作曲", @"编曲", @"作詞", @"作词", @"編曲", @"by:", @"ti:", @"ar:", @"al:",
                         @"offset", @"kana", @"length", @"hash", @"id:"];
    NSMutableString *body = [NSMutableString string];
    for (NSString *raw in [lyric componentsSeparatedByString:@"\n"]) {
        NSString *t = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSTextCheckingResult *m = [prefixRe firstMatchInString:t options:0 range:NSMakeRange(0, t.length)];
        NSString *text = m ? [t substringFromIndex:m.range.length] : t;
        // 前缀后面常跟空格,不二次 trim 的话 hasPrefix 全跪(实测英文词 credits 行漏网即因此)
        text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSString *low = text.lowercaseString;
        BOOL isCredit = NO;
        for (NSString *c in credits) {
            if ([low hasPrefix:c]) { isCredit = YES; break; }
        }
        if (!isCredit) [body appendString:text];
    }
    long kana = 0, cjk = 0, hangul = 0;
    NSUInteger n = body.length;
    for (NSUInteger i = 0; i < n; i++) {
        unichar c = [body characterAtIndex:i];
        if (c >= 0x3040 && c <= 0x30FF) kana++;
        else if (c >= 0x4E00 && c <= 0x9FFF) cjk++;
        else if (c >= 0xAC00 && c <= 0xD7AF) hangul++;
    }
    switch (script) {
        case 1: return kana >= 5;
        case 2: return (cjk + kana + hangul) >= 5;
        case 3: return hangul >= 5;
        case 4: return (cjk + kana + hangul) == 0;
    }
    return YES;
}

static void Log(NSString *l) { printf("%s\n", l.UTF8String); }

// 排版+内嵌+写后校验(搜索路径与映射路径共用);成功返回 YES
static BOOL EmbedSong(NSString *path, NSString *base, NSDictionary *song, NSDictionary *ly,
                      NSMutableArray<NSString *> *failed, int *done) {
    printf("  [*] 选中 [%s] %s — %s\n", [song[@"sourceName"] UTF8String] ?: "?",
           [song[@"name"] UTF8String] ?: "?", [song[@"singer"] UTF8String] ?: "?");
    // 交错排版(原文+译文+音译,有则收)
    OBLyricSource src = [song[@"source"] isEqualToString:@"qq"] ? OBLyricSourceQQ : OBLyricSourceGeneric;
    NSArray *o = [OBLyric parseLRC:ly[@"lyric"] source:src ignoreEmpty:YES];
    if (!o.count) {
        printf("  [!] 原文为空\n");
        [failed addObject:[base stringByAppendingString:@" | 原文为空"]];
        return NO;
    }
    NSMutableArray *tracks = [NSMutableArray arrayWithObject:o];
    for (NSString *k in @[@"trans", @"roma"]) {
        NSString *t = ly[k];
        if (![t isKindOfClass:[NSString class]] || !t.length) continue;
        NSArray *p = [OBLyric parseLRC:t source:src ignoreEmpty:YES];
        if (p.count) [tracks addObject:[OBLyric alignTrans:p toOrigin:o deviation:500
                                                  lostRule:OBLyricLostEmpty]];
    }
    NSString *body = [OBLyric lrcString:[OBLyric renderStagger:tracks]];
    NSMutableData *d = [[NSMutableData alloc] initWithContentsOfFile:path];
    NSString *ee = nil;
    uint32_t nl = d ? [OBMP4 applyLyrics:d lyrics:body error:&ee] : 0;
    BOOL ok = nl > 0 && [d writeToFile:path atomically:YES];
    NSString *back = ok ? [OBMP4 readLyrics:d error:NULL] : nil;
    if (ok && [back isEqualToString:body]) {
        printf("  [+] 内嵌 %lu字\n", (unsigned long)body.length);
        (*done)++;
        return YES;
    }
    printf("  [!] 内嵌失败: %s\n", (ee ?: @"?").UTF8String);
    [failed addObject:[base stringByAppendingString:@" | 内嵌失败"]];
    return NO;
}

// 映射文件:每行 "文件名.m4a | songId [ne|qq]" 或 "文件名.m4a | skip"(纯音乐备注跳过)
// 返回 @{文件名: @{@"songId":..., @"source":...} 或 @{@"skip":@YES}}
// 文件名比对做 NFC 归一化:macOS 盘上假名常是 NFD(分解形),手写映射多为 NFC,直接比必跪
static NSString *NormName(NSString *s) { return s.precomposedStringWithCanonicalMapping ?: s; }
static NSDictionary *LoadMap(NSString *mapPath) {
    NSData *d = [[NSData alloc] initWithContentsOfFile:mapPath];
    if (!d) return @{};
    NSString *text = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!text) return @{};
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!line.length || [line hasPrefix:@"#"]) continue;
        NSArray *parts = [line componentsSeparatedByString:@"|"];
        if (parts.count < 2) continue;
        NSString *fn = [parts[0] stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceCharacterSet]];
        NSString *vid = [parts[1] stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceCharacterSet]];
        if (!fn.length || !vid.length) continue;
        if ([vid caseInsensitiveCompare:@"skip"] == NSOrderedSame) {
            out[NormName(fn)] = @{ @"skip": @YES };
            continue;
        }
        NSString *src = @"ne";
        if (parts.count >= 3) {
            NSString *s3 = [parts[2] stringByTrimmingCharactersInSet:
                            [NSCharacterSet whitespaceCharacterSet]].lowercaseString;
            if ([s3 isEqualToString:@"qq"]) src = @"qq";
        }
        out[NormName(fn)] = @{ @"songId": vid, @"source": src,
                     @"sourceName": [src isEqualToString:@"qq"] ? @"QQ音乐" : @"网易云" };
    }
    return out;
}

// 去括号后缀的小写核心(比较曲名用)
static NSString *CoreTitle(NSString *s) {
    NSString *t = s.lowercaseString ?: @"";
    for (NSArray *pair in @[@[@"(", @")"], @[@"（", @"）"], @[@"[", @"]"], @[@"【", @"】"]]) {
        for (;;) {
            NSRange a = [t rangeOfString:pair[0]];
            if (a.location == NSNotFound) break;
            NSRange b = [t rangeOfString:pair[1]
                                 options:0
                                   range:NSMakeRange(a.location, t.length - a.location)];
            if (b.location == NSNotFound) break;
            t = [[t substringToIndex:a.location]
                 stringByAppendingString:[t substringFromIndex:b.location + b.length]];
        }
    }
    return [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

// 版本关键词:文件名有而候选名没有 → 重罚(错版混入是批量最大污染源,宁缺毋滥)
static NSInteger VersionPenalty(NSString *filename, NSString *candName) {
    NSArray *groups = @[
        @[@"日文", @"日语", @"日本語", @"japanese"],
        @[@"中文", @"国语", @"mandarin"],
        @[@"伴奏", @"inst", @"off vocal", @"karaoke"],
        @[@"acoustic", @"unplugged"],
        @[@"remix"],
        @[@"live", @"现场"],
        @[@"demo"],
    ];
    NSString *fn = filename.lowercaseString, *cn = (candName ?: @"").lowercaseString;
    for (NSArray *g in groups) {
        BOOL inFile = NO;
        for (NSString *k in g) if ([fn containsString:k]) { inFile = YES; break; }
        if (!inFile) continue;
        BOOL inCand = NO;
        for (NSString *k in g) if ([cn containsString:k]) { inCand = YES; break; }
        if (!inCand) return -8;
    }
    return 0;
}

// 评分:硬门限 Δ>8s 出局;时长接近 + 艺人重合 + 曲名核心重合 + 版本一致;网易云 +1(译文通常更全)
static NSInteger ScoreSong(NSDictionary *s, NSString *filename, long localMs) {
    long dm = [s[@"duration"] longValue];
    if (localMs <= 0 || dm <= 0) return -1;
    long delta = llabs(dm - localMs);
    if (delta > 8000) return -1;
    NSInteger sc = delta <= 2000 ? 4 : (delta <= 5000 ? 2 : 1);
    NSString *fn = filename.lowercaseString;
    for (NSString *singer in [(s[@"singer"] ?: @"") componentsSeparatedByString:@" / "]) {
        NSString *sg = [singer stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (sg.length > 1 && [fn containsString:sg.lowercaseString]) { sc += 4; break; }
    }
    NSString *core = CoreTitle(s[@"name"]);
    NSString *coreFile = CoreTitle([filename.stringByDeletingPathExtension componentsSeparatedByString:@" - "].lastObject ?: filename);
    if (core.length > 2 && coreFile.length > 2 &&
        ([coreFile containsString:core] || [core containsString:coreFile])) sc += 4;
    if ([s[@"source"] isEqualToString:@"ne"]) sc += 1;
    sc += VersionPenalty(filename, s[@"name"]);
    return sc;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) { printf("usage: lyricbatch <dir> [--force] [--sleep N] [--map file] [--only-map]\n"); return 2; }
        NSString *dir = @(argv[1]);
        BOOL force = NO, onlyMap = NO;
        double sleepSecs = 2.0;
        NSString *mapArg = nil;
        for (int i = 2; i < argc; i++) {
            if (!strcmp(argv[i], "--force")) force = YES;
            else if (!strcmp(argv[i], "--only-map")) onlyMap = YES;
            else if (!strcmp(argv[i], "--sleep") && i + 1 < argc) sleepSecs = atof(argv[++i]);
            else if (!strcmp(argv[i], "--map") && i + 1 < argc) mapArg = @(argv[++i]);
        }
        // 映射:显式 --map 优先,否则目录下 lyric_ids.txt 有则自动用
        NSString *mapPath = mapArg ?: [dir stringByAppendingPathComponent:@"lyric_ids.txt"];
        NSDictionary *idMap = LoadMap(mapPath);
        if (idMap.count) printf("[*] 映射 %lu 条 (%s)\n", (unsigned long)idMap.count, mapPath.UTF8String);
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDirectoryEnumerator *en = [fm enumeratorAtPath:dir];
        NSMutableArray<NSString *> *files = [NSMutableArray array];
        for (NSString *rel in en) {
            if ([[rel.pathExtension lowercaseString] isEqualToString:@"m4a"])
                [files addObject:[dir stringByAppendingPathComponent:rel]];
        }
        [files sortUsingSelector:@selector(localizedStandardCompare:)];
        printf("=== 批量内嵌歌词: %lu 首 in %s (force=%d sleep=%.0fs) ===\n",
               (unsigned long)files.count, dir.UTF8String, force, sleepSecs);

        int done = 0, skipped = 0;
        NSMutableArray<NSString *> *failed = [NSMutableArray array];
        for (NSUInteger fi = 0; fi < files.count; fi++) {
            NSString *path = files[fi];
            NSString *base = [path.lastPathComponent stringByDeletingPathExtension];
            printf("[%lu/%lu] %s\n", fi + 1, (unsigned long)files.count, base.UTF8String);
            // 已有词跳过(断点续传;纯本地读，不占间隔)
            if (!force) {
                NSData *probe = [[NSData alloc] initWithContentsOfFile:path];
                NSString *e0 = nil;
                NSString *have = probe ? [OBMP4 readLyrics:probe error:&e0] : nil;
                if (have.length) {
                    printf("  [=] 已有内嵌词(%lu字),跳过\n", (unsigned long)have.length);
                    skipped++;
                    continue;
                }
            }
            // 映射直取(绕过搜索+打分;语言门照守;--only-map 下非映射文件直接过)
            NSDictionary *mapped = idMap[NormName(path.lastPathComponent)];
            if (onlyMap && !mapped) continue;
            if (mapped[@"skip"]) {
                printf("  [=] 映射备注跳过(纯音乐)\n");
                skipped++;
                continue;
            }
            if (mapped) {
                if (sleepSecs > 0) [NSThread sleepForTimeInterval:sleepSecs];
                NSDictionary *song = @{ @"source": mapped[@"source"],
                                        @"sourceName": mapped[@"sourceName"],
                                        @"songId": mapped[@"songId"],
                                        @"name": base, @"singer": @"", @"album": @"", @"duration": @0 };
                NSString *le = nil;
                NSDictionary *ly = [OBLyricSearch lyricFor:song logf:^(NSString *l){ Log(l); } error:&le];
                if (!ly) {
                    printf("  [!] 取词失败: %s\n", (le ?: @"?").UTF8String);
                    [failed addObject:[base stringByAppendingString:@" | 取词失败"]];
                    continue;
                }
                if (!LyricPassesGate(ly[@"lyric"] ?: @"", ExpectedScript(base))) {
                    printf("  [!] 语言不符(映射 ID 请核对)\n");
                    [failed addObject:[base stringByAppendingString:@" | 语言不符"]];
                    continue;
                }
                EmbedSong(path, base, song, ly, failed, &done);
                continue;
            }
            // 查询链:全文件名 → 去括号曲名 → 曲名+艺人token;每轮后最高分≥10提前收
            // 间隔只给网络活(跳过检查已过;失败 continue 照样覆盖——失败风暴是上次限流的直接原因)
            if (fi > 0 && sleepSecs > 0) [NSThread sleepForTimeInterval:sleepSecs];
            void (^Log2)(NSString *) = ^(NSString *l){ Log(l); };
            NSString *titlePart = [[base componentsSeparatedByString:@" - "].lastObject ?: base
                                   stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSString *artistPart = [base containsString:@" - "] ?
                [base substringToIndex:[base rangeOfString:@" - "].location] : @"";
            NSMutableArray *queries = [NSMutableArray arrayWithObject:base];
            NSString *simple = CoreTitle(titlePart);
            if (simple.length > 1 && [simple caseInsensitiveCompare:base] != NSOrderedSame)
                [queries addObject:simple];
            // 艺人token(取前2个):版本曲的同曲家族常挂在固定艺人名下(如 HOYO-MiX)
            NSMutableArray *tokens = [NSMutableArray array];
            for (NSString *raw in [artistPart componentsSeparatedByCharactersInSet:
                                   [NSCharacterSet characterSetWithCharactersInString:@"&/,、，；;"]]) {
                NSString *t = CoreTitle([raw stringByTrimmingCharactersInSet:
                                         [NSCharacterSet whitespaceCharacterSet]]);
                if (t.length > 2) [tokens addObject:t];
                if (tokens.count >= 2) break;
            }
            for (NSString *tok in tokens) {
                NSString *q = [NSString stringWithFormat:@"%@ %@", simple.length > 1 ? simple : base, tok];
                if (queries.count < 4) [queries addObject:q];
            }
            __block NSString *e = nil;
            __block BOOL chainLimited = NO;   // 本轮任一查询见过限流特征
            long localMs = LocalDurationMs(path);
            // 搜词链抽成 block(可整轮重跑;返回合并去重后的候选)
            NSArray *(^runChain)(void) = ^NSArray *{
                NSMutableArray *res2 = [NSMutableArray array];
                NSMutableSet *seen2 = [NSMutableSet set];
                chainLimited = NO;
                for (NSString *q in queries) {
                    if (q != queries[0]) {
                        NSInteger probe = -1;
                        for (NSDictionary *s in res2)
                            probe = MAX(probe, ScoreSong(s, path.lastPathComponent, localMs));
                        if (probe >= 10) break;   // 够用就别多搜
                        printf("  [*] 当前最高%ld分,换查询 \"%s\" 再搜\n", (long)probe, q.UTF8String);
                    }
                    NSString *qe = nil;
                    NSArray *more = [OBLyricSearch search:q limit:5 sources:nil logf:Log2 error:&qe];
                    if (qe && ([qe containsString:@"操作频繁"] || [qe containsString:@"HTTP"] ||
                               [qe containsString:@"429"] || [qe containsString:@"405"]))
                        chainLimited = YES;
                    if (!more.count && !res2.count) e = qe;
                    for (NSDictionary *s in more) {
                        NSString *k = [NSString stringWithFormat:@"%@_%@", s[@"source"], s[@"songId"]];
                        if (![seen2 containsObject:k]) { [seen2 addObject:k]; [res2 addObject:s]; }
                    }
                }
                return res2;
            };
            NSMutableArray *allRes = [runChain() mutableCopy];
            // 最高分 <5 且见过限流 → 60s 后整轮重搜一次(限流时低分多为残缺结果)
            NSInteger topNow = -1;
            for (NSDictionary *s in allRes)
                topNow = MAX(topNow, ScoreSong(s, path.lastPathComponent, localMs));
            if (topNow < 5 && chainLimited) {
                printf("  [!] 见过限流且最高仅%ld分,休眠60s后整轮重搜\n", (long)topNow);
                [NSThread sleepForTimeInterval:60];
                allRes = [runChain() mutableCopy];
            }
            NSArray *res = allRes;
            if (!res.count) {
                printf("  [!] 搜不到: %s\n", (e ?: @"?").UTF8String);
                [failed addObject:[base stringByAppendingString:@" | 搜不到"]];
                continue;
            }
            // 打分排序(分降序,同分时长近者前);逐个试(最多3个):取词 → 语言门 → 过则用
            NSMutableArray *ranked = [NSMutableArray array];
            for (NSDictionary *s in res) {
                NSInteger sc = ScoreSong(s, path.lastPathComponent, localMs);
                long dm = [s[@"duration"] longValue];
                long delta = (localMs > 0 && dm > 0) ? llabs(dm - localMs) : LONG_MAX;
                if (localMs <= 0) { sc = 0; delta = 0; }   // 无本地时长:保持原序,全员候选
                [ranked addObject:@{@"song": s, @"score": @(sc), @"delta": @(delta)}];
            }
            [ranked sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                NSInteger sa = [a[@"score"] integerValue], sb = [b[@"score"] integerValue];
                if (sa != sb) return sa > sb ? NSOrderedAscending : NSOrderedDescending;
                long da = [a[@"delta"] longValue], db = [b[@"delta"] longValue];
                return da < db ? NSOrderedAscending : (da > db ? NSOrderedDescending : NSOrderedSame);
            }];
            int wantScript = ExpectedScript(base);
            NSDictionary *song = nil, *ly = nil;
            int tried = 0;
            NSString *rejectReason = nil;
            for (NSDictionary *cand in ranked) {
                if (tried >= 3) break;
                NSInteger sc = [cand[@"score"] integerValue];
                if (localMs > 0 && sc < 5) {
                    if (!rejectReason) rejectReason = @"信号不足";   // 5分以下宁缺毋滥
                    continue;
                }
                NSDictionary *cs = cand[@"song"];
                printf("  [*] 试 [%s] %s — %s (%ld分)\n",
                       [cs[@"sourceName"] UTF8String] ?: "?",
                       [cs[@"name"] UTF8String] ?: "?", [cs[@"singer"] UTF8String] ?: "?",
                       (long)sc);
                tried++;
                NSString *le = nil;
                NSDictionary *cy = [OBLyricSearch lyricFor:cs logf:^(NSString *l){ Log(l); } error:&le];
                if (!cy) { rejectReason = le ?: @"取词失败"; continue; }
                if (!LyricPassesGate(cy[@"lyric"] ?: @"", wantScript)) {
                    rejectReason = @"语言不符";
                    printf("  [!] 语言不符,换下一个\n");
                    continue;
                }
                song = cs; ly = cy;
                break;
            }
            if (!ly) {
                if (!song && localMs <= 0 && res.count) {
                    // 无本地时长信息:信首个(无门可守)
                    song = res[0];
                    printf("  [*] 无本地时长,信首个结果\n");
                    NSString *le = nil;
                    ly = [OBLyricSearch lyricFor:song logf:^(NSString *l){ Log(l); } error:&le];
                    if (!ly) rejectReason = le;
                }
                if (!ly) {
                    printf("  [!] 无可用候选: %s\n", (rejectReason ?: @"?").UTF8String);
                    [failed addObject:[base stringByAppendingString:
                                       [NSString stringWithFormat:@" | %@", rejectReason ?: @"无候选"]]];
                    continue;
                }
            }
            EmbedSong(path, base, song, ly, failed, &done);
        }
        printf("=== 完成: 成功 %d, 跳过 %d, 失败 %lu ===\n", done, skipped, (unsigned long)failed.count);
        for (NSString *f in failed) printf("  FAIL: %s\n", f.UTF8String);
        return failed.count ? 1 : 0;
    }
}
