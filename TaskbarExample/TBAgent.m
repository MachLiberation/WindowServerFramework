//
//  TBAgent.m
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// The taskbar is two panels per display, around MenuBarAgent's own bar window (level 24) rather
// than in place of it, so the bar's status items stay the real ones:
//
//   base   level 24 like the bar, ordered under the agent's bar windows and over WindowServer's
//          own bar backing. The full width: the surface the status items sit on.
//   cover  level 25, from the left edge to the first pinned status item. Hides the app menu
//          strip (the Apple menu, File, Edit, ...), draws the running apps over it and, at its
//          right end, the chevron of the tray's overflow. The status items past the pinned few
//          sit under it, and the chevron's flyout shows copies of them (TBTray.h).
//
// The menu strip's titles are what a right click on an app shows. The app is brought forward
// first, since the agent only has the menus of the app in front; the titles are read from the
// agent's own (hidden) items, and choosing one clicks that item, so the dropdown is the app's.

#import "TBAgent.h"
#import "TBBar.h"
#import "TBChrome.h"
#import "TBStripView.h"
#import "TBTray.h"
#import "TBAppMenu.h"
#import <WindowServerFramework/WXFBus.h>
#import <WindowServerFramework/WXFDropdown.h>
#import <os/log.h>

static const NSTimeInterval kTick = 0.2;
static const NSTimeInterval kMenuWait = 3.0;        // for the agent to load a strip for the app
static const CGFloat kTrayEdge = 10;                // between the pinned icons and the screen's edge
static const NSUInteger kPinned = 1;                // status items that stay on the bar: the clock; the rest are in the tray
static const CGFloat kChevronW = 30;

@interface TBScreenBar : NSObject
@property (nonatomic, strong) NSScreen *screen;
@property (nonatomic, strong) TBPanel *base;
@property (nonatomic, strong) TBPanel *cover;
@property (nonatomic, strong) TBStripView *strip;
@property (nonatomic, strong) TBChevronView *chevron;
@property (nonatomic, strong) TBTrayBarView *trayBar;                // the pinned icons
@property (nonatomic, copy) NSString *pinnedSignature;
@property (nonatomic) CGFloat trayWidth;
@property (nonatomic, strong) TBTrayFlyout *flyout;
@property (nonatomic, copy) NSArray<TBStatusItem *> *overflow;     // status items behind the chevron
@property (nonatomic, copy) NSString *overflowSignature;
@property (nonatomic) NSUInteger itemCount;
@property (nonatomic, strong, nullable) NSRunningApplication *pendingApp;   // right-clicked, menu not shown yet
@property (nonatomic) NSRect pendingCell;
@property (nonatomic) NSTimeInterval pendingSince;
@end
@implementation TBScreenBar
@end

@interface TBAgent : NSObject <TBStripDelegate>
@end

@implementation TBAgent {
    double _height;
    NSMutableArray<TBScreenBar *> *_bars;
    NSTimer *_timer;
    NSRunningApplication *_activating;          // an app asked to come forward, until it has
    NSTimeInterval _activatingSince;
    BOOL _activatingFallback;
    TBScreenBar *_menuBar;                      // where the last app menu was shown, and under which cell
    NSRect _menuCell;
}

- (instancetype)initWithHeight:(double)height {
    if ((self = [super init])) {
        _height = height;
        _bars = [NSMutableArray array];
    }
    return self;
}

