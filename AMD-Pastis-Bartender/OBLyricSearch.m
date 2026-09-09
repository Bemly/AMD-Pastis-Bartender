#import "OBLyricSearch.h"
#import "OBHttp.h"
#import "OBStrings.h"

static void Logf(void (^logf)(NSString *), NSString *fmt, ...) {
    if (!logf) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    logf(s);
}

static NSString *EncQ(NSString *s) {
    // URLQueryAllowedCharacterSet 会放过 &(+/=?),文件名里常见,直接拼 URL 会被截断查询词
    static NSCharacterSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *m = [[NSCharacterSet URLQueryAllowedCharacterSet] mutableCopy];
        [m removeCharactersInString:@"&+=?"];
        set = m;
    });
    return [s stringByAddingPercentEncodingWithAllowedCharacters:set] ?: @"";
}

static NSString *JoinNames(NSArray *arr, NSString *key) {
    NSMutableArray *ns = [NSMutableArray array];
    for (NSDictionary *d in arr) {
        NSString *n = [d isKindOfClass:[NSDictionary class]] ? d[key] : nil;
        if ([n isKindOfClass:[NSString class]] && n.length) [ns addObject:n];
    }
    return [ns componentsJoinedByString:@" / "];
}

@implementation OBLyricSearch

static NSCache *gMem;

+ (void)initialize {
    if (self == [OBLyricSearch class]) gMem = [NSCache new];
}

#pragma mark - 缓存

+ (NSString *)cacheDir {
    NSArray *cs = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *base = cs.firstObject ?: NSTemporaryDirectory();
    NSString *d = [[base stringByAppendingPathComponent:@"AMD-Pastis-Bartender"]
                   stringByAppendingPathComponent:@"lyric"];
    [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES
                                                attributes:nil error:NULL];
    return d;
}

+ (NSString *)cacheKeyForSong:(NSDictionary *)song {
    return [NSString stringWithFormat:@"%@_%@", song[@"source"] ?: @"?", song[@"songId"] ?: @"?"];
}

+ (nullable NSDictionary *)cacheGet:(NSDictionary *)song {
    NSString *k = [self cacheKeyForSong:song];
    NSDictionary *hit = [gMem objectForKey:k];
    if (hit) return hit;
    NSData *d = [[NSData alloc] initWithContentsOfFile:[[self cacheDir] stringByAppendingPathComponent:k]];
    hit = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
    if ([hit isKindOfClass:[NSDictionary class]]) {
        [gMem setObject:hit forKey:k];
        return hit;
    }
    return nil;
}

+ (void)cachePut:(NSDictionary *)song lyric:(NSDictionary *)lyric {
    NSString *k = [self cacheKeyForSong:song];
    NSMutableDictionary *v = [NSMutableDictionary dictionary];
    v[@"song"] = song;
    v[@"lyric"] = lyric;
    [gMem setObject:v forKey:k];
    NSData *d = [NSJSONSerialization dataWithJSONObject:v options:0 error:NULL];
    [d writeToFile:[[self cacheDir] stringByAppendingPathComponent:k] atomically:YES];
}

+ (void)clearCache {
    [gMem removeAllObjects];
    [[NSFileManager defaultManager] removeItemAtPath:[self cacheDir] error:NULL];
}

#pragma mark - 网易云(明文端点)

+ (NSArray<NSDictionary *> *)searchNE:(NSString *)keyword
                                limit:(NSInteger)limit
                                error:(NSString **)err {
    NSString *url = [NSString stringWithFormat:@"https://%@/api/search/get/web?s=%@&type=1&limit=%ld",
                     OB_LY_HOST_NE, EncQ(keyword), (long)MAX(1, limit)];
    NSString *e = nil;
    NSData *d = [OBHttp get:url header:@"Referer"
                       value:[NSString stringWithFormat:@"https://%@/", OB_LY_HOST_NE]
                     timeout:20 error:&e];
    if (!d) { if (err) *err = e; return @[]; }
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    // code 非 200(如 405 操作频繁)要把服务端原话带出来,别吞成"无结果"(限流退避就靠它识别)
    if ([j[@"code"] longValue] != 200) {
        if (err) *err = [NSString stringWithFormat:@"%@(%@)",
                         j[@"msg"] ?: (j[@"message"] ?: @"拒绝"), j[@"code"] ?: @"?"];
        return @[];
    }
    NSArray *songs = j[@"result"][@"songs"];
    if (![songs isKindOfClass:[NSArray class]]) { if (err) *err = @"无结果"; return @[]; }
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *s in songs) {
        if (![s isKindOfClass:[NSDictionary class]]) continue;
        [out addObject:@{
            @"source": @"ne", @"sourceName": @"网易云",
            @"songId": [s[@"id"] description] ?: @"",
            @"name": s[@"name"] ?: @"",
            @"singer": JoinNames(s[@"artists"], @"name"),
            @"album": s[@"album"][@"name"] ?: @"",
            @"duration": s[@"duration"] ?: @0,
        }];
        if (out.count >= limit) break;
    }
    return out;
}

