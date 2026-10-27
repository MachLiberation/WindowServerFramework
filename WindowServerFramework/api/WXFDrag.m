//Created by bedtime on 10/26/26.

#include <WindowServerFramework/WXFDrag.h>
#include <WindowServerFramework/WXFMisc.h>
#include "WXFBase-Private.h"
#include "WXFDragShader-Private.h"
#include "WXFHooks-Private.h"
#include <pthread.h>
#include <stdlib.h>
#include <stddef.h>

struct __WXFDragContext {
    WXFBase base;
    WXFDragPhase phase;
    CGXWindow *window;
    bool transformed;
};

#define MAX_OBSERVERS 64
static struct {
    WXFDragObserverID id;
    uint32_t mask;
    WXFDragCallback cb;
    void *userInfo;
} gObservers[MAX_OBSERVERS];
static WXFDragObserverID gNextObserverID = 1;
static pthread_mutex_t gObserverLock = PTHREAD_MUTEX_INITIALIZER;

#include <os/log.h>
#include <math.h>
#include <string.h>

// WindowServer runs one window drag at a time per session, so one driver is sufficient. Everything
// below runs on WindowServer's main thread (hooks and scheduled callbacks), except observer
// registration which is guarded by gObserverLock.
// Symbols only the clone needs; the rest of what the driver does with windows is in WXFMisc.h.
typedef CGXWindow *(*CreateCloneFn)(CGXWindow *, CGRect, const void *, bool);
typedef void (*SystemWindowReleaseFn)(CGXWindow *);

static CreateCloneFn gCreateClone;
static SystemWindowReleaseFn gSystemWindowRelease;
typedef void (*ClearShadowFn)(CGXWindow *);
typedef int (*SetShadowParamsFn)(uint32_t, uint32_t, float, float, float, float);
static ClearShadowFn gClearShadowDensity, gSetShadowEnable, gReleaseShadowResources;
static SetShadowParamsFn gSetShadowParameters;

#define kFrameInterval (1.0 / 60.0)

static struct {
    bool dragging;          // between Begin and DidEnd
    uint32_t dragWindowID;
    WXFDragAnimationRef animation;
    bool live;              // tick loop running
    bool shaderActive;
    bool releasing;
    double beginTime;
    double releaseTime;
    float releaseProgress;
    CGPoint lastOrigin;
    double lastTime;
    // The shader draws on a snapshot clone of the window, not the window itself: a real window is
    // usually CA-backed, and those are never drawn through the compositor path a filter reaches.
    // The clone exists only for the drag; the real window is hidden under it meanwhile.
    CGXWindow *clone;
    uint32_t cloneWindowID;
    CGPoint cloneOffset;    // clone origin minus the window's untransformed origin
    float savedAlpha;       // the window's own alpha factor, restored when the clone goes
    CGPoint cloneOrigin;    // where the clone is (whole points; the server moves by whole points)
    bool haveLast;
    CGPoint velocity;
} gDriver;

static const WXFClass kDragContextClass = {
    .name = "WXFDragContext",
    .destructor = NULL,
    .equal = NULL,
};

static WXFTypeID gDragContextTypeID = WXFTypeIDInvalid;
static pthread_once_t gDragContextOnce = PTHREAD_ONCE_INIT;
static struct __WXFDragContext *gContext;

static void RegisterDragContextClass(void) {
    gDragContextTypeID = WXFRegisterClass(&kDragContextClass);
    gContext = (struct __WXFDragContext *)WXFCreateInstance(gDragContextTypeID, sizeof *gContext);
}

WXFDragPhase WXFDragContextGetPhase(WXFDragContextRef c) { return c->phase; }
CGXWindow *WXFDragContextGetWindow(WXFDragContextRef c) { return c->window; }
bool WXFDragContextIsTransformed(WXFDragContextRef c) { return c->transformed; }

