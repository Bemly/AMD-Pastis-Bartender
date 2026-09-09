#import "OBLyric.h"

@implementation OBLyric

// 毫秒 → "HH:mm:ss,SSS"
static NSString *SrtTS(long ms) {
    if (ms < 0) ms = 0;
    return [NSString stringWithFormat:@"%02ld:%02ld:%02ld,%03ld",
            ms / 3600000, (ms % 3600000) / 60000, (ms % 60000) / 1000, ms % 1000];
}

#pragma mark - 解析

+ (long)parseTimestamp:(NSString *)bracket {
    // 形如 [mm:ss] / [mm:ss.x] / [mm:ss.xx] / [mm:ss.xxx],分隔符 . 或 :
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"^\\[\\s*(\\d{1,3})\\s*:\\s*(\\d{1,2})(?:\\s*[.:]\\s*(\\d{1,3}))?\\s*\\]$"
                                                   options:0 error:NULL];
    });
    NSTextCheckingResult *m = [re firstMatchInString:bracket options:0
                                               range:NSMakeRange(0, bracket.length)];
    if (!m || m.numberOfRanges < 3) return -1;
    long mm = (long)[[bracket substringWithRange:[m rangeAtIndex:1]] longLongValue];
    long ss = (long)[[bracket substringWithRange:[m rangeAtIndex:2]] longLongValue];
    long frac = 0;
    if (m.numberOfRanges >= 4 && [m rangeAtIndex:3].location != NSNotFound) {
        NSString *f = [bracket substringWithRange:[m rangeAtIndex:3]];
        if (f.length == 1) frac = (long)f.longLongValue * 100;
        else if (f.length == 2) frac = (long)f.longLongValue * 10;
        else frac = (long)[[f substringToIndex:3] longLongValue];
    }
    if (ss > 59) return -1;
    return (mm * 60 + ss) * 1000 + frac;
}

+ (NSArray<NSDictionary *> *)parseLRC:(NSString *)text
                               source:(OBLyricSource)src
                          ignoreEmpty:(BOOL)ignoreEmpty {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    if (!text.length) return out;
    static NSRegularExpression *prefixRe;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefixRe = [NSRegularExpression regularExpressionWithPattern:@"^((?:\\[[^\\]\r\n]*\\])+)"
                                                             options:0 error:NULL];
    });
    for (NSString *raw in [text componentsSeparatedByString:@"\n"]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceCharacterSet]];
        if (!line.length) continue;
        // QQ 正式歌词开始标识:清掉之前累积的头部行(上游同款)
        if (src == OBLyricSourceQQ &&
            ([line isEqualToString:@"[offset:0]"] || [line hasPrefix:@"[kana:"])) {
            [out removeAllObjects];
            continue;
        }
        NSTextCheckingResult *pm = [prefixRe firstMatchInString:line options:0
                                                          range:NSMakeRange(0, line.length)];
        NSMutableArray<NSNumber *> *stamps = [NSMutableArray array];
        NSString *content = line;
        if (pm && [pm rangeAtIndex:1].length > 0) {
            NSString *heads = [line substringWithRange:[pm rangeAtIndex:1]];
            content = [[line substringFromIndex:[pm rangeAtIndex:1].length]
                       stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceCharacterSet]];
            // 连续多个前缀逐个试(合法的展开成多行,元信息行走非法路径)
            static NSRegularExpression *oneRe;
            static dispatch_once_t once2;
            dispatch_once(&once2, ^{
                oneRe = [NSRegularExpression regularExpressionWithPattern:@"\\[[^\\]\r\n]*\\]"
                                                                  options:0 error:NULL];
            });
            for (NSTextCheckingResult *om in
                 [oneRe matchesInString:heads options:0 range:NSMakeRange(0, heads.length)]) {
                long ms = [self parseTimestamp:[heads substringWithRange:om.range]];
                if (ms >= 0) [stamps addObject:@(ms)];
            }
        }
        if (!stamps.count) {
            if (ignoreEmpty) continue;
            [out addObject:@{ @"ms": @(-1), @"text": @"" }];
            continue;
        }
        if (!content.length && ignoreEmpty) continue;
        for (NSNumber *ms in stamps)
            [out addObject:@{ @"ms": ms, @"text": content }];
    }
    return out;
}

#pragma mark - 译文对齐