- (void)start {
    [self rebuild];
    NSNotificationCenter *center = NSWorkspace.sharedWorkspace.notificationCenter;
    for (NSNotificationName name in @[NSWorkspaceDidLaunchApplicationNotification,
                                      NSWorkspaceDidTerminateApplicationNotification,
                                      NSWorkspaceDidActivateApplicationNotification,
                                      NSWorkspaceDidHideApplicationNotification,
                                      NSWorkspaceDidUnhideApplicationNotification])
        [center addObserver:self selector:@selector(tick) name:name object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(rebuild)
                                               name:NSApplicationDidChangeScreenParametersNotification object:nil];
    _timer = [NSTimer timerWithTimeInterval:kTick target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    os_log(OS_LOG_DEFAULT, "WXF taskbar agent: started, height %.0f, %lu screens", _height, (unsigned long)_bars.count);
}

#pragma mark - Panels

- (NSRect)barFrameOnScreen:(NSScreen *)screen width:(CGFloat)width {
    return NSMakeRect(NSMinX(screen.frame), NSMaxY(screen.frame) - _height, width, _height);
}

- (void)rebuild {
    for (TBScreenBar *bar in _bars) {
        [bar.base orderOut:nil];
        [bar.flyout hide];
        [bar.cover orderOut:nil];
    }
    [_bars removeAllObjects];

    for (NSScreen *screen in NSScreen.screens) {
        TBScreenBar *bar = [[TBScreenBar alloc] init];
        bar.screen = screen;
        CGFloat width = NSWidth(screen.frame);

        bar.base = [TBPanel panelWithFrame:[self barFrameOnScreen:screen width:width] level:TBLevelBase];
        bar.base.contentView = [[TBBackgroundView alloc] initWithFrame:NSMakeRect(0, 0, width, _height)];

        bar.cover = [TBPanel panelWithFrame:[self barFrameOnScreen:screen width:width] level:TBLevelCover];
        TBBackgroundView *surface = [[TBBackgroundView alloc] initWithFrame:NSMakeRect(0, 0, width, _height)];
        bar.strip = [[TBStripView alloc] initWithFrame:surface.bounds];
        bar.strip.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        bar.strip.delegate = self;
        [surface addSubview:bar.strip];
        bar.cover.contentView = surface;

        bar.chevron = [[TBChevronView alloc] initWithFrame:NSMakeRect(0, 0, kChevronW, kChevronW)];
        bar.chevron.hidden = YES;
        [surface addSubview:bar.chevron];
        bar.trayBar = [[TBTrayBarView alloc] initWithFrame:NSMakeRect(0, 0, 10, _height)];
        [surface addSubview:bar.trayBar];
        bar.pinnedSignature = @"";
        bar.flyout = [[TBTrayFlyout alloc] init];
        bar.overflow = @[];
        bar.overflowSignature = @"";
        __weak TBAgent *weakSelf = self;
        __weak TBScreenBar *weakBar = bar;
        bar.chevron.action = ^{ [weakSelf toggleFlyoutOnBar:weakBar]; };
        bar.flyout.didHide = ^{ weakBar.chevron.open = NO; };
        void (^pick)(TBStatusItem *, BOOL, CGFloat) = ^(TBStatusItem *item, BOOL right, CGFloat screenX) {
            // A flyout is closing; click once it has gone, with the menu asked to open under the icon.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf anchorDropdownOnBar:weakBar atX:screenX];
                BOOL clicked = [TBBar click:item right:right];
                os_log(OS_LOG_DEFAULT, "WXF taskbar agent: tray click (%d) -> %d", right, clicked);
            });
        };
        bar.flyout.pick = pick;
        bar.trayBar.pick = pick;

        [bar.base orderFrontRegardless];
        [bar.cover orderFrontRegardless];
        [_bars addObject:bar];
        os_log(OS_LOG_DEFAULT, "WXF taskbar agent: screen %{public}@ -> bar %{public}@",
               NSStringFromRect(screen.frame), NSStringFromRect(bar.cover.frame));
    }
    [self tick];
}

#pragma mark - Apps

- (NSArray<NSRunningApplication *> *)runningApps {
    NSMutableArray *apps = [NSMutableArray array];
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications)
        if (app.activationPolicy == NSApplicationActivationPolicyRegular && !app.terminated &&
            app.processIdentifier != getpid())
            [apps addObject:app];
    // Finder first, then in the order the apps were launched.
    [apps sortUsingComparator:^NSComparisonResult(NSRunningApplication *a, NSRunningApplication *b) {
        BOOL fa = [a.bundleIdentifier isEqualToString:@"com.apple.finder"];
        BOOL fb = [b.bundleIdentifier isEqualToString:@"com.apple.finder"];
        if (fa != fb) return fa ? NSOrderedAscending : NSOrderedDescending;
        if (a.launchDate && b.launchDate) {
            NSComparisonResult r = [a.launchDate compare:b.launchDate];
            if (r != NSOrderedSame) return r;
        } else if (a.launchDate || b.launchDate) {
            return a.launchDate ? NSOrderedAscending : NSOrderedDescending;
        }
        return a.processIdentifier < b.processIdentifier ? NSOrderedAscending : NSOrderedDescending;
    }];
    return apps;
}

