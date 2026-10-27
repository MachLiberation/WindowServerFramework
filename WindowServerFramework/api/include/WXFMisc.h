//
//  WXFMisc.h
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// The mid-level building blocks the features are made of, for tweaks that want to do something
// the features don't: look a window up, read its frame, fade it, put a 3D transform on it,
// reorder it, activate its application, read the cursor, run something on WindowServer's main
// thread. Each call is a thin wrapper over one WindowServer function (found by name at runtime,
// so see docs/expose-internals.md and docs/drag-internals.md for what they map to), safe to call when the function is missing
// on this OS build: it does nothing and returns 0 / NULL / false. WXFMiscIsAvailable says up
// front whether the functions a group of calls needs were found.
//
// Everything here is meant for WindowServer's main thread, which is where hooks and callbacks run.
//
// Features that use these (WXFExpose, WXFDrag) set windows through the same calls, so a tweak
// that changes the same window at the same time as one of them will fight with it. A window has
// one transform slot and one alpha: whoever wrote last wins.

#ifndef WXFMISC_H
#define WXFMISC_H

#include <stdint.h>
#include <stdbool.h>
#include <CoreGraphics/CoreGraphics.h>
#include <WindowServerFramework/WXFBase.h>
#include <WindowServerFramework/CGXWindow.h>

