//
//  TBTray.h
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// The overflow of the system tray: a chevron at the end of the taskbar and the flyout it opens.
//
// The tray's icons are the system's own status items, hosted as scenes in MenuBarAgent's bar, and
// they cannot be moved: a scene view taken out of the bar renders blank. What can be shown twice
// is the scene's picture, a CALayerHost of the item's context id, so the flyout shows copies of
// the overflow icons while the originals stay where the agent has them, under the taskbar's cover.
// Clicking a copy clicks the original.

#import <AppKit/AppKit.h>
#import "TBBar.h"

NS_ASSUME_NONNULL_BEGIN

/// The "^" button.
@interface TBChevronView : NSView
@property (nonatomic) BOOL open;
@property (nonatomic, copy, nullable) void (^action)(void);
@end

/// The icons that stay on the bar: live copies of the status items' pictures, drawn on the
/// taskbar's own surface. WindowServer paints the real ones itself, together with the system's
/// bar backing, in a window the taskbar cannot get between, so the taskbar covers them and shows
/// copies on its dark surface instead. Clicking a copy clicks the original.
@interface TBTrayBarView : NSView
/// Called with the item that was clicked, which button and the left edge of its cell in screen
/// coordinates.
@property (nonatomic, copy, nullable) void (^pick)(TBStatusItem *item, BOOL right, CGFloat screenX);
/// Replaces the icons (left to right) and returns the width the row needs.
- (CGFloat)setItems:(NSArray<TBStatusItem *> *)items;
@end

/// The popup of overflow icons. It is an ordinary panel at level 27, and goes away on the next
/// click anywhere else.
@interface TBTrayFlyout : NSObject
@property (nonatomic, readonly) BOOL shown;
/// Called with the item that was clicked, which button and the left edge of its cell in screen
/// coordinates; the flyout closes itself.
@property (nonatomic, copy, nullable) void (^pick)(TBStatusItem *item, BOOL right, CGFloat screenX);
/// Called when the flyout closes, however it did.
@property (nonatomic, copy, nullable) void (^didHide)(void);

/// Opens the flyout with its top right corner at `corner`, in screen coordinates.
- (void)showWithItems:(NSArray<TBStatusItem *> *)items topRight:(NSPoint)corner;
/// Keeps an open flyout's icons current; does nothing when it is closed.
- (void)updateItems:(NSArray<TBStatusItem *> *)items;
- (void)hide;
@end

NS_ASSUME_NONNULL_END