+ (NSArray<NSDictionary *> *)alignTrans:(NSArray<NSDictionary *> *)trans
                               toOrigin:(NSArray<NSDictionary *> *)origin
                              deviation:(long)deviation
                               lostRule:(OBLyricLostRule)rule {
    // 原文 ms→行(同戳后者覆盖,与上游 Dict 语义一致)
    NSMutableDictionary<NSNumber *, NSDictionary *> *oMap = [NSMutableDictionary dictionary];
    for (NSDictionary *l in origin) {
        long ms = [l[@"ms"] longValue];
        if (ms >= 0) oMap[@(ms)] = l;
    }
    NSMutableArray<NSDictionary *> *base = [trans mutableCopy] ?: [NSMutableArray array];
    NSMutableArray<NSNumber *> *unmatched = [NSMutableArray array]; // base 下标
    for (NSUInteger i = 0; i < base.count; i++) {
        long ms = [base[i][@"ms"] longValue];
        if (oMap[@(ms)]) [oMap removeObjectForKey:@(ms)];
        else [unmatched addObject:@(i)];
    }
    // 误差窗吸附:候选窗被相邻译文行夹界,同时收敛到 ±deviation
    if (deviation > 0) {
        for (NSNumber *n in unmatched) {
            NSUInteger i = n.unsignedIntegerValue;
            if (i >= base.count) continue;
            long ts = [base[i][@"ms"] longValue];
            long lo = (i == 0) ? 0 : [base[i - 1][@"ms"] longValue] + 1;
            if (ts - deviation > lo) lo = ts - deviation;
            long hi;
            if (i == base.count - 1) {
                hi = ts;
                for (NSDictionary *l in origin) {
                    long m = [l[@"ms"] longValue];
                    if (m > hi) hi = m;
                }
            } else {
                hi = [base[i + 1][@"ms"] longValue] - 1;
            }
            if (ts + deviation < hi) hi = ts + deviation;
            for (long c = lo; c <= hi; c++) {
                if (oMap[@(c)]) {
                    [oMap removeObjectForKey:@(c)];
                    base[i] = @{ @"ms": @(c), @"text": base[i][@"text"] ?: @"" };
                    break;
                }
            }
        }
    }
    // 缺失规则:原文有而译文无的时间戳
    if (rule != OBLyricLostIgnore) {
        for (NSNumber *ms in oMap) {
            NSString *fill = (rule == OBLyricLostFillOrigin)
                ? (oMap[ms][@"text"] ?: @"") : @"";
            [base addObject:@{ @"ms": ms, @"text": fill }];
        }
    }
    [base sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        long x = [a[@"ms"] longValue], y = [b[@"ms"] longValue];
        return x < y ? NSOrderedAscending : (x > y ? NSOrderedDescending : NSOrderedSame);
    }];
    return base;
}

#pragma mark - 排版

+ (NSArray<NSDictionary *> *)renderStagger:(NSArray<NSArray<NSDictionary *> *> *)tracks {
    // K 路归并:堆太小,直接多指针线性归并(行数千级,足够)
    NSMutableArray<NSNumber *> *pos = [NSMutableArray array];
    for (NSUInteger i = 0; i < tracks.count; i++) [pos addObject:@0];
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (;;) {
        NSInteger best = -1;
        for (NSUInteger t = 0; t < tracks.count; t++) {
            NSUInteger p = pos[t].unsignedIntegerValue;
            if (p >= tracks[t].count) continue;
            if (best < 0 ||
                [tracks[t][p][@"ms"] longValue] < [tracks[best][pos[best].unsignedIntegerValue][@"ms"] longValue])
                best = (NSInteger)t;
        }
        if (best < 0) break;
        NSUInteger p = pos[best].unsignedIntegerValue;
        [out addObject:tracks[best][p]];
        pos[best] = @(p + 1);
    }
    return out;
}

