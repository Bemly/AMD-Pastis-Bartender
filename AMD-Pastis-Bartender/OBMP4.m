#import "OBMP4.h"
#import "OBStrings.h"
#include <malloc/_malloc.h>

@implementation OBMP4

#pragma mark - 基础工具

static inline uint32_t RD32(const uint8_t *d, uint32_t off) {
    return ((uint32_t)d[off] << 24) | ((uint32_t)d[off + 1] << 16) | ((uint32_t)d[off + 2] << 8) | d[off + 3];
}
static inline uint16_t RD16(const uint8_t *d, uint32_t off) {
    return (uint16_t)((d[off] << 8) | d[off + 1]);
}
static inline void WR32(uint8_t *d, uint32_t off, uint32_t v) {
    d[off] = (uint8_t)(v >> 24); d[off + 1] = (uint8_t)(v >> 16);
    d[off + 2] = (uint8_t)(v >> 8); d[off + 3] = (uint8_t)v;
}

#define FCC4(a, b, c, d) (((uint32_t)(a) << 24) | ((uint32_t)(b) << 16) | ((uint32_t)(c) << 8) | (uint32_t)(d))

// 敏感盒名:OB 池 → fourcc,运行时还原(懒加载一次)
static uint32_t g_fccProtDesc, g_fccProtWrap;
static void initFccs(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // OBS 已还原明文(盒名字面量),直接取 UTF8 字节——不能再当 base64 解一次
        const uint8_t *pa = (const uint8_t *)OBS(@"dGVuYw==").UTF8String;
        const uint8_t *pb = (const uint8_t *)OBS(@"c2luZg==").UTF8String;
        g_fccProtDesc = FCC4(pa[0], pa[1], pa[2], pa[3]);
        g_fccProtWrap = FCC4(pb[0], pb[1], pb[2], pb[3]);
    });
}

// 非敏感盒名直接字面量
enum {
    kMoov = 'moov', kTrak = 'trak', kMdia = 'mdia', kMinf = 'minf', kStbl = 'stbl',
    kMvex = 'mvex', kEdts = 'edts', kUdta = 'udta', kMoof = 'moof', kTraf = 'traf',
    kStsd = 'stsd', kSenc = 'senc', kSaiz = 'saiz', kSaio = 'saio', kPssh = 'pssh',
    kUuid = 'uuid', kSbgp = 'sbgp', kSgpd = 'sgpd', kTrun = 'trun', kTfhd = 'tfhd',
    kFrma = 'frma', kSchi = 'schi', kWave = 'wave', kMdat = 'mdat',
};

static inline BOOL isContainer(uint32_t t) {
    return t == kMoov || t == kTrak || t == kMdia || t == kMinf || t == kStbl ||
           t == kMvex || t == kEdts || t == kUdta || t == kSchi || t == kWave;
}

#pragma mark - 顶层解析

+ (void)parsePlain:(const uint8_t *)d len:(uint32_t)len from:(uint32_t)off to:(uint32_t)end out:(OBBoxList *)out {
    out->v = NULL; out->n = 0;
    uint32_t cap = 0;
    uint32_t pos = off;
    while (pos + 8 <= end && pos + 8 <= len) {
        uint32_t size = RD32(d, pos);
        uint32_t type = RD32(d, pos + 4);
        uint32_t hdr = 8;
        if (size == 1) { size = (uint32_t)(((uint64_t)RD32(d, pos + 8) << 32) | RD32(d, pos + 12)); hdr = 16; }
        else if (size == 0) { size = end - pos; }
        if (size < hdr || pos + size > end || pos + size > len) break;
        if (out->n >= (int)cap) {
            cap = cap ? cap * 2 : 16;
            out->v = (OBBox *)realloc(out->v, cap * sizeof(OBBox));
            if (!out->v) { out->n = 0; return; }
        }
        out->v[out->n++] = (OBBox){ type, pos, hdr, size };
        pos += size;
    }
}

+ (void)freeList:(OBBoxList *)l {
    free(l->v); l->v = NULL; l->n = 0;
}

#pragma mark - 清洗(融合 transform+encode;契约与参考脚本逐条对齐)

