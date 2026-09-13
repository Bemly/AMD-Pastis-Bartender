#import <Foundation/Foundation.h>
#import "OBStrings.h"
#import "AMDConfig.h"
#import "OBADB.h"
#import "OBDL.h"
#import "AMDSearch.h"
#import "TaskRunner.h"

// ─────────────────────────────────────────────────────────────────────────────
// AMDCli.m — অ্যাপ-বান্ডেলের ভেতরের কমান্ড-লাইন ইন্টারফেস (Contents/MacOS/obcli)।
//
// উদ্দেশ্য: GUI-র সব মূল কাজ বাইরের এজেন্ট/স্ক্রিপ্ট যেন সরাসরি ডাকতে পারে।
// GUI-ই যেসব ইঞ্জিন ক্লাস ব্যবহার করে (OBDL / OBADB / AMDSearch / AMDConfig),
// CLI-ও ঠিক সেগুলোই ডাকে — কোনো আলাদা বাস্তবায়ন নেই, তাই আচরণ এক-এক।
//
// নিয়মকানুন:
//   • লগ/প্রগতি লাইন যায় stderr-এ; মেশিন-পাঠ্য ফলাফল যায় stdout-এ (ট্যাব-আলাদা কলাম)।
//   • exit কোড: 0 = সফল, 1 = ব্যর্থ/খালি, 2 = ভুল অপশন।
//   • Ctrl-C (SIGINT/SIGTERM) সরাসরি প্রস্থান করে না — ইঞ্জিনের বাতিল-পতাকা সেট করে,
//     ইঞ্জিন নিরাপদ বিরতিতে (খণ্ডের মাঝে) বেরিয়ে আসে।
//   • সংবেদনশীল সব স্ট্রিং OBStrings.h-এর Base64 পুল থেকে রানটাইমে ফিরে আসে;
//     এই ফাইলে মূল পাঠ্য (মন্তব্য + সাহায্য) শুধুমাত্র বাংলায় লেখা।
// ─────────────────────────────────────────────────────────────────────────────

// বাতিল-পতাকা: ইঞ্জিন খণ্ডের মাঝে/নেটওয়ার্ক ফাঁকে এটি পর্যবেক্ষণ করে
static volatile BOOL gCancel = NO;

static void OnSignal(int sig) { (void)sig; gCancel = YES; }

// GUI-র পাঁচ-অঞ্চল তালিকার সমতুল্য (সার্চ ও রিভার্স-লুকআপ দুটোতেই ব্যবহৃত)
static NSArray<NSString *> *AllCountries(void) {
    return @[@"hk", @"tw", @"jp", @"us", @"cn"];
}

#pragma mark - আউটপুট সহায়ক

