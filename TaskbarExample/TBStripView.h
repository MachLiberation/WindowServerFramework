//
//  TBStripView.h
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// The running apps, as a row of icons on the taskbar.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class TBStripView;

@protocol TBStripDelegate <NSObject>
/// A left click: bring the app forward.
- (void)strip:(TBStripView *)strip activateApp:(NSRunningApplication *)app;
/// A right click: show the app's menu bar items as a menu opening from `cell` (in the strip's
/// coordinates).
- (void)strip:(TBStripView *)strip showMenusForApp:(NSRunningApplication *)app cell:(NSRect)cell;
@end

@interface TBStripView : NSView <NSViewToolTipOwner>

@property (nonatomic, weak, nullable) id<TBStripDelegate> delegate;

/// The width the icons may use, from the left edge of the view. On a notched display this is the
/// part of the bar left of the notch; icons that don't fit move to an overflow menu.
@property (nonatomic) CGFloat availableWidth;

/// Replaces the apps shown, in order, and the one that is frontmost.
- (void)setApps:(NSArray<NSRunningApplication *> *)apps activePid:(pid_t)activePid;

/// Pops `menu` up under `cell`, which is a cell's rect in the strip's coordinates.
- (void)popUpMenu:(NSMenu *)menu belowCell:(NSRect)cell;

@end

NS_ASSUME_NONNULL_END