- (void)activate:(NSRunningApplication *)app {
    if (app.hidden) [app unhide];
    BOOL asked = [app activateWithOptions:NSApplicationActivateAllWindows];
    os_log(OS_LOG_DEFAULT, "WXF taskbar agent: activate %{public}@ -> %d", app.localizedName, asked);
    _activating = app;
    _activatingSince = NSProcessInfo.processInfo.systemUptime;
    _activatingFallback = NO;
}

// An agent has no right to take the front from the app that has it, so if the plain activation was
// not honoured, ask LaunchServices to open the app, which it does by bringing it forward.
- (void)checkActivation:(pid_t)front {
    if (!_activating) return;
    if (_activating.terminated || _activating.processIdentifier == front) { _activating = nil; return; }
    NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime - _activatingSince;
    if (elapsed > 0.3 && !_activatingFallback && _activating.bundleURL) {
        _activatingFallback = YES;
        NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
        config.activates = YES;
        config.addsToRecentItems = NO;
        os_log(OS_LOG_DEFAULT, "WXF taskbar agent: activate %{public}@ not honoured, opening it", _activating.localizedName);
        [NSWorkspace.sharedWorkspace openApplicationAtURL:_activating.bundleURL configuration:config completionHandler:nil];
    } else if (elapsed > 3) {
        _activating = nil;
    }
}

#pragma mark - Strip delegate

- (void)strip:(TBStripView *)strip activateApp:(NSRunningApplication *)app {
    [self activate:app];
}

- (void)strip:(TBStripView *)strip showMenusForApp:(NSRunningApplication *)app cell:(NSRect)cell {
    TBScreenBar *bar = nil;
    for (TBScreenBar *candidate in _bars) if (candidate.strip == strip) bar = candidate;
    if (!bar) return;
    // An app that shares its menu needs no bringing forward: the whole menu is here to show.
    NSArray *shared = [self sharedMenuForPid:app.processIdentifier];
    if (shared.count) {
        bar.pendingCell = cell;
        [self showSharedMenu:shared forApp:app onBar:bar];
        return;
    }
    bar.pendingApp = app;
    bar.pendingCell = cell;
    bar.pendingSince = NSProcessInfo.processInfo.systemUptime;
    if (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != app.processIdentifier)
        [self activate:app];
    [self tick];
}

#pragma mark - Dropdown placement

// Asks WindowServer to put the next dropdown with its left edge at `x` (screen coordinates), just
// below the bar. The agent can't move the app's window itself; WXFDropdown.h says how this works.
- (void)anchorDropdownOnBar:(TBScreenBar *)bar atX:(CGFloat)x {
    if (!bar) return;
    NSScreen *screen = bar.screen;
    CGFloat primaryHeight = NSScreen.screens.firstObject.frame.size.height;
    CGFloat barBottom = primaryHeight - NSMaxY(screen.frame) + _height;
    BOOL sent = WXFDropdownAnchor(x, barBottom);
    os_log(OS_LOG_DEFAULT, "WXF taskbar agent: dropdown anchor x %.0f y %.0f -> %d", x, barBottom, sent);
}

#pragma mark - The tray

- (void)toggleFlyoutOnBar:(TBScreenBar *)bar {
    if (!bar) return;
    if (bar.flyout.shown) { [bar.flyout hide]; return; }
    if (!bar.overflow.count) return;
    // Hangs from the bar's lower edge, right-aligned with the chevron.
    NSRect cover = bar.cover.frame;
    NSPoint corner = NSMakePoint(NSMinX(cover) + NSMaxX(bar.chevron.frame) + 4, NSMinY(cover) - 6);
    [bar.flyout showWithItems:bar.overflow topRight:corner];
    bar.chevron.open = YES;
}

#pragma mark - The app's menu

