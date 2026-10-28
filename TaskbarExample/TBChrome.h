//
//  TBChrome.h
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// The taskbar's windows and the surface they are painted with.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Window levels around the agent's bar. The base is at the bar's own level, 24, and ordered just
/// below the agent's bar windows (TBAgent): WindowServer's own bar window is at 24 as well and
/// paints the system's translucent backing, so a base at 23 would sit under that.
extern const NSInteger TBLevelBase;
extern const NSInteger TBLevelCover;

/// A borderless panel that never takes focus or activates the agent, on every space.
@interface TBPanel : NSPanel
+ (instancetype)panelWithFrame:(NSRect)frame level:(NSInteger)level;
@end

/// The taskbar's surface: an opaque dark gradient with a hairline along the bottom edge. The
/// base and the cover are painted identically, so where the cover ends the base carries on.
@interface TBBackgroundView : NSView
@end

NS_ASSUME_NONNULL_END
