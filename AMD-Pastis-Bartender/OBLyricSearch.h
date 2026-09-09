#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 双平台歌词搜索(对标参照区 163MusicLyrics 的聚合搜索):
//   网易云明文端点(搜索+取词,无加密)优先;QQ(musicu.fcg 搜索+取词)尽力,失败降级。
// 结果 song:@{@"source":@"ne"/@"qq", @"sourceName":显示名, @"songId":NSString,
//   @"name":..., @"singer":..., @"album":..., @"duration":@(毫秒)}。
// 取词 lyric:@{@"lyric":原文LRC, @"trans":译文LRC(可空), @"roma":音译(可空), @"source":...}。
// 缓存:内存 + 磁盘(Caches/lyric,按 source_songId 落盘)。
@interface OBLyricSearch : NSObject

// 关键字搜歌;sources 传 @[@"ne"]/@[@"qq"] 限定单源,nil=双源合并(网易云在前)
+ (NSArray<NSDictionary *> *)search:(NSString *)keyword
                              limit:(NSInteger)limit
                            sources:(nullable NSArray<NSString *> *)sources
                               logf:(void (^ _Nullable)(NSString *))logf
                              error:(NSString * _Nullable * _Nullable)err;

// 取一首的词(走缓存)
+ (nullable NSDictionary *)lyricFor:(NSDictionary *)song
                               logf:(void (^ _Nullable)(NSString *))logf
                              error:(NSString * _Nullable * _Nullable)err;

+ (void)clearCache;

@end

NS_ASSUME_NONNULL_END
