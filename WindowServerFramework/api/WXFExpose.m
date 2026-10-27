//
//  WXFExpose.m
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// Custom Exposé (docs/expose-internals.md). The Dock normally lays windows out and moves the real
// windows with window transforms. This does the same from inside WindowServer: it lists the
// windows, hands the layout to the tweak every frame, and applies the result as a window
// transform. Everything runs on WindowServer's main thread, except events (see WXFEvent.h), which
// only touch state from the event thread while no layout runs; the two are not interleaved by
// WindowServer, so there is no locking here.

#include <WindowServerFramework/WXFExpose.h>
#include <WindowServerFramework/WXFMisc.h>
#include "WXFBase-Private.h"
#include <math.h>
#include <os/log.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

// --- Objects --------------------------------------------------------------------------------
struct __WXFExposeProvider {
    WXFBase base;
    WXFExposeCallbacks cb;
};

struct __WXFExposeItem {
    uint32_t windowID;
    uint32_t ownerID;
    long index;
    CGRect frame;                   // natural, screen coordinates
    WXFExposeItemLayout layout;     // wanted
    WXFExposeItemLayout applied;    // what the window currently has
    float originalAlpha;            // the window's own alpha factor
    uint32_t belowID;               // the window directly below at the same level, 0 if none
    bool dirty;
    bool touched;                   // a transform or alpha of ours is on the window
};

// A window that does not take part. The tweak decides what happens to it through its alpha.
struct __WXFExposeBackground {
    uint32_t windowID;
    int32_t level;
    float originalAlpha;
    float alpha;                    // wanted, 0...1 of the window's own
    float applied;                  // what the window has now
    bool dirty;
};

struct __WXFExposeSession {
    WXFBase base;
    WXFExposeProviderRef provider;
    WXFExposeScope scope;
    CGRect bounds;
    struct __WXFExposeItem *items;
    long itemCount;
    long *stack;            // item indices as stacked on screen, front first
    struct __WXFExposeBackground *bg;
    long bgCount;
    bool restacked;         // the real order was changed and has to be put back
    double beginTime, lastTime;
    bool ticking;           // a Tick is scheduled
    bool ending;
    double endTime;
    WXFExposeEndReason endReason;
    uint32_t selectedWindowID;
};

static void ProviderDestroy(WXFTypeRef obj) {
    struct __WXFExposeProvider *p = (struct __WXFExposeProvider *)obj;
    if (p->cb.release) p->cb.release(p->cb.info);
}

static void SessionDestroy(WXFTypeRef obj) {
    struct __WXFExposeSession *s = (struct __WXFExposeSession *)obj;
    free(s->items);
    free(s->stack);
    free(s->bg);
    if (s->provider) WXFRelease(s->provider);
}

static const WXFClass kProviderClass = { .name = "WXFExposeProvider", .destructor = ProviderDestroy };
static const WXFClass kSessionClass  = { .name = "WXFExposeSession",  .destructor = SessionDestroy };
static WXFTypeID gProviderTypeID = WXFTypeIDInvalid, gSessionTypeID = WXFTypeIDInvalid;
static pthread_once_t gClassOnce = PTHREAD_ONCE_INIT;

static void RegisterClasses(void) {
    gProviderTypeID = WXFRegisterClass(&kProviderClass);
    gSessionTypeID = WXFRegisterClass(&kSessionClass);
}

WXFExposeProviderRef WXFExposeProviderCreate(const WXFExposeCallbacks *callbacks) {
    pthread_once(&gClassOnce, RegisterClasses);
    if (!callbacks) return NULL;
    struct __WXFExposeProvider *p = (struct __WXFExposeProvider *)WXFCreateInstance(gProviderTypeID, sizeof *p);
    if (!p) return NULL;
    p->cb = *callbacks;
    if (p->cb.retain) p->cb.info = (void *)p->cb.retain(p->cb.info);
    return p;
}

static os_log_t Log(void) {
    static os_log_t log;
    if (!log) log = os_log_create("com.windowserverframework", "expose");
    return log;
}

// --- Layout maths ---------------------------------------------------------------------------
static WXFExposeItemLayout NaturalLayout(CGRect frame, float alpha) {
    WXFExposeItemLayout l = {0};
    l.center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    l.scale = CGSizeMake(1, 1);
    l.eye = l.center;
    l.alpha = alpha;
    return l;
}

