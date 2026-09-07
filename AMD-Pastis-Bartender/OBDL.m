#import "OBDL.h"
#import "OBLink.h"
#import "OBScript.h"
#import "OBHttp.h"
#import "OBPlaylist.h"
#import "OBMP4.h"
#import "OBADB.h"
#import "mac-dual-pipe.h"
#import "AMDConfig.h"
#import "OBStrings.h"
#import "AMDDebug.h"
#import "TaskRunner.h"

// 磁盘元数据路径(扩展名走 OB 池)
static NSString *MetaPath(NSString *base, NSString *name) {
    return [NSString stringWithFormat:@"%@/%@%@", base, name, OB_META_EXT];
}

static NSString *SafeName(NSString *s) {
    NSString *r = [s stringByReplacingOccurrencesOfString:@"[\\\\/:*?\"<>|\\n\\r\\t]+"
                                               withString:@"_"
                                                  options:NSRegularExpressionSearch
                                                    range:NSMakeRange(0, s.length)];
    r = [r stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (r.length > 120) r = [r substringToIndex:120];
    return r;
}

static NSString *Hex(const uint8_t *b, unsigned n) {
    NSMutableString *s = [NSMutableString stringWithCapacity:n * 2];
    for (unsigned i = 0; i < n; i++) [s appendFormat:@"%02x", b[i]];
    return s;
}

// 批量上限:引擎通道单包密文 1.5MB(b64 后约 2MB);直传纯二进制无编码开销,单请求 8MB
static const NSUInteger kRpcBatchCap = 1500000;
static const NSUInteger kTcpBatchCap = 8000000;

@implementation OBDLJob

+ (void)logf:(void (^)(NSString *))f fmt:(NSString *)fmt, ... NS_FORMAT_FUNCTION(2, 3) {
    if (!f) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    f(s);
}

#pragma mark - 曲库元数据

+ (nullable NSDictionary *)lookupMeta:(NSString *)adam error:(NSString * _Nullable * _Nullable)err {
    for (NSString *cc in @[@"cn", @"jp", @"us"]) {
        NSString *url = [NSString stringWithFormat:@"https://%@/lookup?id=%@&entity=song&country=%@",
                         OB_STORE_HOST, adam, cc];
        NSData *d = [OBHttp get:url error:nil];
        NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
        if (![j[@"resultCount"] unsignedIntegerValue]) continue;
        NSDictionary *r = j[@"results"][0];
        NSMutableDictionary *meta = [NSMutableDictionary dictionary];
        meta[@"artist"] = r[@"artistName"] ?: @"";
        meta[@"title"] = r[@"trackName"] ?: [NSString stringWithFormat:@"track_%@", adam];
        meta[@"album"] = r[@"collectionName"] ?: @"";
        NSString *rd = r[@"releaseDate"] ?: @"";
        meta[@"date"] = [rd substringToIndex:MIN(10, rd.length)];
        meta[@"genre"] = r[@"primaryGenreName"] ?: @"";
        meta[@"track"] = r[@"trackNumber"] ?: @0;
        meta[@"track_total"] = r[@"track" @"Cou" @"nt"] ?: @0;
        meta[@"disc"] = r[@"discNumber"] ?: @0;
        meta[@"copyright"] = r[@"copyright"] ?: @"";
        meta[@"artwork"] = [(r[@"artworkUrl100"] ?: @"") stringByReplacingOccurrencesOfString:@"100x100bb"
                                                                                   withString:@"1000x1000bb"];
        // 单曲 lookup 常缺版权字段 → 专辑 lookup 兜底
        if ([meta[@"copyright"] length] == 0 && [r[@"collectionId"] intValue]) {
            NSString *u2 = [NSString stringWithFormat:@"https://%@/lookup?id=%@&entity=album&country=%@",
                            OB_STORE_HOST, r[@"collectionId"], cc];
            NSData *d2 = [OBHttp get:u2 error:nil];
            NSDictionary *j2 = d2 ? [NSJSONSerialization JSONObjectWithData:d2 options:0 error:NULL] : nil;
            if (j2[@"results"][0][@"copyright"]) meta[@"copyright"] = j2[@"results"][0][@"copyright"];
        }
        return meta;
    }
    if (err) *err = @"曲库三区均未命中";
    return @{};
}

#pragma mark - RPC 批量解密

// 一次 decmany;失败重连一次再试。返回明文数组(nil=失败)。
+ (nullable NSArray<NSData *> *)decMany:(OBLink *)link
                           scriptReload:(BOOL *)needReload
                                    key:(NSString *)key
                                     pt:(int)pt
                                   flag:(BOOL)flag
                                constIv:(NSString *)constIv
                                batchCt:(NSData *)batchCt
                              batchLens:(NSArray<NSNumber *> *)lens
                                   logf:(void (^)(NSString *))f
                                  error:(NSString * _Nullable * _Nullable)err {
    (void)needReload;
    for (NSInteger attempt = 0; attempt < 2; attempt++) {
        if (attempt == 1) {
            [self logf:f fmt:@"[!] 批量解密失败,重连引擎…"];
            [link disconnect];
            NSString *cerr = nil;
            if (![link connectToProcess:OB_PROC_NAME error:&cerr] ||
                ![link loadScriptSource:[OBScript agentSource] error:&cerr]) {
                if (err) *err = cerr;
                return nil;
            }
            [link rpc:@"refresh" args:nil data:nil timeout:10 error:nil];
        }
        NSString *resp = [link rpc:@"decmany"
                              args:@{ @"key": key, @"pt": @(pt), @"flag": @(flag),
                                      @"ivB64": constIv,
                                      @"ctB64": [batchCt base64EncodedStringWithOptions:0],
                                      @"lens": lens }
                             data:nil timeout:180 error:nil];
        if (!resp) continue;
        NSDictionary *root = [NSJSONSerialization JSONObjectWithData:[resp dataUsingEncoding:NSUTF8StringEncoding]
                                                             options:0 error:NULL];
        NSDictionary *p = root[@"payload"];
        if (![p[@"ok"] boolValue]) {
            [self logf:f fmt:@"[!] RPC 错误: %@", p[@"error"] ?: @"?"];
            continue;
        }
        NSArray *list = p[@"list"];
        if (list.count != lens.count) {
            if (err) *err = @"应答包数不齐";
            return nil;
        }
        NSMutableArray<NSData *> *out = [NSMutableArray arrayWithCapacity:list.count];
        for (NSString *b in list) {
            NSData *plain = [[NSData alloc] initWithBase64EncodedString:b options:0];
            [out addObject:plain ?: [NSData data]];
        }
        return out;
    }
    if (err) *err = @"批量解密失败(含重连重试)";
    return nil;
}

// 收尾:先关直传服务(tcpStop,让手机端线程自己退出),再断引擎连接。dual 幂等,nil 即直断。
+ (void)endLink:(OBLink *)link dual:(MDPDual *)dual {
    if (dual) [dual close];
    [link disconnect];
}

// 按配置建直传双链;失败/关闭不拦路(回退引擎通道),调用方判 nil 即可。
// 环境粘合全在这里(控制映射/adb 转发/LAN 探测),库内只剩 socket 与调度。
+ (nullable MDPDual *)buildDual:(OBLink *)link logf:(void (^)(NSString *))f {
    AMDConfig *c = [AMDConfig shared];
    if (!c.useTcp) return nil;
    MDPConfig *cfg = [MDPConfig new];
    int base = c.tcpPort.intValue;
    cfg.basePort = (base > 0 && base <= 65530) ? base : 17001;
    cfg.lanIp = c.lanIp.length ? c.lanIp : [self detectLanIp];
    cfg.expectedGen = @"A7";
    cfg.control = ^NSDictionary *(NSString *op, NSDictionary *args, NSTimeInterval t, NSString **e) {
        NSString *rop = op;
        NSDictionary *rargs = args;
        if ([op isEqualToString:@"start"]) {
            rop = @"tcpStart";
            NSMutableDictionary *a = [args mutableCopy] ?: [NSMutableDictionary dictionary];
            a[@"ctxId"] = @0;   // 沿用 refresh 已拿到的上下文
            rargs = a;
        } else if ([op isEqualToString:@"stop"]) {
            rop = @"tcpStop";
            rargs = nil;
        }
        NSString *resp = [link rpc:rop args:rargs data:nil timeout:t error:e];
        if (!resp) return nil;
        NSDictionary *root = [NSJSONSerialization JSONObjectWithData:[resp dataUsingEncoding:NSUTF8StringEncoding]
                                                             options:0 error:NULL];
        return root[@"payload"];
    };
    cfg.ensureForward = ^BOOL (int port, NSString **e) { return [self ensureForward:port error:e]; };
    cfg.log = f;
    NSString *e = nil;
    MDPDual *d = [MDPDual buildWithConfig:cfg error:&e];
    if (!d) [self logf:f fmt:@"[!] 直传不可用,回退引擎通道: %@", e ?: @"?"];
    return d;
}

// 本地转发:本地端口被旧映射占着(指到别处)会连到旧实例→先清掉(串台教训)
+ (BOOL)ensureForward:(int)p1 error:(NSString **)err {
    NSString *want = [NSString stringWithFormat:@"tcp:%d", p1];
    NSString *list = [OBADB shellRetry:@[@"forward", @"--list"] timeout:15 error:nil];
    BOOL exact = NO;
    NSMutableArray<NSString *> *stale = [NSMutableArray array];
    for (NSString *ln in [list componentsSeparatedByString:@"\n"]) {
        NSArray *f = [ln componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSMutableArray *t = [NSMutableArray array];
        for (NSString *x in f) if (x.length) [t addObject:x];
        if (t.count < 3) continue;
        if ([t[1] isEqualToString:want]) {
            if ([t[2] isEqualToString:want]) exact = YES;
            else [stale addObject:t[1]];
        }
    }
    for (NSString *s in stale)
        [OBADB shellRetry:@[@"forward", @"--remove", s] timeout:15 error:nil];
    if (!exact) {
        NSString *fe = nil;
        [OBADB shellRetry:@[@"forward", want, want] timeout:15 error:&fe];
        if (fe) { if (err) *err = [NSString stringWithFormat:@"forward: %@", fe]; return NO; }
    }
    return YES;
}

// 手机无线地址:直连无线链路用(取不到则只用有线)
+ (nullable NSString *)detectLanIp {
    NSString *out = [OBADB shellRetry:@[@"shell", @"ip -o -4 addr show wlan0"] timeout:15 error:nil];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"inet ([0-9.]+)/"
                                                                        options:0 error:NULL];
    NSTextCheckingResult *m = [re firstMatchInString:out options:0 range:NSMakeRange(0, out.length)];
    if (m && m.numberOfRanges >= 2) return [out substringWithRange:[m rangeAtIndex:1]];
    NSString *g = [[OBADB shellRetry:@[@"shell", @"getprop dhcp.wlan0.ipaddress"] timeout:15 error:nil]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *first = [g componentsSeparatedByString:@"\n"][0];
    if (first.length >= 7 && [first rangeOfString:@"."].location != NSNotFound) return first;
    return nil;
}

// 引擎通道批量解密(直传兜底用):按 1.5MB 再拆包,逐包调 decMany
+ (nullable NSArray<NSData *> *)rpcDecryptBatch:(NSArray<NSData *> *)batch
                                           link:(OBLink *)link
                                            key:(NSString *)key
                                             pt:(int)pt
                                           flag:(BOOL)flag
                                        constIv:(NSString *)constIv
                                           logf:(void (^)(NSString *))f
                                          error:(NSString **)err {
    NSMutableArray<NSData *> *all = [NSMutableArray arrayWithCapacity:batch.count];
    NSMutableArray<NSData *> *grp = [NSMutableArray array];
    NSMutableArray<NSNumber *> *lens = [NSMutableArray array];
    NSMutableData *ct = [NSMutableData data];
    NSUInteger size = 0;
    for (NSData *one in batch) {
        if (size + one.length >= kRpcBatchCap && grp.count) {
            NSArray<NSData *> *pl = [self decMany:link scriptReload:NULL key:key pt:pt flag:flag
                                          constIv:constIv batchCt:ct batchLens:lens logf:f error:err];
            if (!pl) return nil;
            [all addObjectsFromArray:pl];
            grp = [NSMutableArray array]; lens = [NSMutableArray array];
            ct = [NSMutableData data]; size = 0;
        }
        [grp addObject:one]; [lens addObject:@(one.length)]; [ct appendData:one];
        size += one.length;
    }
    if (grp.count) {
        NSArray<NSData *> *pl = [self decMany:link scriptReload:NULL key:key pt:pt flag:flag
                                      constIv:constIv batchCt:ct batchLens:lens logf:f error:err];
        if (!pl) return nil;
        [all addObjectsFromArray:pl];
    }
    return all;
}

#pragma mark - 单碎片处理

// 返回 nil=成功;非 nil=错误信息
+ (NSString *)runFragment:(uint32_t)fragIdx
                      data:(const uint8_t *)fileBuf
                    moofOff:(uint32_t)moofOff moofLen:(uint32_t)moofLen
                    mdatOff:(uint32_t)mdatOff mdatLen:(uint32_t)mdatLen
                       prot:(OBProtBox *)prot keyMap:(NSDictionary<NSString *, NSArray *> *)keyMap
                   segments:(NSArray *)segments prefetchPart:(NSString *)prefetchPart
                    constIv:(NSString *)constIv link:(OBLink *)link dual:(MDPDual *)dual
                     result:(NSMutableData *)result
                     sOff:(uint32_t *)sOff sSize:(uint32_t *)sSize
                    sSubN:(unsigned *)sSubN sSubOff:(unsigned *)sSubOff
                    subBuf:(uint32_t *)subBuf spliceBuf:(uint32_t *)spliceBuf
                     logf:(void (^)(NSString *))logf cancel:(volatile BOOL *)cancelFlag
             totalSamples:(unsigned *)totalSamples totalBlocks:(unsigned *)totalBlocks {
    (void)spliceBuf;
    NSDictionary *seg = segments[MIN((NSUInteger)fragIdx, segments.count - 1)];
    NSString *ku = [OBPlaylist normKeyUri:(seg[@"key"] == [NSNull null] || !seg[@"key"]) ? nil : seg[@"key"]];
    if (!ku.length) ku = prefetchPart;
    NSArray *kf = keyMap[ku];
    if (!kf) return [NSString stringWithFormat:@"碎片 %u 的 keyUri %@ 无键", fragIdx, ku];

    // 直传:槽位一次登记(key 只走引擎通道,线上只走 handle);IV 转 16B 二进制
    uint32_t slot = 0;
    NSData *ivData = nil;
    if (dual) {
        NSString *se = nil;
        NSString *key = kf[2];
        NSString *fp = [NSString stringWithFormat:@"%lu|%d|%d|%@|%@",
                        (unsigned long)key.length, [kf[0] intValue], [kf[1] boolValue],
                        [key substringToIndex:MIN(24, key.length)],
                        key.length > 24 ? [key substringFromIndex:key.length - 24] : key];
        slot = [dual slotForKey:fp spec:@{ @"key": key, @"pt": kf[0], @"flag": kf[1] } error:&se];
        if (!slot) return [NSString stringWithFormat:@"碎片 %u 槽位登记失败: %@", fragIdx, se ?: @"?"];
        ivData = [[NSData alloc] initWithBase64EncodedString:constIv options:0];
        if (ivData.length != 16) return [NSString stringWithFormat:@"碎片 %u IV 非 16B", fragIdx];
    }

    NSInteger nSamples = [OBMP4 samplesInMoof:fileBuf moofLen:moofLen moofOff:moofOff mdatOff:mdatOff
                                defaultIvSize:prot->perSampleIvSize outCap:8192
                                        outOff:sOff outSize:sSize outSubN:sSubN outSubOff:sSubOff
                                        subBuf:subBuf subCap:8192];
    if (nSamples < 0) return [NSString stringWithFormat:@"碎片 %u 样本表解析失败", fragIdx];
    *totalSamples += (unsigned)nSamples;
    const uint8_t *mdat = fileBuf + mdatOff + 8;
    NSMutableData *dmd = [NSMutableData dataWithBytes:mdat length:mdatLen];

    // 组批:整碎片拼大包(直传 8MB/引擎通道 1.5MB);每项记录 (rel, sz, splice 对, 对数)
    NSUInteger batchCap = dual ? kTcpBatchCap : kRpcBatchCap;
    NSMutableArray<NSMutableDictionary *> *batchList = [NSMutableArray array];
    NSMutableDictionary *curBatch = nil;
    uint32_t curBytes = 0;
    for (NSInteger si = 0; si < nSamples; si++) {
        if (*cancelFlag) return @"已取消";
        uint32_t rel = sOff[si], sz = sSize[si];
        if ((int64_t)rel + sz > (int64_t)mdatLen)
            return [NSString stringWithFormat:@"样本越界 rel=%u sz=%u", rel, sz];
        uint32_t splice[512 * 2];
        unsigned spliceN = 0;
        NSData *ct = [OBMP4 buildSampleCt:mdat + rel len:sz
                                     subs:subBuf + (NSUInteger)sSubOff[si] * 2 subN:sSubN[si]
                                   splice:splice spliceCap:512 outN:&spliceN];
        if (!ct.length) continue;
        if (!curBatch || curBytes + ct.length >= batchCap) {
            curBatch = [NSMutableDictionary dictionary];
            curBatch[@"lens"] = [NSMutableArray array];
            curBatch[@"ct"] = [NSMutableData data];
            curBatch[@"parts"] = [NSMutableArray array];
            curBatch[@"items"] = [NSMutableArray array];
            curBytes = 0;
            [batchList addObject:curBatch];
        }
        [(NSMutableData *)curBatch[@"ct"] appendData:ct];
        [(NSMutableArray *)curBatch[@"lens"] addObject:@(ct.length)];
        [(NSMutableArray *)curBatch[@"parts"] addObject:ct];
        [curBatch[@"items"] addObject:@{
            @"rel": @(rel), @"sz": @(sz),
            @"sp": [NSData dataWithBytes:splice length:spliceN * 2 * sizeof(uint32_t)],
            @"spn": @(spliceN),
        }];
        curBytes += (uint32_t)ct.length;
    }

    // 逐批解密并回拼(明文按 splice 位置写回样本区)
    for (NSMutableDictionary *batch in batchList) {
        if (*cancelFlag) return @"已取消";
        NSString *derr = nil;
        NSArray<NSData *> *plains = nil;
        if (dual) {
            int pt = [kf[0] intValue];
            BOOL flag = [kf[1] boolValue];
            NSString *key = kf[2];
            plains = [dual processMany:slot iv:ivData items:batch[@"parts"]
                              fallback:^NSArray<NSData *> *(NSArray<NSData *> *bb, NSString **ferr) {
                                  return [self rpcDecryptBatch:bb link:link key:key pt:pt flag:flag
                                                       constIv:constIv logf:logf error:ferr];
                              }
                                  logf:logf error:&derr];
        } else {
            plains = [self decMany:link scriptReload:NULL
                               key:kf[2] pt:[kf[0] intValue] flag:[kf[1] boolValue]
                             constIv:constIv batchCt:batch[@"ct"]
                             batchLens:batch[@"lens"] logf:logf error:&derr];
        }
        if (!plains) return derr;
        *totalBlocks += (unsigned)[batch[@"lens"] count];
        for (NSUInteger b = 0; b < [batch[@"items"] count]; b++) {
            NSDictionary *item = batch[@"items"][b];
            NSData *sp = item[@"sp"];
            uint8_t *dst = (uint8_t *)dmd.mutableBytes + [item[@"rel"] unsignedIntValue];
            [OBMP4 splicePlain:dst
                            len:[item[@"sz"] unsignedIntValue]
                         plain:plains[b].bytes plainLen:(uint32_t)plains[b].length
                        splice:(const uint32_t *)sp.bytes n:(unsigned)[item[@"spn"] unsignedIntValue]];
        }
    }
    [self logf:logf fmt:@"[*] frag %u 样本=%lu", fragIdx + 1, (unsigned long)nSamples];

    // 重建:清洗 moof(trun 偏移修正已内置) + 解密后的 mdat
    NSMutableData *cleaned = [OBMP4 cleanMoof:fileBuf from:moofOff to:moofOff + moofLen];
    [result appendData:cleaned];
    uint8_t mdatHdr[8];
    uint32_t mdatTotal = (uint32_t)dmd.length + 8;
    mdatHdr[0] = (uint8_t)(mdatTotal >> 24); mdatHdr[1] = (uint8_t)(mdatTotal >> 16);
    mdatHdr[2] = (uint8_t)(mdatTotal >> 8); mdatHdr[3] = (uint8_t)mdatTotal;
    mdatHdr[4] = 'm'; mdatHdr[5] = 'd'; mdatHdr[6] = 'a'; mdatHdr[7] = 't';
    [result appendBytes:mdatHdr length:8];
    [result appendData:dmd];
    return nil;
}

#pragma mark - 主流程(网络路线)

+ (nullable NSDictionary *)runAdam:(NSString *)adam
                            outDir:(NSString *)dir
                             force:(BOOL)force
                              logf:(void (^)(NSString *))logf
                            cancel:(volatile BOOL *)cancelFlag
                             error:(NSString * _Nullable * _Nullable)err {
    NSTimeInterval t0 = [NSDate date].timeIntervalSince1970;
    [self logf:logf fmt:@"=== adam %@ 原生下载开始 ===", adam];
    MDPDual *dual = nil; // 直传双链(探针通过后按配置建,失败回退引擎通道)

    // ---- 0) 磁盘元数据就位(缺则深链触发预取,3s 轮询) ----
    NSString *cache = [NSString stringWithFormat:@"/data/data/%@/cache/playback_assets/hls", OB_PHONE_PKG];
    NSString *assetPath = MetaPath(cache, [NSString stringWithFormat:@"%@/asset", adam]);
    NSString *keyPath = MetaPath(cache, [NSString stringWithFormat:@"%@/persistentKey", adam]);
    if (![OBADB suCat:assetPath] || ![OBADB suCat:keyPath]) {
        [self logf:logf fmt:@"[*] 磁盘无 asset/key,深链触发预取…"];
        [OBADB deeplinkSong:adam];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:45];
        while (![OBADB suCat:assetPath] || ![OBADB suCat:keyPath]) {
            if (*cancelFlag) { if (err) *err = @"已取消"; return nil; }
            if ([deadline timeIntervalSinceNow] <= 0) {
                if (err) *err = @"key/asset 未落盘(试在手机上播放一次)";
                return nil;
            }
            [NSThread sleepForTimeInterval:3];
        }
    }

    // ---- 1) 键与标题 ----
    NSString *trackJson = [OBADB suCat:keyPath];
    NSDictionary *tk = trackJson ? [NSJSONSerialization JSONObjectWithData:[trackJson dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL] : nil;
    if (!tk[@"metadata"][@"keyUri"] || !tk[@"persistentKey"]) {
        if (err) *err = @"曲目 key 元数据不完整";
        return nil;
    }
    NSString *trackUri = tk[@"metadata"][@"keyUri"];
    NSString *trackKey = tk[@"persistentKey"];
    NSString *pfJson = [OBADB suCat:[NSString stringWithFormat:@"/data/data/%@/files/foothill/persistentKey%@",
                                     OB_PHONE_PKG, OB_META_EXT]];
    NSDictionary *pf = pfJson ? [NSJSONSerialization JSONObjectWithData:[pfJson dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL] : nil;
    NSString *prefetchKey = pf[@"persistentKey"];
    if (!prefetchKey) { if (err) *err = @"预取 key 缺失"; return nil; }

    NSDictionary *meta = [self lookupMeta:adam error:nil];
    NSString *name = SafeName([NSString stringWithFormat:@"%@ - %@",
                               [meta[@"artist"] length] ? meta[@"artist"] : @"?",
                               meta[@"title"] ?: [NSString stringWithFormat:@"track_%@", adam]]);
    NSString *outPath = [dir stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"m4a"]];
    if (!force && [[NSFileManager defaultManager] fileExistsAtPath:outPath]) {
        [self logf:logf fmt:@"[=] 已存在,跳过: %@", outPath];
        if (err) *err = [NSString stringWithFormat:@"已存在 %@", name];
        return nil;
    }

    // ---- 2) 清单 ----
    NSString *assetJson = [OBADB suCat:assetPath];
    NSDictionary *aj = assetJson ? [NSJSONSerialization JSONObjectWithData:[assetJson dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL] : nil;
    NSString *manifest = aj[@"manifest"];
    if (!manifest.length) { if (err) *err = @"asset 元数据无 manifest"; return nil; }
    NSString *merr = nil;
    NSData *master = [OBHttp get:manifest error:&merr];
    if (!master) { if (err) *err = [NSString stringWithFormat:@"母清单: %@", merr]; return nil; }
    NSString *manifestBase = [manifest substringToIndex:[manifest rangeOfString:@"/" options:NSBackwardsSearch].location];
    NSDictionary *v = [OBPlaylist pickVariantOfMaster:[[NSString alloc] initWithData:master encoding:NSUTF8StringEncoding]
                                             baseUrl:manifestBase error:&merr];
    if (!v) { if (err) *err = merr; return nil; }
    NSData *mediaData = [OBHttp get:v[@"url"] error:&merr];
    if (!mediaData) { if (err) *err = [NSString stringWithFormat:@"媒体清单: %@", merr]; return nil; }
    NSDictionary *pm = [OBPlaylist parseMedia:[[NSString alloc] initWithData:mediaData encoding:NSUTF8StringEncoding]
                                     mediaUrl:v[@"url"] error:&merr];
    if (!pm) { if (err) *err = merr; return nil; }
    NSArray *segments = pm[@"segments"];
    NSRange initRange = [pm[@"initLoc"] rangeValue];
    [self logf:logf fmt:@"[*] asset=%@ 段数=%lu", v[@"codec"], (unsigned long)segments.count];

    // ---- 3) 连接引擎(短连接,先于下载:预检不过就不用白拉 30MB) ----
    [OBADB shellRetry:@[@"forward", @"tcp:27042", @"tcp:27042"] timeout:20 error:nil];
    OBLink *link = [OBLink shared];
    NSString *cerr = nil;
    if (![link connectToProcess:OB_PROC_NAME error:&cerr]) {
        if (err) *err = [NSString stringWithFormat:@"引擎连接: %@", cerr];
        return nil;
    }
    if (![link loadScriptSource:[OBScript agentSource] error:&cerr]) {
        [self endLink:link dual:dual];
        if (err) *err = [NSString stringWithFormat:@"装脚本: %@", cerr];
        return nil;
    }
    NSString *rf = [link rpc:@"refresh" args:nil data:nil timeout:10 error:nil];
    [self logf:logf fmt:@"[*] 引擎就绪 pid=%u ctx=%@", link.pid, rf ?: @"?"];

    // ---- 3.5) key 预检与回退(租约随切歌失效;磁盘元数据过期时试会话内存 force 直取) ----
    NSString *trackUse = trackKey;
    if (![self probeKey:link key:trackKey pt:5 flag:NO]) {
        NSString *mem = [link rpc:@"getexisting" args:@{ @"adam": adam, @"uri": trackUri, @"force": @YES }
                                       data:nil timeout:15 error:nil];
        NSDictionary *memRoot = mem ? [NSJSONSerialization JSONObjectWithData:[mem dataUsingEncoding:NSUTF8StringEncoding]
                                                                     options:0 error:NULL] : nil;
        NSString *memKey = memRoot[@"payload"][@"key"];
        if (![memKey length] || ![self probeKey:link key:memKey pt:5 flag:NO]) {
            [self endLink:link dual:dual];
            if (err) *err = @"曲目 key 已失效且会话无有效 key——在手机上播放该曲目后重试";
            return nil;
        }
        trackUse = memKey;
        [self logf:logf fmt:@"[*] 磁盘 key 失效,改用会话 key(getExisting force)"];
    }
    NSString *pfUse = prefetchKey;
    if (![self probeKey:link key:pfUse pt:7 flag:YES]) {
        NSString *pfUri = [NSString stringWithFormat:@"%@P000000000/s1/e1", OB_SKD_PREFIX];
        NSString *pfMem = [link rpc:@"getexisting" args:@{ @"adam": @"0", @"uri": pfUri, @"force": @YES }
                                       data:nil timeout:15 error:nil];
        NSDictionary *pfMemRoot = pfMem ? [NSJSONSerialization JSONObjectWithData:[pfMem dataUsingEncoding:NSUTF8StringEncoding]
                                                                          options:0 error:NULL] : nil;
        NSString *pfMemKey = pfMemRoot[@"payload"][@"key"];
        if (![pfMemKey length] || ![self probeKey:link key:pfMemKey pt:7 flag:YES]) {
            [self endLink:link dual:dual];
            if (err) *err = @"预取 key 失效:在手机上随便播一首刷新后重试";
            return nil;
        }
        pfUse = pfMemKey;
        [self logf:logf fmt:@"[*] 预取磁盘 key 失效,改用会话 key"];
    }
    [self logf:logf fmt:@"[*] key 预检通过 track=%luB prefetch=%luB",
         (unsigned long)trackUse.length, (unsigned long)pfUse.length];

    // ---- 3.6) 直传建链(失败不拦路,回退引擎通道) ----
    dual = [self buildDual:link logf:logf];

    // ---- 4) key 方案(播放列表 ↔ 磁盘元数据自洽,防错资产) ----
    NSString *prefetchPart = @"p000000000/s1/e1";
    NSMutableDictionary<NSString *, NSArray *> *keyMap = [NSMutableDictionary dictionary]; // norm → @[pt,flag,key]
    for (NSDictionary *seg in segments) {
        NSString *ku = [OBPlaylist normKeyUri:(seg[@"key"] == [NSNull null] || !seg[@"key"]) ? nil : seg[@"key"]];
        if (!ku.length) ku = prefetchPart;
        if (keyMap[ku]) continue;
        if ([ku containsString:prefetchPart]) {
            keyMap[ku] = @[@7, @YES, pfUse];
        } else if ([ku isEqualToString:[OBPlaylist normKeyUri:trackUri]]) {
            keyMap[ku] = @[@5, @NO, trackUse];
        } else {
            if (err) *err = [NSString stringWithFormat:@"播放列表出现未知 keyUri %@(磁盘 %@)", ku, [OBPlaylist normKeyUri:trackUri]];
            [self endLink:link dual:dual];
            return nil;
        }
    }
    [self logf:logf fmt:@"[*] key 方案: %@", keyMap.allKeys];

    // ---- 5) 下载整文件 ----
    NSData *fileData = [OBHttp get:pm[@"url"] error:&merr];
    if (!fileData) { [self endLink:link dual:dual]; if (err) *err = [NSString stringWithFormat:@"分段文件: %@", merr]; return nil; }
    uint32_t fileLen = (uint32_t)fileData.length;
    const uint8_t *fileBuf = fileData.bytes;
    [self logf:logf fmt:@"[*] 下载 %lu 字节", (unsigned long)fileLen];

    uint32_t initEnd = initRange.location + initRange.length;
    OBProtBox prots[8];
    int protN = [OBMP4 findProt:fileBuf len:fileLen initEnd:initEnd out:prots cap:8];
    if (protN < 1) { [self endLink:link dual:dual]; if (err) *err = @"保护方案描述盒未找到"; return nil; }
    unsigned ivLen = prots[0].constIvLen ?: 16;
    // agent 的 ivB64 期望 IV 字节的 base64(参考脚本同款);hex 字符串按 base64 解出来是垃圾 IV
    NSString *constIv = [[NSData dataWithBytes:prots[0].constIv length:ivLen]
        base64EncodedStringWithOptions:0];

    // ---- 6) 逐碎片:拆样本 → 批量解密(≤1.5MB/包) → 回拼 → 重建 ----
    NSMutableData *result = [[OBMP4 cleanInit:fileBuf initEnd:initEnd dedupe:NO] mutableCopy];
    uint32_t fragOff = initEnd, fragIdx = 0, totalSamples = 0, totalBlocks = 0;
    uint32_t *sOff = malloc(8192 * 4), *sSize = malloc(8192 * 4);
    unsigned *sSubN = malloc(8192 * 4), *sSubOff = malloc(8192 * 4);
    uint32_t *subBuf = malloc(8192 * 2 * 4);
    uint32_t *spliceBuf = malloc(512 * 2 * 4);
    BOOL bufsOk = sOff && sSize && sSubN && sSubOff && subBuf && spliceBuf;
    if (!bufsOk) { [self endLink:link dual:dual]; if (err) *err = @"内存不足"; return nil; }

    NSString *loopErr = nil;
    for (;;) {
        if (*cancelFlag) { loopErr = @"已取消"; break; }
        uint32_t moofOff, moofLen, mdatOff, mdatLen, next;
        if (![OBMP4 fragments:fileBuf len:fileLen from:fragOff moofOff:&moofOff moofLen:&moofLen
                       mdatOff:&mdatOff mdatLen:&mdatLen next:&next]) break;
        loopErr = [self runFragment:fragIdx data:fileBuf
                             moofOff:moofOff moofLen:moofLen mdatOff:mdatOff mdatLen:mdatLen
                                prot:&prots[0] keyMap:keyMap segments:segments
                          prefetchPart:prefetchPart constIv:constIv link:link dual:dual result:result
                                 sOff:sOff sSize:sSize sSubN:sSubN sSubOff:sSubOff
                               subBuf:subBuf spliceBuf:spliceBuf
                                 logf:logf cancel:cancelFlag
                          totalSamples:&totalSamples totalBlocks:&totalBlocks];
        if (loopErr) break;
        fragIdx++;
        fragOff = next;
    }
    free(sOff); free(sSize); free(sSubN); free(sSubOff); free(subBuf); free(spliceBuf);
    if (loopErr) {
        [self endLink:link dual:dual];
        if ([loopErr rangeOfString:@"已取消"].location != NSNotFound && *cancelFlag) loopErr = @"已取消";
        if (err) *err = loopErr;
        return nil;
    }
    [self logf:logf fmt:@"[*] 碎片=%u 样本=%u 块=%u", fragIdx, totalSamples, totalBlocks];

    // ---- 7) 写盘 ----
    [result writeToFile:outPath atomically:YES];
    [self logf:logf fmt:@"[+] 写盘 %@ (%lu 字节)", outPath, (unsigned long)result.length];

    // ---- 8) 验证 ----
    NSDictionary *verify = [self verify:outPath expect:totalSamples];
    [self logf:logf fmt:@"[%@] 验证: %@", [verify[@"ok"] boolValue] ? @"✅" : @"❌", verify];
    if (![verify[@"ok"] boolValue]) {
        [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
        [self endLink:link dual:dual];
        if (err) *err = [NSString stringWithFormat:@"验证失败 packets=%@ expect=%u fferr=%@",
                         verify[@"packets"], totalSamples, verify[@"ffmpeg_errors"]];
        return nil;
    }

    // ---- 8.5) 标签写入(等价参考工具的 mutagen 步骤;封面拉取失败不拦路) ----
    BOOL tagged = NO;
    NSString *artUrl = meta[@"artwork"];
    NSData *cover = [artUrl length] ? [OBHttp get:artUrl error:nil] : nil;
    if ([cover length] > 8) {
        NSMutableDictionary *tm = [meta mutableCopy];
        tm[@"cover"] = cover;
        uint32_t nl = [OBMP4 applyTags:result meta:tm];
        if (nl) {
            [result writeToFile:outPath atomically:YES];
            tagged = YES;
            [self logf:logf fmt:@"[+] 标签+封面已写入 (封面 %lu 字节)", (unsigned long)cover.length];
        }
    }

    // ---- 9) sidecar ----
    NSDictionary *sidecar = @{
        @"adam": adam, @"artist": meta[@"artist"] ?: @"", @"title": meta[@"title"] ?: @"",
        @"codec": v[@"codec"], @"keyUri": trackUri, @"manifest": manifest,
        @"size": @(result.length), @"segments": @(fragIdx), @"blocks": @(totalBlocks),
        @"secs": @([NSDate date].timeIntervalSince1970 - t0),
        @"verify": verify, @"tagged": @(tagged), @"source": @"native",
        @"transport": dual ? @"tcp" : @"rpc",
    };
    NSData *sj = [NSJSONSerialization dataWithJSONObject:sidecar options:NSJSONWritingPrettyPrinted error:NULL];
    [sj writeToFile:[dir stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"json"]]
           atomically:YES];
    [self endLink:link dual:dual];
    [self logf:logf fmt:@"=== %@ 完成 ===", name];
    return sidecar;
}


#pragma mark - key 探针

// 探一个 key 是否仍有效(create 校验 key 内容,假/过期 key 直接被拒)
+ (BOOL)probeKey:(OBLink *)link key:(NSString *)key pt:(int)pt flag:(BOOL)flag {
    if (!key.length) return NO;
    NSString *resp = [link rpc:@"probemany"
                          args:@{ @"items": @[ @[ key, @(pt), @(flag) ] ] }
                         data:nil timeout:15 error:nil];
    if (!resp) return NO;
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:[resp dataUsingEncoding:NSUTF8StringEncoding]
                                                         options:0 error:NULL];
    NSArray *oklist = root[@"payload"][@"oklist"];
    return oklist.count > 0 && [oklist[0] boolValue];
}

// 按新鲜度选 key:候选依次探,返回首个有效者(全失效返回 nil)
+ (NSString *)pickFreshKey:(OBLink *)link
                candidates:(NSArray<NSString *> *)cands
                        pt:(int)pt flag:(BOOL)flag {
    for (NSString *c in cands) {
        if (c.length && [self probeKey:link key:c pt:pt flag:flag]) return c;
    }
    return nil;
}

#pragma mark - 缓存直解

+ (nullable NSDictionary *)runFromCache:(NSString *)adam
                                 outDir:(NSString *)dir
                                  force:(BOOL)force
                                   logf:(void (^)(NSString *))logf
                                 cancel:(volatile BOOL *)cancelFlag
                                  error:(NSString * _Nullable * _Nullable)err {
    NSTimeInterval t0 = [NSDate date].timeIntervalSince1970;
    [self logf:logf fmt:@"=== adam %@ 缓存直解开始 ===", adam];
    MDPDual *dual = nil; // 直传双链(key 就绪后按配置建,失败回退引擎通道)
    NSString *c2 = [NSString stringWithFormat:@"/data/data/%@/no_backup/assets/hls", OB_PHONE_PKG];

    // ---- 0) 缓存目录三件套 ----
    NSString *dMeta = [OBADB suCat:MetaPath(c2, [NSString stringWithFormat:@"%@/download", adam])];
    NSDictionary *cacheMeta = dMeta ? [NSJSONSerialization JSONObjectWithData:[dMeta dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL] : nil;
    NSString *assetFn = cacheMeta[@"assetFilename"], *plFn = cacheMeta[@"playlistManifest"];
    if (!assetFn.length || !plFn.length) { if (err) *err = @"缓存无 download 元数据(该曲未完整缓存)"; return nil; }
    NSNumber *assetSize = cacheMeta[@"assetSize"];

    // ---- 1) 元数据与命名 ----
    NSDictionary *meta = [self lookupMeta:adam error:nil];
    NSString *name = SafeName([NSString stringWithFormat:@"%@ - %@",
                               [meta[@"artist"] length] ? meta[@"artist"] : @"?",
                               meta[@"title"] ?: [NSString stringWithFormat:@"track_%@", adam]]);
    NSString *outPath = [dir stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"m4a"]];
    if (!force && [[NSFileManager defaultManager] fileExistsAtPath:outPath]) {
        [self logf:logf fmt:@"[=] 已存在,跳过: %@", outPath];
        if (err) *err = [NSString stringWithFormat:@"已存在 %@", name];
        return nil;
    }

    // ---- 2) key 探针(旧缓存 key 大概率被服务端过期;拉文件前先定胜负) ----
    NSString *tkJson = [OBADB suCat:MetaPath(c2, [NSString stringWithFormat:@"%@/persistentKey", adam])];
    NSDictionary *tk = tkJson ? [NSJSONSerialization JSONObjectWithData:[tkJson dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL] : nil;
    if (!tk[@"metadata"][@"keyUri"] || !tk[@"persistentKey"]) { if (err) *err = @"缓存 key 元数据缺失"; return nil; }
    NSString *trackUri = tk[@"metadata"][@"keyUri"], *trackKey = tk[@"persistentKey"];
    NSString *pfJson = [OBADB suCat:[NSString stringWithFormat:@"/data/data/%@/files/foothill/persistentKey%@",
                                     OB_PHONE_PKG, OB_META_EXT]];
    NSDictionary *pf = pfJson ? [NSJSONSerialization JSONObjectWithData:[pfJson dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL] : nil;

    [OBADB shellRetry:@[@"forward", @"tcp:27042", @"tcp:27042"] timeout:20 error:nil];
    OBLink *link = [OBLink shared];
    NSString *cerr = nil;
    if (![link connectToProcess:OB_PROC_NAME error:&cerr]) { if (err) *err = [NSString stringWithFormat:@"引擎连接: %@", cerr]; return nil; }
    if (![link loadScriptSource:[OBScript agentSource] error:&cerr]) { [self endLink:link dual:dual]; if (err) *err = [NSString stringWithFormat:@"装脚本: %@", cerr]; return nil; }
    [link rpc:@"refresh" args:nil data:nil timeout:10 error:nil];

    // 曲目 key 候选:缓存自带 → 会话内存(force);预取候选:foothill → 会话内存
    NSMutableArray *keyCands = [NSMutableArray arrayWithObject:trackKey];
    NSString *mem = [link rpc:@"getexisting" args:@{ @"adam": adam, @"uri": trackUri, @"force": @YES } data:nil timeout:15 error:nil];
    NSDictionary *memRoot = mem ? [NSJSONSerialization JSONObjectWithData:[mem dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL] : nil;
    NSString *memKey = memRoot[@"payload"][@"key"];
    if ([memKey length]) [keyCands addObject:memKey];
    NSString *trackUse = [self pickFreshKey:link candidates:keyCands pt:5 flag:NO];
    if (!trackUse) {
        [self endLink:link dual:dual];
        if (err) *err = @"曲目 key 全部失效:在手机上播放一次该曲目刷新后重试";
        return nil;
    }
    // 预取 URI 含敏感词,走 OB 池拼装
    NSString *pfUri = [NSString stringWithFormat:@"skd://%@/P000000000/s1/e1", OB_STORE_HOST];
    NSMutableArray *pfCands = [NSMutableArray array];
    if (pf[@"persistentKey"]) [pfCands addObject:pf[@"persistentKey"]];
    NSString *pfMem = [link rpc:@"getexisting" args:@{ @"adam": @"0", @"uri": pfUri, @"force": @YES } data:nil timeout:15 error:nil];
    NSDictionary *pfMemRoot = pfMem ? [NSJSONSerialization JSONObjectWithData:[pfMem dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL] : nil;
    if ([pfMemRoot[@"payload"][@"key"] length]) [pfCands addObject:pfMemRoot[@"payload"][@"key"]];
    NSString *pfUse = [self pickFreshKey:link candidates:pfCands pt:7 flag:YES];
    if (!pfUse) {
        [self endLink:link dual:dual];
        if (err) *err = @"预取 key 失效:在手机上随便播一首刷新后重试";
        return nil;
    }
    [self logf:logf fmt:@"[*] key 就绪 track=%luB prefetch=%luB", (unsigned long)trackUse.length, (unsigned long)pfUse.length];

    // ---- 2.5) 直传建链(失败不拦路,回退引擎通道) ----
    dual = [self buildDual:link logf:logf];

    // ---- 3) 拉本地文件(pull,二进制安全) ----
    NSString *stage = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@".stage_%@", adam]];
    [[NSFileManager defaultManager] createDirectoryAtPath:stage withIntermediateDirectories:YES attributes:nil error:NULL];
    for (NSString *fn in @[plFn, assetFn]) {
        if (![OBADB pull:[NSString stringWithFormat:@"%@/%@/%@", c2, adam, fn]
                      to:[stage stringByAppendingPathComponent:fn] error:&cerr]) {
            [self endLink:link dual:dual];
            if (err) *err = [NSString stringWithFormat:@"拉取 %@: %@", fn, cerr ?: @"?"];
            return nil;
        }
    }
    NSData *fileData = [NSData dataWithContentsOfFile:[stage stringByAppendingPathComponent:assetFn]];
    NSString *mediaText = [NSString stringWithContentsOfFile:[stage stringByAppendingPathComponent:plFn]
                                                   encoding:NSUTF8StringEncoding error:NULL];
    if (!fileData || !mediaText) { [self endLink:link dual:dual]; if (err) *err = @"暂存文件读取失败"; return nil; }
    if (assetSize && (uint64_t)fileData.length != assetSize.unsignedLongLongValue) {
        [self endLink:link dual:dual];
        if (err) *err = [NSString stringWithFormat:@"缓存不完整 %lu != %@(在 App 里重播一次可补全)",
                         (unsigned long)fileData.length, assetSize];
        return nil;
    }
    uint32_t fileLen = (uint32_t)fileData.length;
    const uint8_t *fileBuf = fileData.bytes;

    // ---- 4) 清单与 key 方案 ----
    NSDictionary *pm = [OBPlaylist parseMedia:mediaText
                                     mediaUrl:[NSString stringWithFormat:@"https://local/%@", plFn] error:&cerr];
    if (!pm) { [self endLink:link dual:dual]; if (err) *err = cerr; return nil; }
    NSArray *segments = pm[@"segments"];
    NSRange initRange = [pm[@"initLoc"] rangeValue];
    NSString *prefetchPart = @"p000000000/s1/e1";
    NSMutableDictionary<NSString *, NSArray *> *keyMap = [NSMutableDictionary dictionary];
    for (NSDictionary *seg in segments) {
        NSString *ku = [OBPlaylist normKeyUri:(seg[@"key"] == [NSNull null] || !seg[@"key"]) ? nil : seg[@"key"]];
        if (!ku.length) ku = prefetchPart;
        if (keyMap[ku]) continue;
        if ([ku containsString:prefetchPart]) {
            keyMap[ku] = @[@7, @YES, pfUse];
        } else if ([ku isEqualToString:[OBPlaylist normKeyUri:trackUri]]) {
            keyMap[ku] = @[@5, @NO, trackUse];
        } else {
            [self endLink:link dual:dual];
            if (err) *err = [NSString stringWithFormat:@"播放列表出现未知 keyUri %@(缓存 %@)", ku, [OBPlaylist normKeyUri:trackUri]];
            return nil;
        }
    }
    [self logf:logf fmt:@"[*] %@ | keyUri=%@ 段数=%lu", name, [OBPlaylist normKeyUri:trackUri], (unsigned long)segments.count];

    // ---- 5) 碎片解密重建(与网络路线同构) ----
    uint32_t initEnd = initRange.location + initRange.length;
    OBProtBox prots[8];
    int protN = [OBMP4 findProt:fileBuf len:fileLen initEnd:initEnd out:prots cap:8];
    if (protN < 1) { [self endLink:link dual:dual]; if (err) *err = @"保护方案描述盒未找到"; return nil; }
    unsigned ivLen = prots[0].constIvLen ?: 16;
    // agent 的 ivB64 期望 IV 字节的 base64(参考脚本同款);hex 字符串按 base64 解出来是垃圾 IV
    NSString *constIv = [[NSData dataWithBytes:prots[0].constIv length:ivLen]
        base64EncodedStringWithOptions:0];

    NSMutableData *result = [[OBMP4 cleanInit:fileBuf initEnd:initEnd dedupe:NO] mutableCopy];
    uint32_t fragOff = initEnd, fragIdx = 0, totalSamples = 0, totalBlocks = 0;
    uint32_t *sOff = malloc(8192 * 4), *sSize = malloc(8192 * 4);
    unsigned *sSubN = malloc(8192 * 4), *sSubOff = malloc(8192 * 4);
    uint32_t *subBuf = malloc(8192 * 2 * 4);
    uint32_t *spliceBuf = malloc(512 * 2 * 4);
    BOOL bufsOk = sOff && sSize && sSubN && sSubOff && subBuf && spliceBuf;

    NSString *loopErr = nil;
    for (;;) {
        if (*cancelFlag) { loopErr = @"已取消"; break; }
        uint32_t moofOff, moofLen, mdatOff, mdatLen, next;
        if (![OBMP4 fragments:fileBuf len:fileLen from:fragOff moofOff:&moofOff moofLen:&moofLen
                       mdatOff:&mdatOff mdatLen:&mdatLen next:&next]) break;
        if (!bufsOk) { loopErr = @"内存不足"; break; }
        loopErr = [self runFragment:fragIdx data:fileBuf
                             moofOff:moofOff moofLen:moofLen mdatOff:mdatOff mdatLen:mdatLen
                                prot:&prots[0] keyMap:keyMap segments:segments
                          prefetchPart:prefetchPart constIv:constIv link:link dual:dual result:result
                                 sOff:sOff sSize:sSize sSubN:sSubN sSubOff:sSubOff
                               subBuf:subBuf spliceBuf:spliceBuf
                                 logf:logf cancel:cancelFlag
                          totalSamples:&totalSamples totalBlocks:&totalBlocks];
        if (loopErr) break;
        fragIdx++;
        fragOff = next;
    }
    free(sOff); free(sSize); free(sSubN); free(sSubOff); free(subBuf); free(spliceBuf);
    [[NSFileManager defaultManager] removeItemAtPath:stage error:NULL];
    if (loopErr) {
        [self endLink:link dual:dual];
        if ([loopErr rangeOfString:@"已取消"].location != NSNotFound && *cancelFlag) loopErr = @"已取消";
        if (err) *err = loopErr;
        return nil;
    }
    [self logf:logf fmt:@"[*] 碎片=%u 样本=%u 块=%u", fragIdx, totalSamples, totalBlocks];

    // ---- 6) 写盘/验证/sidecar ----
    [result writeToFile:outPath atomically:YES];
    [self logf:logf fmt:@"[+] 写盘 %@ (%lu 字节)", outPath, (unsigned long)result.length];
    NSDictionary *verify = [self verify:outPath expect:totalSamples];
    [self logf:logf fmt:@"[%@] 验证: %@", [verify[@"ok"] boolValue] ? @"✅" : @"❌", verify];
    if (![verify[@"ok"] boolValue]) {
        [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];
        [self endLink:link dual:dual];
        if (err) *err = [NSString stringWithFormat:@"验证失败 packets=%@ expect=%u fferr=%@",
                         verify[@"packets"], totalSamples, verify[@"ffmpeg_errors"]];
        return nil;
    }
    // 标签写入(与网络路线同一套;封面拉取失败不拦路)
    BOOL tagged = NO;
    NSString *artUrl = meta[@"artwork"];
    NSData *cover = [artUrl length] ? [OBHttp get:artUrl error:nil] : nil;
    if ([cover length] > 8) {
        NSMutableDictionary *tm = [meta mutableCopy];
        tm[@"cover"] = cover;
        uint32_t nl = [OBMP4 applyTags:result meta:tm];
        if (nl) {
            [result writeToFile:outPath atomically:YES];
            tagged = YES;
            [self logf:logf fmt:@"[+] 标签+封面已写入 (封面 %lu 字节)", (unsigned long)cover.length];
        }
    }
    NSDictionary *sidecar = @{
        @"adam": adam, @"artist": meta[@"artist"] ?: @"", @"title": meta[@"title"] ?: @"",
        @"codec": @"alac", @"keyUri": trackUri, @"source": @"native-cache",
        @"asset": assetFn, @"size": @(result.length), @"segments": @(fragIdx),
        @"transport": dual ? @"tcp" : @"rpc",
        @"blocks": @(totalBlocks), @"secs": @([NSDate date].timeIntervalSince1970 - t0),
        @"verify": verify, @"tagged": @(tagged),
    };
    NSData *sj = [NSJSONSerialization dataWithJSONObject:sidecar options:NSJSONWritingPrettyPrinted error:NULL];
    [sj writeToFile:[dir stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"json"]] atomically:YES];
    [self endLink:link dual:dual];
    [self logf:logf fmt:@"=== %@ 完成 ===", name];
    return sidecar;
}

#pragma mark - 验证

+ (NSDictionary *)verify:(NSString *)path expect:(unsigned)expect {
    NSString *ffprobe = [OBADB which:@"ffprobe"];
    NSString *ffmpeg = [OBADB which:@"ffmpeg"];
    if (!ffprobe || !ffmpeg) return @{ @"ok": @YES, @"skipped": @"no ffprobe/ffmpeg" };
    NSMutableDictionary *vBox = [NSMutableDictionary dictionary];
    vBox[@"expect_samples"] = @(expect);
    int st = 0;
    NSString *out = [TaskRunner runSync:ffprobe arguments:@[
        @"-v", @"error", @"-count_packets", @"-select_streams", @"a:0",
        @"-show_entries", @"stream=codec_name,nb_read_packets,duration", @"-of", @"json", path]
                                   cwd:nil env:nil status:&st];
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[out dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
    NSDictionary *stream = j[@"streams"][0];
    vBox[@"codec"] = stream[@"codec_name"] ?: @"";
    vBox[@"packets"] = stream[@"nb_read_packets"] ?: @"0";
    vBox[@"duration"] = @([stream[@"duration"] doubleValue]);
    // -threads 1:ffmpeg 8 的线程调度器对个别输入会挂死(实测 sch_wait 全员空等);单线程解码 67MB 也在 1s 内
    NSString *errOut = [TaskRunner runSync:ffmpeg arguments:@[@"-v", @"error", @"-threads", @"1", @"-i", path, @"-f", @"null", @"-"]
                                       cwd:nil env:nil status:&st];
    NSArray *lines = [errOut componentsSeparatedByString:@"\n"];
    NSMutableArray *errs = [NSMutableArray array];
    for (NSString *l in lines) if (l.length) [errs addObject:l];
    vBox[@"ffmpeg_errors"] = @(errs.count);
    if (errs.count) vBox[@"ffmpeg_sample"] = [errs subarrayWithRange:NSMakeRange(0, MIN(3, errs.count))];
    // DSE 豁免:全是解码器未实现类报错时,warning 级复查确认非损坏(混入其他报错一律不豁免)
    BOOL allUnimpl = errs.count > 0;
    for (NSString *l in errs) if (![l containsString:@"Not yet implemented in FFmpeg"]) { allUnimpl = NO; break; }
    if (allUnimpl) {
        NSString *w = [TaskRunner runSync:ffmpeg arguments:@[@"-v", @"warning", @"-threads", @"1", @"-i", path, @"-f", @"null", @"-"]
                                     cwd:nil env:nil status:&st];
        if ([w containsString:@"Syntax element 4"]) vBox[@"waived"] = @"DSE(解码器未实现,非损坏)";
    }
    // ffprobe 的 nb_read_packets/duration 是字符串(docs/09 坑4 的原生翻版),intValue/doubleValue 取数
    unsigned packets = (unsigned)[(NSString *)vBox[@"packets"] intValue];
    BOOL ok = packets == expect
        && ([vBox[@"ffmpeg_errors"] intValue] == 0 || vBox[@"waived"] != nil)
        && [(NSString *)vBox[@"duration"] doubleValue] > 0;
    vBox[@"ok"] = @(ok);
    return vBox;
}

#pragma mark - 自检

+ (NSArray<NSString *> *)selfTest {
    NSMutableArray *lines = [NSMutableArray array];
    [lines addObject:@"[引擎] 原生自检开始"];
    [OBADB shellRetry:@[@"forward", @"tcp:27042", @"tcp:27042"] timeout:20 error:nil];
    OBLink *link = [OBLink shared];
    MDPDual *dual = nil;
    NSString *err = nil;
    if (![link connectToProcess:OB_PROC_NAME error:&err]) {
        [lines addObject:[NSString stringWithFormat:@"[引擎] ❌ 连接: %@", err]];
        return lines;
    }
    [lines addObject:[NSString stringWithFormat:@"[引擎] ✅ attach pid=%u", link.pid]];
    if (![link loadScriptSource:[OBScript agentSource] error:&err]) {
        [self endLink:link dual:dual];
        [lines addObject:[NSString stringWithFormat:@"[引擎] ❌ 脚本: %@", err]];
        return lines;
    }
    NSString *rf = [link rpc:@"refresh" args:nil data:nil timeout:10 error:&err];
    [lines addObject:[NSString stringWithFormat:@"[引擎] %@ refresh→%@", rf ? @"✅" : @"❌", rf ?: (err ?: @"?")]];
    if (rf && [AMDConfig shared].useTcp) [self tcpSelfTest:link lines:lines];
    [self endLink:link dual:dual];
    [lines addObject:@"[引擎] 已断开(按需短连接)"];
    return lines;
}

// 直传自检:建链 → 各链 128KB 回环 → 找有效钥匙 → 引擎通道/直传解密对拍 → 确定性关闭
+ (void)tcpSelfTest:(OBLink *)link lines:(NSMutableArray<NSString *> *)lines {
    void (^add)(NSString *) = ^(NSString *s) { @synchronized (lines) { [lines addObject:s]; } };
    add(@"[直传] 双链自检…");
    AMDDBG(@"selftest: tcp begin");
    MDPDual *dual = [self buildDual:link logf:add];
    if (!dual) { add(@"[直传] ❌ 建链失败(下载自动回退引擎通道,不受影响)"); return; }
    @try {
        NSMutableData *blob = [NSMutableData dataWithLength:131072];
        arc4random_buf(blob.mutableBytes, blob.length);
        if (![dual echoAll:blob logf:add]) { add(@"[直传] ❌ 回环失败"); return; }
        // 找一把有效钥匙:预取 → 磁盘前 30
        NSString *key = nil;
        int pt = 5;
        BOOL flag = NO;
        NSString *pfJson = [OBADB suCat:[NSString stringWithFormat:@"/data/data/%@/files/foothill/persistentKey%@",
                                         OB_PHONE_PKG, OB_META_EXT]];
        NSDictionary *pf = pfJson ? [NSJSONSerialization JSONObjectWithData:[pfJson dataUsingEncoding:NSUTF8StringEncoding]
                                                                    options:0 error:NULL] : nil;
        if ([pf[@"persistentKey"] length] && [self probeKey:link key:pf[@"persistentKey"] pt:7 flag:YES]) {
            key = pf[@"persistentKey"]; pt = 7; flag = YES;
        } else {
            NSDictionary *disk = [self readAllTrackKeys];
            NSArray *adams = [disk.allKeys subarrayWithRange:NSMakeRange(0, MIN(30, disk.allKeys.count))];
            NSMutableArray *items = [NSMutableArray array];
            for (NSString *a in adams) [items addObject:@[ disk[a][1], @5, @NO ]];
            if (items.count) {
                NSArray *oks = [self probeKeys:link items:items];
                for (NSUInteger i = 0; i < adams.count; i++) {
                    if ([oks[i] boolValue]) { key = disk[adams[i]][1]; pt = 5; flag = NO; break; }
                }
            }
        }
        if (!key) { add(@"[直传] 回环已过;无有效钥匙,对拍跳过(手机播一首后再测)"); return; }
        // 对拍:24 包×64KB 随机密文,两侧输出逐字节比对
        NSMutableData *iv = [NSMutableData dataWithLength:16];
        arc4random_buf(iv.mutableBytes, iv.length);
        NSMutableArray<NSData *> *cts = [NSMutableArray array];
        for (int i = 0; i < 24; i++) {
            NSMutableData *one = [NSMutableData dataWithLength:65536];
            arc4random_buf(one.mutableBytes, one.length);
            [cts addObject:one];
        }
        NSString *e = nil;
        NSMutableData *allCt = [NSMutableData data];
        NSMutableArray *lens = [NSMutableArray array];
        for (NSData *c in cts) { [allCt appendData:c]; [lens addObject:@(c.length)]; }
        NSArray<NSData *> *ref = [self decMany:link scriptReload:NULL key:key pt:pt flag:flag
                                        constIv:[iv base64EncodedStringWithOptions:0]
                                        batchCt:allCt batchLens:lens logf:add error:&e];
        if (!ref) { add([NSString stringWithFormat:@"[直传] ❌ 引擎通道基准失败: %@", e ?: @"?"]); return; }
        uint32_t slot = [dual slotForKey:key spec:@{ @"key": key, @"pt": @(pt), @"flag": @(flag) } error:&e];
        if (!slot) { add([NSString stringWithFormat:@"[直传] ❌ 槽位登记失败: %@", e ?: @"?"]); return; }
        NSArray<NSData *> *got = [dual processMany:slot iv:iv items:cts fallback:nil logf:add error:&e];
        BOOL same = got && got.count == ref.count;
        if (same) {
            for (NSUInteger i = 0; i < ref.count; i++) {
                if (![ref[i] isEqualToData:got[i]]) { same = NO; break; }
            }
        }
        add([NSString stringWithFormat:@"[直传] %@ 解密对拍(24 包/1536KB): %@",
             same ? @"✅" : @"❌", same ? @"一致" : (e ?: @"不一致!")]);
        AMDDBG(@"selftest: tcp 对拍 %@", same ? @"一致" : @"不一致");
    } @finally {
        [dual close];
    }
}


#pragma mark - 跟随收割 v2(内存轮询)

// 合并读缓存曲目清单(等价参考脚本 cache_scan):一次 cat 全部 download 元数据,
// 按下载位置字段边界切分。adam 取路径末段(元数据里没有 storeId 字段)。
+ (NSDictionary<NSString *, NSDictionary *> *)cacheScan {
    NSString *c2 = [NSString stringWithFormat:@"/data/data/%@/no_backup/assets/hls", OB_PHONE_PKG];
    NSString *raw = [OBADB shellRetry:@[@"shell",
        [NSString stringWithFormat:@"su -c 'cat %@/*/download%@'", c2, OB_META_EXT]]
        timeout:60 error:nil];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    if (!raw.length || [raw containsString:@"No such file"]) return out;
    for (NSString *chunk in [raw componentsSeparatedByString:@"{\"downloadLocation\""]) {
        if (!chunk.length) continue;
        NSRange r = [chunk rangeOfString:@"}"];
        if (r.location == NSNotFound) continue;
        NSString *j = [NSString stringWithFormat:@"{\"downloadLocation\"%@",
                       [chunk substringToIndex:r.location + 1]];
        NSDictionary *d = [NSJSONSerialization JSONObjectWithData:[j dataUsingEncoding:NSUTF8StringEncoding]
                                                          options:0 error:NULL];
        NSString *dl = d[@"downloadLocation"];
        if (![dl length]) continue;
        NSString *adam = [dl stringByReplacingOccurrencesOfString:@"/" withString:@""];
        if (adam.length) out[adam] = d;
    }
    return out;
}

// 合并读全部磁盘 key(等价 read_all_track_keys):连排 JSON 逐个解;adam 取 metadata.storeId
+ (NSDictionary<NSString *, NSArray *> *)readAllTrackKeys {
    NSString *c2 = [NSString stringWithFormat:@"/data/data/%@/no_backup/assets/hls", OB_PHONE_PKG];
    NSString *raw = [OBADB shellRetry:@[@"shell",
        [NSString stringWithFormat:@"su -c 'cat %@/*/persistentKey%@'", c2, OB_META_EXT]]
        timeout:60 error:nil];
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSData *dd = [raw dataUsingEncoding:NSUTF8StringEncoding];
    if (!dd) return out;
    NSUInteger i = 0, n = dd.length;
    const unsigned char *b = dd.bytes;
    while (i < n) {
        while (i < n && (b[i] == ' ' || b[i] == '\t' || b[i] == '\r' || b[i] == '\n')) i++;
        if (i >= n) break;
        // 从 i 起找完整 JSON 对象(数平衡括号,字符串内跳过转义)——连排 JSON 无分隔符
        NSInteger depth = 0, k = (NSInteger)i;
        BOOL inStr = NO, esc = NO;
        for (; k < (NSInteger)n; k++) {
            char ch = (char)b[k];
            if (esc) { esc = NO; continue; }
            if (ch == '\\') { esc = YES; continue; }
            if (ch == '"') inStr = !inStr;
            if (inStr) continue;
            if (ch == '{') depth++;
            else if (ch == '}') { depth--; if (!depth) break; }
        }
        if (depth != 0 || k >= (NSInteger)n) break;
        NSData *seg = [dd subdataWithRange:NSMakeRange(i, k + 1 - i)];
        i = k + 1;
        NSDictionary *d = [NSJSONSerialization JSONObjectWithData:seg options:0 error:NULL];
        NSString *adam = d[@"metadata"][@"storeId"];
        if (![adam length] || ![d[@"persistentKey"] length]) continue;
        out[adam] = @[ d[@"metadata"][@"keyUri"] ?: @"", d[@"persistentKey"] ];
    }
    return out;
}

// 批量会话取 key(分片 100,纯读 force=NO):adam → key
+ (NSDictionary<NSString *, NSString *> *)memKeys:(OBLink *)link
                                           pairs:(NSArray<NSArray *> *)pairs {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSUInteger c = 0; c < pairs.count; c += 100) {
        NSArray *part = [pairs subarrayWithRange:NSMakeRange(c, MIN(100, pairs.count - c))];
        NSString *resp = [link rpc:@"getexistingmany"
                              args:@{ @"items": part } data:nil timeout:30 error:nil];
        if (!resp) continue;
        NSDictionary *root = [NSJSONSerialization JSONObjectWithData:[resp dataUsingEncoding:NSUTF8StringEncoding]
                                                             options:0 error:NULL];
        NSArray *keys = root[@"payload"][@"keys"];
        if (![keys isKindOfClass:[NSArray class]]) continue;
        for (NSUInteger i = 0; i < part.count && i < keys.count; i++) {
            NSString *k = keys[i];
            if ([k length]) out[part[i][0]] = k;
        }
    }
    return out;
}

// 批量探针(分片 100):items=[[key, pt, flag]] → 与输入一一对应的 ok 数组
+ (NSArray<NSNumber *> *)probeKeys:(OBLink *)link items:(NSArray *)items {
    NSMutableArray *oks = [NSMutableArray arrayWithCapacity:items.count];
    for (NSUInteger i = 0; i < items.count; i++) [oks addObject:@NO];
    for (NSUInteger c = 0; c < items.count; c += 100) {
        NSRange r = NSMakeRange(c, MIN(100, items.count - c));
        NSArray *part = [items subarrayWithRange:r];
        NSString *resp = [link rpc:@"probemany" args:@{ @"items": part } data:nil timeout:60 error:nil];
        if (!resp) continue;
        NSDictionary *root = [NSJSONSerialization JSONObjectWithData:[resp dataUsingEncoding:NSUTF8StringEncoding]
                                                             options:0 error:NULL];
        NSArray *oklist = root[@"payload"][@"oklist"];
        if (![oklist isKindOfClass:[NSArray class]]) continue;
        for (NSUInteger i = 0; i < part.count && i < oklist.count; i++)
            oks[c + i] = oklist[i] ? @YES : @NO;
    }
    return oks;
}

// 当前前台媒体会话包名(发媒体键前必查;不是目标 App 就返回 nil)
+ (NSString *)frontMediaPackage {
    NSString *s = [OBADB shellRetry:@[@"shell", @"dumpsys media_session"] timeout:20 error:nil];
    if (![s length]) return nil;
    __block NSString *pkg = nil;
    [[s componentsSeparatedByString:@"\n"] enumerateObjectsUsingBlock:^(NSString *ln, NSUInteger i, BOOL *stop) {
        NSRange r = [ln rangeOfString:@"sessionPackage="];
        if (r.location != NSNotFound) {
            pkg = [ln substringFromIndex:r.location + r.length];
            pkg = [pkg componentsSeparatedByCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]].firstObject;
            *stop = YES;
        }
    }];
    return pkg;
}

// sidecar 是否记录了一次绿色验证(断点续传依据;.m4a 被移走只剩 sidecar 也算已收)
+ (BOOL)sidecarGreen:(NSString *)path {
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[[NSData alloc] initWithContentsOfFile:path]
                                                      options:0 error:NULL];
    if (!j || [j[@"error"] length] || [j[@"skipped"] length]) return NO;
    NSDictionary *v = j[@"verify"];
    if (![v isKindOfClass:[NSDictionary class]]) return NO;
    if ([v[@"skipped"] length]) return YES;
    return [v[@"ok"] boolValue];
}

+ (void)followCache:(NSString *)dir
           interval:(NSTimeInterval)secs
           autoNext:(BOOL)autoNext
               logf:(void (^)(NSString *))logf
            statusf:(void (^)(NSString *))statusf
             cancel:(volatile BOOL *)cancelFlag {
    [self logf:logf fmt:@"=== 跟随收割 v2 开始 (interval=%.0fs autoNext=%d) ===", secs, autoNext];

    // ---- 曲目全集:cache_index.json 优先,否则现扫缓存 ----
    NSMutableDictionary<NSString *, NSDictionary *> *index = [NSMutableDictionary dictionary];
    NSString *cip = [dir stringByAppendingPathComponent:@"cache_index.json"];
    NSData *ciData = [[NSData alloc] initWithContentsOfFile:cip];
    if (ciData) {
        NSArray *arr = [NSJSONSerialization JSONObjectWithData:ciData options:0 error:NULL];
        for (NSDictionary *r in arr) {
            NSString *a = [NSString stringWithFormat:@"%@", r[@"adam"]];
            if ([a length]) index[a] = r;
        }
    }
    if (!index.count) {
        NSDictionary *scan = [self cacheScan];
        [index addEntriesFromDictionary:scan];
        [self logf:logf fmt:@"[*] 缓存现扫: %lu 首", (unsigned long)index.count];
    } else {
        [self logf:logf fmt:@"[*] 索引载入: %lu 首", (unsigned long)index.count];
    }
    if (!index.count) { [self logf:logf fmt:@"[!] 缓存无曲目,退出"]; return; }

    // ---- 已收判定 ----
    NSMutableArray<NSString *> *failed = [NSMutableArray array];   // 本轮硬失败,循环内跳过
    int done = 0;
    int total = (int)index.count;
    for (NSString *a in index) {
        NSDictionary *ti = index[a];
        NSString *nm = SafeName([NSString stringWithFormat:@"%@ - %@",
                                 [ti[@"artist"] length] ? ti[@"artist"] : @"?",
                                  ti[@"title"] ?: a]);
        if ([[NSFileManager defaultManager] fileExistsAtPath:
                [dir stringByAppendingPathComponent:[nm stringByAppendingPathExtension:@"m4a"]]] ||
            [self sidecarGreen:[dir stringByAppendingPathComponent:
                                [nm stringByAppendingPathExtension:@"json"]]]) done++;
    }
    [self logf:logf fmt:@"[*] 已收 %d/%d", done, total];

    // ---- 连接一次,全程复用(短连接纪律在跟随内以"常驻探测"例外,断开靠退出) ----
    [OBADB shellRetry:@[@"forward", @"tcp:27042", @"tcp:27042"] timeout:20 error:nil];
    OBLink *link = [OBLink shared];
    NSString *cerr = nil;
    if (![link connectToProcess:OB_PROC_NAME error:&cerr]) {
        [self logf:logf fmt:@"[!] 引擎连接失败: %@(60s 后重试)", cerr ?: @"?"];
    }

    // ---- 存量收割:磁盘 key 批量探针,有效即收 ----
    NSDictionary *disk = [self readAllTrackKeys];
    [self logf:logf fmt:@"[*] 磁盘 key 快照: %lu 个", (unsigned long)disk.count];
    NSMutableArray *probeItems = [NSMutableArray array];
    NSMutableArray<NSString *> *probeAdams = [NSMutableArray array];
    for (NSString *a in index) {
        if (![disk[a] count]) continue;
        [probeAdams addObject:a];
        [probeItems addObject:@[ disk[a][1], @5, @NO ]];
    }
    if (probeItems.count) {
        NSArray *oks = [self probeKeys:link items:probeItems];
        for (NSUInteger i = 0; i < probeAdams.count; i++) {
            if (*cancelFlag) return;
            if (![oks[i] boolValue]) continue;
            NSString *a = probeAdams[i];
            [self logf:logf fmt:@"=== [存量] %@ key 有效,缓存直解 ===", a];
            NSDictionary *sc = [self runFromCache:a outDir:dir force:NO logf:logf cancel:cancelFlag error:nil];
            if (sc) done++;
            else [failed addObject:a];
        }
        [self logf:logf fmt:@"[*] 存量收割完成: %d/%d", done, total];
    }
    if (statusf) statusf([NSString stringWithFormat:@"跟随中 %d/%d", done, total]);

    // ---- 主循环:三路抓新鲜 key ----
    while (!*cancelFlag) {
        if (done >= total) { [self logf:logf fmt:@"[+] 全部曲目已收割完成"]; break; }
        [NSThread sleepForTimeInterval:secs];
        if (*cancelFlag) break;

        // 引擎掉线自动重连
        if (![link isConnected]) {
            NSString *e2 = nil;
            if (![link connectToProcess:OB_PROC_NAME error:&e2]) {
                [self logf:logf fmt:@"[!] 重连失败: %@(下轮再试)", e2 ?: @"?"];
                continue;
            }
        }

        // 剩余清单
        NSMutableArray<NSString *> *remaining = [NSMutableArray array];
        for (NSString *a in index) {
            if ([failed containsObject:a]) continue;
            NSDictionary *ti = index[a];
            NSString *nm = SafeName([NSString stringWithFormat:@"%@ - %@",
                                     [ti[@"artist"] length] ? ti[@"artist"] : @"?",
                                     ti[@"title"] ?: a]);
            if ([[NSFileManager defaultManager] fileExistsAtPath:
                    [dir stringByAppendingPathComponent:[nm stringByAppendingPathExtension:@"m4a"]]] ||
                [self sidecarGreen:[dir stringByAppendingPathComponent:
                                    [nm stringByAppendingPathExtension:@"json"]]]) continue;
            [remaining addObject:a];
        }
        if (statusf) statusf([NSString stringWithFormat:@"跟随中 %d/%d(待收 %lu)", done, total, (unsigned long)remaining.count]);
        if (!remaining.count) { [self logf:logf fmt:@"[+] 全部曲目已收割完成"]; break; }

        // 1) App 内存批量 sweep(纯读)+ 探针
        NSMutableArray *pairs = [NSMutableArray array];
        for (NSString *a in remaining) {
            NSString *uri = disk[a][0];
            if ([uri length]) [pairs addObject:@[ a, uri, @NO ]];
        }
        NSDictionary *mem = [self memKeys:link pairs:pairs];
        NSMutableArray *hits = [NSMutableArray array];
        if (mem.count) {
            NSMutableArray *mitems = [NSMutableArray array];
            NSMutableArray<NSString *> *madams = [NSMutableArray array];
            for (NSString *a in mem) {
                [madams addObject:a];
                [mitems addObject:@[ mem[a], @5, @NO ]];
            }
            NSArray *oks = [self probeKeys:link items:mitems];
            for (NSUInteger i = 0; i < madams.count; i++)
                if ([oks[i] boolValue]) [hits addObject:madams[i]];
        }
        // 2) 磁盘重读(内容比对,非 mtime):新 key/续租 → 探针
        NSDictionary *fresh = [self readAllTrackKeys];
        NSMutableArray *fitems = [NSMutableArray array];
        NSMutableArray<NSString *> *fadams = [NSMutableArray array];
        for (NSString *a in remaining) {
            if (![fresh[a] count]) continue;
            if ([disk[a][1] isEqualToString:fresh[a][1]]) continue;
            [fadams addObject:a];
            [fitems addObject:@[ fresh[a][1], @5, @NO ]];
        }
        if (fitems.count) {
            NSArray *oks = [self probeKeys:link items:fitems];
            for (NSUInteger i = 0; i < fadams.count; i++) {
                if ([oks[i] boolValue] && ![hits containsObject:fadams[i]]) [hits addObject:fadams[i]];
            }
        }
        disk = fresh;
        if (!hits.count) continue;

        // ---- 收割本轮命中 ----
        for (NSString *a in hits) {
            if (*cancelFlag) break;
            if ([failed containsObject:a]) continue;
            [self logf:logf fmt:@"=== [follow] %@ key 有效,开下 ===", a];
            NSDictionary *sc = [self runFromCache:a outDir:dir force:NO logf:logf cancel:cancelFlag error:nil];
            if (sc) {
                done++;
                [failed removeObject:a];
            } else {
                if (![failed containsObject:a]) [failed addObject:a];
            }
        }
        if (autoNext && ![[self frontMediaPackage] isEqualToString:OB_PHONE_PKG]) {
            [self logf:logf fmt:@"[!] 前台媒体会话非目标 App,跳过切歌"];
        } else if (autoNext) {
            [OBADB mediaKeyNext];
            [self logf:logf fmt:@"[*] 已切下一首"];
        }
    }
    [link disconnect];
    [self logf:logf fmt:@"=== 跟随收割退出 (%d/%d) ===", done, total];
}


#pragma mark - 一键安装引擎服务

+ (NSArray<NSString *> *)installEngineService {
    NSMutableArray *L = [NSMutableArray array];
    NSString *remote = [NSString stringWithFormat:@"/data/local/tmp/%@", OB_AGENT_SRV16];
    [L addObject:@"[安装] 引擎服务安装开始"];

    // 0) 现状检查
    NSString *have = [OBADB shellRetry:@[@"shell",
        [NSString stringWithFormat:@"su -c 'ls -l %@'", remote]] timeout:20 error:nil];
    if ([have containsString:OB_AGENT_SRV16]) {
        [L addObject:@"[安装] 手机端已存在服务本体,跳过下载"];
    } else {
        // 1) 下载(.xz,约 15MB;NSURLSession 自动跟随发布直链重定向)
        [L addObject:@"[安装] 下载服务本体(.xz)…"];
        NSString *derr = nil;
        NSData *xz = [OBHttp get:OB_KIT_URL header:@"" value:@"" timeout:600 error:&derr];
        if (![xz length]) {
            [L addObject:[NSString stringWithFormat:@"[安装] ❌ 下载失败: %@", derr ?: @"?"]];
            return L;
        }
        [L addObject:[NSString stringWithFormat:@"[安装] 下载完成 %lu 字节", (unsigned long)xz.length]];
        // 2) 本机解压(需要 xz;GUI 环境补 brew PATH)
        NSString *xzPath = [OBADB which:@"xz"];
        if (!xzPath) {
            [L addObject:@"[安装] ❌ 本机无 xz(brew install xz)"];
            return L;
        }
        NSString *tmpXz = @"/tmp/.amd_engine.xz";
        NSString *tmpBin = @"/tmp/.amd_engine";
        [xz writeToFile:tmpXz atomically:YES];
        int st = 0;
        [TaskRunner runSync:xzPath arguments:@[@"-d", @"-f", @"-k", tmpXz] cwd:nil env:nil status:&st];
        NSData *bin = [[NSData alloc] initWithContentsOfFile:tmpBin];
        if (![bin length]) {
            [L addObject:@"[安装] ❌ 解压失败"];
            return L;
        }
        [L addObject:[NSString stringWithFormat:@"[安装] 解压完成 %lu 字节", (unsigned long)bin.length]];
        // 3) push + chmod
        NSString *perr = nil;
        if (![OBADB shellRetry:@[@"push", tmpBin, remote] timeout:300 error:&perr]) {
            [L addObject:[NSString stringWithFormat:@"[安装] ❌ push 失败: %@", perr ?: @"?"]];
            return L;
        }
        [OBADB shellRetry:@[@"shell",
            [NSString stringWithFormat:@"su -c 'chmod 755 %@'", remote]] timeout:20 error:nil];
        [L addObject:@"[安装] 已推送并赋权"];
        [[NSFileManager defaultManager] removeItemAtPath:tmpXz error:NULL];
        [[NSFileManager defaultManager] removeItemAtPath:tmpBin error:NULL];
    }

    // 4) 杀旧进程并启动(启动形式与参考环境一致:root + 本机回环 27042)
    [OBADB shellRetry:@[@"shell",
        [NSString stringWithFormat:@"su -c 'pkill -f %@ || true'", OB_AGENT_SRV16]] timeout:20 error:nil];
    [NSThread sleepForTimeInterval:1];
    [OBADB shellRetry:@[@"shell",
        [NSString stringWithFormat:@"su -c 'nohup /data/local/tmp/%@ -l 127.0.0.1:27042 >/dev/null 2>&1 &'",
         OB_AGENT_SRV16]] timeout:20 error:nil];
    [NSThread sleepForTimeInterval:2];
    [L addObject:@"[安装] 服务已启动(root, 回环 27042)"];

    // 5) 引擎自检验证
    [L addObjectsFromArray:[self selfTest]];
    return L;
}

@end
