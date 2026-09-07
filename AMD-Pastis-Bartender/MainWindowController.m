#import "MainWindowController.h"
#import "AMDConfig.h"
#import "TaskRunner.h"
#import "AMDSearch.h"
#import "OBStrings.h"
#import "AMDDebug.h"
#import "OBLink.h"
#import "OBDL.h"
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
    NSTextField *_adbPathF, *_adbHostF, *_adbPortF, *_serialF, *_attachF;
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
    // 日志
    NSTextView *_logV;
}

#pragma mark - init / 系统液态玻璃 chrome(侧栏 + 工具栏)

- (instancetype)init {
    AMDDBG(@"wc: init begin");
    if ((self = [super initWithWindow:nil])) {
        _pages = [NSMutableDictionary dictionary];
        _results = [NSMutableArray array];
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
    // 顺序 = 使用流程:配环境 → 连手机 → 找歌 → 下载 → 看结果
    return @[
        SideItem(@"连接", @"slider.horizontal.3"),
        SideItem(@"设备", @"desktopcomputer"),
        SideItem(@"搜索", @"magnifyingglass"),
        SideItem(@"下载", @"arrow.down.circle"),
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
    return (tv == _sideTable) ? (NSInteger)self.sideItems.count : (NSInteger)_results.count;
}

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    if (tv != _sideTable) return nil;   // 结果表走 cell-based(objectValueForTableColumn)
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
        case 4: return @[@"tb.clear", @"tb.copy"];
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
        // 卡 2:解密通道
        NSStackView *v = [self formStack];
        _attachF = [self field:@"auto" width:160];
        [v addViews:@[
            [self formRow:@"注入引擎" items:@[_attachF]],
            [self hint:@"auto = USB 优先,失败退 127.0.0.1:27042;也可手填 host:port。"],
        ]];
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

/// ⑤ 日志:只读输出。清空/复制在工具栏。
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
    _attachF.stringValue = c.attach ?: @"auto";
    _tcpPortF.stringValue = c.tcpPort ?: @"17001";
    _lanIpF.stringValue = c.lanIp ?: @"";
    _scriptDirF.stringValue = c.scriptDir ?: @"";
    _outDirF.stringValue = c.outDir ?: @"";
    _useTcpC.state = c.useTcp ? NSControlStateValueOn : NSControlStateValueOff;
}

// 只允许主线程调(读的是输入框,后台任务请先在动作入口同步好再 dispatch)
- (void)readUIToConfig {
    AMDConfig *c = [AMDConfig shared];
    c.adbPath = [_adbPathF.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    c.adbHost = [_adbHostF.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    c.adbPort = [_adbPortF.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    c.serial = [_serialF.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    c.attach = [_attachF.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (c.attach.length == 0) c.attach = @"auto";
    c.tcpPort = [_tcpPortF.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (c.tcpPort.length == 0) c.tcpPort = @"17001";
    c.lanIp = [_lanIpF.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    c.scriptDir = [_scriptDirF.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    c.outDir = [_outDirF.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    c.useTcp = (_useTcpC.state == NSControlStateValueOn);
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
        [st appendAttributedString:[[NSAttributedString alloc] initWithString:s]];
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

- (NSArray<NSString *> *)downloadBaseArgs:(NSString *)mode {
    // mode: nil=普通下载, @"check"=自检, @"cache"=--from-cache
    // 调用方保证已在主线程 readUIToConfig 过
    AMDConfig *c = [AMDConfig shared];
    NSMutableArray *a = [NSMutableArray array];
    if (c.useTcp) [a addObject:@"--tcp"]; else [a addObject:@"--no-tcp"];
    if (c.adbHost.length > 0) { [a addObject:@"--adb-host"]; [a addObject:c.adbHost]; }
    if (c.adbPort.length > 0) { [a addObject:@"--adb-port"]; [a addObject:c.adbPort]; }
    if (c.serial.length > 0) { [a addObject:@"-s"]; [a addObject:c.serial]; }
    if (c.attach.length > 0) { [a addObject:OB_AGENT_FLAG]; [a addObject:c.attach]; }
    if (c.tcpPort.length > 0) { [a addObject:@"--tcp-port"]; [a addObject:c.tcpPort]; }
    if (c.lanIp.length > 0) { [a addObject:@"--lan-ip"]; [a addObject:c.lanIp]; }
    if (c.outDir.length > 0) { [a addObject:@"--out"]; [a addObject:c.outDir]; }
    if ([mode isEqualToString:@"check"]) [a addObject:@"--check"];
    if ([mode isEqualToString:@"cache"]) [a addObject:@"--from-cache"];
    return a;
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
    if (row < 0 || row >= (NSInteger)_results.count) return @"";
    NSDictionary *r = _results[row];
    NSString *ident = col.identifier;
    if ([ident isEqualToString:@"ID"]) return [r[@"trackId"] stringValue];
    if ([ident isEqualToString:@"曲名"]) return r[@"track"];
    if ([ident isEqualToString:@"艺人"]) return r[@"artist"];
    if ([ident isEqualToString:@"专辑"]) return r[@"album"];
    if ([ident isEqualToString:@"区"]) return r[@"src"];
    return @"";
}

// 交替行底色(半透明,透出玻璃);macOS 没有自定义交替色属性,走 delegate。仅结果表。
- (void)tableView:(NSTableView *)tableView didAddRowView:(NSTableRowView *)rowView forRow:(NSInteger)row {
    if (tableView != _table) return;
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

#pragma mark - download

- (void)runDownloadScriptWithArgs:(void(^)(NSMutableArray *a))fill {
    AMDDBG(@"action: runDownloadScript");
    [self readUIToConfig];
    AMDConfig *c = [AMDConfig shared];
    NSString *script = [c downloadScriptPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:script]) {
        [self appendLog:[NSString stringWithFormat:@"[下载] 找不到脚本: %@ (检查「连接」页的脚本目录)\n", script]];
        return;
    }
    NSString *py = [self resolvedToolPath:[c pythonPath]];
    NSMutableArray *args = [NSMutableArray arrayWithObject:script];
    if (fill) fill(args);
    [self appendLog:[NSString stringWithFormat:@"[下载] %@ %@\n", py, [args componentsJoinedByString:@" "]]];
    if (_dlTask && [_dlTask isRunning]) {
        [self appendLog:@"[下载] 已有任务在跑,先取消\n"];
        return;
    }
    TaskRunner *t = [[TaskRunner alloc] initWithLaunchPath:py arguments:args cwd:c.scriptDir env:nil];
    _dlTask = t;
    __weak typeof(self) weakSelf = self;
    t.onOutput = ^(NSString *text) { [weakSelf appendLog:text]; };
    t.onEnd = ^(int status) {
        __strong typeof(weakSelf) strong = weakSelf;
        if (!strong) return;
        [strong applyDownloadBusy:NO];
        [strong appendLog:[NSString stringWithFormat:@"[下载] 进程结束 exit=%d\n", status]];
        if (status == 0) NSBeep();
    };
    [t launch];
    [self applyDownloadBusy:YES];
}

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