- (void)showMenuForApp:(NSRunningApplication *)app onBar:(TBScreenBar *)bar titles:(NSArray<TBMenuTitle *> *)titles {
    NSString *name = app.localizedName ?: @"";
    NSMenu *menu = [[NSMenu alloc] initWithTitle:name];
    menu.autoenablesItems = NO;

    NSMenuItem *header = [menu addItemWithTitle:name action:nil keyEquivalent:@""];
    header.enabled = NO;
    NSImage *icon = [app.icon copy];
    icon.size = NSMakeSize(16, 16);
    header.image = icon;
    [menu addItem:NSMenuItem.separatorItem];

    for (TBMenuTitle *title in titles) {
        NSMenuItem *item = [menu addItemWithTitle:title.title action:@selector(openTitle:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = title;
    }
    if (titles.count) [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *hide = [menu addItemWithTitle:[@"Hide " stringByAppendingString:name] action:@selector(hideApp:) keyEquivalent:@""];
    hide.target = self;
    hide.representedObject = app;
    NSMenuItem *quit = [menu addItemWithTitle:[@"Quit " stringByAppendingString:name] action:@selector(quitApp:) keyEquivalent:@""];
    quit.target = self;
    quit.representedObject = app;

    _menuBar = bar;
    _menuCell = bar.pendingCell;
    [bar.strip popUpMenu:menu belowCell:bar.pendingCell];
}

#pragma mark - The app's whole menu

// The menu an app shared with the agent (TBAppMenu.h), as the property list it published: nil for
// an app that has not loaded the tweak.
- (NSArray *)sharedMenuForPid:(pid_t)pid {
    uint32_t connection = WXFBusConnectionForPID(pid);
    if (!connection) return nil;
    CFPropertyListRef value = WXFBusCopy(connection, TBAppMenuKey.UTF8String);
    NSDictionary *payload = CFBridgingRelease(value);
    if (![payload isKindOfClass:NSDictionary.class] || [payload[@"pid"] intValue] != pid) return nil;
    return payload[@"items"];
}

- (NSMenu *)menuFromItems:(NSArray<NSDictionary *> *)items pid:(pid_t)pid path:(NSArray<NSNumber *> *)path title:(NSString *)title {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:title];
    menu.autoenablesItems = NO;
    for (NSDictionary *entry in items) {
        if ([entry[@"sep"] boolValue]) { [menu addItem:NSMenuItem.separatorItem]; continue; }
        NSArray *itemPath = [path arrayByAddingObject:entry[@"i"]];
        NSArray *sub = entry[@"sub"];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:entry[@"t"] ?: @"" action:sub ? nil : @selector(performSharedItem:) keyEquivalent:@""];
        item.target = self;
        item.enabled = entry[@"e"] ? [entry[@"e"] boolValue] : YES;
        item.state = (NSControlStateValue)[entry[@"s"] integerValue];
        item.indentationLevel = [entry[@"ind"] integerValue];
        item.representedObject = @{@"pid": @(pid), @"path": itemPath};
        if (sub) {
            item.submenu = [self menuFromItems:sub pid:pid path:itemPath title:entry[@"t"] ?: @""];
        } else if ([entry[@"k"] length]) {
            // Shown as the shortcut; the app's own handling of it is what runs when it is pressed.
            item.keyEquivalent = entry[@"k"];
            item.keyEquivalentModifierMask = (NSEventModifierFlags)[entry[@"m"] unsignedIntegerValue];
        }
        [menu addItem:item];
    }
    return menu;
}

// The app's menu bar as one menu: its titles (the app's own, File, Edit, ...) are submenus.
- (void)showSharedMenu:(NSArray<NSDictionary *> *)items forApp:(NSRunningApplication *)app onBar:(TBScreenBar *)bar {
    NSString *name = app.localizedName ?: @"";
    NSMenu *menu = [self menuFromItems:items pid:app.processIdentifier path:@[] title:name];
    NSMenuItem *header = [[NSMenuItem alloc] initWithTitle:name action:nil keyEquivalent:@""];
    header.enabled = NO;
    NSImage *icon = [app.icon copy];
    icon.size = NSMakeSize(16, 16);
    header.image = icon;
    [menu insertItem:header atIndex:0];
    [menu insertItem:NSMenuItem.separatorItem atIndex:1];
    os_log(OS_LOG_DEFAULT, "WXF taskbar agent: shared menu of %{public}@: %lu titles", name, (unsigned long)items.count);
    _menuBar = bar;
    _menuCell = bar.pendingCell;
    [bar.strip popUpMenu:menu belowCell:bar.pendingCell];
}

- (void)performSharedItem:(NSMenuItem *)item {
    NSDictionary *target = item.representedObject;
    os_log(OS_LOG_DEFAULT, "WXF taskbar agent: perform '%{public}@' in pid %@", item.title, target[@"pid"]);
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:TBAppMenuInvokeName object:nil
                                                              userInfo:target deliverImmediately:YES];
}

