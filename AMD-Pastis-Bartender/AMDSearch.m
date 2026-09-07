#import "AMDSearch.h"
#import "OBStrings.h"

@implementation AMDSearch

+ (NSArray<NSDictionary *> *)search:(NSString *)term
                            country:(NSString *)country
                              limit:(NSInteger)limit
                              error:(NSError **)error {
    NSURLComponents *c = [[NSURLComponents alloc]
        initWithString:[NSString stringWithFormat:@"https://%@/search", OB_STORE_HOST]];
    c.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"term" value:term],
        [NSURLQueryItem queryItemWithName:@"media" value:@"music"],
        [NSURLQueryItem queryItemWithName:@"limit" value:[@(limit) stringValue]],
        [NSURLQueryItem queryItemWithName:@"country" value:country],
    ];
    __block NSData *data = nil;
    __block NSError *reqErr = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithURL:c.URL
                                 completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        data = d; reqErr = e;
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25 * NSEC_PER_SEC)));
    if (reqErr) { if (error) *error = reqErr; return @[]; }
    if (!data) { if (error) *error = [NSError errorWithDomain:@"AMD-Pastis-Bartender" code:-1
                                                     userInfo:@{NSLocalizedDescriptionKey: @"无响应(超时)"}];
        return @[]; }
    NSError *je = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&je];
    if (je) { if (error) *error = je; return @[]; }
    NSMutableArray *out = [NSMutableArray array];
    for (NSDictionary *r in (json[@"results"] ?: @[])) {
        if (!r[@"trackId"]) continue;
        [out addObject:@{
            @"trackId": r[@"trackId"],
            @"track": r[@"trackName"] ?: @"",
            @"artist": r[@"artistName"] ?: @"",
            @"album": r[@"collectionName"] ?: @"",
        }];
    }
    return out;
}

+ (NSNumber *)resolveAdamIdForTitle:(NSString *)title
                             artist:(NSString *)artist
                          countries:(NSArray<NSString *> *)countries
                          bestTitle:(NSString **)bestTitle {
    NSString *t = [title stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *a = [artist stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length == 0) return nil;
    for (NSString *country in countries) {
        NSArray *rows = [self search:t country:country limit:15 error:NULL];
        NSNumber *hit = [self pickFrom:rows title:t artist:a bestTitle:bestTitle];
        if (hit) return hit;
        // 标题搜不到时,用"标题+歌手"再试一次
        if (a.length > 0) {
            rows = [self search:[NSString stringWithFormat:@"%@ %@", t, a]
                        country:country limit:10 error:NULL];
            hit = [self pickFrom:rows title:t artist:a bestTitle:bestTitle];
            if (hit) return hit;
        }
    }
    return nil;
}

+ (NSNumber *)pickFrom:(NSArray<NSDictionary *> *)rows
                title:(NSString *)title
               artist:(NSString *)artist
            bestTitle:(NSString **)bestTitle {
    // 1) 标题精确相等优先
    for (NSDictionary *r in rows) {
        if ([r[@"track"] caseInsensitiveCompare:title] == NSOrderedSame) {
            if (bestTitle) *bestTitle = [NSString stringWithFormat:@"%@ — %@", r[@"track"], r[@"artist"]];
            return r[@"trackId"];
        }
    }
    // 2) 标题互含 + 歌手互含
    NSString *firstArtistToken = [[artist componentsSeparatedByCharactersInSet:
        [NSCharacterSet characterSetWithCharactersInString:@",，&、"]] firstObject];
    firstArtistToken = [firstArtistToken stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    for (NSDictionary *r in rows) {
        NSString *rt = r[@"track"];
        NSString *ra = r[@"artist"];
        BOOL titleHit = ([rt rangeOfString:title options:NSCaseInsensitiveSearch].location != NSNotFound) ||
                        ([title rangeOfString:rt options:NSCaseInsensitiveSearch].location != NSNotFound);
        if (!titleHit) continue;
        if (firstArtistToken.length == 0 ||
            [ra rangeOfString:firstArtistToken options:NSCaseInsensitiveSearch].location != NSNotFound) {
            if (bestTitle) *bestTitle = [NSString stringWithFormat:@"%@ — %@", rt, ra];
            return r[@"trackId"];
        }
    }
    return nil;
}

@end
