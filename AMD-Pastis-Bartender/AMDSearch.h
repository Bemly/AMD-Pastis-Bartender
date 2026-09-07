#import <Foundation/Foundation.h>

/// iTunes Search API 封装:多国家搜曲,回 trackId/title/artist/album。
@interface AMDSearch : NSObject

/// 同步搜索(在后台线程调用)。country 如 @"hk",limit 如 20。
/// 返回数组,元素 @{@"trackId":NSNumber, @"track":NSString, @"artist":NSString, @"album":NSString}
+ (NSArray<NSDictionary *> *)search:(NSString *)term
                            country:(NSString *)country
                              limit:(NSInteger)limit
                              error:(NSError **)error;

/// 按标题/歌手在多国依次搜,挑最佳匹配的 trackId;bestTitle 返回命中的曲名。
+ (NSNumber *)resolveAdamIdForTitle:(NSString *)title
                             artist:(NSString *)artist
                          countries:(NSArray<NSString *> *)countries
                          bestTitle:(NSString **)bestTitle;

@end