+ (nullable NSDictionary *)lyricNE:(NSString *)songId error:(NSString **)err {
    NSString *url = [NSString stringWithFormat:@"https://%@/api/song/lyric?id=%@&lv=1&tv=-1",
                     OB_LY_HOST_NE, EncQ(songId)];
    NSString *e = nil;
    NSData *d = [OBHttp get:url header:@"Referer"
                       value:[NSString stringWithFormat:@"https://%@/", OB_LY_HOST_NE]
                     timeout:20 error:&e];
    if (!d) { if (err) *err = e; return nil; }
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    NSString *lrc = j[@"lrc"][@"lyric"];
    if (![lrc isKindOfClass:[NSString class]] || !lrc.length) {
        if (err) *err = @"该曲无词";
        return nil;
    }
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"source"] = @"ne";
    out[@"lyric"] = lrc;
    NSString *tr = j[@"tlyric"][@"lyric"];
    if ([tr isKindOfClass:[NSString class]] && tr.length) out[@"trans"] = tr;
    NSString *roma = j[@"romalrc"][@"lyric"] ?: j[@"roma"][@"lyric"];
    if ([roma isKindOfClass:[NSString class]] && roma.length) out[@"roma"] = roma;
    return out;
}

#pragma mark - QQ(musicu.fcg 搜索 + 取词)

+ (NSArray<NSDictionary *> *)searchQQ:(NSString *)keyword
                                limit:(NSInteger)limit
                                error:(NSString **)err {
    NSDictionary *body = @{ @"req_1": @{
        @"method": @"DoSearchForQQMusicDesktop",
        @"module": @"music.search.SearchCgiService",
        @"param": @{
            @"num_per_page": [NSString stringWithFormat:@"%ld", (long)MAX(1, limit)],
            @"page_num": @"1", @"query": keyword, @"search_type": @0,
        } } };
    NSData *bd = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    NSString *url = [NSString stringWithFormat:@"https://%@/cgi-bin/musicu.fcg", OB_LY_HOST_QQU];
    NSString *e = nil;
    NSData *d = [OBHttp post:url body:bd contentType:@"application/json"
                      header:@"Referer"
                       value:[NSString stringWithFormat:@"https://%@/", OB_LY_HOST_QQ]
                     timeout:20 error:&e];
    if (!d) { if (err) *err = e; return @[]; }
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    NSArray *list = j[@"req_1"][@"data"][@"body"][@"song"][@"list"];
    if (![list isKindOfClass:[NSArray class]] || !list.count) {
        if (err) *err = @"无结果(QQ 可能不可达)";
        return @[];
    }
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *s in list) {
        if (![s isKindOfClass:[NSDictionary class]] || ![s[@"mid"] length]) continue;
        long sec = [s[@"interval"] longValue];
        [out addObject:@{
            @"source": @"qq", @"sourceName": @"QQ音乐",
            @"songId": s[@"mid"],
            @"name": s[@"name"] ?: @"",
            @"singer": JoinNames(s[@"singer"], @"name"),
            @"album": s[@"album"][@"name"] ?: @"",
            @"duration": @(sec * 1000),
        }];
        if (out.count >= limit) break;
    }
    return out;
}