static bool ResolveDriverSymbols(void) {
    static bool tried, ok;
    if (tried) return ok;
    tried = true;
    gCreateClone        = (CreateCloneFn)WXFResolveServerSymbol("__ZL19CreateCloneOfWindowP9CGXWindow6CGRectPK10PKGDisplayb");
    gSystemWindowRelease = (SystemWindowReleaseFn)WXFResolveServerSymbol("_WSSystemWindowRelease");
    // Optional: the overlay is not meant to have a shadow of its own.
    gClearShadowDensity    = (ClearShadowFn)WXFResolveServerSymbol("__ZL20clear_shadow_densityP9CGXWindow");
    gSetShadowEnable       = (ClearShadowFn)WXFResolveServerSymbol("_WSWindowSetShadowEnable");
    gReleaseShadowResources = (ClearShadowFn)WXFResolveServerSymbol("_WSWindowReleaseShadowResources");
    gSetShadowParameters   = (SetShadowParamsFn)WXFResolveServerSymbol("_SLSSetWindowShadowParameters");
    ok = gCreateClone && gSystemWindowRelease &&
         WXFMiscIsAvailable(WXFMiscFeatureCore | WXFMiscFeatureDisplays | WXFMiscFeatureMove | WXFMiscFeatureShape);
    if (!ok)
        os_log(OS_LOG_DEFAULT, "WXF drag: required WindowServer symbols missing, drag animations disabled");
    return ok;
}

static void DriverTick(void *ctx, double now);
static void DriverUpdate(double now);

// Hiding the dragged window while its snapshot stands in for it, the way the server fades a
// window: through its alpha (see WXFWindowSetAlpha in WXFMisc.m for why that hides its shadow too).

// Released a little after it is ordered out, as the server may still have a frame of it in flight.
static void ReleaseCloneLater(void *ctx, double now) {
    (void)now;
    gSystemWindowRelease((CGXWindow *)ctx);
}

static CGXWindow *CloneCreate(CGXWindow *window) {
    const void *display = WXFWindowGetDisplay(window);
    CGRect windowFrame = WXFWindowGetClippedFrame(window);   // the window with its shadow
    if (!display || windowFrame.size.width < 1 || windowFrame.size.height < 1)
        return NULL;
    // The overlay is the window's frame plus the animation's margin. Whole points, so the
    // geometry the shader sees matches what the server places.
    float margin = gDriver.animation ? WXFDragAnimationGetMargin(gDriver.animation) : 0;
    margin = ceilf(margin);
    CGRect frame = CGRectMake(floor(windowFrame.origin.x) - margin, floor(windowFrame.origin.y) - margin,
                              ceil(windowFrame.size.width) + 2 * margin, ceil(windowFrame.size.height) + 2 * margin);
    CGRect content = WXFWindowGetScreenRect(window);
    if (content.size.width < 1 || content.size.height < 1)
        content = windowFrame;

    CGXWindow *clone = gCreateClone(window, frame, display, true);
    if (!clone)
        return NULL;
    uint32_t wid = clone->window_id;
    if (gClearShadowDensity)
        gClearShadowDensity(clone);
    else if (gSetShadowEnable)
        gSetShadowEnable(clone);
    if (gReleaseShadowResources)
        gReleaseShadowResources(clone);
    if (gSetShadowParameters)
        gSetShadowParameters(0, wid, 0.0f, 0.0f, 0.0f, 0.0f);
    WXFOrderOp op = WXFOrderAbove;
    uint32_t relative = window->window_id;
    WXFOrderWindowList(window->connection, &wid, &op, &relative, 1);

    CGRect base = WXFWindowGetFrame(window);
    gDriver.clone = clone;
    gDriver.cloneWindowID = wid;
    gDriver.cloneOrigin = frame.origin;
    gDriver.cloneOffset = CGPointMake(frame.origin.x - base.origin.x, frame.origin.y - base.origin.y);
    WXFDragShaderSetGeometry((float)frame.size.width, (float)frame.size.height, margin,
                             (float)(content.origin.x - frame.origin.x), (float)(content.origin.y - frame.origin.y),
                             (float)content.size.width, (float)content.size.height);
    gDriver.savedAlpha = WXFWindowGetAlphaFactor(window, 0);
    WXFWindowSetAlpha(window, 0.0f);      // the snapshot stands in for the window from here
    os_log(OS_LOG_DEFAULT, "WXF drag: overlay wid=%u for wid=%u frame=(%.0f,%.0f %.0fx%.0f) margin=%.0f",
           wid, window->window_id, frame.origin.x, frame.origin.y, frame.size.width, frame.size.height, margin);
    return clone;
}

// Keeps the clone over the window as the drag moves it.
static void CloneFollow(CGXWindow *window) {
    if (!gDriver.clone)
        return;
    CGRect base = WXFWindowGetFrame(window);
    float dx = (float)(floor(base.origin.x + gDriver.cloneOffset.x) - gDriver.cloneOrigin.x);
    float dy = (float)(floor(base.origin.y + gDriver.cloneOffset.y) - gDriver.cloneOrigin.y);
    if (dx == 0 && dy == 0)
        return;
    WXFWindowMoveBy(gDriver.clone, dx, dy);
    gDriver.cloneOrigin.x += dx;
    gDriver.cloneOrigin.y += dy;
}

