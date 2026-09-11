#import "MainWindowController.h"
#import "AMDConfig.h"
#import "TaskRunner.h"
#import "AMDSearch.h"
#import "OBStrings.h"
#import "AMDDebug.h"
#import "OBLink.h"
#import "OBDL.h"
#import "OBLyric.h"
#import "OBLyricSearch.h"
#import "OBMP4.h"
#import <QuartzCore/QuartzCore.h>

static NSArray<NSString *> *AllCountries(void) {
    return @[@"hk", @"tw", @"jp", @"us", @"cn"];
}

static NSString * const AMDAppVersion = @"v2026.09.09";

#pragma mark - 侧栏条目

static NSDictionary *SideItem(NSString *title, NSString *symbol) {
    return @{@"title": title, @"symbol": symbol};
}

@interface NSStackView (AMDAddViews)
- (void)addViews:(NSArray<NSView *> *)views;
@end

@implementation NSStackView (AMDAddViews)
- (void)addViews:(NSArray<NSView *> *)views {
    for (NSView *v in views) [self addView:v inGravity:NSStackViewGravityLeading];
}
@end

/// 滚动容器的 documentView 必须用它:NSStackView 自己不是 flipped 视图,直接当
/// documentView 时"内容顶部"在 clip 坐标里是文档末尾,起点永远落在页尾
/// (2026-09-09 实录,geom 打点实锤 clipOrigin=0 而显示的是页尾)。
@interface AMDFlippedDocView : NSView
@end
@implementation AMDFlippedDocView
- (BOOL)isFlipped { return YES; }
@end

@implementation MainWindowController {
    // 侧栏 + 分页
    NSTableView *_sideTable;
    NSVisualEffectView *_sideMat;
    NSView *_contentBox;
    NSMutableDictionary<NSNumber *, NSView *> *_pages;
    NSInteger _section;
    // 连接页
    NSTextField *_adbPathF, *_adbHostF, *_adbPortF, *_serialF;
    NSTextField *_tcpPortF, *_lanIpF, *_scriptDirF, *_outDirF;
    NSButton *_useTcpC;
    NSTextField *_statusL;
    // 设备页
    NSTextField *_nowPlayingL;
    // 搜索页
    NSTextField *_keywordF;
    NSPopUpButton *_countryP;
    NSTableView *_table;
    NSMutableArray<NSDictionary *> *_results;
    NSTextField *_searchHintL;
    // 下载页
    NSTextField *_adamF;
    NSTextField *_dlStatusL;
    NSButton *_cancelBtn;
    TaskRunner *_dlTask;
    volatile BOOL _dlCancel;
    volatile BOOL _followCancel;
    BOOL _followOn;
    // 预览页(输出目录 .m4a 列表;同名 .json 有则读 artist/title)
    NSTableView *_pvTable;
    NSMutableArray<NSDictionary *> *_pvItems;
    NSTextField *_pvHintL;
    // 歌词页(单曲模式:搜索→选行→保存/互转)
    NSTextField *_lyKeyF, *_lyFileF;
    NSButton *_lyNEBtn, *_lyQQBtn;
    NSTableView *_lyTable;
    NSMutableArray<NSDictionary *> *_lyResults;
    NSTextField *_lyHintL;
    NSPopUpButton *_lyModeP, *_lyEncP, *_lyLayoutP;
    NSTextField *_lySepF;
    NSTextField *_lyConvSrcF;
    NSPopUpButton *_lyConvP;
    // 日志
    NSTextView *_logV;
}

#pragma mark - init / 系统液态玻璃 chrome(侧栏 + 工具栏)

- (instancetype)init {
    AMDDBG(@"wc: init begin");
    if ((self = [super initWithWindow:nil])) {
        _pages = [NSMutableDictionary dictionary];
        _results = [NSMutableArray array];
        _pvItems = [NSMutableArray array];
        _lyResults = [NSMutableArray array];
        _section = -1;
        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 920, 620)
                                                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                             NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                                                    backing:NSBackingStoreBuffered
                                                      defer:NO];
        w.title = OB_UI_TITLE;
        w.minSize = NSMakeSize(760, 520);
        self.window = w;

        // 工具栏:系统玻璃 chrome 的一部分,条目随页面切换(每页只放该页的主操作)
        NSToolbar *tb = [[NSToolbar alloc] initWithIdentifier:@"main"];
        tb.delegate = self;
        tb.displayMode = NSToolbarDisplayModeIconAndLabel;
        w.toolbar = tb;

        [self buildSplitChrome];
        [self loadConfigToUI];
        AMDDBG(@"wc: chrome done, sections=%lu", (unsigned long)self.sideItems.count);
    }
    return self;
}

- (NSArray<NSDictionary *> *)sideItems {
    // 顺序 = 使用流程:配环境 → 连手机 → 找歌 → 下载 → 预览成品 → 配歌词 → 看结果
    return @[
        SideItem(@"连接", @"slider.horizontal.3"),
        SideItem(@"设备", @"desktopcomputer"),
        SideItem(@"搜索", @"magnifyingglass"),
        SideItem(@"下载", @"arrow.down.circle"),
        SideItem(@"预览", @"list.bullet"),
        SideItem(@"歌词", @"text.quote"),
        SideItem(@"日志", @"doc.text"),
    ];
}

/// 参考 afm-ime:侧栏用系统玻璃(behavior=sidebar 的 split item + sidebar 材质),
/// 内容从玻璃侧栏下滚过;每个页面只放 2-3 张玻璃小卡,不把所有东西塞一页。
- (void)buildSplitChrome {
    NSWindow *w = self.window;

    // ---- 侧栏 ----
    _sideMat = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    _sideMat.material = NSVisualEffectMaterialSidebar;
    _sideMat.state = NSVisualEffectStateFollowsWindowActiveState;
    _sideMat.wantsLayer = YES;
    _sideMat.translatesAutoresizingMaskIntoConstraints = NO;
    AMDDBG(@"chrome: side material ready");

    _sideTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 176, 200)];
    AMDDBG(@"chrome: side table alloc ok");
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"side"];
    [_sideTable addTableColumn:col];
    AMDDBG(@"chrome: column added");
    NSString *step = @"none";
    @try {
        step = @"rowHeight"; _sideTable.rowHeight = 30;
        step = @"backgroundColor"; _sideTable.backgroundColor = [NSColor clearColor];
        step = @"allowsEmptySelection"; _sideTable.allowsEmptySelection = NO;
        step = @"delegate"; _sideTable.delegate = self;
        step = @"dataSource"; _sideTable.dataSource = self;
    } @catch (NSException *e) {
        AMDDBG(@"chrome EXCEPTION at [%@]: %@ — %@", step, e.name, e.reason);
    }
    _sideTable.autoresizingMask = NSViewWidthSizable;
    AMDDBG(@"chrome: side table configured");
    NSScrollView *sideScroll = [[NSScrollView alloc] init];
    sideScroll.documentView = _sideTable;
    _sideTable.headerView = nil;   // 入列后再置 nil,否则内部约束在无父视图时装配会炸
    _sideTable.style = NSTableViewStyleFullWidth;   // 同理,入列后再设 fullWidth
    sideScroll.hasVerticalScroller = NO;   // 五个条目永远用不到滚,滚动条轨道在玻璃上很难看
    sideScroll.drawsBackground = NO;
    sideScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [_sideMat addSubview:sideScroll];
    AMDDBG(@"chrome: side scroll added");

    // 版本号钉在侧栏底部(参考图样式)
    NSTextField *ver = [NSTextField labelWithString:AMDAppVersion];
    ver.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightRegular];
    ver.textColor = [NSColor tertiaryLabelColor];
    ver.translatesAutoresizingMaskIntoConstraints = NO;
    [_sideMat addSubview:ver];

    [NSLayoutConstraint activateConstraints:@[
        [sideScroll.leadingAnchor constraintEqualToAnchor:_sideMat.leadingAnchor],
        [sideScroll.trailingAnchor constraintEqualToAnchor:_sideMat.trailingAnchor],
        [sideScroll.topAnchor constraintEqualToAnchor:_sideMat.topAnchor constant:8],
        [ver.leadingAnchor constraintEqualToAnchor:_sideMat.leadingAnchor constant:16],
        [ver.bottomAnchor constraintEqualToAnchor:_sideMat.bottomAnchor constant:-8],
        [sideScroll.bottomAnchor constraintEqualToAnchor:ver.topAnchor constant:-6],
    ]];

    NSViewController *sideVC = [[NSViewController alloc] init];
    sideVC.view = _sideMat;
    NSSplitViewItem *sideItem = [NSSplitViewItem sidebarWithViewController:sideVC];
    sideItem.minimumThickness = 150;
    sideItem.maximumThickness = 230;
    sideItem.canCollapse = YES;
    AMDDBG(@"chrome: side item ready");

    // ---- 内容容器 ----
    _contentBox = [[NSView alloc] initWithFrame:NSZeroRect];
    NSViewController *contentVC = [[NSViewController alloc] init];
    contentVC.view = _contentBox;
    NSSplitViewItem *contentItem = [NSSplitViewItem splitViewItemWithViewController:contentVC];

    NSSplitViewController *svc = [[NSSplitViewController alloc] init];
    [svc addSplitViewItem:sideItem];
    [svc addSplitViewItem:contentItem];
    AMDDBG(@"chrome: svc ready");
    w.contentViewController = svc;
    AMDDBG(@"wc: split chrome added");

    [_sideTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    [self switchToSection:_sideTable.selectedRow];   // 选中态已存在时不发通知,显式切一次
}

#pragma mark - 侧栏数据源

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv {
    if (tv == _sideTable) return (NSInteger)self.sideItems.count;
    if (tv == _pvTable) return (NSInteger)_pvItems.count;
    if (tv == _lyTable) return (NSInteger)_lyResults.count;
    return (NSInteger)_results.count;
}