+ (nullable NSDictionary *)lyricQQ:(NSString *)mid error:(NSString **)err {
    NSString *url = [NSString stringWithFormat:
        @"https://%@/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=%@&g_tk=5381&format=json&songtype=0",
        OB_LY_HOST_QQ, EncQ(mid)];
    NSString *e = nil;
    NSData *d = [OBHttp get:url header:@"Referer"
                       value:[NSString stringWithFormat:@"https://%@/", OB_LY_HOST_QQ]
                     timeout:20 error:&e];
    if (!d) { if (err) *err = e; return nil; }
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    if ([j[@"retcode"] longValue] != 0 && [j[@"code"] longValue] != 0) {
        if (err) *err = @"取词被拒";
        return nil;
    }
    NSString *b64 = j[@"lyric"];
    if (![b64 isKindOfClass:[NSString class]] || !b64.length) {
        if (err) *err = @"该曲无词";
        return nil;
    }
    NSData *raw = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
    NSString *lrc = raw ? [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding] : nil;
    if (!lrc.length) { if (err) *err = @"解码失败"; return nil; }
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    out[@"source"] = @"qq";
    out[@"lyric"] = lrc;
    NSString *tb = j[@"trans"];
    if ([tb isKindOfClass:[NSString class]] && tb.length) {
        NSData *tr = [[NSData alloc] initWithBase64EncodedString:tb options:0];
        NSString *trs = tr ? [[NSString alloc] initWithData:tr encoding:NSUTF8StringEncoding] : nil;
        if (trs.length) out[@"trans"] = trs;
    }
    return out;
}

#pragma mark - 对外

+ (NSArray<NSDictionary *> *)search:(NSString *)keyword
                              limit:(NSInteger)limit
                            sources:(NSArray<NSString *> *)sources
                               logf:(void (^)(NSString *))logf
                              error:(NSString **)err {
    NSString *kw = [keyword stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!kw.length) { if (err) *err = @"先填关键词"; return @[]; }
    BOOL wantNE = !sources || [sources containsObject:@"ne"];
    BOOL wantQQ = !sources || [sources containsObject:@"qq"];
    NSMutableArray *out = [NSMutableArray array];
    NSString *lastErr = nil, *limitedErr = nil;
    if (wantNE) {
        NSString *e = nil;
        NSArray *r = [self searchNE:kw limit:limit error:&e];
        Logf(logf, @"[*] 网易云: %lu 条%@", (unsigned long)r.count, e ? [NSString stringWithFormat:@"(%@)", e] : @"");
        [out addObjectsFromArray:r];
        if (e) {
            lastErr = e;
            if ([e containsString:@"操作频繁"] || [e containsString:@"HTTP"] ||
                [e containsString:@"429"] || [e containsString:@"405"]) limitedErr = e;
        }
    }
    if (wantQQ) {
        NSString *e = nil;
        NSArray *r = [self searchQQ:kw limit:limit error:&e];
        Logf(logf, @"[*] QQ音乐: %lu 条%@", (unsigned long)r.count, e ? [NSString stringWithFormat:@"(%@)", e] : @"");
        [out addObjectsFromArray:r];
        if (e) {
            lastErr = e;
            if ([e containsString:@"操作频繁"] || [e containsString:@"HTTP"] ||
                [e containsString:@"429"] || [e containsString:@"405"]) limitedErr = e;
        }
    }
    // 合并 error 时限流优先(调用方退避就靠它识别;否则会被后跑的源覆盖)
    if (!out.count && err) *err = limitedErr ?: lastErr ?: @"两源均无结果";
    return out;
}

+ (nullable NSDictionary *)lyricFor:(NSDictionary *)song
                               logf:(void (^)(NSString *))logf
                              error:(NSString **)err {
    NSDictionary *hit = [self cacheGet:song];
    if (hit) {
        Logf(logf, @"[=] 词缓存命中 %@_%@", song[@"source"], song[@"songId"]);
        return hit[@"lyric"];
    }
    NSString *src = song[@"source"], *sid = song[@"songId"];
    if (![sid length]) { if (err) *err = @"曲目 id 缺失"; return nil; }
    NSString *e = nil;
    NSDictionary *ly = nil;
    if ([src isEqualToString:@"qq"]) ly = [self lyricQQ:sid error:&e];
    else ly = [self lyricNE:sid error:&e];
    if (!ly) { if (err) *err = e; return nil; }
    [self cachePut:song lyric:ly];
    Logf(logf, @"[+] 取词 %@_%@ 原文 %lu 字%@",
         src, sid, (unsigned long)[ly[@"lyric"] length],
         ly[@"trans"] ? @"(含译文)" : @"(无译文)");
    return ly;
}

@end