// 输入 [off,end);写出到 out(尺寸重算,一律 8B 头)
static void cleanRange(const uint8_t *d, uint32_t off, uint32_t end, BOOL inMoof, BOOL inStsdEntry,
                       NSMutableData *out, BOOL dedupe) {
    initFccs();
    uint32_t pos = off;
    while (pos + 8 <= end) {
        uint32_t size = RD32(d, pos);
        uint32_t type = RD32(d, pos + 4);
        uint32_t hdr = 8;
        if (size == 1) { size = (uint32_t)(((uint64_t)RD32(d, pos + 8) << 32) | RD32(d, pos + 12)); hdr = 16; }
        else if (size == 0) { size = end - pos; }
        if (size < hdr || pos + size > end) return;
        const uint8_t *pl = d + pos + hdr;
        uint32_t plLen = size - hdr;

        if (type == kStsd) {
            // 前缀 8B = 4B ver/flags + 4B entry_count;样本项自 +8 起
            uint8_t prefix[8];
            memcpy(prefix, pl, 8);
            NSMutableData *kids = [NSMutableData data];
            int written = 0;
            uint32_t epos = 8;
            while (epos + 36 <= plLen) {
                uint32_t esize = RD32(pl, epos);
                uint32_t etype = RD32(pl, epos + 4);
                if (esize < 36 || epos + esize > plLen) break;
                if (dedupe && written > 0) { epos += esize; continue; }   // 去重:只留首个
                // 样本项 = 8B hdr + 28B ASE + 子盒;取原格式(直系或包装内),丢包装
                uint32_t newType = 0;
                NSMutableData *kept = [NSMutableData data];
                OBBoxList kids1; [OBMP4 parsePlain:pl len:plLen from:epos + 36 to:epos + esize out:&kids1];
                for (int i = 0; i < kids1.n; i++) {
                    OBBox c = kids1.v[i];
                    if (c.type == kFrma) {
                        newType = RD32(pl, c.off + c.hdr);
                    } else if (c.type == g_fccProtWrap) {
                        OBBoxList kids2; [OBMP4 parsePlain:pl len:plLen from:c.off + c.hdr to:c.off + c.size out:&kids2];
                        for (int j = 0; j < kids2.n; j++)
                            if (kids2.v[j].type == kFrma)
                                newType = RD32(pl, kids2.v[j].off + kids2.v[j].hdr);
                        [OBMP4 freeList:&kids2];
                    } else {
                        cleanRange(pl, c.off, c.off + c.size, inMoof, YES, kept, dedupe);
                    }
                }
                [OBMP4 freeList:&kids1];
                uint32_t etype2 = newType ? newType : etype;
                uint8_t hdr8[8];
                WR32(hdr8, 0, 8 + 28 + (uint32_t)kept.length);
                WR32(hdr8, 4, etype2);
                [kids appendBytes:hdr8 length:8];
                [kids appendBytes:pl + epos + 8 length:28];
                [kids appendData:kept];
                written++;
                epos += esize;
            }
            WR32(prefix, 4, (uint32_t)written);   // entry_count 同步改写(历史坑)
            uint8_t hdr8[8];
            WR32(hdr8, 0, 8 + 8 + (uint32_t)kids.length);
            WR32(hdr8, 4, kStsd);
            [out appendBytes:hdr8 length:8];
            [out appendBytes:prefix length:8];
            [out appendData:kids];
        } else if (isContainer(type) || type == kMoof || type == kTraf) {
            NSMutableData *kids = [NSMutableData data];
            cleanRange(d, pos + hdr, pos + size, inMoof || type == kMoof || type == kTraf, inStsdEntry, kids, dedupe);
            uint8_t hdr8[8];
            WR32(hdr8, 0, 8 + (uint32_t)kids.length);
            WR32(hdr8, 4, type);
            [out appendBytes:hdr8 length:8];
            [out appendData:kids];
        } else {
            [out appendBytes:d + pos length:size];   // 叶子:原样保留
        }
        pos += size;
    }
}

+ (NSMutableData *)cleanInit:(const uint8_t *)d initEnd:(uint32_t)initEnd dedupe:(BOOL)dedupe {
    NSMutableData *out = [NSMutableData data];
    cleanRange(d, 0, initEnd, NO, NO, out, dedupe);
    return out;
}

// trun 数据偏移修正:偏移相对 moof 起点;moof 清洗后尺寸变化 → 同步平移
static void fixTrun(uint8_t *b, uint32_t off, uint32_t end, int delta) {
    uint32_t pos = off;
    while (pos + 8 <= end) {
        uint32_t size = RD32(b, pos);
        uint32_t type = RD32(b, pos + 4);
        uint32_t hdr = 8;
        if (size == 1) { size = (uint32_t)(((uint64_t)RD32(b, pos + 8) << 32) | RD32(b, pos + 12)); hdr = 16; }
        else if (size == 0) { size = end - pos; }
        if (size < hdr || pos + size > end) return;
        if (type == kTrun) {
            if (RD32(b, pos + 8) & 0x01) {
                int32_t doff = (int32_t)RD32(b, pos + 16);
                WR32(b, pos + 16, (uint32_t)(doff + delta));
            }
        } else if (type == kMoof || type == kTraf) {
            fixTrun(b, pos + hdr, pos + size, delta);
        }
        pos += size;
    }
}

+ (NSMutableData *)cleanMoof:(const uint8_t *)d from:(uint32_t)off to:(uint32_t)end {
    NSMutableData *out = [NSMutableData data];
    cleanRange(d, off, end, YES, NO, out, NO);
    int delta = (int)out.length - (int)(end - off);
    if (delta != 0 && out.length >= 8)
        fixTrun(out.mutableBytes, 8, (uint32_t)out.length, delta);
    return out;
}

#pragma mark - 碎片遍历

+ (int)fragments:(const uint8_t *)d len:(uint32_t)len from:(uint32_t)start
          moofOff:(uint32_t *)moofOff moofLen:(uint32_t *)moofLen
          mdatOff:(uint32_t *)mdatOff mdatLen:(uint32_t *)mdatLen
             next:(uint32_t *)next {
    uint32_t off = start;
    while (off + 8 <= len) {
        OBBoxList boxes;
        [self parsePlain:d len:len from:off to:len out:&boxes];
        int haveMoof = 0, haveMdat = 0;
        uint32_t mo = 0, ml = 0, mdo = 0, mdl = 0;
        for (int i = 0; i < boxes.n; i++) {
            OBBox b = boxes.v[i];
            if (b.type == kMoof && !haveMoof) { mo = b.off; ml = b.size; haveMoof = 1; }
            else if (b.type == kMdat && haveMoof) { mdo = b.off; mdl = b.size - 8; haveMdat = 1; break; }
        }
        uint32_t nx = haveMdat ? mdo + mdl + 8 : 0;
        [self freeList:&boxes];
        if (!haveMoof || !haveMdat) return 0;
        *moofOff = mo; *moofLen = ml; *mdatOff = mdo; *mdatLen = mdl; *next = nx;
        return 1;
    }
    return 0;
}

