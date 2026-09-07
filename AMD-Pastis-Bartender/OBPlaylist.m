#import "OBPlaylist.h"
#import "OBStrings.h"

@implementation OBPlaylist

+ (nullable NSDictionary *)pickVariantOfMaster:(NSString *)masterText
                                       baseUrl:(NSString *)baseUrl
                                         error:(NSString * _Nullable * _Nullable)err {
    NSArray *lines = [masterText componentsSeparatedByString:@"\n"];
    NSMutableArray<NSDictionary *> *variants = [NSMutableArray array];
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *ln = lines[i];
        if (![ln containsString:@"CODECS="]) continue;
        NSString *codec = @"";
        NSRange cr = [ln rangeOfString:@"CODECS=\""];
        if (cr.location != NSNotFound) {
            NSUInteger s = cr.location + cr.length;
            NSRange e = [ln rangeOfString:@"\"" options:0 range:NSMakeRange(s, ln.length - s)];
            if (e.location != NSNotFound) codec = [ln substringWithRange:NSMakeRange(s, e.location - s)];
        }
        NSString *uri = nil;
        for (NSUInteger j = i + 1; j < lines.count; j++) {
            NSString *l2 = lines[j];
            if (l2.length && ![l2 hasPrefix:@"#"]) { uri = l2; break; }
        }
        if (!uri) continue;
        NSString *abs = [uri hasPrefix:@"http"] ? uri
            : [NSString stringWithFormat:@"%@/%@", baseUrl, uri];
        int bw = 0;
        NSRange br = [ln rangeOfString:@"BANDWIDTH="];
        if (br.location != NSNotFound) {
            NSUInteger s = br.location + br.length, k = s;
            while (k < ln.length && isdigit((int)[ln characterAtIndex:k])) k++;
            if (k > s) bw = (int)[ln substringWithRange:NSMakeRange(s, k - s)].intValue;
        }
        [variants addObject:@{ @"codec": codec, @"bw": @(bw), @"url": abs }];
    }
    if (!variants.count) { if (err) *err = @"母清单无可用变体"; return nil; }
    for (NSDictionary *v in variants)
        if ([[v[@"codec"] lowercaseString] containsString:@"alac"]) return @{ @"url": v[@"url"], @"codec": @"alac" };
    for (NSDictionary *v in variants)
        if ([[v[@"codec"] lowercaseString] containsString:@"ec-3"]) return @{ @"url": v[@"url"], @"codec": @"ec-3" };
    NSDictionary *v = variants[0];
    return @{ @"url": v[@"url"], @"codec": v[@"codec"] };
}

+ (nullable NSDictionary *)parseMedia:(NSString *)mediaText
                             mediaUrl:(NSString *)mediaUrl
                                error:(NSString * _Nullable * _Nullable)err {
    NSString *mbase = [mediaUrl substringToIndex:[mediaUrl rangeOfString:@"/" options:NSBackwardsSearch].location];
    NSArray *lines = [mediaText componentsSeparatedByString:@"\n"];
    NSMutableArray<NSDictionary *> *segments = [NSMutableArray array];
    NSString *keyUri = nil, *fname = nil;
    NSValue *pending = nil;
    NSRange initRange = NSMakeRange(0, 0);
    BOOL hasInit = NO;
    for (NSString *raw in lines) {
        NSString *ln = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([ln hasPrefix:@"#EXT-X-KEY:"] && [ln containsString:@"streamingkeydelivery"]) {
            NSRange ur = [ln rangeOfString:@"URI=\""];
            if (ur.location != NSNotFound) {
                NSUInteger s = ur.location + ur.length;
                NSRange e = [ln rangeOfString:@"\"" options:0 range:NSMakeRange(s, ln.length - s)];
                keyUri = e.location != NSNotFound ? [ln substringWithRange:NSMakeRange(s, e.location - s)] : nil;
            }
        } else if ([ln hasPrefix:@"#EXT-X-MAP:"]) {
            NSRange br = [ln rangeOfString:@"BYTERANGE=\""];
            if (br.location != NSNotFound) {
                NSUInteger s = br.location + br.length;
                NSRange e = [ln rangeOfString:@"\"" options:0 range:NSMakeRange(s, ln.length - s)];
                if (e.location != NSNotFound) {
                    NSString *spec = [ln substringWithRange:NSMakeRange(s, e.location - s)];
                    NSArray *parts = [spec componentsSeparatedByString:@"@"];
                    if (parts.count == 2) {
                        initRange = NSMakeRange([parts[1] intValue], [parts[0] intValue]);
                        hasInit = YES;
                    }
                }
            }
        } else if ([ln hasPrefix:@"#EXT-X-BYTERANGE:"]) {
            NSString *spec = [ln substringFromIndex:@"#EXT-X-BYTERANGE:".length];
            NSArray *parts = [spec componentsSeparatedByString:@"@"];
            if (parts.count == 2) pending = [NSValue valueWithRange:NSMakeRange([parts[1] intValue], [parts[0] intValue])];
        } else if (ln.length && ![ln hasPrefix:@"#"]) {
            if (!fname) fname = ln;
            if (pending) {
                [segments addObject:@{ @"key": keyUri ?: [NSNull null], @"loc": pending }];
                pending = nil;
            }
        }
    }
    if (!fname || !hasInit || !segments.count) {
        if (err) *err = [NSString stringWithFormat:@"媒体清单解析失败 fname=%@ init=%d segs=%lu",
                         fname ?: @"?", hasInit, (unsigned long)segments.count];
        return nil;
    }
    NSString *url = [fname hasPrefix:@"http"] ? fname
        : [NSString stringWithFormat:@"%@/%@", mbase, fname];
    return @{ @"url": url,
              @"initLoc": [NSValue valueWithRange:initRange],
              @"segments": segments };
}

+ (NSString *)normKeyUri:(NSString * _Nullable)u {
    if (!u.length) return @"";
    NSString *s = [u lowercaseString];
    NSString *full = OB_SKD_PREFIX;                 // 敏感前缀走 OB 池
    if ([s hasPrefix:full]) return [s substringFromIndex:full.length];
    if ([s hasPrefix:@"skd://"]) return [s substringFromIndex:6];
    return s;
}

@end