// 三个内容表(搜索/预览/歌词)的 cell 取值;越界返回 nil(调用方转空行)
- (nullable NSString *)cellStringForTable:(NSTableView *)tv
                                     row:(NSInteger)row
                                   ident:(NSString *)ident {
    NSDictionary *r = nil;
    if (tv == _table && row >= 0 && row < (NSInteger)_results.count) r = _results[row];
    else if (tv == _pvTable && row >= 0 && row < (NSInteger)_pvItems.count) r = _pvItems[row];
    else if (tv == _lyTable && row >= 0 && row < (NSInteger)_lyResults.count) r = _lyResults[row];
    if (!r) return nil;
    if ([ident isEqualToString:@"ID"]) return [r[@"trackId"] stringValue] ?: @"";
    if ([ident isEqualToString:@"曲名"]) return r[@"track"] ?: @"";
    if ([ident isEqualToString:@"艺人"]) return r[@"artist"] ?: @"";
    if ([ident isEqualToString:@"专辑"]) return r[@"album"] ?: @"";
    if ([ident isEqualToString:@"区"]) return r[@"src"] ?: @"";
    if ([ident isEqualToString:@"文件名"]) return r[@"name"] ?: @"";
    if ([ident isEqualToString:@"大小"]) return r[@"sizeText"] ?: @"";
    if ([ident isEqualToString:@"来源"]) return r[@"sourceName"] ?: @"";
    if ([ident isEqualToString:@"歌名"]) return r[@"name"] ?: @"";
    if ([ident isEqualToString:@"歌手"]) return r[@"singer"] ?: @"";
    if ([ident isEqualToString:@"时长"]) return r[@"durText"] ?: @"";
    return @"";
}

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    if (tv != _sideTable) {
        // 内容表同样 view-based:必须给 view,只靠 objectValue 行是空的(剩选中高亮)
        NSString *s = [self cellStringForTable:tv row:row ident:col.identifier];
        if (!s) return nil;
        NSTextField *tf = (NSTextField *)[tv makeViewWithIdentifier:col.identifier owner:self];
        if (!tf) {
            tf = [NSTextField labelWithString:@""];
            tf.identifier = col.identifier;
            tf.font = [NSFont systemFontOfSize:13];
            tf.textColor = [NSColor labelColor];
            tf.lineBreakMode = NSLineBreakByTruncatingTail;
            tf.maximumNumberOfLines = 1;
        }
        tf.stringValue = s;
        return tf;
    }
    NSDictionary *item = self.sideItems[row];
    NSTableCellView *cell = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
    NSImageView *iv = [[NSImageView alloc] initWithFrame:NSZeroRect];
    iv.image = [NSImage imageWithSystemSymbolName:item[@"symbol"] accessibilityDescription:nil];
    NSTextField *tf = [NSTextField labelWithString:item[@"title"]];
    tf.lineBreakMode = NSLineBreakByTruncatingTail;
    iv.translatesAutoresizingMaskIntoConstraints = NO;
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    [cell addSubview:iv];
    [cell addSubview:tf];
    cell.imageView = iv;
    cell.textField = tf;
    [NSLayoutConstraint activateConstraints:@[
        [iv.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:8],
        [iv.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        [iv.widthAnchor constraintEqualToConstant:18],
        [iv.heightAnchor constraintEqualToConstant:18],
        [tf.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:8],
        [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-6],
        [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
    ]];
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)note {
    if (note.object != _sideTable) return;
    NSInteger row = _sideTable.selectedRow;
    if (row >= 0) [self switchToSection:row];
}

#pragma mark - 页面切换

- (void)switchToSection:(NSInteger)idx {
    // chrome 未就绪时直接忽略:dataSource 赋值会让表格自动选中行0并提前触发本方法,
    // 而 _contentBox 那时还没建,对 nil 锚建约束会抛异常(坑:先入列后约束)
    if (idx < 0 || !_contentBox) return;
    if (idx == _section && _contentBox.subviews.count > 0) return;
    _section = idx;
    NSView *page = _pages[@(idx)] ?: [self buildPage:idx];
    _pages[@(idx)] = page;
    page.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *s in _contentBox.subviews) [s removeFromSuperview];
    [_contentBox addSubview:page];
    [NSLayoutConstraint activateConstraints:@[
        [page.leadingAnchor constraintEqualToAnchor:_contentBox.leadingAnchor constant:16],
        [page.trailingAnchor constraintEqualToAnchor:_contentBox.trailingAnchor constant:-16],
        [page.topAnchor constraintEqualToAnchor:_contentBox.topAnchor constant:14],
        [page.bottomAnchor constraintEqualToAnchor:_contentBox.bottomAnchor constant:-14],
    ]];
    // 滚动页切回时回顶(flip 容器下 (0,0) 就是页首;用户上次滚过的位置不保留,免得以为页面丢了内容)
    for (NSView *s in _contentBox.subviews) {
        if ([s isKindOfClass:[NSScrollView class]])
            [[(NSScrollView *)s contentView] scrollToPoint:NSMakePoint(0, 0)];
    }
    // 窗口标题固定为 App 名,不随页面切换(导航位置由侧栏选中态表达)
    [self refreshToolbar];
    AMDDBG(@"wc: section → %@ (toolbar items %lu)", self.sideItems[idx][@"title"],
           (unsigned long)self.window.toolbar.items.count);
}

#pragma mark - 工具栏(只放各页的主操作,随页切换)

- (NSDictionary<NSString *, NSDictionary *> *)toolbarSpecs {
    return @{
        // 连接页
        @"tb.save":    @{@"title": @"保存设置", @"symbol": @"externaldrive.badge.checkmark", @"action": @"saveConfig:"},
        @"tb.check":   @{@"title": @"环境自检", @"symbol": @"stethoscope", @"action": @"checkEnv:"},
        // 设备页
        @"tb.launch":  @{@"title": @"启动播放器", @"symbol": @"play.fill", @"action": @"launchMusic:"},
        @"tb.kit":     @{@"title": @"原生引擎自检", @"symbol": @"antenna.radiowaves.left.and.right", @"action": @"kitSelfTest:"},
        @"tb.install": @{@"title": @"安装引擎服务", @"symbol": @"arrow.down.to.line.compact", @"action": @"installEngine:"},
        @"tb.restart": @{@"title": @"释放注入·重启", @"symbol": @"arrow.clockwise", @"action": @"cleanMusic:"},
        // 搜索页
        @"tb.search":  @{@"title": @"搜索", @"symbol": @"magnifyingglass", @"action": @"doSearch:"},
        @"tb.fill":    @{@"title": @"填入下载框", @"symbol": @"arrow.right.circle", @"action": @"fillFromSearch:"},
        // 下载页
        @"tb.download": @{@"title": @"开始下载", @"symbol": @"arrow.down.circle", @"action": @"startDownload:"},
        @"tb.cache":    @{@"title": @"缓存直解", @"symbol": @"tray.and.arrow.down", @"action": @"startDownloadCache:"},
        @"tb.follow":   @{@"title": @"跟随收割", @"symbol": @"dot.radiowaves.left.and.right", @"action": @"toggleFollow:"},
        // 预览页
        @"tb.pv.refresh": @{@"title": @"刷新列表", @"symbol": @"arrow.triangle.2.circlepath", @"action": @"refreshPreview:"},
        // 歌词页
        @"tb.ly.search": @{@"title": @"查歌词", @"symbol": @"text.magnifyingglass", @"action": @"lyricSearch:"},
        @"tb.ly.save":   @{@"title": @"保存歌词", @"symbol": @"square.and.arrow.down", @"action": @"lyricSave:"},
        // 日志页
        @"tb.clear":   @{@"title": @"清空日志", @"symbol": @"trash", @"action": @"clearLog:"},
        @"tb.copy":    @{@"title": @"复制日志", @"symbol": @"doc.on.doc", @"action": @"copyLog:"},
    };
}

- (NSArray<NSString *> *)toolbarIdentifiersForSection:(NSInteger)s {
    switch (s) {
        case 0: return @[@"tb.save", @"tb.check"];
        case 1: return @[@"tb.launch", @"tb.kit", @"tb.install", @"tb.restart"];
        case 2: return @[@"tb.search", @"tb.fill"];
        case 3: return @[@"tb.download", @"tb.cache", @"tb.follow"];
        case 4: return @[@"tb.pv.refresh"];
        case 5: return @[@"tb.ly.search", @"tb.ly.save"];
        case 6: return @[@"tb.clear", @"tb.copy"];
        default: return @[];
    }
}

- (void)refreshToolbar {
    NSToolbar *tb = self.window.toolbar;
    if (!tb) return;
    NSArray *want = [self toolbarIdentifiersForSection:_section];
    for (NSInteger i = (NSInteger)tb.items.count - 1; i >= 0; i--) {
        if (![want containsObject:tb.items[i].itemIdentifier]) [tb removeItemAtIndex:i];
    }
    NSInteger at = 0;
    for (NSString *idnt in want) {
        BOOL have = NO;
        for (NSToolbarItem *it in tb.items) if ([it.itemIdentifier isEqualToString:idnt]) have = YES;
        if (!have) {
            [tb insertItemWithItemIdentifier:idnt atIndex:at];
            AMDDBG(@"toolbar: inserted %@ → count=%lu", idnt, (unsigned long)tb.items.count);
        }
        at++;
    }
    // 下载进行中:回到下载页时下载入口保持禁用(防双开,任务守卫另有一层)
    if (_dlTask && _dlTask.isRunning) [self applyDownloadBusy:YES];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return self.toolbarSpecs.allKeys;
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return [self toolbarIdentifiersForSection:_section];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar
   itemForItemIdentifier:(NSString *)itemIdentifier
      willBeInsertedIntoToolbar:(BOOL)flag {
    AMDDBG(@"toolbar: itemFor %@", itemIdentifier);
    NSDictionary *cfg = self.toolbarSpecs[itemIdentifier];
    NSToolbarItem *it = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
    if (cfg) {
        it.label = cfg[@"title"];
        it.image = [NSImage imageWithSystemSymbolName:cfg[@"symbol"] accessibilityDescription:nil];
        it.target = self;
        it.action = NSSelectorFromString(cfg[@"action"]);
    }
    return it;
}

#pragma mark - 玻璃卡片(液态玻璃规范:材质底上小卡片,圆角 16 / 内缩 14)

/// 把内容嵌进液态玻璃(macOS 26+);旧系统回退为雾面材质+图层圆角。
- (NSView *)glassPanelWithBody:(NSView *)body
                   cornerRadius:(CGFloat)radius
                       padding:(NSEdgeInsets)padding
                    interactive:(BOOL)interactive {
    // body 不能直接当 contentView:contentView 会被系统钉满面板,padding 约束打架必输,文字贴边
    // (2026-09-09 实录)。垫一层普通容器自己管几何——也别用 contentView setter(系统内部包层后
    // panel↔content 无共同祖先,建约束激活即抛,坑 #1 的变体),全部走直接父子关系。
    NSView *content = [[NSView alloc] initWithFrame:NSZeroRect];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    NSView *panel;
    if (@available(macOS 26.0, *)) {
        NSGlassEffectView *g = [[NSGlassEffectView alloc] initWithFrame:NSZeroRect];
        g.cornerRadius = radius;
        if (@available(macOS 27.0, *)) g.effectIsInteractive = interactive;
        [g addSubview:content];
        panel = g;
    } else {
        NSVisualEffectView *v = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
        v.material = NSVisualEffectMaterialContentBackground;
        v.state = NSVisualEffectStateFollowsWindowActiveState;
        v.wantsLayer = YES;
        v.layer.cornerRadius = radius;
        v.layer.masksToBounds = YES;
        [v addSubview:content];
        panel = v;
    }
    [content addSubview:body];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:panel.topAnchor],
        [content.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor],
        [body.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:padding.left],
        [body.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-padding.right],
        [body.topAnchor constraintEqualToAnchor:content.topAnchor constant:padding.top],
        [body.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-padding.bottom],
    ]];
    return panel;
}