#ifdef __cplusplus
extern "C" {
#endif

// --- Availability ---------------------------------------------------------------------------

/// Groups of WindowServer functions. A call documents which group it needs.
typedef enum {
    /// Window lookup and frame, alpha, ordering, the clock and scheduling.
    WXFMiscFeatureCore       = 1 << 0,
    /// WXFGetCursorLocation.
    WXFMiscFeatureCursor     = 1 << 1,
    /// Displays: WXFWindowGetDisplay and the WXFDisplay calls.
    WXFMiscFeatureDisplays   = 1 << 2,
    /// WXFWindowSetTransform and friends.
    WXFMiscFeatureTransform  = 1 << 3,
    /// WXFCopyWindowList.
    WXFMiscFeatureWindowList = 1 << 4,
    /// Making an application the front one: WXFForegroundConnection, WXFActivateWindowOwner.
    WXFMiscFeatureActivation = 1 << 5,
    /// WXFWindowMoveBy.
    WXFMiscFeatureMove       = 1 << 6,
    /// WXFWindowGetClippedFrame and WXFWindowGetScreenRect.
    WXFMiscFeatureShape      = 1 << 7,
    /// WXFRebuildVisibleOrder. Missing pieces make it do less, not fail.
    WXFMiscFeatureReorder    = 1 << 8,
    WXFMiscFeatureAll        = (1 << 9) - 1,
} WXFMiscFeature;

/// Whether every function the given groups (OR them together) need was found. The first time a
/// group comes up short, the missing names are logged. Needs SetupFramework to have run.
bool WXFMiscIsAvailable(uint32_t features);

// --- Matrices -------------------------------------------------------------------------------
// 4x4, row-vector convention like CATransform3D: p' = p * M, so WXFMat4Multiply(a, b) applies a
// first. Rotations have the signs of CATransform3DMakeRotation about each axis.

typedef struct { double m[16]; } WXFMat4;

WXFMat4 WXFMat4Identity(void);
/// `a` first, then `b`.
WXFMat4 WXFMat4Multiply(WXFMat4 a, WXFMat4 b);
WXFMat4 WXFMat4MakeTranslation(double x, double y, double z);
WXFMat4 WXFMat4MakeScale(double x, double y, double z);
WXFMat4 WXFMat4MakeRotationX(double radians);
WXFMat4 WXFMat4MakeRotationY(double radians);
WXFMat4 WXFMat4MakeRotationZ(double radians);
/// Returns false, leaving *out alone, if `m` is singular.
bool    WXFMat4Invert(WXFMat4 m, WXFMat4 *out);
/// Where the point (x, y) on the z = 0 plane ends up. False if it ends up behind the eye.
bool    WXFMat4ProjectPoint(const WXFMat4 *m, double x, double y, CGPoint *out);
/// Drops the z row and column, leaving the map of the z = 0 plane. This is what a window
/// transform has to be made of (see WXFWindowApplyTransform).
WXFMat4 WXFMat4FlattenToPlane(WXFMat4 m);

/// Whether `p` is inside the convex quadrilateral `q`, either winding. Edges count as inside.
bool WXFQuadContainsPoint(const CGPoint q[4], CGPoint p);

// --- Clock and scheduling -------------------------------------------------------------------
// Needs WXFMiscFeatureCore.

/// WindowServer's clock, in seconds (SLSCurrentRealTime). 0 if unavailable.
double WXFCurrentTime(void);

/// Calls `callback(info, now)` on WindowServer's main thread of the current session at `when`
/// (a WXFCurrentTime value; now or earlier runs it as soon as possible). It runs once: call this
/// again from the callback to keep going.
void WXFScheduleCallback(void (*callback)(void *info, double now), void *info, double when);

// --- Cursor and displays --------------------------------------------------------------------

/// A display. Opaque; only valid for the calls below.
typedef const void *WXFDisplayRef;

/// The cursor in screen coordinates (top-left origin). False if it can't be read.
/// Needs WXFMiscFeatureCursor.
bool WXFGetCursorLocation(CGPoint *location);

// Need WXFMiscFeatureDisplays.
WXFDisplayRef WXFDisplayForPoint(CGPoint point);        ///< The display best matching the point.
WXFDisplayRef WXFDisplayGetMain(void);
CGRect        WXFDisplayGetBounds(WXFDisplayRef display);   ///< Screen coordinates.
/// The display the window is mostly on.
WXFDisplayRef WXFWindowGetDisplay(CGXWindow *window);

// --- Windows --------------------------------------------------------------------------------

/// The window with this id, or NULL.
CGXWindow *WXFWindowFromID(uint32_t windowID);

/// Where the window is, ignoring any transform on it. Screen coordinates.
CGRect WXFWindowGetFrame(CGXWindow *window);
/// The window with its shadow. Needs WXFMiscFeatureShape.
CGRect WXFWindowGetClippedFrame(CGXWindow *window);
/// The window's own pixels, no shadow. Needs WXFMiscFeatureShape.
CGRect WXFWindowGetScreenRect(CGXWindow *window);

/// The id of the connection (application) that owns the window, 0 if it can't be read. Not the
/// same as `window->connection_id`, which reads 0.
uint32_t WXFWindowGetOwnerConnectionID(const CGXWindow *window);

/// A copy of the windows WindowServer keeps for the current session, front first, which the caller
/// frees. The cursor window is left in the list and also returned through `cursorWindow`
/// (NULL if there is none) so it can be told apart. NULL if the list is empty or unavailable.
/// Needs WXFMiscFeatureWindowList.
typedef enum {
    /// The list the renderer draws from.
    WXFWindowListVisible,
    /// The list ordering edits (WXFOrderWindow changes this one; WXFRebuildVisibleOrder makes the
    /// visible list follow).
    WXFWindowListStacking,
} WXFWindowListKind;
CGXWindow **WXFCopyWindowList(WXFWindowListKind kind, long *count, CGXWindow **cursorWindow);

// --- Alpha ----------------------------------------------------------------------------------
// A window's visibility is the product of three alpha factors: its own (index 0, what the
// application or WXFWindowSetAlpha sets), and two WindowServer uses itself. Needs
// WXFMiscFeatureCore.

/// Factor 0, 1 or 2. 1 if the window or index is invalid.
float WXFWindowGetAlphaFactor(const CGXWindow *window, int index);

/// Sets the window's own alpha factor (0...1) and marks it changed so the next frame shows it,
/// as the server does when it fades a window. Hides the window's shadow along with it.
void  WXFWindowSetAlpha(CGXWindow *window, float alpha);

/// Marks the window changed so the compositor redraws it. Needed after writing window state
/// directly. Does nothing if the function is missing.
void  WXFWindowUpdate(CGXWindow *window);

// --- Transforms -----------------------------------------------------------------------------
// Needs WXFMiscFeatureTransform. These write the slot the Dock uses for Exposé; a window has one.

/// Stores `stored` as the window's transform exactly as given. WindowServer maps a screen point
/// to the window by multiplying (x, y, 0, 1) with the stored matrix, so what it wants is the
/// INVERSE of how the window should move. WXFWindowApplyTransform does that for you.
void WXFWindowSetTransform(CGXWindow *window, const WXFMat4 *stored);

/// Makes the window appear transformed by `forward` (natural screen point -> displayed screen
/// point, which may include perspective), by flattening it to the window plane and storing its
/// inverse. False, and the window is left as it was, if that can't be inverted.
bool WXFWindowApplyTransform(CGXWindow *window, WXFMat4 forward);

/// Removes the transform.
void WXFWindowResetTransform(CGXWindow *window);

// --- Moving and ordering --------------------------------------------------------------------

/// Moves the window by whole points; the server moves by whole points only. Needs
/// WXFMiscFeatureMove.
void WXFWindowMoveBy(CGXWindow *window, float dx, float dy);

typedef enum {
    WXFOrderBelow = -1,     ///< Below `relative`; 0 is the back of the window's level.
    WXFOrderOut   = 0,      ///< Off screen.
    WXFOrderAbove = 1,      ///< Above `relative`; 0 is the front of the window's level.
} WXFOrderOp;

/// Orders `count` windows at once (CGSOrderOp semantics). `connection` is the one the request
/// comes from; the windows' own connection works, so does NULL for ordering out.
void WXFOrderWindowList(CGXConnection *connection, const uint32_t *windowIDs, const WXFOrderOp *ops,
                        const uint32_t *relativeIDs, unsigned count);

/// Orders one window, through its own connection. Does nothing if the window is gone.
void WXFOrderWindow(uint32_t windowID, WXFOrderOp op, uint32_t relativeID);

/// After ordering windows that stay ordered in, WindowServer does not rebuild the list the
/// renderer draws from, so they keep being drawn in the old order. Call this with their ids,
/// front first, to make the renderer follow. Needs WXFMiscFeatureReorder.
void WXFRebuildVisibleOrder(const uint32_t *windowIDs, long count);

/// Logs how the visible list is built (see docs/expose-internals.md), for debugging a
/// reordering that doesn't show.
void WXFLogVisibleOrderMode(void);

// --- Applications ---------------------------------------------------------------------------
// Need WXFMiscFeatureActivation.

/// The connection of the front application, NULL if unknown.
CGXConnection *WXFForegroundConnection(void);

/// Makes the application that owns the window the front one, as clicking its Dock icon would.
/// Doesn't order the window. Returns false if it couldn't be done.
bool WXFActivateWindowOwner(const CGXWindow *window);

#ifdef __cplusplus
}
#endif

#endif
