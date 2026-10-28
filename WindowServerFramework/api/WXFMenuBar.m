//
//  WXFMenuBar.m
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// Sets the menu bar's height by replacing menu_bar_bounds_for_space, the one function every
// consumer of the bar's rectangle asks, and writes the same height into the display's parts so the
// work area follows. See docs/menubar-internals.md and docs/taskbar-internals.md for the callers
// and the evidence.

#include <WindowServerFramework/WXFMenuBar.h>
#include <WindowServerFramework/WXFMisc.h>
#include "WXFBase-Private.h"
#include "WXFHooks-Private.h"
#include <math.h>
#include <os/log.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

// --- Settings -------------------------------------------------------------------------------
static _Atomic double gThickness = 0;
static _Atomic bool gAlwaysVisible = false;

double WXFMenuBarGetThickness(void) { return atomic_load(&gThickness); }
bool WXFMenuBarGetAlwaysVisible(void) { return atomic_load(&gAlwaysVisible); }

// --- The bounds hook ------------------------------------------------------------------------
// CGRect menu_bar_bounds_for_space(PKGManagedMenuSpace *): origin and width from the display, the
// height from PKGDisplay+0x28; (0, 0, 0, 0) when there is no space or display.
void *WXFMenuBarOrig_Bounds;

typedef CGRect (*BoundsFn)(void *space);
typedef void (*RebuildFn)(uint64_t type, BOOL (^test)(void *space));

static RebuildFn gRebuild;

CGRect WXFMenuBarHook_Bounds(void *space) {
    CGRect bar = ((BoundsFn)WXFMenuBarOrig_Bounds)(space);
    double thickness = atomic_load(&gThickness);
    if (thickness > 0 && !CGRectEqualToRect(bar, CGRectZero))
        bar.size.height = thickness;
    return bar;
}

// --- The reveal hook ------------------------------------------------------------------------
// managed_menu_space_synchronized_set_menu_bar_reveal(PKGManagedMenuSpace *, double reveal, bool):
// every reveal of every space, from MenuBarAgent's SLSTransactionSetSpaceReveal and from the
// full screen tile coordination, ends here. Normal spaces keep the value in the space (+128) and
// reposition_one_menu_bar slides the bar by (1 - reveal) * its height; tiled spaces post it to
// their tiles. 1.0 is "fully shown".
void *WXFMenuBarOrig_Reveal;

typedef void (*RevealFn)(void *space, double reveal, bool flag);

void WXFMenuBarHook_Reveal(void *space, double reveal, bool flag) {
    if (atomic_load(&gAlwaysVisible) && reveal < 1.0) reveal = 1.0;
    ((RevealFn)WXFMenuBarOrig_Reveal)(space, reveal, flag);
}

// --- The display parts hook -----------------------------------------------------------------
// void WS::Displays::Display::evaluate_display_parts(): works out, from the bezel paths of the
// display's current mode, where the notch is, and then the menu bar height (the notch's height
// plus one, or the default 24/30 on a display without one). Fields read from its decompile:
//
//   +312  CGRect  the notch, in the display's own space (x y w h at +312 +320 +328 +336)
//   +360  CGRect  the notch with the AppKit (bottom-left origin) transform: what clients get as
//                 the "legacy rect", NSScreen's _notchFrame
//   +392  CGRect  copy of +312, or CGRectNull without a notch
//   +424  CGRect  copy of +312, or CGRectNull without a notch
//   +472  CGRect  copy of +360, or CGRectNull without a notch
//   +504  uint32  the menu bar height: PKGDisplay's copy is what menu_bar_bounds_for_space uses
//                 and SLSGetDisplayMenubarHeight reports to clients
void *WXFMenuBarOrig_EvalParts;

typedef void (*EvalPartsFn)(void *display);
typedef bool (*HasNotchFn)(void *display);

static HasNotchFn gHasNotch;

static void CopyRect(uint8_t *to, const uint8_t *from) { memcpy(to, from, 4 * sizeof(double)); }

