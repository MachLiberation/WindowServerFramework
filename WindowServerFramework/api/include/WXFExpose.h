//
//  WXFExpose.h
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// Custom Exposé: your tweak decides where every window goes while the view is up, the way
// Mission Control does, but with any layout (a grid, a cover flow, a carousel, a stack...). The
// framework supplies the windows, the 3D transform maths, the frame clock and the cleanup. It
// does not talk to the Dock: you start the view yourself (see WXFEvent.h for catching the
// shortcut) and the Dock never hears about it.
//
//     static bool Layout(WXFExposeSessionRef s, const WXFExposeFrame *f, void *info) {
//         for (CFIndex i = 0; i < WXFExposeSessionGetItemCount(s); i++) {
//             WXFExposeItemRef item = WXFExposeSessionGetItemAtIndex(s, i);
//             WXFExposeItemLayout l = WXFExposeItemGetLayout(item);
//             l.center = ...; l.scale = ...;
//             WXFExposeItemSetLayout(item, &l);
//         }
//         return false;           // nothing is moving; call again after the next event
//     }
//
//     WXFExposeCallbacks cb = { .layout = Layout };
//     WXFExposeProviderRef provider = WXFExposeProviderCreate(&cb);
//     WXFExposeBegin(provider, WXFExposeScopeAllWindows);

#ifndef WXFEXPOSE_H
#define WXFEXPOSE_H

#include <stdint.h>
#include <stdbool.h>
#include <CoreGraphics/CoreGraphics.h>
#include <WindowServerFramework/WXFBase.h>
#include <WindowServerFramework/WXFEvent.h>
#include <WindowServerFramework/CGXWindow.h>