// Natural screen point -> displayed screen point.
static WXFMat4 ForwardMatrix(const struct __WXFExposeItem *item) {
    const WXFExposeItemLayout *l = &item->layout;
    double sx = fabs(l->scale.width) < 1e-3 ? 1e-3 : l->scale.width;
    double sy = fabs(l->scale.height) < 1e-3 ? 1e-3 : l->scale.height;
    WXFMat4 m = WXFMat4MakeTranslation(-CGRectGetMidX(item->frame), -CGRectGetMidY(item->frame), 0);
    m = WXFMat4Multiply(m, WXFMat4MakeScale(sx, sy, 1));
    m = WXFMat4Multiply(m, WXFMat4MakeRotationX(l->rotationX));
    m = WXFMat4Multiply(m, WXFMat4MakeRotationY(l->rotationY));
    m = WXFMat4Multiply(m, WXFMat4MakeRotationZ(l->rotationZ));
    if (l->perspective > 1) {
        double d = l->perspective;
        double z = fmin(l->translationZ, d * 0.9);      // keep the window in front of the eye
        m = WXFMat4Multiply(m, WXFMat4MakeTranslation(l->center.x - l->eye.x, l->center.y - l->eye.y, z));
        WXFMat4 p = WXFMat4Identity();
        p.m[11] = -1.0 / d;
        m = WXFMat4Multiply(m, p);
        m = WXFMat4Multiply(m, WXFMat4MakeTranslation(l->eye.x, l->eye.y, 0));
    } else {
        m = WXFMat4Multiply(m, WXFMat4MakeTranslation(l->center.x, l->center.y, 0));
    }
    return m;
}

static bool LayoutsEqual(const WXFExposeItemLayout *a, const WXFExposeItemLayout *b) {
    return memcmp(a, b, sizeof *a) == 0;
}

// --- Applying to windows --------------------------------------------------------------------
static void ApplyItem(struct __WXFExposeItem *item) {
    item->dirty = false;
    CGXWindow *window = WXFWindowFromID(item->windowID);
    if (!window || LayoutsEqual(&item->layout, &item->applied)) return;
    if (WXFWindowApplyTransform(window, ForwardMatrix(item)))       // a singular layout is left as it was
        item->touched = true;
    if (fabsf(item->layout.alpha - item->applied.alpha) > 1e-4f) {
        WXFWindowSetAlpha(window, item->originalAlpha * fminf(fmaxf(item->layout.alpha, 0), 1));
        item->touched = true;
    }
    item->applied = item->layout;
}

static void ApplyBackground(struct __WXFExposeBackground *b) {
    b->dirty = false;
    float factor = fminf(fmaxf(b->alpha, 0), 1);
    if (fabsf(factor - b->applied) < 1e-3f) return;
    CGXWindow *window = WXFWindowFromID(b->windowID);
    if (!window) return;
    WXFWindowSetAlpha(window, b->originalAlpha * factor);
    b->applied = factor;
}

static void RestoreBackground(struct __WXFExposeSession *s) {
    for (long i = 0; i < s->bgCount; i++) {
        struct __WXFExposeBackground *b = &s->bg[i];
        CGXWindow *window = b->applied == 1.0f ? NULL : WXFWindowFromID(b->windowID);
        if (window) WXFWindowSetAlpha(window, b->originalAlpha);
        b->applied = b->alpha = 1.0f;
    }
}

// Reads the real order back (front first) from both window lists and logs it, at most once a
// second, next to the order asked for and each card's depth.
static void CheckStacking(const struct __WXFExposeSession *s) {
    static double last;
    double now = WXFCurrentTime();
    if (now - last < 1.0) return;
    last = now;
    long c32, c56;
    CGXWindow *cursor;
    CGXWindow **l32 = WXFCopyWindowList(WXFWindowListStacking, &c32, &cursor);
    CGXWindow **l56 = WXFCopyWindowList(WXFWindowListVisible, &c56, &cursor);
    char out[400] = "";
    long ol = 0;
    for (long k = 0; k < s->itemCount && ol < (long)sizeof out - 48; k++) {
        const struct __WXFExposeItem *it = &s->items[s->stack[k]];
        long p32 = -1, p56 = -1;
        for (long i = 0; l32 && i < c32; i++) if (l32[i]->window_id == it->windowID) { p32 = i; break; }
        for (long i = 0; l56 && i < c56; i++) if (l56[i]->window_id == it->windowID) { p56 = i; break; }
        ol += snprintf(out + ol, sizeof out - ol, "%x(z%.0f @%ld/%ld) ", it->windowID, it->layout.translationZ, p32, p56);
    }
    os_log(Log(), "WXF expose: asked front first, with depth and position in list32/list56 (%ld/%ld windows): %s", c32, c56, out);
    free(l32);
    free(l56);
}

