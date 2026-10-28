//
//  WXFDock.m
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// The Dock's rectangle lives in the session as four doubles (x, y, w, h at +64 of the session's
// package data, which is *(*(__sessionControlRef + 32) + 216)). _XSetDockRectWithReason stores it
// from the Dock's message and _XGetDockRectWithReason replies with it as four floats at +36 of the
// reply; AppKit's NSScreen._dockRect is that reply. See docs/taskbar-internals.md.

#include <WindowServerFramework/WXFDock.h>
#include <WindowServerFramework/WXFMisc.h>
#include "WXFBase-Private.h"
#include "WXFHooks-Private.h"
#include <os/log.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

static _Atomic bool gReserves = true;

bool WXFDockGetReservesSpace(void) { return atomic_load(&gReserves); }

void *WXFDockOrig_SetRect;
void *WXFDockOrig_GetRect;

typedef void (*MIGFn)(void *request, void *reply);

static void *const *gSessionControlRef;

// The stored rectangle, or NULL.
static double *StoredRect(void) {
    if (!gSessionControlRef) gSessionControlRef = (void *const *)WXFResolveServerData("___sessionControlRef");
    if (!gSessionControlRef || !*gSessionControlRef) return NULL;
    uint8_t *control = *gSessionControlRef;
    uint8_t *session = *(uint8_t **)(control + 32);
    if (!session) return NULL;
    uint8_t *data = *(uint8_t **)(session + 216);
    return data ? (double *)(data + 64) : NULL;
}

void WXFDockHook_SetRect(void *request, void *reply) {
    ((MIGFn)WXFDockOrig_SetRect)(request, reply);
    if (!atomic_load(&gReserves)) {
        double *rect = StoredRect();
        if (rect) memset(rect, 0, 4 * sizeof(double));
    }
}

void WXFDockHook_GetRect(void *request, void *reply) {
    ((MIGFn)WXFDockOrig_GetRect)(request, reply);
    // Only a successful reply (return code 0 at +32) carries a rectangle (4 floats at +36).
    if (!atomic_load(&gReserves) && *(int32_t *)((uint8_t *)reply + 32) == 0)
        memset((uint8_t *)reply + 36, 0, 4 * sizeof(float));
}

bool WXFDockSetReservesSpace(bool reserves) {
    if (!reserves && !WXFHooksInstall(WXFHookGroupDockRect)) {
        os_log(OS_LOG_DEFAULT, "WXF dock: rect hooks not available on this build");
        return false;
    }
    if (atomic_exchange(&gReserves, reserves) != reserves) {
        os_log(OS_LOG_DEFAULT, "WXF dock: reserves space %d", reserves);
        if (!reserves) {
            double *rect = StoredRect();
            if (rect) memset(rect, 0, 4 * sizeof(double));
        }
    }
    return true;
}