/// 参考工程 GlassCard:标题(headline) + 内容,玻璃圆角 16,内缩 14
- (NSView *)glassCard:(NSString *)title body:(NSView *)body {
    NSTextField *l = [NSTextField labelWithString:title];
    l.font = [NSFont boldSystemFontOfSize:13];
    NSStackView *stack = [NSStackView stackViewWithViews:@[]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 10;
    stack.alignment = NSLayoutAttributeLeading;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [stack addArrangedSubview:l];
    [stack addArrangedSubview:body];
    [body.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    return [self glassPanelWithBody:stack
                       cornerRadius:16
                            padding:NSEdgeInsetsMake(14, 18, 16, 18)
                        interactive:YES];
}

#pragma mark - 控件工厂

- (NSTextField *)label:(NSString *)s width:(CGFloat)wd {
    NSTextField *l = [NSTextField labelWithString:s];
    l.font = [NSFont systemFontOfSize:12];
    if (wd > 0) [l.widthAnchor constraintEqualToConstant:wd].active = YES;
    [l setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    return l;
}

- (NSTextField *)field:(NSString *)placeholder width:(CGFloat)wd {
    NSTextField *f = [[NSTextField alloc] init];
    f.placeholderString = placeholder ?: @"";
    f.font = [NSFont systemFontOfSize:12];
    // 低 hugging:在行里横向膨胀吃掉剩余宽度(有定宽约束时定宽优先)
    [f setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    if (wd > 0) [f.widthAnchor constraintEqualToConstant:wd].active = YES;
    return f;
}

- (NSTextField *)hint:(NSString *)s {
    // 参考图样式:行下方的灰色小字说明(可多行换行)
    NSTextField *l = [NSTextField wrappingLabelWithString:s];
    l.font = [NSFont systemFontOfSize:11];
    l.textColor = [NSColor secondaryLabelColor];
    [l setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return l;
}

- (NSButton *)button:(NSString *)title action:(SEL)sel {
    NSButton *b = [NSButton buttonWithTitle:title target:self action:sel];
    if (@available(macOS 26.0, *)) {
        b.bezelStyle = NSBezelStyleGlass;   // 液态玻璃底座
    } else {
        b.bezelStyle = NSBezelStyleRounded;
    }
    b.font = [NSFont systemFontOfSize:12];
    return b;
}

- (NSStackView *)row {
    NSStackView *r = [NSStackView stackViewWithViews:@[]];
    r.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r.spacing = 6;
    r.alignment = NSLayoutAttributeCenterY;
    return r;
}

/// 「标签 + 控件们」的一行:标签定宽对齐,控件跟在后面
- (NSStackView *)formRow:(NSString *)labelText items:(NSArray<NSView *> *)items {
    NSStackView *r = [self row];
    [r addViews:@[[self label:labelText width:72]]];
    [r addViews:items];
    return r;
}

- (NSStackView *)pageStack {
    NSStackView *p = [NSStackView stackViewWithViews:@[]];
    p.orientation = NSUserInterfaceLayoutOrientationVertical;
    p.spacing = 14;
    p.alignment = NSLayoutAttributeLeading;
    p.translatesAutoresizingMaskIntoConstraints = NO;
    return p;
}

- (NSStackView *)formStack {
    NSStackView *v = [NSStackView stackViewWithViews:@[]];
    v.orientation = NSUserInterfaceLayoutOrientationVertical;
    v.spacing = 6;
    v.alignment = NSLayoutAttributeLeading;
    v.translatesAutoresizingMaskIntoConstraints = NO;
    return v;
}

/// 让表单的每个孩子(行/说明文字)与表单同宽——输入框才有空间可膨胀,说明文字才有换行宽度
- (void)stretchChildren:(NSStackView *)stack {
    for (NSView *v in stack.arrangedSubviews)
        [v.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
}

- (void)addCard:(NSView *)card toPage:(NSStackView *)page {
    [page addArrangedSubview:card];
    [card.widthAnchor constraintEqualToAnchor:page.widthAnchor].active = YES;
}

/// 表单页内容包进滚动视图(卡片多时窗口装得下也滚得动);
/// 表格/日志页不用这个——它们要吃掉剩余高度,不能滚。
- (NSScrollView *)scrollWrap:(NSStackView *)page {
    NSScrollView *sv = [[NSScrollView alloc] init];
    sv.hasVerticalScroller = YES;
    sv.drawsBackground = NO;          // 玻璃上不盖实心板(坑 #10)
    sv.autohidesScrollers = YES;
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    // NSStackView 不是 flipped(见 AMDFlippedDocView 注释),必须垫翻转容器当 documentView;
    // 页面钉满容器,容器高度 = max(内容高, 可视高)——内容少时铺满,内容多时可滚
    AMDFlippedDocView *doc = [[AMDFlippedDocView alloc] initWithFrame:NSZeroRect];
    doc.translatesAutoresizingMaskIntoConstraints = NO;
    [doc addSubview:page];
    page.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [page.topAnchor constraintEqualToAnchor:doc.topAnchor],
        [page.bottomAnchor constraintEqualToAnchor:doc.bottomAnchor],
        [page.leadingAnchor constraintEqualToAnchor:doc.leadingAnchor],
        [page.trailingAnchor constraintEqualToAnchor:doc.trailingAnchor],
    ]];
    sv.documentView = doc;            // 先入列再建 doc↔clipview 约束(坑 #1:共同祖先)
    [NSLayoutConstraint activateConstraints:@[
        [doc.widthAnchor constraintEqualToAnchor:sv.contentView.widthAnchor],
        [doc.heightAnchor constraintGreaterThanOrEqualToAnchor:sv.contentView.heightAnchor],
    ]];
    return sv;
}

#pragma mark - 页面(顺序 = 使用流程)

- (NSView *)buildPage:(NSInteger)idx {
    AMDDBG(@"page: build %ld", (long)idx);
    switch (idx) {
        case 0: return [self buildConnectionPage];
        case 1: return [self buildDevicePage];
        case 2: return [self buildSearchPage];
        case 3: return [self buildDownloadPage];
        case 4: return [self buildPreviewPage];
        case 5: return [self buildLyricPage];
        default: return [self buildLogPage];
    }
}

/// ① 连接:配好一切参数。主操作在工具栏(保存/自检),上下文动作(浏览/探测)贴着字段。
- (NSView *)buildConnectionPage {
    NSStackView *page = [self pageStack];
    NSStackView *intro = [self row];
    [intro addViews:@[[self hint:@"首次使用:本页配好并「环境自检」→ 「设备」确认手机就绪 → 「搜索」找歌 → 「下载」。"]]];
    [page addArrangedSubview:intro];
    [intro.widthAnchor constraintEqualToAnchor:page.widthAnchor].active = YES;

    {
        // 卡 1:ADB 连接
        NSStackView *v = [self formStack];
        _adbPathF = [self field:@"/opt/homebrew/bin/adb(留空自动探测)" width:0];
        [v addViews:@[
            [self formRow:@"adb 路径" items:@[_adbPathF, [self button:@"浏览…" action:@selector(browseAdb:)]]],
            [self hint:@"adb 可执行文件路径;GUI 拉起的子进程会自动补上 Homebrew PATH。"],
        ]];
        _serialF = [self field:@"单台设备自动采用" width:0];
        [v addViews:@[
            [self formRow:@"序列号" items:@[_serialF, [self button:@"探测设备" action:@selector(detectSerial:)]]],
            [self hint:@"多台设备同时在线时必填(UURemote / 多机场景)。"],
        ]];
        _adbHostF = [self field:@"空=标准" width:110];
        _adbPortF = [self field:@"空=5037" width:90];
        [v addViews:@[
            [self formRow:@"adb server" items:@[_adbHostF, [self label:@":" width:2], _adbPortF]],
            [self hint:@"普通 USB / 无线 adb 两项都留空;UURemote 代理只填 Port 15037。"],
        ]];
        [self stretchChildren:v];
        [self addCard:[self glassCard:@"ADB 连接" body:v] toPage:page];
    }
    {
        // 卡 2:解密通道(原生行为固定等价 auto:USB 优先,失败退回环 27042)
        NSStackView *v = [self formStack];
        _useTcpC = [NSButton checkboxWithTitle:@"使用 TCP 双链传输" target:nil action:nil];
        [v addArrangedSubview:_useTcpC];
        [v addViews:@[
            [self hint:@"有线 forward + 无线 LAN 并发分包,链路全挂自动回退;无线只走可信局域网。"],
        ]];
        _tcpPortF = [self field:@"17001" width:80];
        _lanIpF = [self field:@"自动探测" width:130];
        [v addViews:@[
            [self formRow:@"TCP 端口" items:@[_tcpPortF, [self label:@"LAN IP" width:44], _lanIpF,
                            [self button:@"探测IP" action:@selector(detectLan:)]]],
            [self hint:@"端口占用会自动顺延;LAN IP 探不到时手填手机的 wlan0 地址。"],
        ]];
        [self stretchChildren:v];
        [self addCard:[self glassCard:@"传输通道" body:v] toPage:page];
    }
    {
        // 卡 3:脚本与输出 + 状态
        NSStackView *v = [self formStack];
        _scriptDirF = [self field:@"download_tcp.py 与 .venv 所在目录" width:0];
        [v addViews:@[
            [self formRow:@"脚本目录" items:@[_scriptDirF, [self button:@"浏览…" action:@selector(browseScript:)]]],
            [self hint:@"Python 解释器按「脚本目录/.venv/bin/python」自动探测。"],
        ]];
        _outDirF = [self field:@"下载成品保存位置" width:0];
        [v addViews:@[
            [self formRow:@"输出目录" items:@[_outDirF, [self button:@"浏览…" action:@selector(browseOut:)]]],
        ]];
        NSStackView *st = [self row];
        _statusL = [NSTextField labelWithString:@"状态: 未保存"];
        _statusL.font = [NSFont systemFontOfSize:12];
        _statusL.textColor = [NSColor secondaryLabelColor];
        [st addViews:@[_statusL,
                       [self button:@"恢复默认" action:@selector(restoreDefaults:)]]];
        [v addViews:@[st]];
        [self stretchChildren:v];
        [self addCard:[self glassCard:@"脚本与输出" body:v] toPage:page];
    }
    return [self scrollWrap:page];
}

/// ② 设备:确认手机就绪。启动/重启是页面主操作 → 工具栏;反查是「正在播放」的上下文动作。
- (NSView *)buildDevicePage {
    NSStackView *page = [self pageStack];
    {
        NSStackView *v = [self formStack];
        _nowPlayingL = [NSTextField wrappingLabelWithString:@"尚未读取。"];
        _nowPlayingL.font = [NSFont systemFontOfSize:12];
        [v addArrangedSubview:_nowPlayingL];
        [v addViews:@[
            [self hint:@"先在手机上播首歌,再点下面的按钮:读到曲目后自动反查 adamId 并填入下载页。"],
        ]];
        NSStackView *r = [self row];
        [r addViews:@[[self button:@"读取正在播放并反查" action:@selector(fetchNowPlaying:)]]];
        [v addViews:@[r]];
        [self stretchChildren:v];
        [self addCard:[self glassCard:@"正在播放" body:v] toPage:page];
    }
    {
        NSStackView *v = [self formStack];
        [v addViews:@[
            [self hint:@"工具栏「启动播放器」:确保手机端注入引擎在跑,再拉起播放器主入口。日常下载前点一次即可。"],
            [self hint:@"工具栏「释放注入·重启」:强停并重新拉起播放器,清掉残留的注入线程;遇到播放异常 / 解密失败先用它恢复,再重试下载。"],
            [self hint:@"环境是否就绪用「连接」页工具栏的「环境自检」,四项全绿即可开下。"],
        ]];
        [self stretchChildren:v];
        [self addCard:[self glassCard:@"恢复与排查" body:v] toPage:page];
    }
    return [self scrollWrap:page];
}

/// ③ 搜索:找 adamId。回车即搜;双击结果行或工具栏「填入下载框」进入下一步。
- (NSView *)buildSearchPage {
    NSStackView *page = [self pageStack];
    {
        NSStackView *v = [self formStack];
        NSStackView *r = [self row];
        _keywordF = [self field:@"歌名 / 歌名 + 歌手" width:0];
        _keywordF.target = self;
        _keywordF.action = @selector(doSearch:);   // 回车直接搜
        _countryP = [[NSPopUpButton alloc] init];
        [_countryP addItemsWithTitles:@[@"全部", @"hk", @"tw", @"jp", @"us", @"cn"]];
        [_countryP selectItemWithTitle:@"全部"];
        [r addViews:@[_keywordF, [self label:@"区" width:12], _countryP]];
        [v addArrangedSubview:r];
        [v addViews:@[
            [self hint:@"一个区搜不到就换区(部分日区曲目在 CN 搜不到);多区并发会比单区慢一点。"],
        ]];
        [self stretchChildren:v];
        [self addCard:[self glassCard:@"关键词" body:v] toPage:page];
    }

    _table = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 800, 140)];
    _table.autoresizingMask = NSViewWidthSizable;
    _table.rowHeight = 22;   // 13pt 结果字不被裁
    _searchHintL = [NSTextField labelWithString:@""];
    NSArray *cols = @[@[@"ID", @90], @[@"曲名", @180], @[@"艺人", @160], @[@"专辑", @130], @[@"区", @36]];
    for (NSArray *c in cols) {
        NSTableColumn *tcol = [[NSTableColumn alloc] initWithIdentifier:c[0]];
        tcol.title = c[0];
        tcol.width = [c[1] doubleValue];
        [_table addTableColumn:tcol];
    }
    _table.delegate = self;
    _table.dataSource = self;
    _table.target = self;
    _table.doubleAction = @selector(fillFromSearch:);   // 双击=填入下载框
    _table.backgroundColor = [NSColor clearColor];
    NSScrollView *ts = [[NSScrollView alloc] init];
    ts.documentView = _table;
    ts.hasVerticalScroller = YES;
    ts.hasHorizontalScroller = NO;   // 列宽按最小窗口设计,宁可用省略号也不出横向滚动条
    ts.drawsBackground = NO;
    ts.autohidesScrollers = YES;
    ts.translatesAutoresizingMaskIntoConstraints = NO;
    [page addArrangedSubview:ts];
    [page addArrangedSubview:_searchHintL];
    [self stretchChildren:page];   // 表格与提示行铺满页宽
    // 表格吃掉剩余高度,提示行贴在下面
    [ts.heightAnchor constraintGreaterThanOrEqualToConstant:180].active = YES;
    [ts setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
    return page;
}

/// ④ 下载:填 adamId 开下。两个入口是页面主操作 → 工具栏;取消/打开目录是执行状态卡的上下文动作。
- (NSView *)buildDownloadPage {
    NSStackView *page = [self pageStack];
    {
        NSStackView *v = [self formStack];
        _adamF = [self field:@"如 1863847878,多个用逗号/空格分隔" width:0];
        _adamF.target = self;
        _adamF.action = @selector(startDownload:);   // 回车直接下
        [v addArrangedSubview:_adamF];
        [v addViews:@[
            [self hint:@"来源:搜索页双击结果行、设备页「读取正在播放并反查」,或手动粘贴。回车=开始下载。"],
        ]];
        [self stretchChildren:v];
        [self addCard:[self glassCard:@"目标曲目" body:v] toPage:page];
    }
    {
        NSStackView *v = [self formStack];
        NSStackView *r = [self row];
        _dlStatusL = [NSTextField labelWithString:@"状态: 空闲"];
        _dlStatusL.font = [NSFont systemFontOfSize:12];
        _dlStatusL.textColor = [NSColor secondaryLabelColor];
        _cancelBtn = [self button:@"取消" action:@selector(cancelDownload:)];
        _cancelBtn.enabled = NO;
        [r addViews:@[_dlStatusL, _cancelBtn,
                      [self button:@"打开输出目录" action:@selector(openOutDir:)]]];
        [v addViews:@[r]];
        [v addViews:@[
            [self hint:@"两种方式都在工具栏:「开始下载」走网络(自动深链预取→下载→解密→验证);"
                        "「缓存直解」只吃手机已缓存的曲目,零网络,要求 key 未过期。"],
            [self hint:@"完成后自动校验包数/解码/时长并写入标签与封面;详细进度看「日志」页。"],
        ]];
        [self stretchChildren:v];
        [self addCard:[self glassCard:@"执行" body:v] toPage:page];
    }
    return [self scrollWrap:page];
}

- (NSPopUpButton *)popWithTitles:(NSArray<NSString *> *)titles {
    NSPopUpButton *p = [[NSPopUpButton alloc] init];
    [p addItemsWithTitles:titles];
    [p selectItemAtIndex:0];
    return p;
}

// 内容表(搜索/预览/歌词三表同构):列定义 @[@[标题, 宽], ...],双击动作可空
- (NSTableView *)contentTable:(NSArray<NSArray *> *)cols action:(nullable SEL)sel {
    NSTableView *t = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 800, 140)];
    t.autoresizingMask = NSViewWidthSizable;
    t.rowHeight = 22;
    for (NSArray *c in cols) {
        NSTableColumn *tcol = [[NSTableColumn alloc] initWithIdentifier:c[0]];
        tcol.title = c[0];
        tcol.width = [c[1] doubleValue];
        [t addTableColumn:tcol];
    }
    t.delegate = self;
    t.dataSource = self;
    t.target = self;
    if (sel) t.doubleAction = sel;
    t.backgroundColor = [NSColor clearColor];
    return t;
}

// 表格滚动容器(吃掉剩余高度);调用方先 addArrangedSubview 再调本方法做约束(先入列后激活)
- (NSScrollView *)tableScroll:(NSTableView *)t {
    NSScrollView *ts = [[NSScrollView alloc] init];
    ts.documentView = t;
    ts.hasVerticalScroller = YES;
    ts.hasHorizontalScroller = NO;   // 列宽按最小窗口设计,宁可用省略号也不出横向滚动条
    ts.drawsBackground = NO;
    ts.autohidesScrollers = YES;
    ts.translatesAutoresizingMaskIntoConstraints = NO;
    return ts;
}

/// ⑤ 预览:输出目录 .m4a 清单(只认 m4a;同名 .json 有则读 artist/title,无则回退文件名)。
/// 主操作 → 工具栏「刷新列表」;双击行把文件名填进歌词页(单曲模式)并跳过去。
- (NSView *)buildPreviewPage {
    NSStackView *page = [self pageStack];
    _pvTable = [self contentTable:@[@[@"文件名", @260], @[@"艺人", @150], @[@"曲名", @180], @[@"大小", @80]]
                           action:@selector(fillFromPreview:)];
    NSScrollView *ts = [self tableScroll:_pvTable];
    _pvHintL = [NSTextField labelWithString:@""];
    [page addArrangedSubview:ts];
    [page addArrangedSubview:_pvHintL];
    [self stretchChildren:page];
    [ts.heightAnchor constraintGreaterThanOrEqualToConstant:180].active = YES;
    [ts setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
    {
        NSStackView *v = [self formStack];
        NSStackView *r = [self row];
        [r addViews:@[[self button:@"打开输出目录" action:@selector(openOutDir:)]]];
        [v addViews:@[r]];
        [v addViews:@[
            [self hint:@"只列 .m4a;艺人/曲名优先读同名 .json(跟随收割与下载都会写),没有就从文件名猜。双击一行=填入歌词页。"],
        ]];
        [self stretchChildren:v];
        [self addCard:[self glassCard:@"成品" body:v] toPage:page];
    }
    return page;
}

/// ⑥ 歌词:单曲模式。目标(搜索名+文件名)→ 搜索选源 → 输出选项 → 互转。查/存是页面主操作 → 工具栏。
- (NSView *)buildLyricPage {
    NSStackView *page = [self pageStack];
    {
        NSStackView *v = [self formStack];
        _lyKeyF = [self field:@"如 9Lana - BLUE MOON,可从预览页双击填入" width:0];
        _lyKeyF.target = self;
        _lyKeyF.action = @selector(lyricSearch:);   // 回车直接查
        [v addViews:@[
            [self formRow:@"搜索名" items:@[_lyKeyF]],
            [self hint:@"歌词源(网易云/QQ)按这个名字搜;要是文件名带艺人-曲名,直接用也行。"],
        ]];
        _lyFileF = [self field:@"目标 m4a 路径(预览页双击填入,或手动选)" width:0];
        [v addViews:@[
            [self formRow:@"文件名" items:@[_lyFileF, [self button:@"选择…" action:@selector(browseLyricFile:)]]],
            [self hint:@"内嵌/外置都以这个文件为基准(外置写同名 .lrc/.srt;相对路径按输出目录解)。"],
        ]];
        [self stretchChildren:v];
        [self addCard:[self glassCard:@"目标" body:v] toPage:page];
    }
    {
        NSStackView *v = [self formStack];
        NSStackView *r = [self row];
        _lyNEBtn = [NSButton checkboxWithTitle:@"网易云" target:nil action:nil];
        _lyQQBtn = [NSButton checkboxWithTitle:@"QQ音乐" target:nil action:nil];
        [r addViews:@[[self label:@"歌词源" width:44], _lyNEBtn, _lyQQBtn]];
        [v addArrangedSubview:r];
        _lyTable = [self contentTable:@[@[@"来源", @60], @[@"歌名", @200], @[@"歌手", @150], @[@"时长", @60]]
                               action:nil];
        NSScrollView *ts = [self tableScroll:_lyTable];
        [v addArrangedSubview:ts];
        _lyHintL = [NSTextField labelWithString:@"尚未搜索。"];
        _lyHintL.font = [NSFont systemFontOfSize:12];
        [v addArrangedSubview:_lyHintL];
        [v addViews:@[
            [self hint:@"两源合并一表,网易云在前;点中一行再按工具栏「保存歌词」。"],
        ]];
        [self stretchChildren:v];
        [self addCard:[self glassCard:@"搜索" body:v] toPage:page];
        [ts.heightAnchor constraintGreaterThanOrEqualToConstant:140].active = YES;
        [ts setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
    }
    {
        NSStackView *v = [self formStack];
        _lyModeP = [self popWithTitles:@[@"内嵌m4a", @"外置lrc", @"外置srt"]];
        _lyEncP = [self popWithTitles:@[@"UTF-8", @"GB18030", @"UTF-16"]];
        _lyLayoutP = [self popWithTitles:@[@"交错", @"独立", @"合并"]];
        _lySepF = [self field:@" / " width:60];
        [v addViews:@[
            [self formRow:@"输出" items:@[_lyModeP, [self label:@"编码" width:32], _lyEncP]],
            [self hint:@"内嵌=写进 m4a 的歌词原子(可重打);外置=同目录同名文本(编码只对外置有效)。"],
            [self formRow:@"双语" items:@[_lyLayoutP, [self label:@"分隔" width:32], _lySepF]],
            [self hint:@"交错=原文译文按时间穿插;独立=各轨顺接;合并=同时间戳拼一行(用分隔符)。"],
        ]];
        [self stretchChildren:v];
        [self addCard:[self glassCard:@"输出选项" body:v] toPage:page];
    }
    {
        NSStackView *v = [self formStack];
        _lyConvSrcF = [self field:@"源文件(.lrc/.srt/.m4a)" width:0];
        _lyConvP = [self popWithTitles:@[@"lrc→srt", @"srt→lrc", @"文本→m4a内嵌", @"m4a内嵌→lrc", @"m4a内嵌→srt"]];
        NSStackView *r = [self row];
        [r addViews:@[_lyConvP, [self button:@"开始转换" action:@selector(lyricConvert:)]]];
        [v addViews:@[
            [self formRow:@"源文件" items:@[_lyConvSrcF, [self button:@"选择…" action:@selector(browseConvSrc:)]]],
        ]];
        [v addArrangedSubview:r];
        [v addViews:@[
            [self hint:@"lrc↔srt 纯文本互转(时间戳零漂移);文本→m4a 把同名文本嵌进去;m4a→文本把内嵌词导出来。目标默认同目录同名。"],
        ]];
        [self stretchChildren:v];
        [self addCard:[self glassCard:@"互转" body:v] toPage:page];
    }
    [self loadLyricConfigToUI];   // 懒建:控件现在才出生,把已存配置刷上去
    return [self scrollWrap:page];
}

/// ⑦ 日志:只读输出。清空/复制在工具栏。
- (NSView *)buildLogPage {
    NSStackView *page = [self pageStack];
    NSScrollView *ls = [[NSScrollView alloc] init];
    ls.hasVerticalScroller = YES;
    ls.hasHorizontalScroller = NO;   // 文本宽度自动跟随,横向滚动条是多余的
    ls.drawsBackground = NO;
    ls.autohidesScrollers = YES;
    ls.translatesAutoresizingMaskIntoConstraints = NO;
    _logV = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 800, 220)];
    _logV.minSize = NSMakeSize(0, 220);
    _logV.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
    _logV.verticallyResizable = YES;
    _logV.horizontallyResizable = NO;
    _logV.autoresizingMask = NSViewWidthSizable;
    [[_logV textContainer] setContainerSize:NSMakeSize(800, FLT_MAX)];
    [[_logV textContainer] setWidthTracksTextView:YES];
    _logV.editable = NO;
    _logV.drawsBackground = NO;   // 透出玻璃,不做黑板
    _logV.textColor = [NSColor whiteColor];   // 固定深色模式,黑色字看不见
    _logV.insertionPointColor = [NSColor whiteColor];
    _logV.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    ls.documentView = _logV;
    [page addArrangedSubview:ls];
    [ls.widthAnchor constraintEqualToAnchor:page.widthAnchor].active = YES;
    [ls.heightAnchor constraintGreaterThanOrEqualToConstant:240].active = YES;
    [ls setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
    [self appendLog:[NSString stringWithFormat:@"%@\n", OB_UI_READY]];
    return page;
}

#pragma mark - config

- (void)loadConfigToUI {
    AMDConfig *c = [AMDConfig shared];
    _adbPathF.stringValue = c.adbPath ?: @"";
    _adbHostF.stringValue = c.adbHost ?: @"";
    _adbPortF.stringValue = c.adbPort ?: @"";
    _serialF.stringValue = c.serial ?: @"";
    _tcpPortF.stringValue = c.tcpPort ?: @"17001";
    _lanIpF.stringValue = c.lanIp ?: @"";
    _scriptDirF.stringValue = c.scriptDir ?: @"";
    _outDirF.stringValue = c.outDir ?: @"";
    _useTcpC.state = c.useTcp ? NSControlStateValueOn : NSControlStateValueOff;
    [self loadLyricConfigToUI];
}

// 歌词选项 UI ↔ 配置(页面懒建,load 时控件可能 nil,消息空转安全)
- (void)loadLyricConfigToUI {
    AMDConfig *c = [AMDConfig shared];
    NSArray *modes = @[@"embed", @"lrc", @"srt"];
    NSArray *layouts = @[@"stagger", @"isolated", @"merge"];
    NSArray *encs = @[@"UTF-8", @"GB18030", @"UTF-16"];
    NSInteger mi = [modes indexOfObject:c.lyricMode];
    [_lyModeP selectItemAtIndex:(mi == NSNotFound || mi > 2) ? 0 : mi];
    NSInteger li = [layouts indexOfObject:c.lyricLayout];
    [_lyLayoutP selectItemAtIndex:(li == NSNotFound || li > 2) ? 0 : li];
    NSInteger ei = [encs indexOfObject:c.lyricEncoding];
    [_lyEncP selectItemAtIndex:(ei == NSNotFound || ei > 2) ? 0 : ei];
    _lySepF.stringValue = c.lyricMergeSep ?: @" / ";
    _lyNEBtn.state = c.lyricUseNE ? NSControlStateValueOn : NSControlStateValueOff;
    _lyQQBtn.state = c.lyricUseQQ ? NSControlStateValueOn : NSControlStateValueOff;
}

// 只允许主线程调(读的是输入框,后台任务请先在动作入口同步好再 dispatch)
- (void)readUIToConfig {
    AMDConfig *c = [AMDConfig shared];
    c.adbPath = [_adbPathF.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    c.adbHost = [_adbHostF.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    c.adbPort = [_adbPortF.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    c.serial = [_serialF.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    c.tcpPort = [_tcpPortF.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (c.tcpPort.length == 0) c.tcpPort = @"17001";
    c.lanIp = [_lanIpF.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    c.scriptDir = [_scriptDirF.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    c.outDir = [_outDirF.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    c.useTcp = (_useTcpC.state == NSControlStateValueOn);
    [self readLyricUIToConfig];
}

// 歌词页没建出来(_lyModeP 为 nil)就不碰配置,免得把已存值洗成默认
- (void)readLyricUIToConfig {
    if (!_lyModeP) return;
    AMDConfig *c = [AMDConfig shared];
    NSArray *modes = @[@"embed", @"lrc", @"srt"];
    NSArray *layouts = @[@"stagger", @"isolated", @"merge"];
    NSArray *encs = @[@"UTF-8", @"GB18030", @"UTF-16"];
    NSInteger mi = [_lyModeP indexOfSelectedItem];
    c.lyricMode = (mi >= 0 && mi < 3) ? modes[mi] : @"embed";
    NSInteger li = [_lyLayoutP indexOfSelectedItem];
    c.lyricLayout = (li >= 0 && li < 3) ? layouts[li] : @"stagger";
    NSInteger ei = [_lyEncP indexOfSelectedItem];
    c.lyricEncoding = (ei >= 0 && ei < 3) ? encs[ei] : @"UTF-8";
    NSString *sep = [_lySepF.stringValue stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    c.lyricMergeSep = sep.length ? _lySepF.stringValue : @" / ";
    c.lyricUseNE = (_lyNEBtn.state == NSControlStateValueOn);
    c.lyricUseQQ = (_lyQQBtn.state == NSControlStateValueOn);
}

- (void)saveConfig:(id)sender {
    AMDDBG(@"action: saveConfig");
    [self readUIToConfig];
    [[AMDConfig shared] save];
    _statusL.stringValue = [NSString stringWithFormat:@"状态: 已保存(%@)",
                            [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                          dateStyle:NSDateFormatterNoStyle
                                                          timeStyle:NSDateFormatterShortStyle]];
    [self appendLog:@"[设置] 已保存\n"];
}

- (void)restoreDefaults:(id)sender {
    AMDDBG(@"action: restoreDefaults");
    [[AMDConfig shared] restoreDefaults];
    [[AMDConfig shared] save];
    [self loadConfigToUI];
    _statusL.stringValue = @"状态: 已恢复默认";
    [self appendLog:@"[设置] 已恢复默认\n"];
}

#pragma mark - log

- (void)appendLog:(NSString *)s {
    if (!s.length || !_logV) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTextStorage *st = self->_logV.textStorage;
        if (!st) return;
        // 日志字色固定白色(见建页处注释)
        NSFont *f = self->_logV.font ?: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
        NSDictionary *at = @{NSForegroundColorAttributeName: [NSColor whiteColor],
                             NSFontAttributeName: f};
        [st appendAttributedString:[[NSAttributedString alloc] initWithString:s attributes:at]];
        // 上限:保留最后约 6000 行
        if (st.string.length > 600000) {
            [st deleteCharactersInRange:NSMakeRange(0, st.string.length - 600000)];
        }
        [self->_logV scrollRangeToVisible:NSMakeRange(st.length, 0)];
    });
}

- (void)clearLog:(id)sender { AMDDBG(@"action: clearLog"); _logV.string = @""; }
- (void)copyLog:(id)sender {
    AMDDBG(@"action: copyLog");
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:_logV.string forType:NSPasteboardTypeString];
}

#pragma mark - adb helpers (数组传参,无 shell,避开 zsh/引号坑)

// NSTask 要求绝对路径;用户若只填 "adb" 则 which 解析
- (NSString *)resolvedToolPath:(NSString *)p {
    if ([p rangeOfString:@"/"].location != NSNotFound) return p;
    int st = 0;
    NSString *out = [TaskRunner runSync:@"/bin/zsh" arguments:@[@"-lc", [@"which " stringByAppendingString:p]]
                                    cwd:nil env:nil status:&st];
    NSString *t = [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (st == 0 && t.length > 0 && [t hasPrefix:@"/"]) return [t componentsSeparatedByString:@"\n"][0];
    return p;
}

- (NSArray<NSString *> *)adbArgsWithTail:(NSArray<NSString *> *)tail {
    // 注意:不读 UI,直接用已同步进 AMDConfig 的值;
    // 各按钮动作在主线程入口先 readUIToConfig,后台块只管用。
    AMDConfig *c = [AMDConfig shared];
    NSMutableArray *a = [NSMutableArray arrayWithArray:[c adbBaseArgs]];
    [a addObjectsFromArray:tail];
    return a;
}

- (NSString *)runAdbSync:(NSArray<NSString *> *)tail status:(int *)st {
    AMDConfig *c = [AMDConfig shared];
    NSString *adb = [self resolvedToolPath:c.adbPath.length ? c.adbPath : @"adb"];
    NSString *out = [TaskRunner runSync:adb arguments:[self adbArgsWithTail:tail] cwd:nil env:nil status:st];
    AMDDBG(@"adb: %@ → exit=%d out=%@", [tail componentsJoinedByString:@" "], st ? *st : -1,
           out.length > 200 ? [out substringToIndex:200] : out);
    return out;
}

// 注入引擎服务保活:不存在则按 docs/01 命令拉起
- (void)ensureAgentServer {
    int st = 0;
    NSString *psCmd = [NSString stringWithFormat:@"su -c 'ps -A | grep -i %@'", OB_AGENT_TAG];
    NSString *ps = [self runAdbSync:@[@"shell", psCmd] status:&st];
    if (st == 0 && [ps rangeOfString:OB_AGENT_SRV].location != NSNotFound) {
        [self appendLog:[NSString stringWithFormat:@"%@\n", OB_UI_LOG_RUNNING]];
        return;
    }
    [self appendLog:[NSString stringWithFormat:@"%@\n", OB_UI_LOG_STARTING]];
    NSString *upCmd = [NSString stringWithFormat:@"su -c 'nohup /data/local/tmp/%@ -l 127.0.0.1:27042 >/dev/null 2>&1 &'", OB_AGENT_SRV16];
    [self runAdbSync:@[@"shell", upCmd] status:&st];
    [NSThread sleepForTimeInterval:2.0];
    NSString *ps2 = [self runAdbSync:@[@"shell", psCmd] status:&st];
    if ([ps2 rangeOfString:OB_AGENT_SRV].location != NSNotFound)
        [self appendLog:[NSString stringWithFormat:@"%@\n", OB_UI_LOG_STARTED]];
    else
        [self appendLog:[NSString stringWithFormat:@"%@\n", OB_UI_LOG_FAIL]];
}

#pragma mark - file pickers

- (void)pickExecutableInto:(NSTextField *)f {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseFiles = YES; p.canChooseDirectories = NO; p.allowsMultipleSelection = NO;
    if ([p runModal] == NSModalResponseOK && p.URLs.count > 0)
        f.stringValue = p.URLs[0].path;
}

- (void)pickDirectoryInto:(NSTextField *)f {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseFiles = NO; p.canChooseDirectories = YES; p.allowsMultipleSelection = NO;
    if ([p runModal] == NSModalResponseOK && p.URLs.count > 0)
        f.stringValue = p.URLs[0].path;
}

- (void)browseAdb:(id)sender { AMDDBG(@"action: browseAdb"); [self pickExecutableInto:_adbPathF]; }
- (void)browseScript:(id)sender { AMDDBG(@"action: browseScript"); [self pickDirectoryInto:_scriptDirF]; }
- (void)browseOut:(id)sender { AMDDBG(@"action: browseOut"); [self pickDirectoryInto:_outDirF]; }
- (void)openOutDir:(id)sender {
    AMDDBG(@"action: openOutDir");
    [self readUIToConfig];
    NSString *dir = [AMDConfig shared].outDir;
    if (dir.length == 0) return;
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:dir]];
}

#pragma mark - device buttons

// 动作入口统一:主线程先同步 UI → 配置,再派后台活(后台块绝不碰输入框)
- (void)detectSerial:(id)sender {
    AMDDBG(@"action: detectSerial");
    [self readUIToConfig];
    [self appendLog:@"[adb] 探测设备…\n"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int st = 0;
        NSString *out = [self runAdbSync:@[@"devices", @"-l"] status:&st];
        __block NSString *found = nil;
        [out enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
            NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (t.length == 0 || [t hasPrefix:@"List of"] || [t hasPrefix:@"*"]) return;
            NSArray *parts = [t componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSMutableArray *tok = [NSMutableArray array];
            for (NSString *x in parts) if (x.length) [tok addObject:x];
            if (tok.count >= 2 && [tok[1] isEqualToString:@"device"]) { found = tok[0]; *stop = YES; }
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (found) {
                self->_serialF.stringValue = found;
                [self appendLog:[NSString stringWithFormat:@"[adb] 设备: %@\n", found]];
                self->_statusL.stringValue = [@"状态: 设备 " stringByAppendingString:found];
            } else {
                [self appendLog:[NSString stringWithFormat:@"[adb] 未找到设备,输出:\n%@\n", out]];
                self->_statusL.stringValue = @"状态: 未找到设备";
            }
        });
    });
}

- (void)detectLan:(id)sender {
    AMDDBG(@"action: detectLan");
    [self readUIToConfig];
    [self appendLog:@"[adb] 探测手机 LAN IP…\n"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int st = 0;
        NSString *ip = nil;
        NSString *out = [self runAdbSync:@[@"shell", @"ip -o -4 addr show wlan0"] status:&st];
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"inet ([0-9.]+)/" options:0 error:NULL];
        NSTextCheckingResult *m = [re firstMatchInString:out options:0 range:NSMakeRange(0, out.length)];
        if (m && m.numberOfRanges >= 2) ip = [out substringWithRange:[m rangeAtIndex:1]];
        if (!ip) {
            NSString *out2 = [self runAdbSync:@[@"shell", @"getprop dhcp.wlan0.ipaddress"] status:&st];
            NSString *t = [out2 stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (t.length >= 7 && [t rangeOfString:@"."].location != NSNotFound) ip = [t componentsSeparatedByString:@"\n"][0];
        }
        NSString *found = ip;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (found) {
                self->_lanIpF.stringValue = found;
                [self appendLog:[NSString stringWithFormat:@"[adb] 手机 LAN IP: %@\n", found]];
            } else {
                [self appendLog:@"[adb] 探测失败(手机未连 WiFi?)\n"];
            }
        });
    });
}

- (void)launchMusic:(id)sender {
    AMDDBG(@"action: launchMusic");
    [self readUIToConfig];
    [self appendLog:[NSString stringWithFormat:@"%@\n", OB_UI_LAUNCH_LOG]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self ensureAgentServer];
        int st = 0;
        // SplashActivity 为 recents 实锤的入口 cmp(docs/08 用 deep-link,此处直接拉起主入口)
        NSString *cmd = [NSString stringWithFormat:@"am start -n %@/.onboarding.activities.SplashActivity", OB_PHONE_PKG];
        NSString *out = [self runAdbSync:@[@"shell", cmd] status:&st];
        NSString *msg = [NSString stringWithFormat:@"[设备] am start (exit=%d): %@\n", st,
                         [[out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] substringToIndex:MIN(300, out.length)]];
        [self appendLog:msg];
    });
}

// 原生引擎自检:forward → 连接(attach)→ 装完整 agent → refresh 往返 → 断开(按需短连接)。
- (void)kitSelfTest:(id)sender {
    AMDDBG(@"action: kitSelfTest");
    [self readUIToConfig];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (NSString *line in [OBDLJob selfTest])
            [self appendLog:[line stringByAppendingString:@"\n"]];
    });
}

