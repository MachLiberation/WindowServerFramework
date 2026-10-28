//
//  TBBar.m
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// MenuBarAgent draws the bar in MenuBarCore.DisplayItemAppKitWindow windows. Their content view
// (MenuBarHitTestingView) holds, as direct subviews:
//   - AppMenuItemContainerView, and one AppMenuItemView per menu of the app the window belongs to
//     (frame in the window, remoteProcessIdentifier ivar at +648 = that app's pid);
//   - one SceneHostDisplayItemContainerView per status item, hosting the item's scene.

#import "TBBar.h"
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>

// NSStringFromClass gives a Swift class its Module.Name form (class_getName the mangled one), and
// [object class] skips the NSKVONotifying_ subclass the agent's own observers put on its views.
static BOOL ClassNamed(id object, const char *name) {
    return strcmp(NSStringFromClass([object class]).UTF8String, name) == 0;
}

static BOOL IsBarWindow(NSWindow *window) { return ClassNamed(window, "MenuBarCore.DisplayItemAppKitWindow"); }

static BOOL IsAppMenuView(NSView *view) {
    return ClassNamed(view, "MenuBarCore.AppMenuItemView") ||
           ClassNamed(view, "MenuBarCore.AppMenuItemContainerView");
}

// Reads a Swift String stored in an ivar (two words). Small strings (up to 15 UTF-8 bytes) are in
// the words themselves; large native ones are a count and a heap object whose bytes start 32 in.
// Anything else (bridged NSStrings, literals) gives nil, and memory is only touched safely.
static NSString *SwiftString(const uint64_t *words) {
    uint64_t low = words[0], high = words[1];
    unsigned form = (unsigned)(high >> 60);
    if (form == 0xE || form == 0xA) {
        unsigned count = (unsigned)((high >> 56) & 0xF);
        char bytes[16];
        memcpy(bytes, &low, 8);
        memcpy(bytes + 8, &high, 8);
        return [[NSString alloc] initWithBytes:bytes length:count encoding:NSUTF8StringEncoding];
    }
    if (form == 0x0) {
        uint64_t count = low & 0xFFFFFFFFFFFFULL;
        uint64_t object = high & 0x00FFFFFFFFFFFFFFULL;
        if (count == 0 || count > 256 || object < 0x1000) return nil;
        char bytes[256];
        mach_vm_size_t read = 0;
        if (mach_vm_read_overwrite(mach_task_self(), (mach_vm_address_t)(object + 32), count,
                                   (mach_vm_address_t)bytes, &read) != KERN_SUCCESS || read != count)
            return nil;
        return [[NSString alloc] initWithBytes:bytes length:count encoding:NSUTF8StringEncoding];
    }
    return nil;
}

@implementation TBMenuTitle
@end

@implementation TBStatusItem
@end

// The context id of the first CALayerHost under a view (the scene's picture).
static uint32_t SceneContextId(CALayer *layer) {
    if ([layer respondsToSelector:@selector(contextId)] && strstr(class_getName([layer class]), "LayerHost"))
        return ((uint32_t (*)(id, SEL))objc_msgSend)(layer, @selector(contextId));
    for (CALayer *sub in layer.sublayers) {
        uint32_t found = SceneContextId(sub);
        if (found) return found;
    }
    return 0;
}

static NSEvent *MouseEvent(NSEventType type, NSPoint point, NSWindow *window, NSInteger number) {
    return [NSEvent mouseEventWithType:type location:point modifierFlags:0
                             timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber
                               context:nil eventNumber:number clickCount:1 pressure:(type == NSEventTypeLeftMouseUp || type == NSEventTypeRightMouseUp) ? 0 : 1];
}

@implementation TBBar

+ (NSArray<NSWindow *> *)windowsOnScreen:(NSScreen *)screen {
    NSRect screenFrame = screen.frame;
    NSRect strip = NSMakeRect(NSMinX(screenFrame), NSMaxY(screenFrame) - 80, NSWidth(screenFrame), 80);
    NSMutableArray *found = [NSMutableArray array];
    for (NSWindow *window in NSApp.windows)
        if (IsBarWindow(window) && NSIntersectsRect(window.frame, strip))
            [found addObject:window];
    return found;
}

+ (CGFloat)statusItemsMinXOnScreen:(NSScreen *)screen fallback:(CGFloat)fallback {
    CGFloat minX = CGFLOAT_MAX;
    for (NSWindow *window in [self windowsOnScreen:screen])
        for (NSView *item in window.contentView.subviews) {
            if (IsAppMenuView(item) || item.hidden || NSWidth(item.frame) <= 0) continue;
            NSRect onScreen = [window convertRectToScreen:[item convertRect:item.bounds toView:nil]];
            minX = MIN(minX, NSMinX(onScreen) - NSMinX(screen.frame));
        }
    return minX == CGFLOAT_MAX ? fallback : minX;
}