static void CloneDestroy(void) {
    CGXWindow *clone = gDriver.clone;
    if (!clone)
        return;
    WXFDragShaderDetach(clone);
    CGXWindow *original = WXFWindowFromID(gDriver.dragWindowID);
    if (original)
        WXFWindowSetAlpha(original, gDriver.savedAlpha);
    WXFOrderOp op = WXFOrderOut;
    uint32_t relative = 0;
    WXFOrderWindowList(NULL, &gDriver.cloneWindowID, &op, &relative, 1);
    WXFScheduleCallback(ReleaseCloneLater, clone, WXFCurrentTime() + 0.1);
    gDriver.clone = NULL;
    gDriver.cloneWindowID = 0;
}

static void DriverStop(void) {
    if (gDriver.live && gDriver.shaderActive) {
        CloneDestroy();
        WXFDragShaderDeactivate();
    }
    gDriver.live = false;
    gDriver.shaderActive = false;
    gDriver.releasing = false;
    gDriver.haveLast = false;
    if (gDriver.animation) {
        WXFRelease(gDriver.animation);
        gDriver.animation = NULL;
    }
}

static void DriverStart(void) {
    if (gDriver.live || !gDriver.animation || !ResolveDriverSymbols())
        return;
    WXFDragAnimationRef anim = gDriver.animation;
    const void *lib;
    size_t libLength;
    const char *fragment;
    if (!WXFDragAnimationGetShader(anim, &lib, &libLength, &fragment, NULL, NULL))
        return;
    CGXWindow *window = WXFWindowFromID(gDriver.dragWindowID);
    if (!window || !WXFDragShaderActivate(lib, libLength, fragment))
        return;

    float params[kWXFFilterParamCount] = {0};   // progress 0: the shader starts as identity
    CGXWindow *clone = CloneCreate(window);
    if (!clone || !WXFDragShaderAttach(clone, params)) {
        CloneDestroy();
        WXFDragShaderDeactivate();
        return;
    }
    gDriver.live = true;
    gDriver.shaderActive = true;
    gDriver.releasing = false;
    gDriver.haveLast = false;
    gDriver.velocity = CGPointZero;
    gDriver.beginTime = WXFCurrentTime();
    WXFScheduleCallback(DriverTick, &gDriver, gDriver.beginTime);
}

static void DriverUpdate(double now) {
    if (!gDriver.live || !gDriver.animation)
        return;
    CGXWindow *window = WXFWindowFromID(gDriver.dragWindowID);
    if (!window) {              // window went away
        DriverStop();
        return;
    }

    WXFDragAnimationRef anim = gDriver.animation;
    now = WXFCurrentTime();
    double durationSec = WXFDragAnimationGetDuration(anim) / 1e9;
    double delaySec = WXFDragAnimationGetDelay(anim) / 1e9;

    float progress;
    bool releaseDone = false;
    if (gDriver.releasing) {
        double t = (now - gDriver.releaseTime) / durationSec;
        releaseDone = t >= 1.0;
        progress = releaseDone ? 0.0f
                 : gDriver.releaseProgress * (1.0f - WXFDragAnimationEvaluateEasing(anim, (float)t));
    } else {
        progress = WXFDragAnimationEvaluateEasing(anim, (float)((now - gDriver.beginTime - delaySec) / durationSec));
    }

    CGRect frame = WXFWindowGetFrame(window);
    CloneFollow(window);
    // Drag events arrive faster than the timer, so smooth the velocity and ignore samples too
    // close together to differentiate.
    if (!gDriver.haveLast) {
        gDriver.lastOrigin = frame.origin;
        gDriver.lastTime = now;
        gDriver.haveLast = true;
    } else if (now - gDriver.lastTime >= 0.004) {
        double dt = now - gDriver.lastTime;
        gDriver.velocity.x = gDriver.velocity.x * 0.6 + ((frame.origin.x - gDriver.lastOrigin.x) / dt) * 0.4;
        gDriver.velocity.y = gDriver.velocity.y * 0.6 + ((frame.origin.y - gDriver.lastOrigin.y) / dt) * 0.4;
        gDriver.lastOrigin = frame.origin;
        gDriver.lastTime = now;
    }

    CGPoint cursor;
    WXFDragFrame f = {
        .window = window,
        .frame = frame,
        .cursor = {0, 0},
        .cursorValid = WXFGetCursorLocation(&cursor),
        .velocity = gDriver.velocity,
        .progress = progress,
        .elapsed = now - gDriver.beginTime,
        .releasing = gDriver.releasing,
        .intensity = WXFDragAnimationGetIntensity(anim),
    };
    if (f.cursorValid)
        f.cursor = cursor;

    // Shader params first: slot 0 is the framework's (progress), slots 1-4 are the developer's.
    if (gDriver.shaderActive) {
        WXFDragShaderParamFunction pfn = NULL;
        void *pinfo = NULL;
        float params[kWXFFilterParamCount] = { progress, 0, 0, 0, 0 };
        float data[kWXFDragShaderDataCount] = {0};
        bool moving = false;
        if (WXFDragAnimationGetShader(anim, NULL, NULL, NULL, &pfn, &pinfo) && pfn)
            moving = pfn(&f, data, pinfo);
        memcpy(&params[1], data, 4 * sizeof(float));   // also marks the filter changed
        // Past the release animation the overlay lives on while the developer's effect is moving.
        if (releaseDone && (!moving || now - gDriver.releaseTime > 10.0)) {
            DriverStop();
            return;
        }
        WXFDragShaderUpdate(gDriver.clone, params, data);
    } else if (releaseDone) {
        DriverStop();
        return;
    }

}

