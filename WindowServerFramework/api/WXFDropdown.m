//
//  WXFDropdown.m
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// Request layouts, read from the decompiles of the MIG server routines in SkyLight (macOS 27):
//
//   _XSetConnectionProperty  size at +4 (68..192), key at +64 (NUL-terminated, at most 128 bytes)
//   _XOrderWindow            size 44; window id +32, order operation +36 (1 = above), relative id +40
//   _XMoveWindow             size 44; window id +32, x +36, y +40 (ints, the window's new origin)
//
// _XMoveWindow turns the new origin into a delta against the shape's bounding box and calls
// CGXMoveWindowList(connection, &id, 1, 0, dx, dy) as the window's owner; so does the order hook
// when it has to move a window the app is only now showing. A window's level is at +32 of the
// window (WSWindowGetLevel); a pop-up menu is at 101.

#include <WindowServerFramework/WXFDropdown.h>
#include <WindowServerFramework/WXFMisc.h>
#include "WXFBase-Private.h"
#include "WXFHooks-Private.h"
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <math.h>
#include <os/log.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static const int32_t kPopUpMenuLevel = 101;
static const double kYTolerance = 16;
static const uint64_t kLifetimeNs = 1500000000ull;
static const char kPrefix[] = "WXFAnchor:";

// --- WindowServer side ----------------------------------------------------------------------
static _Atomic bool gEnabled;

static struct {
    _Atomic uint64_t at;        // when it was asked, 0 for none
    double x, y;
    uint32_t used;              // the window it was applied to
} gAnchor;

void *WXFDropdownOrig_Property;
void *WXFDropdownOrig_Order;
void *WXFDropdownOrig_Move;

typedef void (*MIGFn)(void *request, void *reply);
typedef void *(*WindowByIDFn)(uint32_t id);
typedef int64_t (*WindowLevelFn)(void *window);
typedef void *(*WindowShapeFn)(void *window);
typedef CGRect (*BoundingBoxFn)(void *region);
typedef void *(*ConnectionForPortFn)(uint32_t port);
typedef void (*MoveWindowListFn)(void *connection, uint32_t *ids, uint32_t count, int64_t flag, float dx, float dy);

static WindowByIDFn gWindowByID;
static WindowLevelFn gWindowLevel;
static WindowShapeFn gWindowShape;
static BoundingBoxFn gBoundingBox;
static ConnectionForPortFn gConnectionForPort;
static MoveWindowListFn gMoveWindowList;

static uint64_t Now(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC); }

static bool Resolve(void) {
    if (gMoveWindowList) return true;
    gWindowByID = (WindowByIDFn)WXFResolveServerSymbol("__ZL12window_by_idj");
    gWindowLevel = (WindowLevelFn)WXFResolveServerSymbol("_WSWindowGetLevel");
    gWindowShape = (WindowShapeFn)WXFResolveServerSymbol("_WSWindowGetShape");
    gBoundingBox = (BoundingBoxFn)WXFResolveServerSymbol("_CGRegionGetBoundingBox");
    gConnectionForPort = (ConnectionForPortFn)WXFResolveServerSymbol("_CGXConnectionForPort");
    MoveWindowListFn move = (MoveWindowListFn)WXFResolveServerSymbol("_CGXMoveWindowList");
    if (!gWindowByID || !gWindowLevel || !gWindowShape || !gBoundingBox || !gConnectionForPort || !move) {
        os_log(OS_LOG_DEFAULT, "WXF dropdown: symbols missing (%p %p %p %p %p %p)", gWindowByID, gWindowLevel,
               gWindowShape, gBoundingBox, gConnectionForPort, move);
        return false;
    }
    gMoveWindowList = move;
    return true;
}

// The anchor if there is a live one.
static bool CurrentAnchor(double *x, double *y) {
    uint64_t at = atomic_load(&gAnchor.at);
    if (!at || Now() - at > kLifetimeNs) return false;
    *x = gAnchor.x;
    *y = gAnchor.y;
    return true;
}

// The window's bounding box if it is a pop-up menu window near the anchor's y.
static bool IsAnchoredWindow(uint32_t windowID, double anchorY, CGRect *box) {
    void *window = gWindowByID(windowID);
    if (!window || gWindowLevel(window) != kPopUpMenuLevel) return false;
    void *shape = gWindowShape(window);
    if (!shape) return false;
    *box = gBoundingBox(shape);
    return fabs(box->origin.y - anchorY) <= kYTolerance;
}