// Windows are drawn in stacking order whatever their transform's z, so the layout's translationZ
// decides the order: nearest the viewer in front, ties in their real order.
static void Restack(struct __WXFExposeSession *s) {
    long n = s->itemCount, order[n];
    for (long i = 0; i < n; i++) {
        long j = i;
        for (; j > 0 && s->items[order[j - 1]].layout.translationZ < s->items[i].layout.translationZ; j--)
            order[j] = order[j - 1];
        order[j] = i;
    }
    if (!memcmp(order, s->stack, sizeof order)) return;
    for (long k = n - 1; k >= 0; k--)       // back to front, each to the front of its level
        WXFOrderWindow(s->items[order[k]].windowID, WXFOrderAbove, 0);
    uint32_t ids[n];
    for (long k = 0; k < n; k++) ids[k] = s->items[order[k]].windowID;
    WXFRebuildVisibleOrder(ids, n);
    memcpy(s->stack, order, sizeof order);
    s->restacked = true;
    CheckStacking(s);
}

static void FlushDirty(struct __WXFExposeSession *s) {
    bool any = false;
    for (long i = 0; i < s->itemCount; i++)
        if (s->items[i].dirty) {
            ApplyItem(&s->items[i]);
            any = true;
        }
    for (long i = 0; i < s->bgCount; i++)
        if (s->bg[i].dirty) ApplyBackground(&s->bg[i]);
    if (any) Restack(s);
}

// Back to front, each window above the one that was below it: those are either windows that never
// moved or ones already put back.
static void RestoreStacking(struct __WXFExposeSession *s) {
    if (!s->restacked) return;
    for (long i = s->itemCount - 1; i >= 0; i--) {
        const struct __WXFExposeItem *item = &s->items[i];
        if (!item->belowID)
            WXFOrderWindow(item->windowID, WXFOrderBelow, 0);
        else if (WXFWindowFromID(item->belowID))
            WXFOrderWindow(item->windowID, WXFOrderAbove, item->belowID);
    }
    s->restacked = false;
    uint32_t ids[s->itemCount];
    for (long i = 0; i < s->itemCount; i++) ids[i] = s->items[i].windowID;     // the original front-first order
    WXFRebuildVisibleOrder(ids, s->itemCount);
}

static void RestoreItem(struct __WXFExposeItem *item) {
    if (!item->touched) return;
    CGXWindow *window = WXFWindowFromID(item->windowID);
    if (window) {
        WXFWindowResetTransform(window);
        WXFWindowSetAlpha(window, item->originalAlpha);
    }
    item->touched = false;
}

// --- Items and session accessors ------------------------------------------------------------
CGXWindow *WXFExposeItemGetWindow(WXFExposeItemRef i) { return WXFWindowFromID(i->windowID); }
uint32_t WXFExposeItemGetWindowID(WXFExposeItemRef i) { return i->windowID; }
uint32_t WXFExposeItemGetOwnerID(WXFExposeItemRef i) { return i->ownerID; }
long WXFExposeItemGetIndex(WXFExposeItemRef i) { return i->index; }
CGRect WXFExposeItemGetFrame(WXFExposeItemRef i) { return i->frame; }
WXFExposeItemLayout WXFExposeItemGetLayout(WXFExposeItemRef i) { return i->layout; }

void WXFExposeItemSetLayout(WXFExposeItemRef i, const WXFExposeItemLayout *layout) {
    if (!layout) return;
    i->layout = *layout;
    i->dirty = true;
}

bool WXFExposeItemGetQuad(WXFExposeItemRef i, CGPoint corners[4]) {
    WXFMat4 m = ForwardMatrix(i);
    CGRect f = i->frame;
    return WXFMat4ProjectPoint(&m, CGRectGetMinX(f), CGRectGetMinY(f), &corners[0]) &&
           WXFMat4ProjectPoint(&m, CGRectGetMaxX(f), CGRectGetMinY(f), &corners[1]) &&
           WXFMat4ProjectPoint(&m, CGRectGetMaxX(f), CGRectGetMaxY(f), &corners[2]) &&
           WXFMat4ProjectPoint(&m, CGRectGetMinX(f), CGRectGetMaxY(f), &corners[3]);
}