// 一键安装手机端引擎服务(在线下载,不打包本体;已存在则跳过下载只重启+自检)
- (void)installEngine:(id)sender {
    AMDDBG(@"action: installEngine");
    [self readUIToConfig];
    [self appendLog:@"[安装] 开始安装引擎服务…\n"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (NSString *line in [OBDLJob installEngineService])
            [self appendLog:[line stringByAppendingString:@"\n"]];
    });
}

// 释放残留注入:force-stop 杀掉 App 内注入引擎的僵尸 Java 线程(docs/03附),再拉起
- (void)cleanMusic:(id)sender {
    AMDDBG(@"action: cleanMusic");
    [self readUIToConfig];
    [self appendLog:[NSString stringWithFormat:@"%@\n", OB_UI_RESTART_LOG]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int st = 0;
        NSString *stopCmd = [NSString stringWithFormat:@"am force-stop %@", OB_PHONE_PKG];
        [self runAdbSync:@[@"shell", stopCmd] status:&st];
        [NSThread sleepForTimeInterval:1.5];
        NSString *pidCmd = [NSString stringWithFormat:@"pidof %@", OB_PHONE_PKG];
        NSString *check = [self runAdbSync:@[@"shell", pidCmd] status:&st];
        NSString *left = [check stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (left.length == 0) {
            [self appendLog:@"[设备] 已停止,正在重新拉起…\n"];
            NSString *startCmd = [NSString stringWithFormat:@"am start -n %@/.onboarding.activities.SplashActivity", OB_PHONE_PKG];
            [self runAdbSync:@[@"shell", startCmd] status:&st];
            [self appendLog:@"[设备] 已重新拉起\n"];
        } else {
            [self appendLog:[NSString stringWithFormat:@"[设备] 仍在运行(pid %@),请重试\n", left]];
        }
    });
}