static void PatchDisplay(uint8_t *d, double thickness) {
    uint32_t *bar = (uint32_t *)(d + 504);
    uint32_t before = *bar;
    if (before == 0) return;    // never evaluated (a display with no parts), leave it alone

    double *notch = (double *)(d + 312);
    double *legacy = (double *)(d + 360);
    bool hasNotch = gHasNotch ? gHasNotch(d) : notch[3] > 0;
    double oldH = notch[3], oldLegacyH = legacy[3];
    uint32_t want = (uint32_t)llround(thickness);
    double newH = (double)want - 1.0;    // the system's bar is the notch plus one

    bool grow = hasNotch && oldH > 1 && oldH < 200 && newH > oldH;
    // The rectangles must agree before they are changed: same height in both spaces, and the
    // legacy one touching the top of the display (it has a bottom-left origin).
    bool consistent = grow && fabs(oldLegacyH - oldH) < 1.0 && legacy[1] > 0;
    if (grow && !consistent)
        os_log(OS_LOG_DEFAULT, "WXF menubar: notch rects disagree (%.1f vs %.1f, legacy y %.1f), work area left as is",
               oldH, oldLegacyH, legacy[1]);

    if (consistent) {
        double dy = oldH - newH;                       // negative: growing
        if (fabs(notch[1]) > 0.5) notch[1] += dy;      // y-up space: keep the top edge where it was
        notch[3] = newH;
        legacy[1] += dy;                               // bottom-left origin: the top edge is y + h
        legacy[3] = newH;
        CopyRect(d + 392, d + 312);
        CopyRect(d + 424, d + 312);
        CopyRect(d + 472, d + 360);
    }
    *bar = want;
    os_log(OS_LOG_DEFAULT, "WXF menubar: display %p bar %u -> %u, notch %.1f -> %.1f (%s)",
           d, before, want, oldH, consistent ? newH : oldH, hasNotch ? "notched" : "no notch");
}

void WXFMenuBarHook_EvalParts(void *display) {
    ((EvalPartsFn)WXFMenuBarOrig_EvalParts)(display);
    double thickness = atomic_load(&gThickness);
    if (thickness > 0 && display) PatchDisplay(display, thickness);
}

// --- Rebuilding -----------------------------------------------------------------------------
// The bar only repositions when it is told to rebuild. set_needs_rebuild_menu_bars_passing_test
// is what CGXPackagesUpdateMenuBarForManagedSpace calls, with type 16 for "the front connection
// changed".
static void RebuildNow(void *info, double now) {
    (void)info; (void)now;
    if (!gRebuild) return;
    gRebuild(16, ^BOOL(void *space) { (void)space; return YES; });
}

static void RequestRebuild(void) {
    if (WXFMiscIsAvailable(WXFMiscFeatureCore))
        WXFScheduleCallback(RebuildNow, NULL, WXFCurrentTime());
    else
        RebuildNow(NULL, 0);
}

static bool Prepare(void) {
    if (!WXFHooksInstall(WXFHookGroupMenuBar)) {
        os_log(OS_LOG_DEFAULT, "WXF menubar: bounds hook not available on this build");
        return false;
    }
    if (!gRebuild) {
        gRebuild = (RebuildFn)WXFResolveServerSymbol(
            "__ZL40set_needs_rebuild_menu_bars_passing_testmU13block_pointerFbP15PKGManagedSpaceE");
        os_log(OS_LOG_DEFAULT, "WXF menubar: rebuild %p", gRebuild);
    }
    return true;
}

// --- API ------------------------------------------------------------------------------------
bool WXFMenuBarSetThickness(double points) {
    if (!(points >= 0) || isinf(points)) return false;
    if (!Prepare()) return false;
    // The work area is best effort: without these hooks the bar still resizes.
    if (!gHasNotch)
        gHasNotch = (HasNotchFn)WXFResolveServerSymbol("__ZN2WS8Displays7Display22current_mode_has_notchEv");
    if (!WXFHooksInstall(WXFHookGroupMenuBarDisplayParts))
        os_log(OS_LOG_DEFAULT, "WXF menubar: display parts hook not available, work area unchanged");
    if (atomic_exchange(&gThickness, points) != points) {
        os_log(OS_LOG_DEFAULT, "WXF menubar: thickness %.1f", points);
        RequestRebuild();
    }
    return true;
}

bool WXFMenuBarSetAlwaysVisible(bool visible) {
    if (visible && !WXFHooksInstall(WXFHookGroupMenuBarReveal)) {
        os_log(OS_LOG_DEFAULT, "WXF menubar: reveal hook not available on this build");
        return false;
    }
    if (!Prepare()) return false;    // for gRebuild
    if (atomic_exchange(&gAlwaysVisible, visible) != visible) {
        os_log(OS_LOG_DEFAULT, "WXF menubar: always visible %d", visible);
        RequestRebuild();
    }
    return true;
}