long WXFExposeSessionGetBackgroundCount(WXFExposeSessionRef s) { return s->bgCount; }

WXFExposeBackgroundRef WXFExposeSessionGetBackgroundAtIndex(WXFExposeSessionRef s, long index) {
    return (index >= 0 && index < s->bgCount) ? &s->bg[index] : NULL;
}

CGXWindow *WXFExposeBackgroundGetWindow(WXFExposeBackgroundRef b) { return WXFWindowFromID(b->windowID); }
uint32_t WXFExposeBackgroundGetWindowID(WXFExposeBackgroundRef b) { return b->windowID; }
int32_t WXFExposeBackgroundGetLevel(WXFExposeBackgroundRef b) { return b->level; }
WXFExposeBackgroundKind WXFExposeBackgroundGetKind(WXFExposeBackgroundRef b) {
    return b->level < 0 ? WXFExposeBackgroundKindDesktop
         : b->level == 0 ? WXFExposeBackgroundKindWindow : WXFExposeBackgroundKindOverlay;
}
float WXFExposeBackgroundGetAlpha(WXFExposeBackgroundRef b) { return b->alpha; }
void WXFExposeBackgroundSetAlpha(WXFExposeBackgroundRef b, float alpha) {
    alpha = fminf(fmaxf(alpha, 0), 1);
    if (alpha == b->alpha) return;
    b->alpha = alpha;
    b->dirty = true;
}

WXFExposeProviderRef WXFExposeSessionGetProvider(WXFExposeSessionRef s) { return s->provider; }
WXFExposeScope WXFExposeSessionGetScope(WXFExposeSessionRef s) { return s->scope; }
CGRect WXFExposeSessionGetBounds(WXFExposeSessionRef s) { return s->bounds; }
bool WXFExposeSessionIsEnding(WXFExposeSessionRef s) { return s->ending; }
long WXFExposeSessionGetItemCount(WXFExposeSessionRef s) { return s->itemCount; }

WXFExposeItemRef WXFExposeSessionGetItemAtIndex(WXFExposeSessionRef s, long index) {
    return (index >= 0 && index < s->itemCount) ? &s->items[index] : NULL;
}

double WXFExposeSessionGetElapsed(WXFExposeSessionRef s) {
    return WXFCurrentTime() - s->beginTime;
}

CGPoint WXFExposeSessionGetCursor(WXFExposeSessionRef s) {
    (void)s;
    CGPoint p;
    WXFGetCursorLocation(&p);
    return p;
}

WXFExposeItemRef WXFExposeSessionHitTest(WXFExposeSessionRef s, CGPoint point) {
    for (long k = 0; k < s->itemCount; k++) {
        struct __WXFExposeItem *item = &s->items[s->stack[k]];
        CGPoint q[4];
        if (WXFExposeItemGetQuad(item, q) && WXFQuadContainsPoint(q, point))
            return item;
    }
    return NULL;
}

// --- Session lifecycle ----------------------------------------------------------------------
#define kFrameInterval (1.0 / 60.0)
#define kEndTimeout 1.5

static WXFExposeSessionRef gActive;
static uintptr_t gGeneration;        // identifies the session a scheduled Tick belongs to
static WXFEventHandlerID gHandler;

static void Tick(void *ctx, double now);

static void ScheduleTick(struct __WXFExposeSession *s, double when) {
    if (s->ticking) return;
    s->ticking = true;
    WXFScheduleCallback(Tick, (void *)gGeneration, when);
}

void WXFExposeSessionSetNeedsLayout(WXFExposeSessionRef s) {
    if (s == gActive) ScheduleTick(s, WXFCurrentTime());
}

static void Finish(struct __WXFExposeSession *s) {
    for (long i = 0; i < s->itemCount; i++) RestoreItem(&s->items[i]);
    RestoreBackground(s);
    RestoreStacking(s);
    if (s->endReason == WXFExposeEndReasonSelected && s->selectedWindowID) {
        WXFActivateWindowOwner(WXFWindowFromID(s->selectedWindowID));
        WXFOrderWindow(s->selectedWindowID, WXFOrderAbove, 0);
    }

    const WXFExposeCallbacks *cb = &s->provider->cb;
    gActive = NULL;
    gGeneration++;
    if (cb->didEnd) cb->didEnd(s, cb->info);
    os_log(Log(), "WXF expose: ended");
    WXFRelease(s);          // the framework's reference from Begin
}

