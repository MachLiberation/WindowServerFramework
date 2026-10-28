//
//  TBAppMenu.m
//  WindowServerFramework
//
//  Created by bedtime on 10/28/26.
//

#import "TBAppMenu.h"
#import <AppKit/AppKit.h>
#import <WindowServerFramework/WXFBus.h>
#import <os/log.h>

NSString *const TBAppMenuKey = @"WXFTaskbarMenu";
NSString *const TBAppMenuInvokeName = @"com.bedtime.WXFTaskbar.invoke";

static const NSTimeInterval kRefresh = 0.5;     // while the app is in front
static const NSInteger kMaxDepth = 8;

static NSArray *Serialize(NSMenu *menu, NSInteger depth) {
    NSMutableArray *out = [NSMutableArray array];
    if (depth > kMaxDepth) return out;
    // Validates the items (enabled, checked) and lets a delegate fill the menu in lazily (Window,
    // Open Recent), the way opening it would.
    [menu update];
    NSArray<NSMenuItem *> *items = menu.itemArray;
    for (NSUInteger i = 0; i < items.count; i++) {
        NSMenuItem *item = items[i];
        if (item.hidden || item.alternate) continue;
        NSMutableDictionary *entry = [NSMutableDictionary dictionary];
        entry[@"i"] = @(i);
        if (item.separatorItem) {
            entry[@"sep"] = @YES;
        } else {
            NSString *title = item.title.length ? item.title : item.submenu.title;
            entry[@"t"] = title ?: @"";
            entry[@"e"] = @(item.enabled);
            if (item.state != NSControlStateValueOff) entry[@"s"] = @(item.state);
            if (item.keyEquivalent.length) {
                entry[@"k"] = item.keyEquivalent;
                entry[@"m"] = @((NSUInteger)item.keyEquivalentModifierMask);
            }
            if (item.indentationLevel) entry[@"ind"] = @(item.indentationLevel);
            if (item.submenu) entry[@"sub"] = Serialize(item.submenu, depth + 1);
        }
        [out addObject:entry];
    }
    return out;
}

@interface TBAppMenuSharer : NSObject
@end

@implementation TBAppMenuSharer {
    NSTimer *_timer;
    NSData *_last;              // what was shared last, to share only changes
    NSUInteger _sequence;
    BOOL _refreshing;           // -[NSMenu update] posts change notifications of its own
}

- (void)start {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(schedule) name:NSApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:self selector:@selector(schedule) name:NSMenuDidChangeItemNotification object:nil];
    [center addObserver:self selector:@selector(schedule) name:NSMenuDidAddItemNotification object:nil];
    [center addObserver:self selector:@selector(schedule) name:NSMenuDidRemoveItemNotification object:nil];
    [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(invoke:)
                                                          name:TBAppMenuInvokeName object:nil
                                            suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    // Validation (enabled, checked) changes without a notification, so look again while in front.
    _timer = [NSTimer timerWithTimeInterval:kRefresh target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    [self refresh];
    os_log(OS_LOG_DEFAULT, "WXF taskbar app: sharing the menu of %{public}@ (pid %d)",
           NSRunningApplication.currentApplication.localizedName, getpid());
}

- (void)schedule {
    if (_refreshing) return;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(refresh) object:nil];
    [self performSelector:@selector(refresh) withObject:nil afterDelay:0.1];
}

- (void)tick {
    if (NSApp.isActive) [self refresh];
}

- (void)refresh {
    NSMenu *main = NSApp.mainMenu;
    if (!main) return;
    _refreshing = YES;
    NSArray *items = Serialize(main, 0);
    _refreshing = NO;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:items format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (data && [data isEqualToData:_last]) return;
    _last = data;
    NSDictionary *payload = @{
        @"pid": @(getpid()),
        @"seq": @(++_sequence),
        @"name": NSRunningApplication.currentApplication.localizedName ?: @"",
        @"items": items,
    };
    BOOL ok = WXFBusPublish(TBAppMenuKey.UTF8String, (__bridge CFPropertyListRef)payload);
    os_log(OS_LOG_DEFAULT, "WXF taskbar app: published menu #%lu, %lu titles -> %d",
           (unsigned long)_sequence, (unsigned long)items.count, ok);
}

- (void)invoke:(NSNotification *)note {
    NSDictionary *info = note.userInfo;
    if ([info[@"pid"] intValue] != getpid()) return;
    NSArray<NSNumber *> *path = info[@"path"];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMenu *menu = NSApp.mainMenu;
        for (NSUInteger depth = 0; menu && depth < path.count; depth++) {
            NSInteger index = path[depth].integerValue;
            if (index < 0 || index >= menu.numberOfItems) { menu = nil; break; }
            if (depth + 1 == path.count) {
                os_log(OS_LOG_DEFAULT, "WXF taskbar app: performing '%{public}@'", [menu itemAtIndex:index].title);
                [menu performActionForItemAtIndex:index];
                break;
            }
            menu = [menu itemAtIndex:index].submenu;
        }
        self->_last = nil;
        [self refresh];
    });
}

@end

static TBAppMenuSharer *gSharer;

static void StartWhenRunning(int attempt) {
    if (!NSApp || !NSApp.isRunning) {
        if (attempt < 120)
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                StartWhenRunning(attempt + 1);
            });
        return;
    }
    if (NSApp.activationPolicy != NSApplicationActivationPolicyRegular) return;
    gSharer = [[TBAppMenuSharer alloc] init];
    [gSharer start];
}

void TBAppMenuStart(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ StartWhenRunning(0); });
}
