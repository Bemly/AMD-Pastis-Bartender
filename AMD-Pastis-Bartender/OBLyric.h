#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 歌词纯逻辑层(无网络、无 UI):LRC 解析/三轨排版/LRC↔SRT/文件编码。
// 算法对标上游开源实现(Apache-2.0,见参照区 163MusicLyrics 的 LyricUtils/SrtUtils):
//   交错(stagger)=多轨按时间戳归并、原文优先;独立=各轨顺接;合并=同时间戳同行拼分隔符。
// 行模型一律 NSDictionary {@"ms":@(毫秒), @"text":NSString}。

// 歌词源(解析時的特殊规则;如 QQ 的 [offset:0]/[kana:] 重置)
typedef NS_ENUM(NSInteger, OBLyricSource) {
    OBLyricSourceGeneric = 0,
    OBLyricSourceQQ      = 1,
};

// 译文缺失规则(原文时间戳在译文里找不到对应行时)
typedef NS_ENUM(NSInteger, OBLyricLostRule) {
    OBLyricLostIgnore      = 0, // 跳过该行
    OBLyricLostFillOrigin  = 1, // 用原文内容补
    OBLyricLostEmpty       = 2, // 补空行(占位)
};

@interface OBLyric : NSObject

// ---- 解析 ----

// 解析 LRC 全文 → 行数组。ignoreEmpty=YES 时丢无时间戳/空文本行,否则空文本行保留占位。
// QQ 源遇到 [offset:0] 或 [kana: 开头行时清空之前累积(上游同款规则)。
+ (NSArray<NSDictionary *> *)parseLRC:(nullable NSString *)text
                               source:(OBLyricSource)src
                          ignoreEmpty:(BOOL)ignoreEmpty;

// 单个时间戳 "[mm:ss.xx]" → 毫秒;非法返回 -1(支持 . / : 分隔,1~3 位小数,多前缀逐个调)
+ (long)parseTimestamp:(NSString *)bracket;

// ---- 译文对齐 ----

// 把译文轨对齐到原文轨:精确匹配→误差窗(±deviation 毫秒,被相邻行夹界)→缺失规则;返回排序后的译文轨。
+ (NSArray<NSDictionary *> *)alignTrans:(NSArray<NSDictionary *> *)trans
                               toOrigin:(NSArray<NSDictionary *> *)origin
                              deviation:(long)deviation
                               lostRule:(OBLyricLostRule)rule;

// ---- 排版 ----

// 交错:多轨按 ms 归并(同戳原文在前);合并:交错后再把同戳行按 separator 拼一行;
// 独立:原样返回各轨(调用方决定写一个文件还是分文件)。
+ (NSArray<NSDictionary *> *)renderStagger:(NSArray<NSArray<NSDictionary *> *> *)tracks;
+ (NSArray<NSDictionary *> *)renderMerge:(NSArray<NSArray<NSDictionary *> *> *)tracks
                               separator:(NSString *)sep;
+ (NSArray<NSArray<NSDictionary *> *> *)renderIsolated:(NSArray<NSArray<NSDictionary *> *> *)tracks;

// ---- 文本生成 ----

// 行 → "[mm:ss.xx]"(厘秒,向下取整);全文 join
+ (NSString *)lrcString:(NSArray<NSDictionary *> *)lines;
+ (NSString *)lineString:(NSDictionary *)line;

// LRC 行 → SRT 全文。结束时间=下一行开始(末行用 durationMs);同时间戳块依次展开。
// durationMs<=0 时回退 末行+3000。
+ (NSString *)srtString:(NSArray<NSDictionary *> *)lines durationMs:(long)durationMs;

// SRT 全文 → LRC 行(只取开始时间,按时间排序)
+ (NSArray<NSDictionary *> *)parseSRT:(nullable NSString *)text;

// ---- 文件 ----

// 读歌词文件:UTF-8 严格试探 → GB18030 回退;返回 @{@"text":..., @"encoding":@"UTF-8"/@"GB18030"/...}
+ (nullable NSDictionary *)readFile:(NSString *)path error:(NSString * _Nullable * _Nullable)err;
// 写歌词文件:encoding 取 @"UTF-8" / @"GB18030" / @"UTF-16"(含 BOM),nil/未知则 UTF-8
+ (BOOL)writeFile:(NSString *)text to:(NSString *)path encoding:(nullable NSString *)enc
            error:(NSString * _Nullable * _Nullable)err;

@end

NS_ASSUME_NONNULL_END
