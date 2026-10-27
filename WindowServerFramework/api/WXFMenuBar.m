//
//  WXFMenuBar.m
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// Sets the menu bar's height by replacing menu_bar_bounds_for_space, the one function every
// consumer of the bar's rectangle asks. See docs/menubar-internals.md for the callers and the
// evidence.

#include <WindowServerFramework/WXFMenuBar.h>
#include <WindowServerFramework/WXFMisc.h>
#include "WXFBase-Private.h"
#include "WXFHooks-Private.h"
#include <math.h>
#include <os/log.h>
#include <stdatomic.h>
#include <stdint.h>

// --- Settings -------------------------------------------------------------------------------
static _Atomic double gThickness = 0;

double WXFMenuBarGetThickness(void) { return atomic_load(&gThickness); }

// --- The hook -------------------------------------------------------------------------------
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
    if (atomic_exchange(&gThickness, points) != points) {
        os_log(OS_LOG_DEFAULT, "WXF menubar: thickness %.1f", points);
        RequestRebuild();
    }
    return true;
}