static void Tick(void *ctx, double now) {
    struct __WXFExposeSession *s = gActive;
    if (!s || (uintptr_t)ctx != gGeneration) return;
    s->ticking = false;
    now = WXFCurrentTime();

    const WXFExposeCallbacks *cb = &s->provider->cb;
    WXFExposeFrame frame = {
        .bounds = s->bounds,
        .elapsed = now - s->beginTime,
        .delta = s->lastTime ? now - s->lastTime : 0,
        .ending = s->ending,
    };
    s->lastTime = now;

    bool again = cb->layout ? cb->layout(s, &frame, cb->info) : false;
    FlushDirty(s);

    if (s->ending) {
        if (!again || now - s->endTime > kEndTimeout) {
            Finish(s);
            return;
        }
    }
    if (again) ScheduleTick(s, now + kFrameInterval);
}

void WXFExposeEnd(WXFExposeSessionRef s, WXFExposeEndReason reason, WXFExposeItemRef selected) {
    if (!s || s != gActive || s->ending) return;
    s->ending = true;
    s->endReason = reason;
    s->endTime = WXFCurrentTime();
    s->selectedWindowID = (reason == WXFExposeEndReasonSelected && selected) ? selected->windowID : 0;
    const WXFExposeCallbacks *cb = &s->provider->cb;
    if (cb->willEnd) cb->willEnd(s, reason, selected, cb->info);
    FlushDirty(s);
    ScheduleTick(s, s->endTime);    // runs the layout with `ending` set (or the one already due does)
}

WXFExposeSessionRef WXFExposeGetActiveSession(void) { return gActive; }

// Input while the view is up.
enum { kVKEscape = 53 };

static bool gSwallowMouseUp;    // the click that chose a window is still down

static WXFEventDisposition HandleEvent(WXFEventRef event, void *userInfo) {
    (void)userInfo;
    struct __WXFExposeSession *s = gActive;
    WXFEventType type = WXFEventGetType(event);
    if (!s) {
        if (gSwallowMouseUp && type == WXFEventTypeMouseUp && WXFEventGetButton(event) == 0) {
            gSwallowMouseUp = false;
            return WXFEventDispositionConsume;
        }
        return WXFEventDispositionPass;
    }
    if (type == WXFEventTypeMouseUp && WXFEventGetButton(event) == 0)
        gSwallowMouseUp = false;            // consumed below, nothing left to swallow

    // The way out, whatever the provider does.
    const uint32_t kPanic = WXFEventFlagControl | WXFEventFlagOption | WXFEventFlagCommand;
    if (type == WXFEventTypeKeyDown && WXFEventGetKeyCode(event) == kVKEscape &&
        (WXFEventGetFlags(event) & kPanic) == kPanic) {
        WXFExposeEnd(s, WXFExposeEndReasonCancelled, NULL);
        return WXFEventDispositionConsume;
    }

    const WXFExposeCallbacks *cb = &s->provider->cb;
    bool used = !s->ending && cb->handleEvent && cb->handleEvent(s, event, cb->info);
    if (used) {
        FlushDirty(s);
        return WXFEventDispositionConsume;
    }
    if (type == WXFEventTypeFlagsChanged) return WXFEventDispositionPass;

    if (!s->ending) {
        if (type == WXFEventTypeKeyDown && WXFEventGetKeyCode(event) == kVKEscape) {
            WXFExposeEnd(s, WXFExposeEndReasonCancelled, NULL);
        } else if (type == WXFEventTypeMouseDown && WXFEventGetButton(event) == 0) {
            WXFExposeItemRef hit = WXFExposeSessionHitTest(s, WXFEventGetLocation(event));
            gSwallowMouseUp = true;
            WXFExposeEnd(s, hit ? WXFExposeEndReasonSelected : WXFExposeEndReasonCancelled, hit);
        }
    }
    return WXFEventDispositionConsume;
}

