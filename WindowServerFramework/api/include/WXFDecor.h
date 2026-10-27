//
//  WXFDecor.h
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// Window decor: stick things on application windows (horns, ears, borders, badges), behind the
// window or in front of it, inside its edges or sticking out of them.
//
// How (docs/decor-internals.md): every application window has a layer tree that WindowServer itself
// keeps for it. Decor puts a layer of its own at the bottom of that tree (behind the window and its
// shadow) and one at the top (over its content), and your elements go in those. They are part of the
// window as far as the renderer is concerned: they move, resize, fade, stack and transform (Exposé)
// with it in the same frame, and go away with it. The application is not touched.
//
// Core Animation inside WindowServer: a layer changed outside an explicit CATransaction opens an
// implicit one on the server's main thread, and every commit the server makes after that nests inside
// it and never reaches the screen (the display freezes on the wallpaper). So the layers decor gives you
// may only be touched inside WXFDecorPerform or a rule's setup, which the framework runs inside a
// transaction. Don't keep a layer past that, and don't create, change or release CALayers anywhere else
// in a tweak.
//
// Everything here runs on WindowServer's main thread. Coordinates are points, y down. Angles are
// radians, clockwise. Handles are plain ids: an id that's gone does nothing.

#ifndef WXFDECOR_H
#define WXFDECOR_H

#include <stdint.h>
#include <stdbool.h>
#include <CoreGraphics/CoreGraphics.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint32_t WXFDecorID;
typedef uint32_t WXFDecorElementID;
typedef uint32_t WXFDecorRuleID;

/// Whether the WindowServer functions decor needs were found. Needs SetupFramework.
bool WXFDecorIsAvailable(void);

// --- Placement ------------------------------------------------------------------------------
// The element's anchor (0..1 in the element, (0,0) its top left) goes on the window's anchor (0..1
// of the window's frame), moved by `offset`. The element is `size` points plus `stretch` times the
// window's size, then scaled and rotated about its anchor. `size` and `stretch` both zero means the
// element's natural size (an image's size in points, a custom layer's bounds).
//
//   horn on the top left, standing on the edge:  window (0,0)    element (0.5,1)  offset (70,8)
//   border hugging the window:                   window (.5,.5)  element (.5,.5)  stretch (1,1)

typedef struct {
    CGPoint windowAnchor;
    CGPoint elementAnchor;
    CGPoint offset;
    CGSize  size;
    CGSize  stretch;
    CGFloat rotation;
    CGFloat scale;          ///< 0 means 1.
} WXFDecorPlacement;

WXFDecorPlacement WXFDecorPlacementMake(CGPoint windowAnchor, CGPoint elementAnchor, CGPoint offset);

// --- Decors ---------------------------------------------------------------------------------

/// Decorates a window, or returns its existing decor. 0 if the window doesn't exist or has no
/// server layer tree (it isn't a Core Animation window).
WXFDecorID WXFDecorAttach(CGWindowID window);
WXFDecorID WXFDecorForWindow(CGWindowID window);
CGWindowID WXFDecorGetWindow(WXFDecorID decor);
void       WXFDecorRemove(WXFDecorID decor);

/// Runs `work` inside a transaction that commits the decorated windows' trees, for changing
/// elements' layers (WXFDecorElementGetLayer) outside a rule's setup.
void WXFDecorPerform(void (*work)(void *userInfo), void *userInfo);

// --- Elements -------------------------------------------------------------------------------
// In front of the window by default; they stack in the order they are added. 0 if the decor is gone.

/// A picture. `pixelsPerPoint` is 2 for a @2x image.
WXFDecorElementID WXFDecorAddImage(WXFDecorID decor, CGImageRef image, CGFloat pixelsPerPoint,
                                   WXFDecorPlacement placement);

/// A rectangle with a fill and/or a border (NULL for none), corners rounded by `cornerRadius` plus,
/// if `followWindowCorners`, the window's own radius.
WXFDecorElementID WXFDecorAddRect(WXFDecorID decor, CGColorRef fill, CGColorRef border, CGFloat borderWidth,
                                  CGFloat cornerRadius, bool followWindowCorners, WXFDecorPlacement placement);

/// A border around the window, `gap` points outside its edge, `width` thick, following its corners.
WXFDecorElementID WXFDecorAddBorder(WXFDecorID decor, CGColorRef color, CGFloat width, CGFloat gap);

/// A CALayer of yours (`const void *` so C can pass it). Make it inside WXFDecorPerform or a setup.
/// The decor retains it and owns its position, bounds, anchor point, transform and opacity.
WXFDecorElementID WXFDecorAddLayer(WXFDecorID decor, const void *layer, WXFDecorPlacement placement);

void WXFDecorRemoveElement(WXFDecorElementID element);

/// The element's CALayer. Use it only inside WXFDecorPerform or a setup.
const void *WXFDecorElementGetLayer(WXFDecorElementID element);

void WXFDecorElementSetImage(WXFDecorElementID element, CGImageRef image);
void WXFDecorElementSetPlacement(WXFDecorElementID element, WXFDecorPlacement placement);
void WXFDecorElementSetOpacity(WXFDecorElementID element, float opacity);
void WXFDecorElementSetHidden(WXFDecorElementID element, bool hidden);
/// Behind the window instead of in front: visible only where it sticks out. Drawn over the window's
/// shadow, under the window itself.
void WXFDecorElementSetBelowWindow(WXFDecorElementID element, bool below);

// --- Rules ----------------------------------------------------------------------------------

typedef struct {
    CGWindowID window;
    CGRect     frame;
    uint32_t   ownerConnectionID;
    CGFloat    cornerRadius;
    char       appName[128];        ///< The application's display name ("Brave Browser"), "" if unknown.
    char       bundlePath[1024];    ///< Its bundle ("/Applications/Brave Browser.app"), "" if unknown.
} WXFDecorWindowInfo;

typedef struct {
    /// Return true to decorate. NULL decorates every ordinary application window.
    bool (*match)(const WXFDecorWindowInfo *window, void *userInfo);
    /// Adds the elements. Runs inside a transaction, once per window.
    void (*setup)(WXFDecorID decor, const WXFDecorWindowInfo *window, void *userInfo);
    void *userInfo;
    /// Optional: the window changed size (`window->frame` is the new one). Runs inside a transaction,
    /// before the elements are laid out again, so placements, images and visibility can follow it.
    void (*resized)(WXFDecorID decor, const WXFDecorWindowInfo *window, void *userInfo);
} WXFDecorRule;

/// Decorates every matching application window as it is shown (level 0, at least 64x48, not covering
/// its whole display). Windows opened before SetupFramework ran are not seen.
WXFDecorRuleID WXFDecorAddRule(const WXFDecorRule *rule);

#ifdef __cplusplus
}
#endif

#endif /* WXFDECOR_H */
