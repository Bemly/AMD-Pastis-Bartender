#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// fMP4 盒子解析/清洗/重建(参考脚本同款契约,含全部历史修复:
// stsd 样本项 ASE 前缀 + entry_count 改写 + 包装内取原格式 + 去重可选 + trun 偏移修正)。
// 敏感盒名不作明文,运行时由 Base64 还原 fourcc。
@interface OBMP4 : NSObject

// 保护方案描述盒(等价参考脚本的提取;每样本项一个,顺序返回)
typedef struct {
    unsigned perSampleIvSize;      // 0 = 无逐样本 IV(全样本加密 + 常量 IV)
    unsigned char kid[16];
    unsigned crypt, skip;
    unsigned char constIv[16];
    unsigned constIvLen;
} OBProtBox;

// 顶层盒子(largesize/到尾扩展已处理)
typedef struct { uint32_t type; uint32_t off; uint32_t hdr; uint32_t size; } OBBox;
typedef struct { OBBox *v; int n; } OBBoxList;

+ (void)parsePlain:(const uint8_t *)d len:(uint32_t)len from:(uint32_t)off to:(uint32_t)end out:(OBBoxList *)out;
+ (void)freeList:(OBBoxList *)l;

// 在 init 段找保护方案描述盒(每个样本项一个;返回写入个数,取第 0 个用)
+ (int)findProt:(const uint8_t *)d len:(uint32_t)len initEnd:(uint32_t)initEnd
            out:(OBProtBox *)outArr cap:(int)cap;

// 清洗 init 段(去保护包装、样本项改回原格式、entry_count 同步;dedupe=只留首个样本项)
+ (NSMutableData *)cleanInit:(const uint8_t *)d initEnd:(uint32_t)initEnd dedupe:(BOOL)dedupe;

// 清洗单个 moof(纯透传:实测参考脚本对 moof 内叶子盒一个不丢,trun 偏移无需修正)。
// [off,end) 应恰好覆盖完整 moof 盒。
+ (NSMutableData *)cleanMoof:(const uint8_t *)d from:(uint32_t)off to:(uint32_t)end;

// 遍历碎片:从 start 起找 (moof, mdat) 对;*next 为下一轮起点。有碎片返回 1。
+ (int)fragments:(const uint8_t *)d len:(uint32_t)len from:(uint32_t)start
          moofOff:(uint32_t *)moofOff moofLen:(uint32_t *)moofLen
          mdatOff:(uint32_t *)mdatOff mdatLen:(uint32_t *)mdatLen
             next:(uint32_t *)next;

// 样本表(整个 moof)。返回样本个数,失败 -1。
// outOff/outSize/outSubN/outSubOff 均为调用方分配的 [cap] 数组;subBuf 为 (clear,prot)
// 扁平对数组 [subCap*2]。子样本取 moof 内首个 senc(实测形态即如此),按样本序对齐。
+ (NSInteger)samplesInMoof:(const uint8_t *)d moofLen:(uint32_t)moofLen
                   moofOff:(uint32_t)moofOff mdatOff:(uint32_t)mdatOff
            defaultIvSize:(unsigned)ivSize
                    outCap:(unsigned)cap
                   outOff:(uint32_t *)outOff outSize:(uint32_t *)outSize
                  outSubN:(unsigned *)outSubN outSubOff:(unsigned *)outSubOff
                    subBuf:(uint32_t *)subBuf subCap:(unsigned)subCap;

// 拆样本:返回需解密的整块拼接(16B 对齐段;尾零头按规约留明文),
// splice 输出 (off,len) 对 [2*cap],数量 *outN
+ (NSData *)buildSampleCt:(const uint8_t *)region len:(uint32_t)len
                    subs:(const uint32_t *)subs subN:(unsigned)subN
                  splice:(uint32_t *)spliceBuf spliceCap:(unsigned)spliceCap
                   outN:(unsigned *)outN;

// 回拼:region 原地按 splice 位置写入 plain
+ (void)splicePlain:(uint8_t *)region len:(uint32_t)len
              plain:(const uint8_t *)plain plainLen:(uint32_t)plainLen
             splice:(const uint32_t *)spliceBuf n:(unsigned)spliceN;

// 写入 iTunes 风格标签(在 moov 末尾补 udta→meta→hdlr→ilst,布局与参考工具产物逐字节对齐;
// 已有标签 udta 则先删再写,可重打)。meta 键:title/artist/album/genre/date/track/track_total/
// disc/copyright/lyrics(NSString;lyrics 为歌词全文,©lyr 文本原子),cover(NSData,
// JPEG ffd8→类型13 / PNG→类型14,可缺)。
// 就地修改 d;stco/stco64 块偏移同步平移。返回新长度,失败 0。
+ (uint32_t)applyTags:(NSMutableData *)d meta:(NSDictionary *)meta;

// 只写歌词(©lyr):保留现有 ilst 条目原样,替换/追加后走同一套重建(旧标签不受影响)。
// 就地修改 d;返回新长度,失败 0。
+ (uint32_t)applyLyrics:(NSMutableData *)d lyrics:(NSString *)text
                  error:(NSString * _Nullable * _Nullable)err;

// 读内嵌歌词(©lyr 文本原子,UTF-8);无则 nil。只读不改。
+ (nullable NSString *)readLyrics:(NSData *)d error:(NSString * _Nullable * _Nullable)err;

@end

NS_ASSUME_NONNULL_END
