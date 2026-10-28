//
//  TBBar.h
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// What the taskbar needs to know about MenuBarAgent's own bar (MenuBarCore.DisplayItemAppKitWindow,
// level 24). Everything here reads the agent's live views and is only valid inside MenuBarAgent.
// See docs/taskbar-internals.md for where each class and ivar comes from.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// One title of an app's menu bar (File, Edit, ...), as the agent has it laid out.
@interface TBMenuTitle : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, weak, nullable) NSView *view;
@property (nonatomic, weak, nullable) NSWindow *window;
@property (nonatomic) CGFloat x;
@end

/// One status item (a tray icon), as the agent has it laid out: a container view hosting the item's
/// scene, whose picture is a CALayerHost of `contextId`.
@interface TBStatusItem : NSObject
@property (nonatomic, weak, nullable) NSView *view;
@property (nonatomic, weak, nullable) NSWindow *window;
@property (nonatomic) CGFloat x;            // relative to the screen
@property (nonatomic) NSSize size;
@property (nonatomic) uint32_t contextId;   // 0 when the scene has no picture yet
@end

@interface TBBar : NSObject

/// The bar windows that sit along the top of `screen`. The agent keeps one per application whose
/// menus it has loaded, all at the same frame, so there are usually several.
+ (NSArray<NSWindow *> *)windowsOnScreen:(NSScreen *)screen;

/// The left edge, relative to the screen, of the first status item (the system tray): the bar is
/// ours up to here. Returns `fallback` when there are no status items.
+ (CGFloat)statusItemsMinXOnScreen:(NSScreen *)screen fallback:(CGFloat)fallback;

/// The status items on `screen`, left to right.
+ (NSArray<TBStatusItem *> *)statusItemsOnScreen:(NSScreen *)screen;

/// Clicks `item` in the agent's bar the way a pointer would (`right` for the right button), which
/// is how a status item opens its menu or popover.
+ (BOOL)click:(TBStatusItem *)item right:(BOOL)right;

/// The titles of the menus the agent has loaded for the app `pid`, left to right: the app's own
/// menu (named `appName` when its title can't be read), File, Edit, and so on. The Apple menu is
/// left out. Empty until the agent has loaded the app's menus, which is after it comes forward.
+ (NSArray<TBMenuTitle *> *)menuTitlesForPid:(pid_t)pid appName:(NSString *)appName onScreen:(NSScreen *)screen;

/// Opens the dropdown of `title`, by clicking its (hidden) item in the agent's bar the way a
/// pointer would. The dropdown is the app's own and opens where the agent has the item.
+ (BOOL)open:(TBMenuTitle *)title;

/// Forces the bar's windows to draw for the dark appearance, so status item glyphs are light on
/// the taskbar's dark background whatever the wallpaper is.
+ (void)applyDarkAppearanceOnScreen:(NSScreen *)screen;

/// The bar windows, their frames and the pids of their app menu items, for the log.
+ (NSString *)describeWindows;

@end

NS_ASSUME_NONNULL_END