// 下载入口的可用性:跑任务时禁用工具栏下载项 + 启用取消
- (void)applyDownloadBusy:(BOOL)busy {
    _cancelBtn.enabled = busy;
    if (_dlStatusL) _dlStatusL.stringValue = busy ? @"状态: 下载中…" : @"状态: 空闲";
    for (NSToolbarItem *it in self.window.toolbar.items) {
        if ([it.itemIdentifier isEqualToString:@"tb.download"] ||
            [it.itemIdentifier isEqualToString:@"tb.cache"]) it.enabled = !busy;
    }
}

- (void)checkEnv:(id)sender {
    AMDDBG(@"action: checkEnv (native)");
    // python 路线已降级为隐藏回退:自检默认走原生引擎(脚本仍可手动跑 --check 对照)
    [self readUIToConfig];
    [self appendLog:@"[自检] 原生引擎环境自检…\n"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (NSString *line in [OBDLJob selfTest])
            [self appendLog:[line stringByAppendingString:@"\n"]];
    });
}

#pragma mark - now playing

- (void)fetchNowPlaying:(id)sender {
    AMDDBG(@"action: fetchNowPlaying");
    [self readUIToConfig];
    [self appendLog:@"[播放] 读取 dumpsys media_session…\n"];
    _nowPlayingL.stringValue = @"读取中…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        int st = 0;
        NSString *out = [self runAdbSync:@[@"shell", @"dumpsys media_session"] status:&st];
        // 解析 state + description
        NSString *state = @"";
        NSString *desc = @"";
        NSRegularExpression *reState = [NSRegularExpression regularExpressionWithPattern:@"state=PlaybackState \\{state=(\\w+)" options:0 error:NULL];
        NSRegularExpression *reDesc = [NSRegularExpression regularExpressionWithPattern:@"description=([^\\n]+)" options:0 error:NULL];
        // 取手机播放器会话块附近的 state:找到目标包名后的第一个 state
        NSRange musicRange = [out rangeOfString:OB_PHONE_PKG];
        NSString *scope = out;
        if (musicRange.location != NSNotFound)
            scope = [out substringFromIndex:musicRange.location];
        NSTextCheckingResult *ms = [reState firstMatchInString:scope options:0 range:NSMakeRange(0, MIN(scope.length, 4000))];
        if (ms && ms.numberOfRanges >= 2) state = [scope substringWithRange:[ms rangeAtIndex:1]];
        NSTextCheckingResult *md = [reDesc firstMatchInString:scope options:0 range:NSMakeRange(0, MIN(scope.length, 4000))];
        if (md && md.numberOfRanges >= 1) {
            desc = [scope substringWithRange:[md rangeAtIndex:1]];
            desc = [desc stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
        if (desc.length == 0) {
            [self appendLog:@"[播放] 未读到 description(可能暂停/无会话)\n"];
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_nowPlayingL.stringValue = @"未获取(无会话或已暂停)";
            });
            return;
        }
        NSArray *parts = [desc componentsSeparatedByString:@", "];
        NSString *title = parts.count > 0 ? parts[0] : desc;
        NSString *artist = parts.count > 1 ? parts[1] : @"";
        NSString *album = parts.count > 2 ? [[parts subarrayWithRange:NSMakeRange(2, parts.count - 2)] componentsJoinedByString:@", "] : @"";
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_nowPlayingL.stringValue = [NSString stringWithFormat:@"%@ — %@ [%@] (%@)", title, artist, album, state];
        });
        [self appendLog:[NSString stringWithFormat:@"[播放] %@ — %@ | 反查 adamId 中…\n", title, artist]];
        // 曲库反查(后台)
        NSString *best = nil;
        NSNumber *adam = [AMDSearch resolveAdamIdForTitle:title artist:artist
                                               countries:AllCountries() bestTitle:&best];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (adam) {
                self->_adamF.stringValue = [adam stringValue];
                [self appendLog:[NSString stringWithFormat:@"[播放] 命中 adamId=%@ (%@),已填入下载页\n", adam, best]];
            } else {
                [self appendLog:@"[播放] 曲库五区均未命中,请到「搜索」页手动搜\n"];
            }
        });
    });
}