#pragma mark - 样本表

#define MAX_TRUNS 64
#define MAX_PER_TRUN 4096
#define MAX_SUBSAMPLES 8

+ (NSInteger)samplesInMoof:(const uint8_t *)d moofLen:(uint32_t)moofLen
                   moofOff:(uint32_t)moofOff mdatOff:(uint32_t)mdatOff
            defaultIvSize:(unsigned)ivSize
                    outCap:(unsigned)cap
                   outOff:(uint32_t *)outOff outSize:(uint32_t *)outSize
                  outSubN:(unsigned *)outSubN outSubOff:(unsigned *)outSubOff
                    subBuf:(uint32_t *)subBuf subCap:(unsigned)subCap {
    initFccs();
    const uint8_t *mp = d + moofOff;

    // 堆分配 trun 表(64×4096×4B≈1MB,不能上栈;线程栈只有 512K)
    struct { int32_t doff; uint32_t dsize; int n; uint32_t *sizes; } *truns = calloc(MAX_TRUNS, sizeof(*truns));
    if (!truns) return -1;
    int trunN = 0;
    const uint8_t *sencPayload = NULL;
    uint32_t sencLen = 0;

    OBBoxList top; [self parsePlain:mp len:moofLen from:0 to:moofLen out:&top];
    if (top.n == 1 && top.v[0].type == kMoof) {
        // mp 指向 moof 盒本体:顶层解析只会得到 moof 自己,子级(mfhd/traf)要从头之后取
        OBBoxList kids0; [self parsePlain:mp len:moofLen from:top.v[0].off + top.v[0].hdr to:top.v[0].size out:&kids0];
        [self freeList:&top];
        top = kids0;
    }
    for (int i = 0; i < top.n; i++) {
        OBBox b = top.v[i];
        if (b.type != kTraf) continue;
        OBBoxList kids; [self parsePlain:mp len:moofLen from:b.off + b.hdr to:b.off + b.size out:&kids];
        uint32_t dsize = 0;
        for (int j = 0; j < kids.n; j++) {          // 先扫 tfhd(trun 可能在其后)
            OBBox k2 = kids.v[j];
            if (k2.type != kTfhd) continue;
            const uint8_t *p = mp + k2.off + k2.hdr;
            uint32_t fl = RD32(p, 0) & 0xFFFFFF;
            uint32_t q = 8;
            if (fl & 0x01) q += 8;
            if (fl & 0x02) q += 4;
            if (fl & 0x08) q += 4;
            if (fl & 0x10) dsize = RD32(p, q);
        }
        for (int j = 0; j < kids.n; j++) {
            OBBox k2 = kids.v[j];
            if (k2.type == kTrun && trunN < MAX_TRUNS) {
                const uint8_t *p = mp + k2.off + k2.hdr;
                uint32_t flags = RD32(p, 0) & 0xFFFFFF;
                uint32_t count = RD32(p, 4);
                uint32_t q = 8;
                int32_t doff = 0;
                if (flags & 0x01) { doff = (int32_t)RD32(p, q); q += 4; }
                if (flags & 0x04) q += 4;
                truns[trunN].doff = doff; truns[trunN].dsize = dsize; truns[trunN].n = 0;
                truns[trunN].sizes = malloc(MAX_PER_TRUN * sizeof(uint32_t));
                if (!truns[trunN].sizes) { trunN++; goto done; }
                int n = 0;
                for (uint32_t s = 0; s < count && n < MAX_PER_TRUN; s++) {
                    if (flags & 0x100) q += 4;
                    uint32_t sz = 0xFFFFFFFF;
                    if (flags & 0x200) { sz = RD32(p, q); q += 4; }
                    if (flags & 0x400) q += 4;
                    if (flags & 0x800) q += 4;
                    truns[trunN].sizes[n++] = sz;
                }
                truns[trunN].n = n;
                trunN++;
            } else if (k2.type == kSenc && !sencPayload) {
                sencPayload = mp + k2.off + k2.hdr;
                sencLen = k2.size - k2.hdr;
            } else if (k2.type == kUuid && !sencPayload && k2.size - k2.hdr >= 20 &&
                       memcmp(mp + k2.off + k2.hdr + 16, "senc", 4) == 0) {
                sencPayload = mp + k2.off + k2.hdr + 20;
                sencLen = k2.size - k2.hdr - 20;
            }
        }
        [self freeList:&kids];
    }
done:
    [self freeList:&top];

    // 样本偏移/大小(trun 序;size 省略时回退 tfhd 默认,再无则失败——参考脚本同款)
    NSInteger n = 0;
    int32_t cursor = -1;
    for (int ti = 0; ti < trunN; ti++) {
        int32_t o = truns[ti].doff ? truns[ti].doff : (cursor >= 0 ? cursor : 0);
        for (int s = 0; s < truns[ti].n; s++) {
            uint32_t sz = truns[ti].sizes[s];
            if (sz == 0xFFFFFFFF) {
                if (truns[ti].dsize) sz = truns[ti].dsize;
                else goto fail;
            }
            if ((unsigned)n >= cap) goto fail;
            outOff[n] = (uint32_t)((int64_t)moofOff + o - (int64_t)(mdatOff + 8));
            outSize[n] = sz;
            n++;
            o += (int32_t)sz;
        }
        cursor = o;
    }

    // 子样本:整个 moof 共用首个 senc(实测形态:每样本 1 项 (0, 全长) 的全样本保护编码)
    unsigned subUsed = 0;
    uint32_t sencCount = 0;
    uint32_t *sencSubs = NULL;      // [i][k][2] = (clear, prot),k < MAX_SUBSAMPLES
    uint32_t *perSample = NULL;
    if (sencPayload && sencLen >= 8) {
        uint32_t flags = RD32(sencPayload, 0) & 0xFFFFFF;
        sencCount = RD32(sencPayload, 4);
        if (sencCount > (uint32_t)cap) sencCount = (uint32_t)cap;
        sencSubs = malloc((size_t)sencCount * MAX_SUBSAMPLES * 2 * sizeof(uint32_t));
        perSample = malloc((size_t)sencCount * sizeof(uint32_t));
        uint32_t q = 8;
        for (uint32_t i = 0; i < sencCount; i++) {
            q += ivSize;
            uint32_t sc = 0;
            if (flags & 0x2) {
                if (q + 2 > sencLen) { sencCount = i; break; }
                sc = RD16(sencPayload, q); q += 2;
                if (sc > MAX_SUBSAMPLES) sc = MAX_SUBSAMPLES;
            }
            for (uint32_t k = 0; k < sc; k++) {
                if (q + 6 > sencLen) { sc = k; break; }
                sencSubs[(i * MAX_SUBSAMPLES + k) * 2] = RD16(sencPayload, q);
                sencSubs[(i * MAX_SUBSAMPLES + k) * 2 + 1] = RD32(sencPayload, q + 2);
                q += 6;
            }
            perSample[i] = sc;
        }
    }
    for (NSInteger i = 0; i < n; i++) {
        unsigned cnt = 0, off0 = 0;
        if (sencSubs && i < (NSInteger)sencCount) {
            cnt = perSample[i];
            if (subUsed + cnt > subCap) cnt = subCap - subUsed;
            for (unsigned k = 0; k < cnt; k++) {
                subBuf[(subUsed + k) * 2] = sencSubs[(i * MAX_SUBSAMPLES + k) * 2];
                subBuf[(subUsed + k) * 2 + 1] = sencSubs[(i * MAX_SUBSAMPLES + k) * 2 + 1];
            }
            off0 = subUsed;
            subUsed += cnt;
        }
        outSubN[i] = cnt;
        outSubOff[i] = off0;
    }
    free(sencSubs);
    free(perSample);
    for (int ti = 0; ti < trunN; ti++) free(truns[ti].sizes);
    free(truns);
    return n;

fail:
    for (int ti = 0; ti < trunN; ti++) free(truns[ti].sizes);
    free(truns);
    return -1;
}