+ (NSArray<NSDictionary *> *)renderMerge:(NSArray<NSArray<NSDictionary *> *> *)tracks
                               separator:(NSString *)sep {
    NSArray<NSDictionary *> *st = [self renderStagger:tracks];
    if (!st.count) return st;
    NSString *sp = sep ?: @" / ";
    NSMutableArray<NSDictionary *> *out = [NSMutableArray arrayWithObject:st[0]];
    for (NSUInteger i = 1; i < st.count; i++) {
        NSMutableDictionary *last = [out.lastObject mutableCopy];
        if ([last[@"ms"] longValue] == [st[i][@"ms"] longValue]) {
            last[@"text"] = [NSString stringWithFormat:@"%@%@%@",
                             last[@"text"] ?: @"", sp, st[i][@"text"] ?: @""];
            out[out.count - 1] = last;
        } else {
            [out addObject:st[i]];
        }
    }
    return out;
}

+ (NSArray<NSArray<NSDictionary *> *> *)renderIsolated:(NSArray<NSArray<NSDictionary *> *> *)tracks {
    return tracks ?: @[];
}

#pragma mark - 文本生成

+ (NSString *)lineString:(NSDictionary *)line {
    long ms = [line[@"ms"] longValue];
    if (ms < 0) ms = 0;
    long mm = ms / 60000, ss = (ms % 60000) / 1000, cc = (ms % 1000) / 10;
    return [NSString stringWithFormat:@"[%02ld:%02ld.%02ld]%@",
            mm, ss, cc, line[@"text"] ?: @""];
}

+ (NSString *)lrcString:(NSArray<NSDictionary *> *)lines {
    NSMutableArray<NSString *> *rows = [NSMutableArray arrayWithCapacity:lines.count];
    for (NSDictionary *l in lines) [rows addObject:[self lineString:l]];
    return [rows componentsJoinedByString:@"\n"];
}

+ (NSString *)srtString:(NSArray<NSDictionary *> *)lines durationMs:(long)durationMs {
    if (!lines.count) return @"";
    long tail = durationMs > 0 ? durationMs :
        ([lines.lastObject[@"ms"] longValue] + 3000);
    NSMutableString *sb = [NSMutableString string];
    NSUInteger i = 0, n = lines.count;
    __block long idx = 1;
    void (^emit)(long, long, NSString *) = ^(long s, long e, NSString *t) {
        [sb appendFormat:@"%ld\n%@ --> %@\n%@\n\n", idx++, SrtTS(s), SrtTS(e), t ?: @""];
    };
    if (n == 1) {
        emit([lines[0][@"ms"] longValue], tail, lines[0][@"text"]);
        return sb;
    }
    while (i < n - 1) {
        long a = [lines[i][@"ms"] longValue], b = [lines[i + 1][@"ms"] longValue];
        if (a > b) {
            emit(a, tail, lines[i][@"text"]);   // 乱序行直封尾(上游同款)
            i++;
        } else if (a == b) {
            // 同戳块:找块后第一个更大戳做共同结束,块内逐行展开
            NSUInteger j = i + 1;
            while (j < n && [lines[j][@"ms"] longValue] == a) j++;
            long end = tail;
            if (j < n && [lines[j][@"ms"] longValue] > a) end = [lines[j][@"ms"] longValue];
            while (i < j) {
                emit(a, end, lines[i][@"text"]);
                i++;
            }
        } else {
            emit(a, b, lines[i][@"text"]);
            i++;
        }
    }
    if (i < n) emit([lines[i][@"ms"] longValue], tail, lines[i][@"text"]);
    return sb;
}