#pragma mark - search table

- (id)tableView:(NSTableView *)tv objectValueForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    if (tv == _sideTable) return @"";
    return [self cellStringForTable:tv row:row ident:col.identifier] ?: @"";
}

// 交替行底色(半透明,透出玻璃);macOS 没有自定义交替色属性,走 delegate。三个内容表通用。
- (void)tableView:(NSTableView *)tableView didAddRowView:(NSTableRowView *)rowView forRow:(NSInteger)row {
    if (tableView != _table && tableView != _pvTable && tableView != _lyTable) return;
    rowView.backgroundColor = (row % 2) ? [NSColor colorWithWhite:1.0 alpha:0.05] : [NSColor clearColor];
}

- (void)doSearch:(id)sender {
    AMDDBG(@"action: doSearch");
    NSString *kw = [_keywordF.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (kw.length == 0) { _searchHintL.stringValue = @"先输入关键词"; return; }
    NSString *sel = _countryP.titleOfSelectedItem ?: @"全部";
    NSArray *countries = [sel isEqualToString:@"全部"] ? AllCountries() : @[[sel lowercaseString]];
    _searchHintL.stringValue = @"搜索中…";
    [self appendLog:[NSString stringWithFormat:@"[搜索] \"%@\" (%@)…\n", kw, sel]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray *all = [NSMutableArray array];
        for (NSString *cc in countries) {
            NSError *e = nil;
            NSArray *rows = [AMDSearch search:kw country:cc limit:20 error:&e];
            for (NSDictionary *r in rows) {
                NSMutableDictionary *m = [r mutableCopy];
                m[@"src"] = cc;
                [all addObject:m];
            }
            if (e) [self appendLog:[NSString stringWithFormat:@"[搜索] %@ 区失败: %@\n", cc, e.localizedDescription]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_results removeAllObjects];
            [self->_results addObjectsFromArray:all];
            [self->_table reloadData];
            self->_searchHintL.stringValue = [NSString stringWithFormat:@"共 %lu 条 — 双击行或点工具栏「填入下载框」", (unsigned long)all.count];
            [self appendLog:[NSString stringWithFormat:@"[搜索] 共 %lu 条\n", (unsigned long)all.count]];
        });
    });
}