- (void)openTitle:(NSMenuItem *)item {
    TBMenuTitle *title = item.representedObject;
    TBScreenBar *bar = _menuBar;
    CGFloat x = NSMinX(bar.screen.frame) + _menuCell.origin.x;
    // The menu has to be gone before the click, or the click ends it.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self anchorDropdownOnBar:bar atX:x];
        BOOL opened = [TBBar open:title];
        os_log(OS_LOG_DEFAULT, "WXF taskbar agent: open menu '%{public}@' -> %d", title.title, opened);
    });
}

- (void)hideApp:(NSMenuItem *)item { [(NSRunningApplication *)item.representedObject hide]; }
- (void)quitApp:(NSMenuItem *)item { [(NSRunningApplication *)item.representedObject terminate]; }

#if DEBUG
// A way to drive the taskbar without a pointer: the agent's container has a file, wxf-taskbar-cmd,
// holding "menus <pid>", "perform <pid> <i,j,...>", "activate <pid>", "tray" or "trayclick <index>". It is read and removed on the next tick.
- (void)runDebugCommand {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wxf-taskbar-cmd"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text) return;
    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    NSArray *words = [[text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                      componentsSeparatedByString:@" "];
    NSRunningApplication *app = words.count > 1 ?
        [NSRunningApplication runningApplicationWithProcessIdentifier:(pid_t)[words[1] intValue]] : nil;
    os_log(OS_LOG_DEFAULT, "WXF taskbar agent: debug command '%{public}@'", text);
    TBScreenBar *bar = _bars.firstObject;
    if ([words[0] isEqualToString:@"menus"] && app && bar) [self strip:bar.strip showMenusForApp:app cell:NSMakeRect(10, 6, 44, 38)];
    else if ([words[0] isEqualToString:@"activate"] && app) [self activate:app];
    else if ([words[0] isEqualToString:@"perform"] && words.count > 2) {
        NSMutableArray *path = [NSMutableArray array];
        for (NSString *index in [words[2] componentsSeparatedByString:@","]) [path addObject:@(index.integerValue)];
        [NSDistributedNotificationCenter.defaultCenter postNotificationName:TBAppMenuInvokeName object:nil
                                                                  userInfo:@{@"pid": @(app.processIdentifier), @"path": path} deliverImmediately:YES];
    }
    else if ([words[0] isEqualToString:@"tray"]) [self toggleFlyoutOnBar:bar];
    else if ([words[0] isEqualToString:@"trayclick"] && bar.overflow.count) [TBBar click:bar.overflow[words.count > 1 ? MIN((NSUInteger)[words[1] intValue], bar.overflow.count - 1) : 0] right:NO];
}
#endif

#pragma mark - Ordering

// Keeps the base directly under the agent's bar windows. They are reordered when the front app
// changes, and the base has to stay below every one of them to show under the status items.
- (void)orderBaseOnBar:(TBScreenBar *)bar {
    NSArray<NSWindow *> *barWindows = [TBBar windowsOnScreen:bar.screen];
    NSArray<NSWindow *> *ordered = NSApp.orderedWindows;       // front to back
    NSInteger lowest = -1, own = (NSInteger)[ordered indexOfObject:bar.base];
    for (NSUInteger i = 0; i < ordered.count; i++)
        if ([barWindows containsObject:ordered[i]]) lowest = (NSInteger)i;
    if (lowest < 0) return;
    if (own != (NSInteger)NSNotFound && own > lowest) return;      // already under all of them
    [bar.base orderWindow:NSWindowBelow relativeTo:ordered[lowest].windowNumber];
}

#pragma mark - Updating

- (void)tick {
#if DEBUG
    [self runDebugCommand];
#endif
    NSArray *apps = [self runningApps];
    pid_t front = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    [self checkActivation:front];
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;

    for (TBScreenBar *bar in _bars) {
        NSScreen *screen = bar.screen;
        CGFloat width = NSWidth(screen.frame);
        [TBBar applyDarkAppearanceOnScreen:screen];
        [self orderBaseOnBar:bar];

        // The cover is the whole bar: the real status items are painted by WindowServer along with
        // its blue backing, so it hides them all and the pinned few are shown again as copies.
        NSArray<TBStatusItem *> *items = [TBBar statusItemsOnScreen:screen];
        if (items.count != bar.itemCount) {
            os_log(OS_LOG_DEFAULT, "WXF taskbar agent: %lu status items (was %lu)", (unsigned long)items.count, (unsigned long)bar.itemCount);
            bar.itemCount = items.count;
        }
        NSUInteger hidden = items.count > kPinned ? items.count - kPinned : 0;
        bar.overflow = [items subarrayWithRange:NSMakeRange(0, hidden)];
        NSArray<TBStatusItem *> *pinned = [items subarrayWithRange:NSMakeRange(hidden, items.count - hidden)];
        CGFloat coverW = width;
        NSRect coverFrame = [self barFrameOnScreen:screen width:coverW];
        if (!NSEqualRects(coverFrame, bar.cover.frame)) [bar.cover setFrame:coverFrame display:YES];

        NSMutableString *pinnedSignature = [NSMutableString string];
        for (TBStatusItem *item in pinned) [pinnedSignature appendFormat:@"%u:%.0f,", item.contextId, item.size.width];
        if (![pinnedSignature isEqualToString:bar.pinnedSignature]) {
            bar.pinnedSignature = pinnedSignature;
            bar.trayWidth = [bar.trayBar setItems:pinned];
            os_log(OS_LOG_DEFAULT, "WXF taskbar agent: pinned %{public}@ width %.0f", pinnedSignature, bar.trayWidth);
        }
        CGFloat trayX = coverW - bar.trayWidth - kTrayEdge;
        bar.trayBar.frame = NSMakeRect(trayX, 0, bar.trayWidth, _height);

        // The chevron sits left of the pinned icons, when there is an overflow to open.
        BOOL hasOverflow = hidden > 0;
        bar.chevron.hidden = !hasOverflow;
        if (hasOverflow)
            bar.chevron.frame = NSMakeRect(trayX - kChevronW - 6, floor((_height - kChevronW) / 2), kChevronW, kChevronW);
        else if (bar.flyout.shown)
            [bar.flyout hide];
        NSMutableString *signature = [NSMutableString string];
        for (TBStatusItem *item in bar.overflow) [signature appendFormat:@"%u:%.0f,", item.contextId, item.size.width];
        if (![signature isEqualToString:bar.overflowSignature]) {
            bar.overflowSignature = signature;
            [bar.flyout updateItems:bar.overflow];
        }

        // Icons stay left of the notch and of the chevron.
        CGFloat usable = (hasOverflow ? NSMinX(bar.chevron.frame) : trayX) - 6;
        NSRect left = screen.auxiliaryTopLeftArea;
        if (!NSIsEmptyRect(left)) usable = MIN(usable, NSWidth(left) - 4);
        bar.strip.availableWidth = usable;
        [bar.strip setApps:apps activePid:front];

        // A right-clicked app's menu is shown once it is in front and the agent has its menus; if
        // that doesn't happen the menu still comes up, with just Hide and Quit.
        NSRunningApplication *pending = bar.pendingApp;
        if (!pending) continue;
        NSArray<TBMenuTitle *> *titles = front == pending.processIdentifier ?
            [TBBar menuTitlesForPid:pending.processIdentifier appName:pending.localizedName ?: @"" onScreen:screen] : @[];
        BOOL timedOut = now - bar.pendingSince > kMenuWait;
        if (titles.count || timedOut) {
            bar.pendingApp = nil;
            if (timedOut && !titles.count)
                os_log(OS_LOG_DEFAULT, "WXF taskbar agent: no menus for pid %d after %.0fs (front %d): %{public}@",
                       pending.processIdentifier, kMenuWait, front, [TBBar describeWindows]);
            dispatch_async(dispatch_get_main_queue(), ^{ [self showMenuForApp:pending onBar:bar titles:titles]; });
        }
    }
}

@end

static TBAgent *gAgent;

static void StartWhenRunning(double height, int attempt) {
    if (!NSApp || !NSApp.isRunning) {
        if (attempt > 200) {
            os_log(OS_LOG_DEFAULT, "WXF taskbar agent: application never started running");
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            StartWhenRunning(height, attempt + 1);
        });
        return;
    }
    gAgent = [[TBAgent alloc] initWithHeight:height];
    [gAgent start];
}

void TBAgentStart(double height) {
    dispatch_async(dispatch_get_main_queue(), ^{ StartWhenRunning(height, 0); });
}