+ (NSArray<NSDictionary *> *)parseSRT:(NSString *)text {
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    if (!text.length) return out;
    static NSRegularExpression *tsRe;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tsRe = [NSRegularExpression regularExpressionWithPattern:
                @"(\\d{1,2}):(\\d{2}):(\\d{2})[,.](\\d{1,3})" options:0 error:NULL];
    });
    NSString *norm = [[text stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
                      stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];
    for (NSString *blk in [norm componentsSeparatedByString:@"\n\n"]) {
        NSMutableArray<NSString *> *rows = [NSMutableArray array];
        for (NSString *r in [blk componentsSeparatedByString:@"\n"]) {
            NSString *t = [r stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceCharacterSet]];
            if (t.length) [rows addObject:t];
        }
        if (rows.count < 2) continue;
        NSUInteger ri = [rows[0] containsString:@"-->"] ? 0 : 1;
        if (ri >= rows.count || ![rows[ri] containsString:@"-->"]) continue;
        NSArray<NSString *> *rg = [rows[ri] componentsSeparatedByString:@"-->"];
        if (rg.count != 2) continue;
        NSTextCheckingResult *m = [tsRe firstMatchInString:rg[0] options:0
                                                     range:NSMakeRange(0, [rg[0] length])];
        if (!m) continue;
        long h = (long)[rg[0] substringWithRange:[m rangeAtIndex:1]].longLongValue;
        long mm = (long)[rg[0] substringWithRange:[m rangeAtIndex:2]].longLongValue;
        long ss = (long)[rg[0] substringWithRange:[m rangeAtIndex:3]].longLongValue;
        NSString *f = [rg[0] substringWithRange:[m rangeAtIndex:4]];
        long frac = f.length == 1 ? (long)f.longLongValue * 100 :
            (f.length == 2 ? (long)f.longLongValue * 10 : (long)[[f substringToIndex:3] longLongValue]);
        long start = ((h * 3600 + mm * 60 + ss) * 1000) + frac;
        NSString *content = [[[rows subarrayWithRange:NSMakeRange(ri + 1, rows.count - ri - 1)]
                              componentsJoinedByString:@" "]
                             stringByTrimmingCharactersInSet:
                             [NSCharacterSet whitespaceCharacterSet]];
        [out addObject:@{ @"ms": @(start), @"text": content }];
    }
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        long x = [a[@"ms"] longValue], y = [b[@"ms"] longValue];
        return x < y ? NSOrderedAscending : (x > y ? NSOrderedDescending : NSOrderedSame);
    }];
    return out;
}

#pragma mark - 文件

+ (nullable NSDictionary *)readFile:(NSString *)path error:(NSString **)err {
    NSData *d = [[NSData alloc] initWithContentsOfFile:path];
    if (!d) { if (err) *err = @"读文件失败"; return nil; }
    const uint8_t *b = d.bytes;
    NSUInteger n = d.length, off = 0;
    NSString *enc = nil;
    NSString *s = nil;
    if (n >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) { off = 3; enc = @"UTF-8"; }
    else if (n >= 2 && b[0] == 0xFF && b[1] == 0xFE) { off = 2; enc = @"UTF-16LE"; }
    else if (n >= 2 && b[0] == 0xFE && b[1] == 0xFF) { off = 2; enc = @"UTF-16BE"; }
    NSData *body = off ? [d subdataWithRange:NSMakeRange(off, n - off)] : d;
    if (enc) {
        NSStringEncoding e = [enc isEqualToString:@"UTF-8"] ? NSUTF8StringEncoding :
            ([enc isEqualToString:@"UTF-16LE"] ? NSUTF16LittleEndianStringEncoding :
             NSUTF16BigEndianStringEncoding);
        s = [[NSString alloc] initWithData:body encoding:e];
    } else {
        // 无 BOM:UTF-8 严格试探 → GB18030 回退(中文站歌词常见)
        s = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        enc = @"UTF-8";
        if (!s) {
            NSStringEncoding gb = CFStringConvertEncodingToNSStringEncoding(
                kCFStringEncodingGB_18030_2000);
            s = [[NSString alloc] initWithData:body encoding:gb];
            enc = @"GB18030";
        }
    }
    if (!s) { if (err) *err = @"编码识别失败"; return nil; }
    return @{ @"text": s, @"encoding": enc ?: @"UTF-8" };
}

+ (BOOL)writeFile:(NSString *)text to:(NSString *)path encoding:(NSString *)enc
            error:(NSString **)err {
    NSStringEncoding e = NSUTF8StringEncoding;
    NSMutableData *d = [NSMutableData data];
    if ([enc isEqualToString:@"UTF-16"]) {
        uint8_t bom[2] = { 0xFF, 0xFE };
        [d appendBytes:bom length:2];
        e = NSUTF16LittleEndianStringEncoding;
    } else if ([enc isEqualToString:@"GB18030"]) {
        e = CFStringConvertEncodingToNSStringEncoding(kCFStringEncodingGB_18030_2000);
    }
    NSData *body = [text dataUsingEncoding:e allowLossyConversion:NO];
    if (!body) {
        // 有损兜底(生僻字在目标编码不存在时)
        body = [text dataUsingEncoding:e allowLossyConversion:YES];
    }
    if (!body) { if (err) *err = @"编码失败"; return NO; }
    [d appendData:body];
    if (![d writeToFile:path atomically:YES]) { if (err) *err = @"写文件失败"; return NO; }
    return YES;
}

@end