// ফলাফল লাইন → stdout
static void Emit(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void Emit(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fputs(s.UTF8String, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

// লগ/প্রগতি লাইন → stderr
static void Elog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void Elog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fputs(s.UTF8String, stderr);
    fputc('\n', stderr);
    fflush(stderr);
}

#pragma mark - adb সহায়ক

// একটি adb কমান্ড সিঙ্ক্রোনাস চালান; stdout ফেরত, exit কোড *st-তে
// (GUI-র runAdbSync-এর সমতুল্য: কনফিগের host/port/serial স্বয়ংক্রিয়ভাবে যুক্ত হয়)
static NSString *AdbRun(NSArray<NSString *> *tail, int *st) {
    AMDConfig *c = [AMDConfig shared];
    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithArray:[c adbBaseArgs]];
    [args addObjectsFromArray:tail];
    return [TaskRunner runSync:[OBADB resolvedAdbPath]
                     arguments:args
                           cwd:nil
                           env:nil
                        status:st];
}

// ইঞ্জিন সার্ভিস চালু আছে কি না দেখে, না থাকলে চালু করে
// (GUI-র ensureAgentServer-এর হুবহু প্রতিলিপি)
static void EnsureAgentServer(void) {
    int st = 0;
    NSString *psCmd = [NSString stringWithFormat:@"su -c 'ps -A | grep -i %@'", OB_AGENT_TAG];
    NSString *ps = AdbRun(@[@"shell", psCmd], &st);
    if (st == 0 && [ps rangeOfString:OB_AGENT_SRV].location != NSNotFound) {
        Elog(@"%@", OB_UI_LOG_RUNNING);
        return;
    }
    Elog(@"%@", OB_UI_LOG_STARTING);
    NSString *upCmd = [NSString stringWithFormat:
        @"su -c 'nohup /data/local/tmp/%@ -l 127.0.0.1:27042 >/dev/null 2>&1 &'", OB_AGENT_SRV16];
    AdbRun(@[@"shell", upCmd], &st);
    [NSThread sleepForTimeInterval:2.0];
    NSString *ps2 = AdbRun(@[@"shell", psCmd], &st);
    Elog(@"%@", ([ps2 rangeOfString:OB_AGENT_SRV].location != NSNotFound)
             ? OB_UI_LOG_STARTED : OB_UI_LOG_FAIL);
}

#pragma mark - আদেশসমূহ

// selfcheck / install: ইঞ্জিনের ফেরানো পাঠ্য-ফলাফল সরাসরি stdout-এ
static int CmdLines(NSArray<NSString *> *lines) {
    for (NSString *l in lines) Emit(@"%@", l);
    return 0;
}

// launch: ইঞ্জিন সার্ভিস নিশ্চিত করে ফোন প্লেয়ারের মূল প্রবেশপথ চালু করে
static int CmdLaunch(void) {
    EnsureAgentServer();
    int st = 0;
    NSString *cmd = [NSString stringWithFormat:
        @"am start -n %@/.onboarding.activities.SplashActivity", OB_PHONE_PKG];
    NSString *out = AdbRun(@[@"shell", cmd], &st);
    NSString *t = [(out ?: @"") stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    Elog(@"[চালু] am start (exit=%d): %@", st, [t substringToIndex:MIN(300, t.length)]);
    return st == 0 ? 0 : 1;
}

// restart: জোর করে বন্ধ → মৃত্যু নিশ্চিত → আবার চালু (GUI-র cleanMusic-এর সমতুল্য)
static int CmdRestart(void) {
    int st = 0;
    Elog(@"%@", OB_UI_RESTART_LOG);
    NSString *stopCmd = [NSString stringWithFormat:@"am force-stop %@", OB_PHONE_PKG];
    AdbRun(@[@"shell", stopCmd], &st);
    [NSThread sleepForTimeInterval:1.5];
    NSString *check = AdbRun(@[@"shell",
        [NSString stringWithFormat:@"pidof %@", OB_PHONE_PKG]], &st);
    NSString *left = [check stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (left.length == 0) {
        Elog(@"[পুনরারম্ভ] বন্ধ হয়েছে, আবার চালু হচ্ছে…");
        NSString *startCmd = [NSString stringWithFormat:
            @"am start -n %@/.onboarding.activities.SplashActivity", OB_PHONE_PKG];
        AdbRun(@[@"shell", startCmd], &st);
        Elog(@"[পুনরারম্ভ] আবার চালু হয়েছে");
        return 0;
    }
    Elog(@"[পুনরারম্ভ] এখনও চলছে (pid %@), আবার চেষ্টা করুন", left);
    return 1;
}

// now: dumpsys থেকে চলমান গান পড়ে, বহু-দেশ রিভার্স-লুকআপে adamId বের করে
// (GUI-র "正在播放并反查" বোতামের সমতুল্য)। stdout: ট্যাব-আলাদা কী/মান জোড়া।
static int CmdNow(void) {
    int st = 0;
    Elog(@"[চলছে] dumpsys media_session পড়া হচ্ছে…");
    NSString *out = AdbRun(@[@"shell", @"dumpsys media_session"], &st);
    NSString *state = @"", *desc = @"";
    NSRegularExpression *reState = [NSRegularExpression
        regularExpressionWithPattern:@"state=PlaybackState \\{state=(\\w+)"
                             options:0 error:NULL];
    NSRegularExpression *reDesc = [NSRegularExpression
        regularExpressionWithPattern:@"description=([^\\n]+)"
                             options:0 error:NULL];
    // লক্ষ্য-প্যাকেজের পরের প্রথম সেশন-অবস্থাই ধরা হয় (GUI-র মতোই)
    NSRange musicRange = [out rangeOfString:OB_PHONE_PKG];
    NSString *scope = out;
    if (musicRange.location != NSNotFound) scope = [out substringFromIndex:musicRange.location];
    NSTextCheckingResult *ms = [reState firstMatchInString:scope options:0
                                                     range:NSMakeRange(0, MIN(scope.length, 4000))];
    if (ms && ms.numberOfRanges >= 2) state = [scope substringWithRange:[ms rangeAtIndex:1]];
    NSTextCheckingResult *md = [reDesc firstMatchInString:scope options:0
                                                    range:NSMakeRange(0, MIN(scope.length, 4000))];
    if (md && md.numberOfRanges >= 1) {
        desc = [scope substringWithRange:[md rangeAtIndex:1]];
        desc = [desc stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    if (desc.length == 0) {
        Elog(@"[চলছে] কিছু পাওয়া যায়নি (সেশন নেই বা থেমে আছে)");
        return 1;
    }
    NSArray *parts = [desc componentsSeparatedByString:@", "];
    NSString *title  = parts.count > 0 ? parts[0] : desc;
    NSString *artist = parts.count > 1 ? parts[1] : @"";
    NSString *album  = parts.count > 2
        ? [[parts subarrayWithRange:NSMakeRange(2, parts.count - 2)] componentsJoinedByString:@", "]
        : @"";
    Elog(@"[চলছে] %@ — %@", title, artist);
    // বহু-দেশ অনুসন্ধানে শিরোনাম+শিল্পী মেলানো (GUI-র AllCountries-এর মতোই)
    NSString *best = nil;
    NSNumber *adam = [AMDSearch resolveAdamIdForTitle:title
                                               artist:artist
                                            countries:AllCountries()
                                            bestTitle:&best];
    Emit(@"title\t%@", title);
    Emit(@"artist\t%@", artist);
    Emit(@"album\t%@", album);
    Emit(@"state\t%@", state);
    Emit(@"adamId\t%@", adam ? [adam stringValue] : @"-");
    if (adam) Elog(@"[চলছে] adamId=%@ (%@)", adam, best ?: @"");
    return 0;
}

// search: বহু-দেশ গান অনুসন্ধান। stdout সারি: trackId\tশিরোনাম\tশিল্পী\tঅ্যালবাম\tদেশ
static int CmdSearch(NSArray<NSString *> *args) {
    if (args.count == 0) {
        Elog(@"[সার্চ] কীওয়ার্ড দিন");
        return 1;
    }
    NSString *kw = [args[0] stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    // দ্বিতীয় বিকল্প দিলে শুধু সেই দেশ, না দিলে পাঁচটি অঞ্চলই (GUI-র "সব" নির্বাচনের মতো)
    NSArray *countries = (args.count > 1 && args[1].length)
        ? @[[args[1] lowercaseString]] : AllCountries();
    Elog(@"[সার্চ] \"%@\" খোঁজা হচ্ছে…", kw);
    __block NSUInteger total = 0;
    for (NSString *cc in countries) {
        NSError *e = nil;
        NSArray *rows = [AMDSearch search:kw country:cc limit:20 error:&e];
        for (NSDictionary *r in rows) {
            Emit(@"%@\t%@\t%@\t%@\t%@",
                 [r[@"trackId"] description] ?: @"-",
                 r[@"track"]  ?: @"",
                 r[@"artist"] ?: @"",
                 r[@"album"]  ?: @"",
                 cc);
            total++;
        }
        if (e) Elog(@"[সার্চ] %@ অঞ্চল ব্যর্থ: %@", cc, e.localizedDescription);
    }
    Elog(@"[সার্চ] মোট %lu সারি", (unsigned long)total);
    return total ? 0 : 1;
}

// download: এক বা একাধিক adamId ডাউনলোড (--cache = ক্যাশ থেকে সরাসরি রূপান্তর)
static int CmdDownload(NSArray<NSString *> *args, BOOL cacheMode) {
    NSString *outOverride = nil;
    NSMutableArray<NSString *> *toks = [NSMutableArray array];
    for (NSUInteger i = 0; i < args.count; i++) {
        NSString *a = args[i];
        if ([a isEqualToString:@"--out"]) {
            if (i + 1 < args.count) outOverride = args[++i];
            continue;
        }
        if ([a isEqualToString:@"--cache"]) { cacheMode = YES; continue; }
        if ([a hasPrefix:@"--"]) {
            Elog(@"[ডাউনলোড] অজানা অপশন: %@", a);
            return 2;
        }
        // কমা/স্পেস/নতুন লাইন — সবই বিভাজক (GUI-র ইনপুট বিশ্লেষণের মতোই)
        [toks addObjectsFromArray:[a componentsSeparatedByCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@", \n\t"]]];
    }
    NSPredicate *nonEmpty = [NSPredicate predicateWithFormat:@"length > 0"];
    NSArray<NSString *> *adams = [toks filteredArrayUsingPredicate:nonEmpty];
    if (!adams.count) {
        Elog(@"[ডাউনলোড] adamId দিন (কমা দিয়ে একাধিক দেওয়া যায়)");
        return 1;
    }
    AMDConfig *c = [AMDConfig shared];
    NSString *outDir = outOverride ?: (c.outDir.length ? c.outDir :
        [NSTemporaryDirectory() stringByAppendingPathComponent:@"amd-dl"]);
    [[NSFileManager defaultManager] createDirectoryAtPath:outDir
                               withIntermediateDirectories:YES attributes:nil error:NULL];
    Elog(@"[ডাউনলোড] গন্তব্য: %@ (%@)", outDir,
         cacheMode ? @"ক্যাশ-সরাসরি" : @"নেটওয়ার্ক");
    int failures = 0;
    for (NSString *adam in adams) {
        if (gCancel) break;   // ইঞ্জিন খণ্ডের মাঝে থামায়; বাকিগুলো বাদ
        NSString *err = nil;
        NSDictionary *meta = cacheMode
            ? [OBDLJob runFromCache:adam outDir:outDir force:NO
                               logf:^(NSString *l) { Elog(@"%@", l); }
                             cancel:&gCancel error:&err]
            : [OBDLJob runAdam:adam outDir:outDir force:NO
                          logf:^(NSString *l) { Elog(@"%@", l); }
                        cancel:&gCancel error:&err];
        if (meta) {
            Emit(@"ok\t%@", adam);
        } else if ([err rangeOfString:@"已存在"].location != NSNotFound) {
            // ইঞ্জিনের স্থায়ী বার্তা (আগেই ডাউনলোড আছে) — GUI-র মতোই এটি ব্যর্থতা নয়
            Emit(@"ok\t%@", adam);
        } else {
            Elog(@"[!] adam %@ ব্যর্থ: %@", adam, err ?: @"?");
            failures++;
        }
    }
    return failures ? 1 : 0;
}

// follow: ক্যাশ অনুসরণ — নতুন key পেলেই স্বয়ংক্রিয় ডাউনলোড; Ctrl-C নিরাপদ বিরতিতে বেরোয়
static int CmdFollow(NSArray<NSString *> *args) {
    NSString *outOverride = nil;
    NSTimeInterval interval = 20;   // GUI-র ডিফল্টের সমতুল্য
    BOOL autoNext = NO;             // GUI v1-ও এটি বন্ধ রাখে (স্বয়ংক্রিয় গান-বদল প্রবাহ ভাঙে)
    for (NSUInteger i = 0; i < args.count; i++) {
        NSString *a = args[i];
        if ([a isEqualToString:@"--out"] && i + 1 < args.count) {
            outOverride = args[++i];
        } else if ([a isEqualToString:@"--interval"] && i + 1 < args.count) {
            interval = [args[++i] doubleValue] ?: 20;
        } else if ([a isEqualToString:@"--auto-next"]) {
            autoNext = YES;
        } else {
            Elog(@"[অনুসরণ] অজানা অপশন: %@", a);
            return 2;
        }
    }
    AMDConfig *c = [AMDConfig shared];
    NSString *outDir = outOverride ?: (c.outDir.length ? c.outDir :
        [NSTemporaryDirectory() stringByAppendingPathComponent:@"amd-dl"]);
    [[NSFileManager defaultManager] createDirectoryAtPath:outDir
                               withIntermediateDirectories:YES attributes:nil error:NULL];
    Elog(@"[অনুসরণ] শুরু (বিরতি %.0f সেকেন্ড, autoNext=%@) — বন্ধ করতে Ctrl-C",
         interval, autoNext ? @"on" : @"off");
    [OBDLJob followCache:outDir
                interval:interval
               autoNext:autoNext
                   logf:^(NSString *l) { Elog(@"%@", l); }
                statusf:^(NSString *s) { Elog(@"[অবস্থা] %@", s); }
                 cancel:&gCancel];
    Elog(@"[অনুসরণ] বেরিয়ে গেছে");
    return 0;
}

// সাহায্য: সব আদেশ ও বিকল্পের সংক্ষিপ্ত তালিকা (stderr-এ, তাই পাইপ নিরাপদ)
static int Usage(void) {
    Elog(@"ব্যবহার: obcli <আদেশ> [বিকল্প]");
    Elog(@"");
    Elog(@"আদেশসমূহ:");
    Elog(@"  selfcheck                 পরিবেশ স্বয়ং-পরীক্ষা (নেটিভ ইঞ্জিন)");
    Elog(@"  install                   ফোন-পার্শ্ব ইঞ্জিন সার্ভিস ইনস্টল/নবীকরণ");
    Elog(@"  launch                    ইঞ্জিন সার্ভিস নিশ্চিত করে ফোন প্লেয়ার চালু");
    Elog(@"  restart                   প্লেয়ার জোর করে বন্ধ করে আবার চালু");
    Elog(@"  now                       চলমান গান পড়ে adamId অনুসন্ধান");
    Elog(@"  search <কীওয়ার্ড> [দেশ]   বহু-দেশ অনুসন্ধান (দেশ: hk tw jp us cn)");
    Elog(@"  download <adamId,...> [--cache] [--out DIR]");
    Elog(@"                            ডাউনলোড; --cache = ক্যাশ থেকে সরাসরি রূপান্তর");
    Elog(@"  follow [--out DIR] [--interval সেকেন্ড] [--auto-next]");
    Elog(@"                            ক্যাশ অনুসরণ: নতুন key পেলেই স্বয়ংক্রিয় ডাউনলোড");
    Elog(@"  help                      এই সাহায্য");
    Elog(@"");
    Elog(@"নোট: লগ stderr-এ, ফলাফল stdout-এ (ট্যাব-আলাদা); Ctrl-C নিরাপদ বিরতিতে বেরোয়।");
    return 1;
}

#pragma mark - প্রবেশদ্বার

int main(int argc, char *argv[]) {
    @autoreleasepool {
        signal(SIGINT, OnSignal);
        signal(SIGTERM, OnSignal);
        // কনফিগ লোড: GUI-র সাথে একই NSUserDefaults ভান্ডার, তাই সব সেটিং ভাগ হয়
        [[AMDConfig shared] load];

        NSArray<NSString *> *all = NSProcessInfo.processInfo.arguments;
        NSArray<NSString *> *args = all.count > 1 ? [all subarrayWithRange:NSMakeRange(1, all.count - 1)] : @[];
        NSString *cmd = args.firstObject ?: @"";
        if (args.count == 0 || [cmd isEqualToString:@"help"] ||
            [cmd isEqualToString:@"--help"] || [cmd isEqualToString:@"-h"]) {
            return Usage();
        }
        NSArray<NSString *> *rest = args.count > 1
            ? [args subarrayWithRange:NSMakeRange(1, args.count - 1)] : @[];

        int rc;
        if      ([cmd isEqualToString:@"selfcheck"]) rc = CmdLines([OBDLJob selfTest]);
        else if ([cmd isEqualToString:@"install"])   rc = CmdLines([OBDLJob installEngineService]);
        else if ([cmd isEqualToString:@"launch"])    rc = CmdLaunch();
        else if ([cmd isEqualToString:@"restart"])   rc = CmdRestart();
        else if ([cmd isEqualToString:@"now"])       rc = CmdNow();
        else if ([cmd isEqualToString:@"search"])    rc = CmdSearch(rest);
        else if ([cmd isEqualToString:@"download"])  rc = CmdDownload(rest, NO);
        else if ([cmd isEqualToString:@"cache"])     rc = CmdDownload(rest, YES);
        else if ([cmd isEqualToString:@"follow"])    rc = CmdFollow(rest);
        else {
            Elog(@"অজানা আদেশ: %@", cmd);
            return Usage();
        }
        fflush(stdout);
        fflush(stderr);
        return rc;
    }
}