+ (NSData *)buildSampleCt:(const uint8_t *)region len:(uint32_t)len
                    subs:(const uint32_t *)subs subN:(unsigned)subN
                  splice:(uint32_t *)spliceBuf spliceCap:(unsigned)spliceCap
                   outN:(unsigned *)outN {
    NSMutableData *ct = [NSMutableData data];
    uint32_t segs[128][2];
    int segN = 0;
    if (subN) {
        uint32_t pos = 0;
        for (unsigned i = 0; i < subN && segN < 128; i++) {
            uint32_t clear = subs[i * 2], prot = subs[i * 2 + 1];
            pos += clear;
            if (pos + prot > len) break;
            if (prot > 0) { segs[segN][0] = pos; segs[segN][1] = prot; segN++; }
            pos += prot;
        }
    } else {
        segs[0][0] = 0; segs[0][1] = len; segN = 1;
    }
    unsigned sn = 0;
    for (int i = 0; i < segN; i++) {
        uint32_t o = segs[i][0], l = segs[i][1];
        uint32_t full = l & ~0xFu;
        if (full && o + full <= len) {
            [ct appendBytes:region + o length:full];
            if (sn < spliceCap) { spliceBuf[sn * 2] = o; spliceBuf[sn * 2 + 1] = full; sn++; }
        }
    }
    *outN = sn;
    return ct;
}

+ (void)splicePlain:(uint8_t *)region len:(uint32_t)len
              plain:(const uint8_t *)plain plainLen:(uint32_t)plainLen
             splice:(const uint32_t *)spliceBuf n:(unsigned)spliceN {
    uint32_t p = 0;
    for (unsigned i = 0; i < spliceN; i++) {
        uint32_t o = spliceBuf[i * 2], l = spliceBuf[i * 2 + 1];
        if (o + l > len || p + l > plainLen) return;
        memcpy(region + o, plain + p, l);
        p += l;
    }
}