+ (NSArray<TBStatusItem *> *)statusItemsOnScreen:(NSScreen *)screen {
    // Every bar window carries the same status items; the live ones are in the front app's window.
    pid_t front = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    NSWindow *chosen = nil;
    for (NSWindow *window in [self windowsOnScreen:screen]) {
        BOOL hasItems = NO, isFront = NO;
        for (NSView *view in window.contentView.subviews) {
            if (ClassNamed(view, "MenuBarCore.SceneHostDisplayItemContainerView")) hasItems = YES;
            if (ClassNamed(view, "MenuBarCore.AppMenuItemView")) {
                Ivar owner = class_getInstanceVariable(object_getClass(view), "remoteProcessIdentifier");
                if (owner && *(int32_t *)((uint8_t *)(__bridge void *)view + ivar_getOffset(owner)) == front) isFront = YES;
            }
        }
        if (hasItems && (!chosen || isFront)) chosen = window;
    }
    NSMutableArray<TBStatusItem *> *items = [NSMutableArray array];
    for (NSView *view in chosen.contentView.subviews) {
        if (!ClassNamed(view, "MenuBarCore.SceneHostDisplayItemContainerView") || view.hidden || NSWidth(view.frame) <= 0) continue;
        TBStatusItem *item = [[TBStatusItem alloc] init];
        item.view = view;
        item.window = chosen;
        item.x = NSMinX([chosen convertRectToScreen:[view convertRect:view.bounds toView:nil]]) - NSMinX(screen.frame);
        item.size = view.frame.size;
        item.contextId = view.layer ? SceneContextId(view.layer) : 0;
        [items addObject:item];
    }
    [items sortUsingComparator:^NSComparisonResult(TBStatusItem *a, TBStatusItem *b) {
        return a.x < b.x ? NSOrderedAscending : (a.x > b.x ? NSOrderedDescending : NSOrderedSame);
    }];
    return items;
}

+ (BOOL)click:(TBStatusItem *)item right:(BOOL)right {
    NSView *view = item.view;
    NSWindow *window = item.window;
    if (!view || !window || view.window != window) return NO;
    NSPoint point = [view convertPoint:NSMakePoint(NSMidX(view.bounds), NSMidY(view.bounds)) toView:nil];
    [window sendEvent:MouseEvent(right ? NSEventTypeRightMouseDown : NSEventTypeLeftMouseDown, point, window, 1)];
    [window sendEvent:MouseEvent(right ? NSEventTypeRightMouseUp : NSEventTypeLeftMouseUp, point, window, 2)];
    return YES;
}

+ (NSArray<TBMenuTitle *> *)menuTitlesForPid:(pid_t)pid appName:(NSString *)appName onScreen:(NSScreen *)screen {
    NSMutableArray<TBMenuTitle *> *titles = [NSMutableArray array];
    for (NSWindow *window in [self windowsOnScreen:screen])
        for (NSView *item in window.contentView.subviews) {
            if (!ClassNamed(item, "MenuBarCore.AppMenuItemView") || item.hidden) continue;
            uint8_t *bytes = (uint8_t *)(__bridge void *)item;
            Ivar owner = class_getInstanceVariable(object_getClass(item), "remoteProcessIdentifier");
            Ivar title = class_getInstanceVariable(object_getClass(item), "_title");
            Ivar bold = class_getInstanceVariable(object_getClass(item), "_prefersBoldFont");
            if (!owner || !title || *(int32_t *)(bytes + ivar_getOffset(owner)) != pid) continue;

            NSString *text = SwiftString((const uint64_t *)(bytes + ivar_getOffset(title)));
            // The app menu is the bold one; the Apple menu is the glyph with no readable text.
            if (!text.length && bold && *(uint8_t *)(bytes + ivar_getOffset(bold))) text = appName;
            if (!text.length) continue;

            TBMenuTitle *entry = [[TBMenuTitle alloc] init];
            entry.title = text;
            entry.view = item;
            entry.window = window;
            entry.x = NSMinX(item.frame);
            [titles addObject:entry];
        }
    [titles sortUsingComparator:^NSComparisonResult(TBMenuTitle *a, TBMenuTitle *b) {
        return a.x < b.x ? NSOrderedAscending : (a.x > b.x ? NSOrderedDescending : NSOrderedSame);
    }];
    return titles;
}

+ (BOOL)open:(TBMenuTitle *)title {
    NSView *view = title.view;
    NSWindow *window = title.window;
    if (!view || !window || view.window != window) return NO;
    NSPoint point = [view convertPoint:NSMakePoint(NSMidX(view.bounds), NSMidY(view.bounds)) toView:nil];
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    NSEvent *down = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:point modifierFlags:0 timestamp:now
                                   windowNumber:window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
    NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:point modifierFlags:0 timestamp:now
                                 windowNumber:window.windowNumber context:nil eventNumber:2 clickCount:1 pressure:0];
    [window sendEvent:down];
    [window sendEvent:up];
    return YES;
}

+ (void)applyDarkAppearanceOnScreen:(NSScreen *)screen {
    NSAppearance *dark = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    for (NSWindow *window in [self windowsOnScreen:screen])
        if (window.appearance != dark) window.appearance = dark;
}

+ (NSString *)describeWindows {
    NSMutableString *text = [NSMutableString stringWithFormat:@"%lu windows ", (unsigned long)NSApp.windows.count];
    for (NSWindow *window in NSApp.windows) {
        if (!IsBarWindow(window)) { [text appendFormat:@"{%@} ", NSStringFromClass([window class])]; continue; }
        NSMutableString *pids = [NSMutableString string];
        for (NSView *item in window.contentView.subviews) {
            if (!ClassNamed(item, "MenuBarCore.AppMenuItemView")) continue;
            Ivar ivar = class_getInstanceVariable(object_getClass(item), "remoteProcessIdentifier");
            if (ivar) [pids appendFormat:@" %d", *(int32_t *)((uint8_t *)(__bridge void *)item + ivar_getOffset(ivar))];
        }
        [text appendFormat:@"[%ld %@ vis=%d items:%@] ", (long)window.windowNumber, NSStringFromRect(window.frame), window.visible, pids];
    }
    return text;
}

@end