static void DriverTick(void *ctx, double now) {
    DriverUpdate(now);
    if (gDriver.live)
        WXFScheduleCallback(DriverTick, &gDriver, WXFCurrentTime() + kFrameInterval);
}

static void DriverRelease(void) {
    if (!gDriver.live || gDriver.releasing)
        return;
    double now = WXFCurrentTime();
    double durationSec = WXFDragAnimationGetDuration(gDriver.animation) / 1e9;
    double delaySec = WXFDragAnimationGetDelay(gDriver.animation) / 1e9;
    gDriver.releaseProgress = WXFDragAnimationEvaluateEasing(
        gDriver.animation, (float)((now - gDriver.beginTime - delaySec) / durationSec));
    gDriver.releaseTime = now;
    gDriver.releasing = true;
}

WXFDragAnimationRef WXFDragContextGetAnimation(WXFDragContextRef c) {
    return (c->window && gDriver.dragging && c->window->window_id == gDriver.dragWindowID)
        ? gDriver.animation : NULL;
}

void WXFDragContextSetAnimation(WXFDragContextRef c, WXFDragAnimationRef animation) {
    if (!c->window || !gDriver.dragging || c->window->window_id != gDriver.dragWindowID)
        return;
    if (animation)
        WXFRetain(animation);
    bool wasLive = gDriver.live;
    if (gDriver.animation)
        WXFRelease(gDriver.animation);
    gDriver.animation = animation;
    if (!animation) {
        DriverStop();
    } else if (!wasLive && !gDriver.releasing) {
        DriverStart();
    }
}

static void Dispatch(WXFDragPhase phase, CGXWindow *window, bool transformed) {
    pthread_once(&gDragContextOnce, RegisterDragContextClass);
    if (!gContext)
        return;

    if (phase == WXFDragPhaseBegin && window) {
        if (gDriver.live || gDriver.animation) {   // leftover from a previous drag
            DriverStop();
        }
        gDriver.dragging = true;
        gDriver.dragWindowID = window->window_id;
    }

    pthread_mutex_lock(&gObserverLock);
    struct { WXFDragCallback cb; void *userInfo; } snap[MAX_OBSERVERS];
    int n = 0;
    for (int i = 0; i < MAX_OBSERVERS; i++) {
        if (gObservers[i].id && (gObservers[i].mask & phase)) {
            snap[n].cb = gObservers[i].cb;
            snap[n].userInfo = gObservers[i].userInfo;
            n++;
        }
    }
    pthread_mutex_unlock(&gObserverLock);

    gContext->phase = phase;
    gContext->window = window;
    gContext->transformed = transformed;
    for (int i = 0; i < n; i++)
        snap[i].cb(gContext, snap[i].userInfo);
    gContext->window = NULL;

    // The server moves the window on every drag event; refresh the shader params (velocity) then.
    if (phase == WXFDragPhaseMove && window && gDriver.live && !gDriver.releasing &&
        window->window_id == gDriver.dragWindowID)
        DriverUpdate(WXFCurrentTime());

    // Release starts the relax-to-rest; the driver stops itself when it finishes.
    if (phase == WXFDragPhaseWillEnd && window && window->window_id == gDriver.dragWindowID)
        DriverRelease();
    if (phase == WXFDragPhaseDidEnd && window && window->window_id == gDriver.dragWindowID) {
        gDriver.dragging = false;
        if (!gDriver.live)
            DriverStop();   // nothing running: drop the animation reference
    }
}