- (void)fillFromSearch:(id)sender {
    AMDDBG(@"action: fillFromSearch");
    NSInteger row = _table.selectedRow;
    if (row < 0 || row >= (NSInteger)_results.count) {
        _searchHintL.stringValue = @"先在表中选一行(可双击)";
        return;
    }
    NSString *adam = [_results[row][@"trackId"] stringValue];
    _adamF.stringValue = adam;
    _searchHintL.stringValue = [NSString stringWithFormat:@"已填入 %@ — 到「下载」页开下", adam];
    [self appendLog:[NSString stringWithFormat:@"[搜索] 填入 adamId=%@ (%@ — %@)\n",
                     adam, _results[row][@"track"], _results[row][@"artist"]]];
}

#pragma mark - preview & lyric

// 目标 m4a 路径归一:绝对路径直接用;相对按输出目录解;不存在/非 m4a 返回 nil
- (nullable NSString *)resolveLyricTarget:(NSString *)s {
    NSString *t = [s stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!t.length) return nil;
    if (![t isAbsolutePath])
        t = [[AMDConfig shared].outDir stringByAppendingPathComponent:t];
    if (![[t.pathExtension lowercaseString] isEqualToString:@"m4a"]) return nil;
    if (![[NSFileManager defaultManager] fileExistsAtPath:t]) return nil;
    return t;
}

- (void)refreshPreview:(id)sender {
    AMDDBG(@"action: refreshPreview");
    [self readUIToConfig];
    NSString *dir = [AMDConfig shared].outDir;
    _pvHintL.stringValue = @"扫描中…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL];
        NSMutableArray *items = [NSMutableArray array];
        for (NSString *fn in [files sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
            if (![[fn.pathExtension lowercaseString] isEqualToString:@"m4a"]) continue;
            NSString *full = [dir stringByAppendingPathComponent:fn];
            NSString *base = [fn stringByDeletingPathExtension];
            NSString *artist = nil, *title = nil;
            // 同名 .json 有则读 artist/title(下载与跟随收割都会写);文件不存在时 data 为 nil,
            // 直接调 JSONObjectWithData 会抛异常(不走 error),必须先判空
            NSString *jp = [[full stringByDeletingPathExtension] stringByAppendingPathExtension:@"json"];
            NSData *jd = [[NSData alloc] initWithContentsOfFile:jp];
            NSDictionary *j = jd ? [NSJSONSerialization JSONObjectWithData:jd options:0 error:NULL] : nil;
            if ([j isKindOfClass:[NSDictionary class]]) {
                if ([j[@"artist"] length]) artist = j[@"artist"];
                if ([j[@"title"] length]) title = j[@"title"];
            }
            if (!artist || !title) {
                // 回退:文件名 "艺人 - 曲名" 切分
                NSRange r = [base rangeOfString:@" - "];
                if (r.location != NSNotFound) {
                    if (!artist) artist = [base substringToIndex:r.location];
                    if (!title) title = [base substringFromIndex:r.location + r.length];
                }
            }
            unsigned long long sz = [[[NSFileManager defaultManager]
                                      attributesOfItemAtPath:full error:NULL] fileSize];
            NSString *sizeText = sz > 1048576 ?
                [NSString stringWithFormat:@"%.1fMB", sz / 1048576.0] :
                [NSString stringWithFormat:@"%.0fKB", sz / 1024.0];
            [items addObject:@{ @"file": full, @"name": base,
                                @"artist": artist ?: @"?", @"title": title ?: base,
                                @"sizeText": sizeText }];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_pvItems removeAllObjects];
            [self->_pvItems addObjectsFromArray:items];
            [self->_pvTable reloadData];
            self->_pvHintL.stringValue =
                [NSString stringWithFormat:@"共 %lu 个 — 双击行填入歌词页", (unsigned long)items.count];
            [self appendLog:[NSString stringWithFormat:@"[预览] %@ 共 %lu 个 m4a\n", dir, (unsigned long)items.count]];
        });
    });
}

// 预览双击:文件名→歌词页搜索名,全路径→文件名框(单曲模式),并跳到歌词页
- (void)fillFromPreview:(id)sender {
    AMDDBG(@"action: fillFromPreview");
    NSInteger row = _pvTable.selectedRow;
    if (row < 0 || row >= (NSInteger)_pvItems.count) {
        _pvHintL.stringValue = @"先在表中选一行(可双击)";
        return;
    }
    NSDictionary *it = _pvItems[row];
    // 先切页(懒建)再填,顺序不能反
    [_sideTable selectRowIndexes:[NSIndexSet indexSetWithIndex:5] byExtendingSelection:NO];
    [self switchToSection:5];
    _lyKeyF.stringValue = it[@"name"] ?: @"";
    _lyFileF.stringValue = it[@"file"] ?: @"";
    [self appendLog:[NSString stringWithFormat:@"[预览] 已填入歌词页: %@\n", it[@"name"]]];
}

- (void)browseLyricFile:(id)sender {
    AMDDBG(@"action: browseLyricFile");
    [self pickExecutableInto:_lyFileF];
}

- (void)browseConvSrc:(id)sender {
    AMDDBG(@"action: browseConvSrc");
    [self pickExecutableInto:_lyConvSrcF];
}

- (void)lyricSearch:(id)sender {
    AMDDBG(@"action: lyricSearch");
    [self readUIToConfig];
    NSString *kw = [_lyKeyF.stringValue stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!kw.length) { _lyHintL.stringValue = @"先填搜索名(可从预览页双击填入)"; return; }
    AMDConfig *c = [AMDConfig shared];
    NSMutableArray *srcs = [NSMutableArray array];
    if (c.lyricUseNE) [srcs addObject:@"ne"];
    if (c.lyricUseQQ) [srcs addObject:@"qq"];
    if (!srcs.count) { _lyHintL.stringValue = @"至少勾一个歌词源"; return; }
    _lyHintL.stringValue = @"搜索中…";
    [self appendLog:[NSString stringWithFormat:@"[歌词] 搜 \"%@\"…\n", kw]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *e = nil;
        NSArray *res = [OBLyricSearch search:kw limit:10 sources:srcs
                                        logf:^(NSString *l) { [self appendLog:[l stringByAppendingString:@"\n"]]; }
                                       error:&e];
        NSMutableArray *rows = [NSMutableArray array];
        for (NSDictionary *s in res) {
            NSMutableDictionary *m = [s mutableCopy];
            long ms = [s[@"duration"] longValue];
            m[@"durText"] = ms > 0 ?
                [NSString stringWithFormat:@"%ld:%02ld", ms / 60000, (ms % 60000) / 1000] : @"";
            [rows addObject:m];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->_lyResults removeAllObjects];
            [self->_lyResults addObjectsFromArray:rows];
            [self->_lyTable reloadData];
            self->_lyHintL.stringValue = rows.count ?
                [NSString stringWithFormat:@"共 %lu 条 — 点中一行再按「保存歌词」", (unsigned long)rows.count] :
                (e ?: @"无结果,换个名字试试");
        });
    });
}

// 取词 → 按配置排版 → 内嵌/外置落盘
- (void)lyricSave:(id)sender {
    AMDDBG(@"action: lyricSave");
    [self readUIToConfig];
    NSInteger row = _lyTable.selectedRow;
    if (row < 0 || row >= (NSInteger)_lyResults.count) {
        _lyHintL.stringValue = @"先搜出来并点中一行";
        return;
    }
    NSString *target = [self resolveLyricTarget:_lyFileF.stringValue];
    if (!target) { _lyHintL.stringValue = @"文件名无效(填已存在的 m4a 路径)"; return; }
    NSDictionary *song = _lyResults[row];
    AMDConfig *c = [AMDConfig shared];
    NSString *mode = c.lyricMode, *enc = c.lyricEncoding;
    NSString *layout = c.lyricLayout, *sep = c.lyricMergeSep;
    _lyHintL.stringValue = @"取词保存中…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *e = nil;
        NSDictionary *ly = [OBLyricSearch lyricFor:song
                                              logf:^(NSString *l) { [self appendLog:[l stringByAppendingString:@"\n"]]; }
                                             error:&e];
        NSString *fail = nil, *done = nil;
        if (ly) {
            NSArray *tracks = [self lyricTracks:ly source:song[@"source"] error:&e];
            NSString *body = tracks ? [self renderLyricTracks:tracks layout:layout sep:sep] : nil;
            if (!body) fail = e ?: @"排版失败";
            else if ([mode isEqualToString:@"embed"]) {
                NSMutableData *d = [[NSMutableData alloc] initWithContentsOfFile:target];
                if (!d) fail = @"读 m4a 失败";
                else if (![OBMP4 applyLyrics:d lyrics:body error:&e]) fail = e ?: @"内嵌失败";
                else if (![d writeToFile:target atomically:YES]) fail = @"写回失败";
                else done = [NSString stringWithFormat:@"内嵌 %@ (%lu 字)", target.lastPathComponent, (unsigned long)body.length];
            } else {
                NSString *ext = [mode isEqualToString:@"srt"] ? @"srt" : @"lrc";
                NSString *out = [[target stringByDeletingPathExtension] stringByAppendingPathExtension:ext];
                NSString *text = body;
                if ([ext isEqualToString:@"srt"]) {
                    NSArray *lines = [OBLyric parseLRC:body source:OBLyricSourceGeneric ignoreEmpty:YES];
                    text = [OBLyric srtString:lines durationMs:[song[@"duration"] longValue]];
                }
                if (![OBLyric writeFile:text to:out encoding:enc error:&e]) fail = e ?: @"写文件失败";
                else done = [NSString stringWithFormat:@"外置 %@ (%@)", out.lastPathComponent, enc];
            }
        } else fail = e;
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_lyHintL.stringValue = done ?: (fail ?: @"失败");
            [self appendLog:[NSString stringWithFormat:@"[歌词] %@\n", done ? [@"✅ " stringByAppendingString:done] : [@"❌ " stringByAppendingString:fail ?: @"?"]]];
        });
    });
}