+ (int)findProt:(const uint8_t *)d len:(uint32_t)len initEnd:(uint32_t)initEnd
            out:(OBProtBox *)outArr cap:(int)cap {
    initFccs();
    int found = 0;
    OBBoxList l0; [self parsePlain:d len:len from:0 to:initEnd out:&l0];
    for (int i = 0; i < l0.n && found < cap; i++) {
        if (l0.v[i].type != kMoov) continue;
        OBBoxList l1; [self parsePlain:d len:len from:l0.v[i].off + l0.v[i].hdr to:l0.v[i].off + l0.v[i].size out:&l1];
        for (int a = 0; a < l1.n && found < cap; a++) {
            if (l1.v[a].type != kTrak) continue;
            OBBoxList l2; [self parsePlain:d len:len from:l1.v[a].off + l1.v[a].hdr to:l1.v[a].off + l1.v[a].size out:&l2];
            for (int b2 = 0; b2 < l2.n && found < cap; b2++) {
                if (l2.v[b2].type != kMdia) continue;
                OBBoxList l3; [self parsePlain:d len:len from:l2.v[b2].off + l2.v[b2].hdr to:l2.v[b2].off + l2.v[b2].size out:&l3];
                for (int c2 = 0; c2 < l3.n && found < cap; c2++) {
                    if (l3.v[c2].type != kMinf) continue;
                    OBBoxList l4; [self parsePlain:d len:len from:l3.v[c2].off + l3.v[c2].hdr to:l3.v[c2].off + l3.v[c2].size out:&l4];
                    for (int e = 0; e < l4.n && found < cap; e++) {
                        if (l4.v[e].type != kStbl) continue;
                        OBBoxList l5; [self parsePlain:d len:len from:l4.v[e].off + l4.v[e].hdr to:l4.v[e].off + l4.v[e].size out:&l5];
                        for (int f2 = 0; f2 < l5.n && found < cap; f2++) {
                            if (l5.v[f2].type != kStsd) continue;
                            const uint8_t *p5 = d + l5.v[f2].off + l5.v[f2].hdr;
                            uint32_t pl5 = l5.v[f2].size - l5.v[f2].hdr;
                            uint32_t epos = 8;
                            while (epos + 36 <= pl5 && found < cap) {
                                uint32_t esize = RD32(p5, epos);
                                if (esize < 36 || epos + esize > pl5) break;
                                OBBoxList ent; [self parsePlain:p5 len:pl5 from:epos + 36 to:epos + esize out:&ent];
                                for (int g = 0; g < ent.n && found < cap; g++) {
                                    if (ent.v[g].type != g_fccProtWrap) continue;
                                    const uint8_t *pw = p5 + ent.v[g].off + ent.v[g].hdr;
                                    uint32_t pwl = ent.v[g].size - ent.v[g].hdr;
                                    OBBoxList l6; [self parsePlain:pw len:pwl from:0 to:pwl out:&l6];
                                    for (int h = 0; h < l6.n && found < cap; h++) {
                                        if (l6.v[h].type != kSchi) continue;
                                        const uint8_t *ps = pw + l6.v[h].off + l6.v[h].hdr;
                                        uint32_t psl = l6.v[h].size - l6.v[h].hdr;
                                        OBBoxList l7; [self parsePlain:ps len:psl from:0 to:psl out:&l7];
                                        for (int k = 0; k < l7.n && found < cap; k++) {
                                            if (l7.v[k].type != g_fccProtDesc) continue;
                                            const uint8_t *tp = ps + l7.v[k].off + l7.v[k].hdr;
                                            uint32_t tpl = l7.v[k].size - l7.v[k].hdr;
                                            if (tpl < 26) continue;
                                            OBProtBox *o = &outArr[found++];
                                            memset(o, 0, sizeof(*o));
                                            unsigned ver = tp[0];
                                            o->perSampleIvSize = tp[5];
                                            memcpy(o->kid, tp + 6, 16);
                                            if (ver == 1) {
                                                o->crypt = tp[22]; o->skip = tp[23];
                                                unsigned civ = tp[24];
                                                if (civ > 16) civ = 16;
                                                if (25 + civ <= tpl) { memcpy(o->constIv, tp + 25, civ); o->constIvLen = civ; }
                                            }
                                        }
                                        [self freeList:&l7];
                                    }
                                    [self freeList:&l6];
                                }
                                [self freeList:&ent];
                                epos += esize;
                            }
                        }
                        [self freeList:&l5];
                    }
                    [self freeList:&l4];
                }
                [self freeList:&l3];
            }
            [self freeList:&l2];
        }
        [self freeList:&l1];
    }
    [self freeList:&l0];
    return found;
}


#pragma mark - 标签写入(ilst;字节布局与参考工具产物逐一对齐)

// ilst 条目:data 子原子 = size+'data'+[3B 零+1B 类型]+4B locale+payload
static NSMutableData *tagEntry(uint32_t fcc, uint32_t type, const void *payload, uint32_t plen) {
    uint32_t dsz = 16 + plen;
    NSMutableData *m = [NSMutableData dataWithCapacity:8 + dsz];
    uint8_t h[16];
    WR32(h, 0, dsz); h[4]='d'; h[5]='a'; h[6]='t'; h[7]='a';
    h[8]=0; h[9]=0; h[10]=0; h[11]=(uint8_t)type; WR32(h, 12, 0);   // locale 0
    [m appendBytes:h length:16];
    if (plen) [m appendBytes:payload length:plen];
    NSMutableData *out = [NSMutableData dataWithCapacity:m.length + 8];
    uint8_t ah[8]; WR32(ah, 0, (uint32_t)m.length + 8); WR32(ah, 4, fcc);
    [out appendBytes:ah length:8]; [out appendData:m];
    return out;
}

static NSMutableData *tagText(uint32_t fcc, NSString *s) {
    if (![s length]) return nil;
    NSData *u = [s dataUsingEncoding:NSUTF8StringEncoding];
    return tagEntry(fcc, 1, u.bytes, (uint32_t)u.length);
}

static void putU16(uint8_t *p, unsigned v) { p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)v; }

// 前向声明(定义在 applyTags 之后,两者共用 splice 逻辑)
static uint32_t spliceNewUdta(NSMutableData *d, NSData *il);