// All hooked functions are called with the same register-based ABI; forwarding x0-x7 and
// d0-d7 untouched passes through whatever the real signature is (none take stack arguments).
typedef uintptr_t (*PassthroughFn)(uintptr_t, uintptr_t, uintptr_t, uintptr_t,
                                   uintptr_t, uintptr_t, uintptr_t, uintptr_t,
                                   double, double, double, double,
                                   double, double, double, double);
#define PASS_PARAMS uintptr_t a0, uintptr_t a1, uintptr_t a2, uintptr_t a3, \
                    uintptr_t a4, uintptr_t a5, uintptr_t a6, uintptr_t a7, \
                    double d0, double d1, double d2, double d3, \
                    double d4, double d5, double d6, double d7
#define PASS_ARGS a0, a1, a2, a3, a4, a5, a6, a7, d0, d1, d2, d3, d4, d5, d6, d7

// before: dispatch before calling the original; otherwise after.
#define DEFINE_HOOK(NAME, PHASE, WINDOW_ARG, TRANSFORMED, BEFORE)            \
    PassthroughFn WXFDragOrig_##NAME;   /* installed by WXFHooks.c */                \
    uintptr_t WXFDragHook_##NAME(PASS_PARAMS) {                                      \
        if (BEFORE) Dispatch(PHASE, (CGXWindow *)WINDOW_ARG, TRANSFORMED);           \
        uintptr_t r = WXFDragOrig_##NAME(PASS_ARGS);                                 \
        if (!(BEFORE)) Dispatch(PHASE, (CGXWindow *)WINDOW_ARG, TRANSFORMED);        \
        return r;                                                                    \
    }

DEFINE_HOOK(Begin, WXFDragPhaseBegin,          a0, false, false)
DEFINE_HOOK(Propose, WXFDragPhasePropose,        a0, false, true)
DEFINE_HOOK(Commit, WXFDragPhaseMove,           a0, false, false)
DEFINE_HOOK(WillEnd, WXFDragPhaseWillEnd,        a0, false, true)
DEFINE_HOOK(DidEnd, WXFDragPhaseDidEnd,         a0, false, false)
DEFINE_HOOK(MoveT, WXFDragPhaseMove,           a0, true,  false)
DEFINE_HOOK(WillEndT, WXFDragPhaseWillEnd,     a0, true,  true)
// animate_drag_transform(sessionData, connection, window, ...) / remove_drag_transform(sessionData, window, bool)
DEFINE_HOOK(AnimBegin, WXFDragPhaseAnimationBegin, a2, true, false)
DEFINE_HOOK(AnimEnd, WXFDragPhaseAnimationEnd, a1, true, false)

WXFDragObserverID WXFDragAddObserver(uint32_t phaseMask, WXFDragCallback callback, void *userInfo) {
    if (!callback || !(phaseMask & WXFDragPhaseAll))
        return WXFDragObserverIDInvalid;

    WXFHooksInstall(WXFHookGroupDrag);   // no-op until SetupFramework has run

    WXFDragObserverID id = WXFDragObserverIDInvalid;
    pthread_mutex_lock(&gObserverLock);
    for (int i = 0; i < MAX_OBSERVERS; i++) {
        if (!gObservers[i].id) {
            id = gNextObserverID++;
            gObservers[i].id = id;
            gObservers[i].mask = phaseMask;
            gObservers[i].cb = callback;
            gObservers[i].userInfo = userInfo;
            break;
        }
    }
    pthread_mutex_unlock(&gObserverLock);
    return id;
}

bool WXFDragRemoveObserver(WXFDragObserverID observer) {
    bool found = false;
    pthread_mutex_lock(&gObserverLock);
    for (int i = 0; i < MAX_OBSERVERS && observer; i++) {
        if (gObservers[i].id == observer) {
            gObservers[i].id = 0;
            found = true;
            break;
        }
    }
    pthread_mutex_unlock(&gObserverLock);
    return found;
}