WXFExposeSessionRef WXFExposeBegin(WXFExposeProviderRef provider, WXFExposeScope scope) {
    if (!provider || gActive || !WXFIsFrameworkSetUp() ||
        !WXFMiscIsAvailable(WXFMiscFeatureCore | WXFMiscFeatureCursor | WXFMiscFeatureDisplays |
                            WXFMiscFeatureTransform | WXFMiscFeatureWindowList))
        return NULL;
    if (gHandler == WXFEventHandlerIDInvalid)
        gHandler = WXFEventAddHandler(WXFEventTypeAll, HandleEvent, NULL);
    if (gHandler == WXFEventHandlerIDInvalid) return NULL;

    // The display under the cursor.
    CGPoint cursor;
    WXFGetCursorLocation(&cursor);
    WXFDisplayRef display = WXFDisplayForPoint(cursor);
    if (!display) display = WXFDisplayGetMain();
    if (!display) return NULL;
    CGRect bounds = WXFDisplayGetBounds(display);

    long count;
    CGXWindow *cursorWindow;
    CGXWindow **windows = WXFCopyWindowList(WXFWindowListVisible, &count, &cursorWindow);
    if (!windows) return NULL;

    struct __WXFExposeItem *items = calloc(count, sizeof *items);
    struct __WXFExposeBackground *bg = calloc(count, sizeof *bg);
    long n = 0, nbg = 0;
    CGXConnection *front = NULL;
    uint32_t frontOwner = 0;        // fallback: the owner of the frontmost window that takes part
    if (scope == WXFExposeScopeFrontApplication) front = WXFForegroundConnection();
    const WXFExposeCallbacks *cb = &provider->cb;
    for (long i = 0; items && bg && i < count; i++) {
        CGXWindow *w = windows[i];
        if (w == cursorWindow || WXFWindowGetDisplay(w) != display) continue;
        CGRect frame = WXFWindowGetFrame(w);
        if (frame.size.width < 1 || frame.size.height < 1) continue;
        bool takes = cb->includeWindow ? cb->includeWindow(w, cb->info) : w->level == 0;
        if (takes && scope == WXFExposeScopeFrontApplication) {
            if (front) {
                takes = w->connection == front;
            } else {
                if (!frontOwner) frontOwner = WXFWindowGetOwnerConnectionID(w);
                takes = WXFWindowGetOwnerConnectionID(w) == frontOwner;
            }
        }
        if (!takes) {
            struct __WXFExposeBackground *b = &bg[nbg++];
            b->windowID = w->window_id;
            b->level = w->level;
            b->originalAlpha = WXFWindowGetAlphaFactor(w, 0);
            b->alpha = b->applied = 1.0f;
            continue;
        }
        struct __WXFExposeItem *item = &items[n];
        item->windowID = w->window_id;
        item->ownerID = WXFWindowGetOwnerConnectionID(w);
        item->index = n;
        item->frame = frame;
        item->originalAlpha = WXFWindowGetAlphaFactor(w, 0);
        item->layout = NaturalLayout(frame, 1);
        item->applied = item->layout;
        for (long j = i + 1; j < count; j++)
            if (windows[j] != cursorWindow && windows[j]->level == w->level) {
                item->belowID = windows[j]->window_id;
                break;
            }
        n++;
    }
    free(windows);
    if (!items || !bg || n == 0) {
        free(items);
        free(bg);
        return NULL;
    }

    pthread_once(&gClassOnce, RegisterClasses);
    struct __WXFExposeSession *s = (struct __WXFExposeSession *)WXFCreateInstance(gSessionTypeID, sizeof *s);
    long *stack = s ? calloc(n, sizeof *stack) : NULL;
    if (!stack) {
        free(items);
        free(bg);
        if (s) WXFRelease(s);
        return NULL;
    }
    for (long i = 0; i < n; i++) stack[i] = i;
    s->stack = stack;
    s->bg = bg;
    s->bgCount = nbg;
    s->provider = (WXFExposeProviderRef)WXFRetain(provider);
    s->scope = scope;
    s->bounds = bounds;
    s->items = items;
    s->itemCount = n;
    s->beginTime = WXFCurrentTime();
    gActive = s;
    gGeneration++;
    gSwallowMouseUp = false;
    os_log(Log(), "WXF expose: began with %ld windows on %.0fx%.0f at %.0f,%.0f (scope %d, front %p)", n,
           bounds.size.width, bounds.size.height, bounds.origin.x, bounds.origin.y, (int)scope, front);
    for (long i = 0; i < n; i++)
        os_log(Log(), "WXF expose: item %ld window %x frame %.0f,%.0f %.0fx%.0f", i, items[i].windowID,
               items[i].frame.origin.x, items[i].frame.origin.y, items[i].frame.size.width,
               items[i].frame.size.height);

    WXFLogVisibleOrderMode();
    if (cb->didBegin) cb->didBegin(s, cb->info);
    FlushDirty(s);
    ScheduleTick(s, s->beginTime);
    return s;
}