void WXFDropdownHook_Property(void *request, void *reply) {
    ((MIGFn)WXFDropdownOrig_Property)(request, reply);
    const uint8_t *message = request;
    uint32_t size = *(const uint32_t *)(message + 4);
    if (!atomic_load(&gEnabled) || size < 68 || size > 192) return;
    const char *key = (const char *)(message + 64);
    if (!memchr(key, 0, size - 64) || strncmp(key, kPrefix, sizeof(kPrefix) - 1) != 0) return;
    double x, y;
    if (sscanf(key + sizeof(kPrefix) - 1, "%lf:%lf", &x, &y) != 2) return;
    gAnchor.x = x;
    gAnchor.y = y;
    gAnchor.used = 0;
    atomic_store(&gAnchor.at, Now());
}

// The dropdown is shown: if it is the one asked for and is in the wrong place, move it first.
void WXFDropdownHook_Order(void *request, void *reply) {
    uint32_t *message = request;
    double x, y;
    if (atomic_load(&gEnabled) && !(message[0] & 0x80000000) && message[1] == 44 && message[9] == 1 &&
        Resolve() && CurrentAnchor(&x, &y) && message[8] != gAnchor.used) {
        CGRect box;
        if (IsAnchoredWindow(message[8], y, &box) && fabs(box.origin.x - x) > 0.5) {
            void *connection = gConnectionForPort(message[3]);
            uint32_t id = message[8];
            if (connection) {
                gMoveWindowList(connection, &id, 1, 0, (float)(x - box.origin.x), 0.0f);
                gAnchor.used = id;
                os_log(OS_LOG_DEFAULT, "WXF dropdown: window %u moved from x %.0f to %.0f at order-in", id, box.origin.x, x);
            }
        }
    }
    ((MIGFn)WXFDropdownOrig_Order)(request, reply);
}

// The app placing the dropdown itself: ask for the anchored x instead.
void WXFDropdownHook_Move(void *request, void *reply) {
    uint32_t *message = request;
    double x, y;
    if (atomic_load(&gEnabled) && !(message[0] & 0x80000000) && message[1] == 44 && Resolve() && CurrentAnchor(&x, &y)) {
        void *window = gWindowByID(message[8]);
        if (window && gWindowLevel(window) == kPopUpMenuLevel && fabs((double)(int32_t)message[10] - y) <= kYTolerance) {
            os_log(OS_LOG_DEFAULT, "WXF dropdown: window %u move x %d -> %.0f", message[8], (int32_t)message[9], x);
            message[9] = (uint32_t)(int32_t)llround(x);
            gAnchor.used = message[8];
        }
    }
    ((MIGFn)WXFDropdownOrig_Move)(request, reply);
}

bool WXFDropdownSetAnchoringEnabled(bool enabled) {
    if (enabled && !WXFHooksInstall(WXFHookGroupDropdown)) {
        os_log(OS_LOG_DEFAULT, "WXF dropdown: hooks not available on this build");
        return false;
    }
    atomic_store(&gEnabled, enabled);
    os_log(OS_LOG_DEFAULT, "WXF dropdown: anchoring %d", enabled);
    return true;
}

// --- Client side ----------------------------------------------------------------------------
typedef int (*MainConnectionFn)(void);
typedef CGError (*SetPropertyFn)(int connection, int target, CFStringRef key, CFTypeRef value);

bool WXFDropdownAnchor(double x, double y) {
    static MainConnectionFn mainConnection;
    static SetPropertyFn setProperty;
    if (!setProperty) {
        mainConnection = (MainConnectionFn)dlsym(RTLD_DEFAULT, "SLSMainConnectionID");
        setProperty = (SetPropertyFn)dlsym(RTLD_DEFAULT, "SLSSetConnectionProperty");
    }
    if (!mainConnection || !setProperty) return false;
    // The numbers are the property's name, since a name is all the server reads without
    // unpacking a value; each request is a new name so it is never taken for a repeat.
    static _Atomic uint32_t sequence;
    char name[128];
    snprintf(name, sizeof name, "%s%.0f:%.0f:%u", kPrefix, x, y, atomic_fetch_add(&sequence, 1));
    CFStringRef key = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
    int cid = mainConnection();
    CGError error = setProperty(cid, cid, key, kCFBooleanTrue);
    CFRelease(key);
    return error == kCGErrorSuccess;
}