// 取词 dict → 排好序的三轨(原文/译文/音译,有则收);译文对齐到原文(±500ms,缺失补空)
- (nullable NSArray<NSArray *> *)lyricTracks:(NSDictionary *)ly
                                      source:(NSString *)src
                                       error:(NSString **)err {
    OBLyricSource s = [src isEqualToString:@"qq"] ? OBLyricSourceQQ : OBLyricSourceGeneric;
    NSArray *o = [OBLyric parseLRC:ly[@"lyric"] source:s ignoreEmpty:YES];
    if (!o.count) { if (err) *err = @"原文为空"; return nil; }
    NSMutableArray *tracks = [NSMutableArray arrayWithObject:o];
    for (NSString *k in @[@"trans", @"roma"]) {
        NSString *t = ly[k];
        if (![t isKindOfClass:[NSString class]] || !t.length) continue;
        NSArray *parsed = [OBLyric parseLRC:t source:s ignoreEmpty:YES];
        if (parsed.count)
            [tracks addObject:[OBLyric alignTrans:parsed toOrigin:o deviation:500
                                        lostRule:OBLyricLostEmpty]];
    }
    return tracks;
}

- (NSString *)renderLyricTracks:(NSArray *)tracks layout:(NSString *)layout sep:(NSString *)sep {
    if ([layout isEqualToString:@"merge"])
        return [OBLyric lrcString:[OBLyric renderMerge:tracks separator:sep.length ? sep : @" / "]];
    if ([layout isEqualToString:@"isolated"]) {
        NSMutableArray *parts = [NSMutableArray array];
        for (NSArray *t in [OBLyric renderIsolated:tracks]) [parts addObject:[OBLyric lrcString:t]];
        return [parts componentsJoinedByString:@"\n"];
    }
    return [OBLyric lrcString:[OBLyric renderStagger:tracks]];
}

// 互转卡:lrc↔srt / 文本→m4a内嵌 / m4a内嵌→文本
- (void)lyricConvert:(id)sender {
    AMDDBG(@"action: lyricConvert");
    [self readUIToConfig];
    NSString *src = [_lyConvSrcF.stringValue stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!src.length || ![[NSFileManager defaultManager] fileExistsAtPath:src]) {
        _lyHintL.stringValue = @"先填存在的源文件";
        return;
    }
    NSInteger dir = [_lyConvP indexOfSelectedItem];
    AMDConfig *c = [AMDConfig shared];
    NSString *enc = c.lyricEncoding;
    NSString *base = [src stringByDeletingPathExtension];
    _lyHintL.stringValue = @"转换中…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *e = nil, *done = nil;
        if (dir == 0 || dir == 1) {
            // lrc→srt / srt→lrc
            NSDictionary *rd = [OBLyric readFile:src error:&e];
            NSString *out = nil;
            if (rd) {
                if (dir == 0) {
                    NSArray *lines = [OBLyric parseLRC:rd[@"text"] source:OBLyricSourceGeneric ignoreEmpty:NO];
                    NSMutableArray *timed = [NSMutableArray array];
                    for (NSDictionary *l in lines)
                        if ([l[@"ms"] longValue] >= 0) [timed addObject:l];
                    out = [OBLyric srtString:timed durationMs:0];
                    NSString *dst = [base stringByAppendingPathExtension:@"srt"];
                    if ([OBLyric writeFile:out to:dst encoding:enc error:&e]) done = dst.lastPathComponent;
                } else {
                    NSArray *lines = [OBLyric parseSRT:rd[@"text"]];
                    if (!lines.count) e = @"SRT 解析为空";
                    else {
                        out = [OBLyric lrcString:lines];
                        NSString *dst = [base stringByAppendingPathExtension:@"lrc"];
                        if ([OBLyric writeFile:out to:dst encoding:enc error:&e]) done = dst.lastPathComponent;
                    }
                }
            }
            if (!done && !e) e = @"转换失败";
        } else if (dir == 2) {
            // 文本→m4a内嵌(同名 m4a 必须存在;srt 先转 lrc)
            NSString *dst = [base stringByAppendingPathExtension:@"m4a"];
            NSDictionary *rd = [OBLyric readFile:src error:&e];
            NSString *body = nil;
            if (rd) {
                if ([[src.pathExtension lowercaseString] isEqualToString:@"srt"]) {
                    NSArray *lines = [OBLyric parseSRT:rd[@"text"]];
                    if (!lines.count) e = @"SRT 解析为空";
                    else body = [OBLyric lrcString:lines];
                } else body = rd[@"text"];
            }
            NSMutableData *d = (body && !e) ? [[NSMutableData alloc] initWithContentsOfFile:dst] : nil;
            if (!d) e = e ?: @"同名 m4a 不存在";
            else if (![OBMP4 applyLyrics:d lyrics:body error:&e]) e = e ?: @"内嵌失败";
            else if (![d writeToFile:dst atomically:YES]) e = @"写回失败";
            else done = [NSString stringWithFormat:@"%@ ← %@", dst.lastPathComponent, src.lastPathComponent];
        } else {
            // m4a内嵌→lrc / →srt
            NSData *d = [[NSData alloc] initWithContentsOfFile:src];
            NSString *lrc = d ? [OBMP4 readLyrics:d error:&e] : nil;
            if (!lrc) e = e ?: @"无内嵌歌词";
            else {
                NSString *ext = (dir == 4) ? @"srt" : @"lrc";
                NSString *text = lrc;
                if (dir == 4) {
                    NSArray *lines = [OBLyric parseLRC:lrc source:OBLyricSourceGeneric ignoreEmpty:YES];
                    text = [OBLyric srtString:lines durationMs:0];
                }
                NSString *dst = [base stringByAppendingPathExtension:ext];
                if ([OBLyric writeFile:text to:dst encoding:enc error:&e]) done = dst.lastPathComponent;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_lyHintL.stringValue = done ?: (e ?: @"失败");
            [self appendLog:[NSString stringWithFormat:@"[互转] %@\n", done ? [@"✅ " stringByAppendingString:done] : [@"❌ " stringByAppendingString:e ?: @"?"]]];
        });
    });
}

#pragma mark - download

- (void)startDownloadNative:(NSString *)adamIds cache:(BOOL)cacheMode {
    // 原生引擎:多目标逐个跑;取消标志为 ivar(地址稳定,引擎在碎片间轮询)
    NSArray *toks = [adamIds componentsSeparatedByCharactersInSet:
                     [NSCharacterSet characterSetWithCharactersInString:@", \n\t"]];
    NSPredicate *nonEmpty = [NSPredicate predicateWithFormat:@"length > 0"];
    NSMutableArray *adams = [[toks filteredArrayUsingPredicate:nonEmpty] mutableCopy];
    if (!adams.count) {
        [self appendLog:cacheMode ? @"[直解] 先填 adamId\n" : @"[下载] 先填 adamId(搜索页可一键填入)\n"];
        [self applyDownloadBusy:NO];
        return;
    }
    AMDConfig *c = [AMDConfig shared];
    NSString *outDir = c.outDir.length ? c.outDir : [NSTemporaryDirectory() stringByAppendingPathComponent:@"amd-dl"];
    [[NSFileManager defaultManager] createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:NULL];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        self->_dlCancel = NO;
        for (NSUInteger i = 0; i < adams.count; i++) {
            if (self->_dlCancel) break;
            NSString *adam = adams[i];
            NSString *err = nil;
            NSDictionary *meta = cacheMode
                ? [OBDLJob runFromCache:adam outDir:outDir force:NO
                                   logf:^(NSString *l) { [self appendLog:[l stringByAppendingString:@"\n"]]; }
                                 cancel:&self->_dlCancel error:&err]
                : [OBDLJob runAdam:adam outDir:outDir force:NO
                              logf:^(NSString *l) { [self appendLog:[l stringByAppendingString:@"\n"]]; }
                            cancel:&self->_dlCancel error:&err];
            if (!meta && ![err containsString:@"已存在"])
                [self appendLog:[NSString stringWithFormat:@"[!] adam %@ 失败: %@\n", adam, err ?: @"?"]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ [self applyDownloadBusy:NO]; });
    });
}

- (void)startDownload:(id)sender {
    AMDDBG(@"action: startDownload(native)");
    [self readUIToConfig];
    [self applyDownloadBusy:YES];
    [self startDownloadNative:_adamF.stringValue cache:NO];
}

- (void)startDownloadCache:(id)sender {
    AMDDBG(@"action: startDownloadCache(native)");
    [self readUIToConfig];
    [self applyDownloadBusy:YES];
    [self startDownloadNative:_adamF.stringValue cache:YES];
}

// 跟随收割开关:常驻轮询缓存 key,新鲜即直解;再点一次在间隙安全退出
- (void)toggleFollow:(id)sender {
    AMDDBG(@"action: toggleFollow (on=%d)", _followOn);
    if (_followOn) {
        _followCancel = YES;
        [self appendLog:@"[跟随] 停止中(当前间隙退出)…\n"];
        return;
    }
    [self readUIToConfig];
    AMDConfig *c = [AMDConfig shared];
    NSString *outDir = c.outDir.length ? c.outDir : [NSTemporaryDirectory() stringByAppendingPathComponent:@"amd-dl"];
    [[NSFileManager defaultManager] createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:NULL];
    _followOn = YES;
    _followCancel = NO;
    [self applyFollowUI];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [OBDLJob followCache:outDir
                    interval:20
                    autoNext:NO   // 切歌影响手机端播放,v1 不开;需要时再暴露
                        logf:^(NSString *l) { [self appendLog:[l stringByAppendingString:@"\n"]]; }
                     statusf:^(NSString *s) {
                         dispatch_async(dispatch_get_main_queue(), ^{
                             if (self->_dlStatusL) self->_dlStatusL.stringValue =
                                 [NSString stringWithFormat:@"状态: %@", s];
                         });
                     }
                      cancel:&self->_followCancel];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_followOn = NO;
            [self applyFollowUI];
            [self appendLog:@"[跟随] 已退出\n"];
        });
    });
}

- (void)applyFollowUI {
    _cancelBtn.enabled = NO;
    for (NSToolbarItem *it in self.window.toolbar.items) {
        if ([it.itemIdentifier isEqualToString:@"tb.follow"]) {
            it.label = _followOn ? @"停止跟随" : @"跟随收割";
            it.paletteLabel = it.label;
        }
        if ([it.itemIdentifier isEqualToString:@"tb.download"] ||
            [it.itemIdentifier isEqualToString:@"tb.cache"]) it.enabled = !_followOn;
    }
    if (_dlStatusL) _dlStatusL.stringValue = _followOn ? @"状态: 跟随收割中…" : @"状态: 空闲";
}

- (void)cancelDownload:(id)sender {
    AMDDBG(@"action: cancelDownload");
    if (_dlTask && [_dlTask isRunning]) {
        [_dlTask terminate];
        [self appendLog:@"[下载] 已发送取消\n"];
    }
    _dlCancel = YES;           // 原生引擎:碎片间退出
    _cancelBtn.enabled = NO;   // 忙碌态由 onEnd 的 applyDownloadBusy 统一复位
}

@end