// meta 容器内的 hdlr:参考工具产物常量字节(33B,mdir/appl)
static const uint8_t kMetaHdlr[33] = {
    0x00,0x00,0x00,0x21, 'h','d','l','r', 0,0,0,0, 0,0,0,0,
    'm','d','i','r', 'a','p','p','l', 0,0,0,0, 0,0,0,0, 0x00
};

// moov 内递归找 stco/stco64,块偏移(绝对)在插点之后的一律 +delta
static void shiftChunks(const uint8_t *d, uint32_t off, uint32_t end, uint32_t insertPos, int32_t delta) {
    uint32_t pos = off;
    while (pos + 8 <= end) {
        uint32_t size = RD32(d, pos);
        uint32_t type = RD32(d, pos + 4);
        uint32_t hdr = 8;
        if (size == 1) { size = (uint32_t)(((uint64_t)RD32(d, pos + 8) << 32) | RD32(d, pos + 12)); hdr = 16; }
        else if (size == 0) { size = end - pos; }
        if (size < hdr || pos + size > end) return;
        const uint8_t *pl = d + pos + hdr;
        uint32_t plLen = size - hdr;
        if (type == FCC4('s','t','c','o') && plLen >= 8) {
            uint32_t n = RD32(pl, 4);
            for (uint32_t i = 0; i < n && 8 + i * 4 + 4 <= plLen; i++) {
                uint32_t q = 8 + i * 4;
                uint32_t v = RD32(pl, q);
                if (v >= insertPos) WR32((uint8_t *)pl, q, (uint32_t)(v + delta));
            }
        } else if (type == FCC4('c','o','6','4') && plLen >= 8) {
            uint32_t n = RD32(pl, 4);
            for (uint32_t i = 0; i < n && 8 + i * 8 + 8 <= plLen; i++) {
                uint32_t q = 8 + i * 8;
                uint64_t v = ((uint64_t)RD32(pl, q) << 32) | RD32(pl, q + 4);
                if (v >= insertPos) {
                    uint64_t nv = v + delta;
                    WR32((uint8_t *)pl, q, (uint32_t)(nv >> 32));
                    WR32((uint8_t *)pl, q + 4, (uint32_t)nv);
                }
            }
        }
        if (type == kMoov || type == kTrak || type == kMdia || type == kMinf || type == kStbl) {
            shiftChunks(d, pos + hdr, pos + size, insertPos, delta);
        }
        pos += size;
    }
}

+ (uint32_t)applyTags:(NSMutableData *)d meta:(NSDictionary *)meta {
    initFccs();
    const uint8_t *b = d.bytes;
    uint32_t len = (uint32_t)d.length;
    OBBoxList top; [self parsePlain:b len:len from:0 to:len out:&top];
    int moovi = -1;
    for (int i = 0; i < top.n; i++) if (top.v[i].type == kMoov) { moovi = i; break; }
    if (moovi < 0) { [self freeList:&top]; return 0; }
    uint32_t moovOff = top.v[moovi].off, moovSize = top.v[moovi].size, moovHdr = top.v[moovi].hdr;
    [self freeList:&top];

    // ---- 组 ilst 条目(顺序与参考产物一致) ----
    NSMutableData *il = [NSMutableData data];
    [il appendData:tagText(0xA96E616D, meta[@"title"]) ?: [NSData data]];
    [il appendData:tagText(0xA9415254, meta[@"artist"]) ?: [NSData data]];
    [il appendData:tagText(0x61415254, [meta[@"artist"] length] ? meta[@"artist"] : meta[@"albumArtist"]) ?: [NSData data]];
    [il appendData:tagText(0xA9616C62, meta[@"album"]) ?: [NSData data]];
    [il appendData:tagText(0xA967656E, meta[@"genre"]) ?: [NSData data]];
    [il appendData:tagText(0xA9646179, meta[@"date"]) ?: [NSData data]];
    [il appendData:tagText(FCC4('c','p','r','t'), meta[@"copyright"]) ?: [NSData data]];
    [il appendData:tagText(0xA96C7972, meta[@"lyrics"]) ?: [NSData data]];   // ©lyr 歌词全文
    unsigned trk = [meta[@"track"] unsignedIntValue], trkTotal = [meta[@"track_total"] unsignedIntValue];
    if (trk) {
        uint8_t tp[8] = {0};
        putU16(tp + 2, trk); putU16(tp + 4, trkTotal);
        [il appendData:tagEntry(FCC4('t','r','k','n'), 0, tp, 8)];
    }
    unsigned disc = [meta[@"disc"] unsignedIntValue];
    if (disc) {
        uint8_t dp[6] = {0};
        putU16(dp + 2, disc);
        [il appendData:tagEntry(FCC4('d','i','s','k'), 0, dp, 6)];
    }
    NSData *cover = meta[@"cover"];
    if ([cover length] > 8) {
        const uint8_t *c = cover.bytes;
        uint32_t ctype = (c[0] == 0xFF && c[1] == 0xD8) ? 13 : (c[0] == 0x89 && c[1] == 'P') ? 14 : 0;
        if (ctype) [il appendData:tagEntry(FCC4('c','o','v','r'), ctype, c, (uint32_t)cover.length)];
    }
    if (!il.length) return 0;
    return spliceNewUdta(d, il);
}