#ifdef __cplusplus
extern "C" {
#endif

struct __WXFExposeProvider;
struct __WXFExposeSession;
struct __WXFExposeItem;
/// What your tweak supplies: the callbacks that lay out and drive the view.
typedef struct __WXFExposeProvider *WXFExposeProviderRef;
/// One showing of the view, from Begin until the windows are back. Owned by the framework; valid
/// until the provider's didEnd callback returns. WXFRetain it to keep it longer.
typedef struct __WXFExposeSession *WXFExposeSessionRef;
/// One window in a session. Owned by the session.
typedef struct __WXFExposeItem *WXFExposeItemRef;

typedef enum {
    /// Every ordinary window on the display under the cursor.
    WXFExposeScopeAllWindows,
    /// Only the windows of the application that owns the frontmost one.
    WXFExposeScopeFrontApplication,
} WXFExposeScope;

typedef enum {
    /// The user dismissed the view. Windows return to where they were.
    WXFExposeEndReasonCancelled,
    /// A window was chosen. It is ordered to the front.
    WXFExposeEndReasonSelected,
    /// WXFExposeEnd was called by the tweak with no particular intent.
    WXFExposeEndReasonRequested,
} WXFExposeEndReason;

/// Where one window should appear. A window is first at its natural place (`center` is the middle
/// of its frame, scale 1) and every field is applied relative to that, in this order: scale,
/// rotate (X, then Y, then Z), move to `center` and `translationZ`, project.
typedef struct {
    /// Where the middle of the window appears, in screen coordinates (top-left origin).
    CGPoint center;
    /// 1 is natural size.
    CGSize  scale;
    /// Radians. Y turns the window about its vertical axis, like a cover flow card.
    float   rotationX, rotationY, rotationZ;
    /// Points toward the viewer (positive) or away. Only visible with `perspective`, but it also
    /// sets the stacking while the view is up: windows nearer the viewer are drawn in front (ties
    /// keep their real order).
    float   translationZ;
    /// Eye distance in points. 0 is orthographic: no foreshortening. 1000 to 2000 looks natural.
    float   perspective;
    /// The vanishing point, in screen coordinates. Use the display's centre for a shared camera.
    CGPoint eye;
    /// 0...1, multiplied with the window's own alpha.
    float   alpha;
} WXFExposeItemLayout;

/// Passed to the layout callback.
typedef struct {
    /// The display the view is on, in screen coordinates.
    CGRect bounds;
    /// Seconds since the view began.
    double elapsed;
    /// Seconds since the previous layout call (0 for the first).
    double delta;
    /// True once the view is being dismissed: animate the windows back and return false when
    /// they are at rest (they are put back exactly at the end; a layout still running after
    /// 1.5 seconds is cut off).
    bool   ending;
} WXFExposeFrame;

/// The callbacks of a provider, in the style of CFRunLoopSourceContext. All are optional. They are
/// called on WindowServer's main thread (events on its event thread), so keep them quick.
typedef struct {
    uint32_t version;       // 0
    void    *info;          // passed to every callback
    const void *(*retain)(const void *info);    // called when the provider is created
    void   (*release)(const void *info);        // called when it is destroyed

    /// Whether a window takes part. Windows that are on another display, have no size or are the
    /// cursor are never offered. Default: ordinary windows only (window level 0).
    bool   (*includeWindow)(CGXWindow *window, void *info);

    /// The view has begun. Items hold their natural layout.
    void   (*didBegin)(WXFExposeSessionRef session, void *info);

    /// Called every frame while the view animates, and once after Begin and after anything that
    /// calls WXFExposeSessionSetNeedsLayout. Set the items' layouts. Return true to be called
    /// again next frame, false when everything is at rest.
    bool   (*layout)(WXFExposeSessionRef session, const WXFExposeFrame *frame, void *info);

    /// Input while the view is up. Return true if you used the event. Events you don't use are
    /// handled by default: Escape or a click outside every window cancels, a click on a window
    /// selects it, everything else is swallowed (modifier changes excepted) so applications don't
    /// react to a click on a window that is somewhere else now. The key combination
    /// control+option+command+escape always cancels, whatever you return.
    bool   (*handleEvent)(WXFExposeSessionRef session, WXFEventRef event, void *info);

    /// The view is about to animate out. `selected` is the chosen item, or NULL.
    void   (*willEnd)(WXFExposeSessionRef session, WXFExposeEndReason reason, WXFExposeItemRef selected, void *info);

    /// The windows are back and the session is over.
    void   (*didEnd)(WXFExposeSessionRef session, void *info);
} WXFExposeCallbacks;

/// Creates a provider. The callbacks are copied. +1 retained; release with WXFRelease.
WXFExposeProviderRef WXFExposeProviderCreate(const WXFExposeCallbacks *callbacks);

/// Shows the view. At most one is up at a time (the later call is refused).
/// @return the session, or NULL if one is already up, there is nothing to show, the framework
/// isn't set up, or a WindowServer symbol is missing on this OS build.
WXFExposeSessionRef WXFExposeBegin(WXFExposeProviderRef provider, WXFExposeScope scope);

/// Dismisses the view: willEnd is called, the layout callback runs with `ending` set until it
/// returns false, then the windows are put back, the selected one is ordered to the front (and its
/// application made the front application) and didEnd is called. `selected` matters for WXFExposeEndReasonSelected and may be NULL otherwise.
/// Does nothing for a session that is already ending.
void WXFExposeEnd(WXFExposeSessionRef session, WXFExposeEndReason reason, WXFExposeItemRef selected);

/// The session that is up, or NULL.
WXFExposeSessionRef WXFExposeGetActiveSession(void);

// MARK: Session

WXFExposeProviderRef WXFExposeSessionGetProvider(WXFExposeSessionRef session);
WXFExposeScope WXFExposeSessionGetScope(WXFExposeSessionRef session);
/// The display the view is on, in screen coordinates.
CGRect WXFExposeSessionGetBounds(WXFExposeSessionRef session);
/// The cursor in screen coordinates (top-left origin). Mouse moves are swallowed during the view,
/// so this is how you follow the pointer from the layout callback.
CGPoint WXFExposeSessionGetCursor(WXFExposeSessionRef session);
/// Seconds since the view began.
double WXFExposeSessionGetElapsed(WXFExposeSessionRef session);
bool WXFExposeSessionIsEnding(WXFExposeSessionRef session);
/// Windows in the session, frontmost first (their real stacking order).
long WXFExposeSessionGetItemCount(WXFExposeSessionRef session);
WXFExposeItemRef WXFExposeSessionGetItemAtIndex(WXFExposeSessionRef session, long index);
/// The frontmost item whose window shows at `point` as laid out now, or NULL.
WXFExposeItemRef WXFExposeSessionHitTest(WXFExposeSessionRef session, CGPoint point);
// MARK: The windows that don't take part

/// A window that does not take part in the view: other applications' windows in the
/// front-application scope, anything `includeWindow` refused, the desktop picture and icons, the
/// menu bar, the Dock, notifications. The framework leaves them alone; the alpha is yours, so
/// you decide whether the desktop dims, the other windows vanish, the menu bar stays. Alphas are
/// restored when the view ends.
typedef struct __WXFExposeBackground *WXFExposeBackgroundRef;

typedef enum {
    /// Below level 0: the wallpaper and desktop icons.
    WXFExposeBackgroundKindDesktop,
    /// Level 0: an ordinary window that was left out.
    WXFExposeBackgroundKindWindow,
    /// Above level 0: the menu bar, the Dock, floating panels, notifications.
    WXFExposeBackgroundKindOverlay,
} WXFExposeBackgroundKind;

long WXFExposeSessionGetBackgroundCount(WXFExposeSessionRef session);
WXFExposeBackgroundRef WXFExposeSessionGetBackgroundAtIndex(WXFExposeSessionRef session, long index);
CGXWindow *WXFExposeBackgroundGetWindow(WXFExposeBackgroundRef background);
uint32_t WXFExposeBackgroundGetWindowID(WXFExposeBackgroundRef background);
int32_t WXFExposeBackgroundGetLevel(WXFExposeBackgroundRef background);
WXFExposeBackgroundKind WXFExposeBackgroundGetKind(WXFExposeBackgroundRef background);
/// 0...1, multiplied with the window's own alpha. 1 until you set it.
float WXFExposeBackgroundGetAlpha(WXFExposeBackgroundRef background);
/// Reaches the screen when the callback that called this returns.
void WXFExposeBackgroundSetAlpha(WXFExposeBackgroundRef background, float alpha);

/// Asks for a layout call even if the last one returned false. Call it after changing your own
/// state, typically from handleEvent.
void WXFExposeSessionSetNeedsLayout(WXFExposeSessionRef session);

// MARK: Item

/// The WindowServer window. Valid only while the session is. Read it, don't retain it.
CGXWindow *WXFExposeItemGetWindow(WXFExposeItemRef item);
uint32_t WXFExposeItemGetWindowID(WXFExposeItemRef item);
/// The id of the connection (application) that owns the window.
uint32_t WXFExposeItemGetOwnerID(WXFExposeItemRef item);
/// Position in WXFExposeSessionGetItemAtIndex.
long WXFExposeItemGetIndex(WXFExposeItemRef item);
/// The window's natural frame in screen coordinates (without its shadow).
CGRect WXFExposeItemGetFrame(WXFExposeItemRef item);
/// The layout last set (initially the natural one).
WXFExposeItemLayout WXFExposeItemGetLayout(WXFExposeItemRef item);
/// Sets the layout. It reaches the screen when the callback that called this returns.
void WXFExposeItemSetLayout(WXFExposeItemRef item, const WXFExposeItemLayout *layout);
/// Where the window's corners are on screen with its current layout: top-left, top-right,
/// bottom-right, bottom-left. @return false if the window is turned behind the eye.
bool WXFExposeItemGetQuad(WXFExposeItemRef item, CGPoint corners[4]);

#ifdef __cplusplus
}
#endif

#endif /* WXFEXPOSE_H */