// 只写歌词:保留现有 ilst 条目(©lyr 除外原样拷贝),替换/追加 ©lyr 后走同一套重建。
// 标题/封面等旧标签不受影响,可反复重打。
+ (uint32_t)applyLyrics:(NSMutableData *)d lyrics:(NSString *)text error:(NSString **)err {
    if (!text.length) { if (err) *err = @"歌词为空"; return 0; }
    const uint8_t *b = d.bytes;
    uint32_t len = (uint32_t)d.length;
    NSMutableData *kept = [NSMutableData data];
    OBBoxList top; [self parsePlain:b len:len from:0 to:len out:&top];
    for (int i = 0; i < top.n; i++) {
        if (top.v[i].type != kMoov) continue;
        uint32_t mo = top.v[i].off, me = mo + top.v[i].size;
        OBBoxList kids; [self parsePlain:b len:len from:mo + top.v[i].hdr to:me out:&kids];
        for (int k = 0; k < kids.n; k++) {
            if (kids.v[k].type != kUdta) continue;
            uint32_t uo = kids.v[k].off, ue = uo + kids.v[k].size;
            OBBoxList uk; [self parsePlain:b len:len from:uo + 8 to:ue out:&uk];
            for (int m = 0; m < uk.n; m++) {
                if (uk.v[m].type != FCC4('m','e','t','a')) continue;
                uint32_t no = uk.v[m].off, ne = no + uk.v[m].size;
                OBBoxList nk; [self parsePlain:b len:len from:no + 12 to:ne out:&nk];
                for (int q = 0; q < nk.n; q++) {
                    if (nk.v[q].type != FCC4('i','l','s','t')) continue;
                    uint32_t io = nk.v[q].off, ie = io + nk.v[q].size;
                    OBBoxList items; [self parsePlain:b len:len from:io + 8 to:ie out:&items];
                    for (int t = 0; t < items.n; t++) {
                        if (items.v[t].type == 0xA96C7972) continue;   // 旧 ©lyr 丢掉
                        [kept appendBytes:b + items.v[t].off length:items.v[t].size];
                    }
                    [self freeList:&items];
                }
                [self freeList:&nk];
            }
            [self freeList:&uk];
        }
        [self freeList:&kids];
    }
    [self freeList:&top];
    NSMutableData *il = [kept mutableCopy] ?: [NSMutableData data];
    NSData *lyr = tagText(0xA96C7972, text);
    if (!lyr) { if (err) *err = @"组装失败"; return 0; }
    [il appendData:lyr];
    uint32_t nl = spliceNewUdta(d, il);
    if (!nl && err) *err = @"重建失败";
    return nl;
}

// 新 udta(由 ilst 条目载荷组装)替换旧标签并重建文件;applyTags 与 applyLyrics 共用
static uint32_t spliceNewUdta(NSMutableData *d, NSData *il) {
    const uint8_t *b = d.bytes;
    uint32_t len = (uint32_t)d.length;
    OBBoxList top; [OBMP4 parsePlain:b len:len from:0 to:len out:&top];
    int moovi = -1;
    for (int i = 0; i < top.n; i++) if (top.v[i].type == kMoov) { moovi = i; break; }
    if (moovi < 0) { [OBMP4 freeList:&top]; return 0; }
    uint32_t moovOff = top.v[moovi].off, moovSize = top.v[moovi].size, moovHdr = top.v[moovi].hdr;
    [OBMP4 freeList:&top];
    uint8_t ilh[8]; WR32(ilh, 0, (uint32_t)il.length + 8); WR32(ilh, 4, FCC4('i','l','s','t'));
    NSMutableData *ilstWrap = [NSMutableData data];
    [ilstWrap appendBytes:ilh length:8]; [ilstWrap appendData:il];

    NSMutableData *metaBox = [NSMutableData data];
    uint8_t mh[12]; WR32(mh, 0, (uint32_t)ilstWrap.length + 12 + (uint32_t)sizeof(kMetaHdlr));
    WR32(mh, 4, FCC4('m','e','t','a')); WR32(mh, 8, 0);
    [metaBox appendBytes:mh length:12];
    [metaBox appendBytes:kMetaHdlr length:sizeof(kMetaHdlr)];
    [metaBox appendData:ilstWrap];
    NSMutableData *udtaBox = [NSMutableData data];
    uint8_t uh[8]; WR32(uh, 0, (uint32_t)metaBox.length + 8); WR32(uh, 4, FCC4('u','d','t','a'));
    [udtaBox appendBytes:uh length:8]; [udtaBox appendData:metaBox];

    // ---- 定位旧标签 udta(moov 直属且含 meta)与插入点 ----
    uint32_t insertPos = moovOff + moovSize;
    uint32_t removeOff = 0, removeLen = 0;
    {
        OBBoxList kids; [OBMP4 parsePlain:b len:len from:moovOff + moovHdr to:moovOff + moovSize out:&kids];
        for (int i = 0; i < kids.n; i++) {
            if (kids.v[i].type != FCC4('u','d','t','a')) continue;
            OBBoxList uk; [OBMP4 parsePlain:b len:len from:kids.v[i].off + 8 to:kids.v[i].off + kids.v[i].size out:&uk];
            BOOL hasMeta = NO;
            for (int j = 0; j < uk.n; j++) if (uk.v[j].type == FCC4('m','e','t','a')) { hasMeta = YES; break; }
            [OBMP4 freeList:&uk];
            if (hasMeta) { removeOff = kids.v[i].off; removeLen = kids.v[i].size; break; }
        }
        if (removeLen) {
            insertPos = removeOff;           // 原位替换
        } else {
            for (int i = 0; i < kids.n; i++) if (kids.v[i].type == kMvex) { insertPos = kids.v[i].off; break; }
        }
        [OBMP4 freeList:&kids];
    }

    // ---- 重建:[0,insertPos) + 新 udta + [insertPos+removeLen, len) ----
    if (insertPos + removeLen > len) return 0;
    NSMutableData *nd = [NSMutableData dataWithCapacity:len + udtaBox.length - removeLen];
    [nd appendBytes:b length:insertPos];
    [nd appendData:udtaBox];
    [nd appendBytes:b + insertPos + removeLen length:len - insertPos - removeLen];
    uint8_t *nb = nd.mutableBytes;

    // ---- 尺寸/偏移修正 ----
    int32_t delta = (int32_t)udtaBox.length - (int32_t)removeLen;
    WR32(nb, moovOff, moovSize + delta);
    if (delta != 0) {
        OBBoxList top2; [OBMP4 parsePlain:nb len:(uint32_t)nd.length from:0 to:(uint32_t)nd.length out:&top2];
        for (int i = 0; i < top2.n; i++) {
            if (top2.v[i].type == kMoov)
                shiftChunks(nb, top2.v[i].off + top2.v[i].hdr, top2.v[i].off + top2.v[i].size, insertPos, delta);
        }
        [OBMP4 freeList:&top2];
    }

    [d setData:nd];
    return (uint32_t)nd.length;
}

#pragma mark - 内嵌歌词读取(©lyr)

+ (nullable NSString *)readLyrics:(NSData *)d error:(NSString **)err {
    const uint8_t *b = d.bytes;
    uint32_t len = (uint32_t)d.length;
    if (len < 8) { if (err) *err = @"文件过小"; return nil; }
    // moov → udta(含 meta) → meta → ilst → ©lyr → data,逐层下钻
    OBBoxList top; [self parsePlain:b len:len from:0 to:len out:&top];
    uint32_t moovOff = UINT32_MAX, moovHdr = 8, moovEnd = 0;
    for (int i = 0; i < top.n; i++) {
        if (top.v[i].type == kMoov) {
            moovOff = top.v[i].off; moovHdr = top.v[i].hdr;
            moovEnd = moovOff + top.v[i].size;
            break;
        }
    }
    [self freeList:&top];
    if (moovOff == UINT32_MAX) { if (err) *err = @"无 moov"; return nil; }
    OBBoxList kids; [self parsePlain:b len:len from:moovOff + moovHdr to:moovEnd out:&kids];
    uint32_t udtaOff = UINT32_MAX, udtaEnd = 0;
    for (int i = 0; i < kids.n; i++) {
        if (kids.v[i].type != kUdta) continue;
        uint32_t uo = kids.v[i].off, ue = uo + kids.v[i].size;
        OBBoxList uk; [self parsePlain:b len:len from:uo + 8 to:ue out:&uk];
        for (int j = 0; j < uk.n; j++) {
            if (uk.v[j].type == FCC4('m','e','t','a')) { udtaOff = uo; udtaEnd = ue; break; }
        }
        [self freeList:&uk];
        if (udtaOff != UINT32_MAX) break;
    }
    [self freeList:&kids];
    if (udtaOff == UINT32_MAX) { if (err) *err = @"无标签"; return nil; }
    // meta 内容从版本/标志 4B 后开始
    OBBoxList mk; [self parsePlain:b len:len from:udtaOff + 8 to:udtaEnd out:&mk];
    uint32_t metaOff = UINT32_MAX, metaEnd = 0;
    for (int i = 0; i < mk.n; i++) {
        if (mk.v[i].type == FCC4('m','e','t','a')) {
            metaOff = mk.v[i].off; metaEnd = metaOff + mk.v[i].size;
            break;
        }
    }
    [self freeList:&mk];
    if (metaOff == UINT32_MAX) return nil;
    OBBoxList ik; [self parsePlain:b len:len from:metaOff + 8 + 4 to:metaEnd out:&ik];
    uint32_t ilstOff = UINT32_MAX, ilstEnd = 0;
    for (int i = 0; i < ik.n; i++) {
        if (ik.v[i].type == FCC4('i','l','s','t')) {
            ilstOff = ik.v[i].off; ilstEnd = ilstOff + ik.v[i].size;
            break;
        }
    }
    [self freeList:&ik];
    if (ilstOff == UINT32_MAX) { if (err) *err = @"无 ilst"; return nil; }
    OBBoxList items; [self parsePlain:b len:len from:ilstOff + 8 to:ilstEnd out:&items];
    NSString *out = nil;
    for (int i = 0; i < items.n && !out; i++) {
        if (items.v[i].type != 0xA96C7972) continue;   // ©lyr
        uint32_t io = items.v[i].off, ie = io + items.v[i].size;
        OBBoxList dk; [self parsePlain:b len:len from:io + 8 to:ie out:&dk];
        for (int j = 0; j < dk.n; j++) {
            if (dk.v[j].type != FCC4('d','a','t','a')) continue;
            uint32_t doff = dk.v[j].off, dsize = dk.v[j].size;
            if (doff + 16 <= ie && doff + dsize <= len) {
                uint32_t plen = dsize - 16;   // data 头 16B(尺寸+名+类型+locale)
                out = [[NSString alloc] initWithBytes:b + doff + 16 length:plen
                                             encoding:NSUTF8StringEncoding];
            }
            break;
        }
        [self freeList:&dk];
    }
    [self freeList:&items];
    if (!out && err) *err = @"无内嵌歌词";
    return out;
}

@end
