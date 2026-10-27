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
#include "WXFBase-Private.h"
#include <dlfcn.h>
#include <math.h>
#include <os/log.h>
#include <pthread.h>
#include <ptrauth.h>
#include <stdlib.h>
#include <string.h>

// --- Matrices -------------------------------------------------------------------------------
// 4x4, row-vector convention like CATransform3D: p' = p * M, so Mul(a, b) applies a first.
typedef struct { double m[16]; } Mat4;

static Mat4 Identity(void) {
    Mat4 r = {{1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0,  0, 0, 0, 1}};
    return r;
}

static Mat4 Mul(Mat4 a, Mat4 b) {
    Mat4 r = {{0}};
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++) {
            double s = 0;
            for (int k = 0; k < 4; k++) s += a.m[i * 4 + k] * b.m[k * 4 + j];
            r.m[i * 4 + j] = s;
        }
    return r;
}

static Mat4 Translate(double x, double y, double z) {
    Mat4 r = Identity();
    r.m[12] = x; r.m[13] = y; r.m[14] = z;
    return r;
}

static Mat4 Scale(double x, double y, double z) {
    Mat4 r = Identity();
    r.m[0] = x; r.m[5] = y; r.m[10] = z;
    return r;
}

// The same signs as CATransform3DMakeRotation about each axis.
static Mat4 RotateX(double a) {
    Mat4 r = Identity();
    r.m[5] = cos(a);  r.m[6] = sin(a);
    r.m[9] = -sin(a); r.m[10] = cos(a);
    return r;
}

static Mat4 RotateY(double a) {
    Mat4 r = Identity();
    r.m[0] = cos(a);  r.m[2] = -sin(a);
    r.m[8] = sin(a);  r.m[10] = cos(a);
    return r;
}

static Mat4 RotateZ(double a) {
    Mat4 r = Identity();
    r.m[0] = cos(a);  r.m[1] = sin(a);
    r.m[4] = -sin(a); r.m[5] = cos(a);
    return r;
}

static bool Invert(Mat4 a, Mat4 *out) {
    double aug[4][8];
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++) {
            aug[i][j] = a.m[i * 4 + j];
            aug[i][j + 4] = (i == j);
        }
    for (int c = 0; c < 4; c++) {
        int pivot = c;
        for (int r = c + 1; r < 4; r++)
            if (fabs(aug[r][c]) > fabs(aug[pivot][c])) pivot = r;
        if (fabs(aug[pivot][c]) < 1e-12) return false;
        if (pivot != c)
            for (int j = 0; j < 8; j++) { double t = aug[c][j]; aug[c][j] = aug[pivot][j]; aug[pivot][j] = t; }
        double d = aug[c][c];
        for (int j = 0; j < 8; j++) aug[c][j] /= d;
        for (int r = 0; r < 4; r++) {
            if (r == c) continue;
            double f = aug[r][c];
            if (f == 0) continue;
            for (int j = 0; j < 8; j++) aug[r][j] -= f * aug[c][j];
        }
    }
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++) out->m[i * 4 + j] = aug[i][j + 4];
    return true;
}

// Projects a point on the window plane (z = 0) through `m`. False if it ends up behind the eye.
static bool Project(const Mat4 *m, double x, double y, CGPoint *out) {
    double X = x * m->m[0] + y * m->m[4] + m->m[12];
    double Y = x * m->m[1] + y * m->m[5] + m->m[13];
    double W = x * m->m[3] + y * m->m[7] + m->m[15];
    if (W < 1e-4) return false;
    *out = CGPointMake(X / W, Y / W);
    return true;
}

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

// --- WindowServer symbols -------------------------------------------------------------------
typedef CGXWindow *(*WindowByIDFn)(uint32_t);
typedef CGRect (*WindowBoundsFn)(CGXWindow *);
typedef int (*GetCursorFn)(double *);
typedef void (*ScheduleFn)(void (*)(void *, double), void *, double);
typedef double (*RealTimeFn)(void);
typedef const void *(*WindowDisplayFn)(CGXWindow *);
typedef const void *(*DisplayForPointFn)(CGPoint);
typedef const void *(*MainDisplayFn)(void);
typedef CGRect (*DisplayBoundsFn)(const void *);
typedef void (*SetTransform3DFn)(CGXConnection *, const uint32_t *, const uint32_t *, const double *);
typedef void (*OrderWindowListFn)(CGXConnection *, const uint32_t *, const int32_t *, const uint32_t *, unsigned, bool);
typedef uint64_t (*UpdateAlphasFn)(CGXWindow *, CGXConnection *, float, float, float, bool);
typedef void (*UpdateWindowFn)(CGXConnection *, CGXWindow *);
typedef CGXConnection *(*ForegroundConnectionFn)(void);
typedef int64_t (*GetConnectionPSNFn)(uint64_t connectionID, uint64_t *psn);
typedef int64_t (*SetFrontProcessFn)(uint64_t psn, const void *event, uint32_t flags);

static WindowByIDFn gWindowByID;
static WindowBoundsFn gFrameBounds;
static GetCursorFn gGetCursor;
static ScheduleFn gSchedule;
static RealTimeFn gRealTime;
static WindowDisplayFn gWindowGetDisplay;
static DisplayForPointFn gDisplayForPoint;
static MainDisplayFn gMainDisplay;
static DisplayBoundsFn gDisplayBounds;
static SetTransform3DFn gSetTransform3D;
static OrderWindowListFn gOrderWindowList;
static UpdateAlphasFn gUpdateAlphas;
static UpdateWindowFn gUpdateWindow;
static ForegroundConnectionFn gForegroundConnection;
static GetConnectionPSNFn gGetConnectionPSN;
static SetFrontProcessFn gSetFrontProcess;
typedef void (*DidChangeOrderFn)(int type, void *data, uint32_t length, void *ctx);
static DidChangeOrderFn gDidChangeOrder;
typedef void *(*GetWorkspaceDataFn)(void *session);
typedef void (*UpdateVisibleWorkspaceOrderingFn)(void);
static UpdateVisibleWorkspaceOrderingFn gUpdateVisibleWorkspaceOrdering;
static GetWorkspaceDataFn gGetWorkspaceData;
static void *const *gSessionControlRef;     // the data symbol ___sessionControlRef (3 underscores)

static os_log_t Log(void) {
    static os_log_t log;
    if (!log) log = os_log_create("com.windowserverframework", "expose");
    return log;
}

static bool ResolveSymbols(void) {
    static bool tried, ok;
    if (tried) return ok;
    tried = true;
    gWindowByID      = (WindowByIDFn)WXFResolveServerSymbol("__ZL12window_by_idj");
    gFrameBounds     = (WindowBoundsFn)WXFResolveServerSymbol("_WSCurrentUntransformedWindowBounds");
    gGetCursor       = (GetCursorFn)WXFResolveServerSymbol("_CGXGetCurrentCursorLocation");
    gSchedule        = (ScheduleFn)WXFResolveServerSymbol("_WSScheduleCallbackOnCurrentSession");
    gRealTime        = (RealTimeFn)dlsym(RTLD_DEFAULT, "SLSCurrentRealTime");
    if (!gRealTime) gRealTime = (RealTimeFn)WXFResolveServerSymbol("_SLSCurrentRealTime");
    gWindowGetDisplay = (WindowDisplayFn)WXFResolveServerSymbol("_PKGWindowGetDisplay");
    gDisplayForPoint = (DisplayForPointFn)WXFResolveServerSymbol("_PKGDisplayBestMatchingPoint");
    gMainDisplay     = (MainDisplayFn)WXFResolveServerSymbol("_PKGDisplayGetMain");
    gDisplayBounds   = (DisplayBoundsFn)WXFResolveServerSymbol("_PKGDisplayGetBounds");
    gSetTransform3D  = (SetTransform3DFn)WXFResolveServerSymbol("_CGXSetWindowTransform3DList");
    gOrderWindowList = (OrderWindowListFn)WXFResolveServerSymbol(
        "__ZL36CGXOrderWindowListSpaceSwitchOptionsP13CGXConnectionPKjPK10CGSOrderOpS2_jb");
    gUpdateAlphas    = (UpdateAlphasFn)WXFResolveServerSymbol("__ZN9CGXWindow13update_alphasEP13CGXConnectionfffb");
    gUpdateWindow    = (UpdateWindowFn)WXFResolveServerSymbol("_updateWindow");
    // Activation: CPXSetFrontProcess(psn, event, flags), as PKGSetFrontProcessForCurrentSpaceSwitch calls it.
    gGetConnectionPSN = (GetConnectionPSNFn)WXFResolveServerSymbol("_CPXGetConnectionPSN");
    gSetFrontProcess = (SetFrontProcessFn)WXFResolveServerSymbol("_CPXSetFrontProcess");
    // The front process's connection; _WSWindowHitTest compares it with window->connection.
    gForegroundConnection = (ForegroundConnectionFn)WXFResolveServerSymbol("_WSForegroundProcessConnection");
    gUpdateVisibleWorkspaceOrdering = (UpdateVisibleWorkspaceOrderingFn)WXFResolveServerSymbol(
        "__ZL38update_visible_workspace_ordering_infov");
    gGetWorkspaceData = (GetWorkspaceDataFn)WXFResolveServerSymbol("_CGSessionGetWorkspaceData");
    gDidChangeOrder = (DidChangeOrderFn)WXFResolveServerSymbol(
        "__ZL39spaces_did_change_window_order_callback19CGSNotificationTypePvjS0_");
    // A data symbol: resolving signs it like a function pointer, so take that off again.
    void *ref = WXFResolveServerSymbol("___sessionControlRef");
    gSessionControlRef = ref ? (void *const *)ptrauth_strip(ref, ptrauth_key_function_pointer) : NULL;

    ok = gWindowByID && gFrameBounds && gGetCursor && gSchedule && gRealTime && gWindowGetDisplay &&
         gDisplayForPoint && gMainDisplay && gDisplayBounds && gSetTransform3D && gOrderWindowList &&
         gUpdateAlphas && gSessionControlRef;
    if (!ok)
        os_log_error(Log(), "WXF expose: missing symbols (byID %d bounds %d cursor %d sched %d time %d "
                     "winDisplay %d dispPt %d dispMain %d dispBounds %d xform %d order %d alpha %d ctl %d)",
                     !!gWindowByID, !!gFrameBounds, !!gGetCursor, !!gSchedule, !!gRealTime,
                     !!gWindowGetDisplay, !!gDisplayForPoint, !!gMainDisplay, !!gDisplayBounds,
                     !!gSetTransform3D, !!gOrderWindowList, !!gUpdateAlphas, !!gSessionControlRef);
    return ok;
}

// --- Window list ----------------------------------------------------------------------------
// session = __sessionControlRef+32; its window data (+144) holds the ordered CGXWindow* array
// (+56) and its length (+64); **(session+256) is the cursor window. docs/expose-internals.md.
// `stacking` reads the list the ordering code edits (data+32, length data+40, as
// start_order_window and highest_window_at_effective_level do) instead of data+56 / +64.
static CGXWindow **CopyOrderedWindows(long *count, CGXWindow **cursorWindow, bool stacking) {
    *count = 0;
    *cursorWindow = NULL;
    uintptr_t control = (uintptr_t)*gSessionControlRef;
    if (!control) return NULL;
    uintptr_t session = *(uintptr_t *)(control + 32);
    if (!session) return NULL;
    uintptr_t data = *(uintptr_t *)(session + 144);
    if (!data) return NULL;
    CGXWindow **array = *(CGXWindow ***)(data + (stacking ? 32 : 56));
    int n = *(int *)(data + (stacking ? 40 : 64));
    uintptr_t *cursorRef = *(uintptr_t **)(session + 256);
    if (cursorRef) *cursorWindow = (CGXWindow *)*cursorRef;
    if (!array || n <= 0) return NULL;
    CGXWindow **copy = calloc(n, sizeof *copy);
    if (!copy) return NULL;
    long out = 0;
    for (int i = 0; i < n; i++)
        if (array[i]) copy[out++] = array[i];
    *count = out;
    return copy;
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
static Mat4 ForwardMatrix(const struct __WXFExposeItem *item) {
    const WXFExposeItemLayout *l = &item->layout;
    double sx = fabs(l->scale.width) < 1e-3 ? 1e-3 : l->scale.width;
    double sy = fabs(l->scale.height) < 1e-3 ? 1e-3 : l->scale.height;
    Mat4 m = Translate(-CGRectGetMidX(item->frame), -CGRectGetMidY(item->frame), 0);
    m = Mul(m, Scale(sx, sy, 1));
    m = Mul(m, RotateX(l->rotationX));
    m = Mul(m, RotateY(l->rotationY));
    m = Mul(m, RotateZ(l->rotationZ));
    if (l->perspective > 1) {
        double d = l->perspective;
        double z = fmin(l->translationZ, d * 0.9);      // keep the window in front of the eye
        m = Mul(m, Translate(l->center.x - l->eye.x, l->center.y - l->eye.y, z));
        Mat4 p = Identity();
        p.m[11] = -1.0 / d;
        m = Mul(m, p);
        m = Mul(m, Translate(l->eye.x, l->eye.y, 0));
    } else {
        m = Mul(m, Translate(l->center.x, l->center.y, 0));
    }
    return m;
}

static bool LayoutsEqual(const WXFExposeItemLayout *a, const WXFExposeItemLayout *b) {
    return memcmp(a, b, sizeof *a) == 0;
}

// --- Applying to windows --------------------------------------------------------------------
// The key the Dock uses for its Exposé transforms (PKGTransactionSetWindowTransform3D).
#define kPlacement 0x30000000u
#define kWindowAlphaOffset 488   /* three float alpha factors; see WXFDrag.m */

static void SetTransform(CGXWindow *window, const Mat4 *inverse) {
    uint32_t wid = window->window_id, placement = kPlacement;
    gSetTransform3D(window->connection, &wid, &placement, inverse->m);
}

static void SetAlpha(CGXWindow *window, float alpha) {
    if (!gUpdateAlphas) return;
    float *factors = (float *)((char *)window + kWindowAlphaOffset);
    gUpdateAlphas(window, window->connection, alpha, factors[1], factors[2], true);
    if (gUpdateWindow) gUpdateWindow(window->connection, window);
}

// WindowServer projects a screen point to the window as (x, y, 0, 1) times the stored matrix, so the
// stored matrix has to be the inverse of the window plane's homography, not of the full 4x4: the
// full inverse would need the screen point's depth, which WindowServer takes as 0 (that skewed
// every rotated card). Dropping the z row and column leaves the plane's 3x3 map; z passes through.
static Mat4 FlattenToPlane(Mat4 m) {
    for (int i = 0; i < 4; i++) {
        m.m[i * 4 + 2] = 0;
        m.m[8 + i] = 0;
    }
    m.m[10] = 1;
    return m;
}

static void ApplyItem(struct __WXFExposeItem *item) {
    item->dirty = false;
    CGXWindow *window = gWindowByID(item->windowID);
    if (!window || LayoutsEqual(&item->layout, &item->applied)) return;
    Mat4 forward = FlattenToPlane(ForwardMatrix(item)), inverse;
    if (Invert(forward, &inverse)) {        // a singular layout is left as it was
        SetTransform(window, &inverse);
        item->touched = true;
    }
    if (fabsf(item->layout.alpha - item->applied.alpha) > 1e-4f) {
        SetAlpha(window, item->originalAlpha * fminf(fmaxf(item->layout.alpha, 0), 1));
        item->touched = true;
    }
    item->applied = item->layout;
}

static void ApplyBackground(struct __WXFExposeBackground *b) {
    b->dirty = false;
    float factor = fminf(fmaxf(b->alpha, 0), 1);
    if (fabsf(factor - b->applied) < 1e-3f) return;
    CGXWindow *window = gWindowByID(b->windowID);
    if (!window) return;
    SetAlpha(window, b->originalAlpha * factor);
    b->applied = factor;
}

static void RestoreBackground(struct __WXFExposeSession *s) {
    for (long i = 0; i < s->bgCount; i++) {
        struct __WXFExposeBackground *b = &s->bg[i];
        CGXWindow *window = b->applied == 1.0f ? NULL : gWindowByID(b->windowID);
        if (window) SetAlpha(window, b->originalAlpha);
        b->applied = b->alpha = 1.0f;
    }
}

static void OrderWindow(uint32_t wid, int32_t op, uint32_t relative) {
    CGXWindow *window = gWindowByID(wid);
    if (window) gOrderWindowList(window->connection, &wid, &op, &relative, 1, false);
}

// Ordering edits the window list (data+32) but the renderer draws from the visible window list
// (data+56). WindowServer builds that one in one of two ways (see IsWMOnly): by merging the
// workspaces, whose order comes from the data+32 positions, or from the window manager's own
// visibility list (WorkspaceData+64). Reordering windows that stay ordered in does not run either
// rebuild, so after ordering `ids` (front first) we make both follow, then run the handler for
// notification 1002 (spaces_did_change_window_order_callback), which rebuilds the visible list.
static bool IsWMOnly(uintptr_t *workspaceData) {
    uintptr_t control = (uintptr_t)*gSessionControlRef;
    uintptr_t session = control ? *(uintptr_t *)(control + 32) : 0;
    if (!session || !gGetWorkspaceData) return false;
    uintptr_t flags = *(uintptr_t *)(session + 176);
    if (workspaceData) *workspaceData = (uintptr_t)gGetWorkspaceData((void *)session);
    return flags && (*(uint8_t *)(flags + 24) & 0x80) && *(uint32_t *)(flags + 20);
}

// Rewrites the window manager's visibility list in place so the nodes holding `ids` carry them in
// the asked order (front first). The list's direction is read from the current visible list.
static void SetVisibilityListOrder(uintptr_t ws, const uint32_t *ids, long n) {
    uintptr_t *nodes[64];
    long c = 0;
    for (uintptr_t *node = *(uintptr_t **)(ws + 64); node && c < 64; node = (uintptr_t *)node[1])
        for (long i = 0; i < n; i++)
            if ((uint32_t)node[0] == ids[i]) { nodes[c++] = node; break; }
    if (c < 2) return;
    long count, p0 = -1, p1 = -1;
    CGXWindow *cursor;
    CGXWindow **visible = CopyOrderedWindows(&count, &cursor, false);
    for (long i = 0; visible && i < count; i++) {
        if (visible[i]->window_id == (uint32_t)nodes[0][0]) p0 = i;
        if (visible[i]->window_id == (uint32_t)nodes[1][0]) p1 = i;
    }
    free(visible);
    if (p0 < 0 || p1 < 0) return;
    bool forward = p0 < p1;         // the list runs front to back like the visible list
    uint32_t wanted[64];
    long w = 0;
    for (long i = 0; i < n && w < c; i++)
        for (long j = 0; j < c; j++)
            if ((uint32_t)nodes[j][0] == ids[i]) { wanted[w++] = ids[i]; break; }
    for (long j = 0; j < c; j++) nodes[j][0] = forward ? wanted[j] : wanted[c - 1 - j];
}

// With session+176 -> +24 bit 6 set and a window manager override map (WorkspaceData+56),
// workspace_window_list_resort_windows sorts each workspace with session_workspace_window_sort:
// windows of the same level that the window manager knows are ordered by their index in that map
// (smaller is further front), not by window order. The map is a std::unordered_map<uint32_t, ...>
// (create_workspace_visibility_override_map): first node at map+16, node = {next, hash, u32 id at
// +16, u64 index at +24}. Hand the indices our windows already hold back out in the asked order.
static void SetOverrideMapOrder(uintptr_t ws, const uint32_t *ids, long n) {
    uintptr_t map = *(uintptr_t *)(ws + 56);
    if (!map) return;
    uintptr_t *nodes[64];
    uint64_t values[64];
    long c = 0;
    for (uintptr_t *node = *(uintptr_t **)(map + 16); node && c < 64; node = (uintptr_t *)node[0]) {
        uint32_t id = *(uint32_t *)((char *)node + 16);
        for (long i = 0; i < n; i++)
            if (id == ids[i]) {
                nodes[c] = node;
                values[c++] = *(uint64_t *)((char *)node + 24);
                break;
            }
    }
    if (c < 2) return;
    for (long i = 1; i < c; i++)            // the indices, smallest (front) first
        for (long j = i; j > 0 && values[j - 1] > values[j]; j--) {
            uint64_t t = values[j]; values[j] = values[j - 1]; values[j - 1] = t;
        }
    long k = 0;
    for (long i = 0; i < n && k < c; i++)
        for (long j = 0; j < c; j++)
            if (*(uint32_t *)((char *)nodes[j] + 16) == ids[i]) {
                *(uint64_t *)((char *)nodes[j] + 24) = values[k++];
                break;
            }
}

static void RebuildVisibleOrder(const uint32_t *ids, long n) {
    uintptr_t ws = 0;
    if (IsWMOnly(&ws) && ws) SetVisibilityListOrder(ws, ids, n);
    if (ws) SetOverrideMapOrder(ws, ids, n);
    if (gUpdateVisibleWorkspaceOrdering) gUpdateVisibleWorkspaceOrdering();     // sort the workspaces
    if (gDidChangeOrder) gDidChangeOrder(1002, NULL, 0, NULL);
}

// Which way WindowServer builds the visible list: from the window manager's visibility list
// (WorkspaceData+64, "wmonly") when session+176 has +24 bit 7 and +20 set, else by merging the
// workspaces. Logged once per session.
static void LogVisibleMode(void) {
    uintptr_t control = (uintptr_t)*gSessionControlRef;
    uintptr_t session = control ? *(uintptr_t *)(control + 32) : 0;
    if (!session || !gGetWorkspaceData) return;
    uintptr_t flags = *(uintptr_t *)(session + 176);
    uintptr_t ws = (uintptr_t)gGetWorkspaceData((void *)session);
    bool wm = flags && (*(uint8_t *)(flags + 24) & 0x80) && *(uint32_t *)(flags + 20);
    long n = 0;
    char ids[120] = "";
    long il = 0;
    for (uintptr_t *node = ws ? *(uintptr_t **)(ws + 64) : NULL; node; node = (uintptr_t *)node[1], n++)
        if (n < 8) il += snprintf(ids + il, sizeof ids - il, "%lx ", (unsigned long)node[0]);
    os_log(Log(), "WXF expose: visible list mode %s (flags byte24 %02x dword20 %u), override list %ld: %s",
           wm ? "wmonly" : "merging", flags ? *(uint8_t *)(flags + 24) : 0, flags ? *(uint32_t *)(flags + 20) : 0, n, ids);
}

enum { kOrderAbove = 1, kOrderBelow = -1 };    // CGSOrderOp; relative 0 is the front / back of the level

// Reads the real order back (front first) from both window lists and logs it, at most once a
// second, next to the order asked for and each card's depth.
static void CheckStacking(const struct __WXFExposeSession *s) {
    static double last;
    double now = gRealTime();
    if (now - last < 1.0) return;
    last = now;
    long c32, c56;
    CGXWindow *cursor;
    CGXWindow **l32 = CopyOrderedWindows(&c32, &cursor, true);
    CGXWindow **l56 = CopyOrderedWindows(&c56, &cursor, false);
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
        OrderWindow(s->items[order[k]].windowID, kOrderAbove, 0);
    uint32_t ids[n];
    for (long k = 0; k < n; k++) ids[k] = s->items[order[k]].windowID;
    RebuildVisibleOrder(ids, n);
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
            OrderWindow(item->windowID, kOrderBelow, 0);
        else if (gWindowByID(item->belowID))
            OrderWindow(item->windowID, kOrderAbove, item->belowID);
    }
    s->restacked = false;
    uint32_t ids[s->itemCount];
    for (long i = 0; i < s->itemCount; i++) ids[i] = s->items[i].windowID;     // the original front-first order
    RebuildVisibleOrder(ids, s->itemCount);
}

static void RestoreItem(struct __WXFExposeItem *item) {
    if (!item->touched) return;
    CGXWindow *window = gWindowByID(item->windowID);
    if (window) {
        Mat4 id = Identity();
        SetTransform(window, &id);
        SetAlpha(window, item->originalAlpha);
    }
    item->touched = false;
}

// --- Items and session accessors ------------------------------------------------------------
CGXWindow *WXFExposeItemGetWindow(WXFExposeItemRef i) { return gWindowByID ? gWindowByID(i->windowID) : NULL; }
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
    Mat4 m = ForwardMatrix(i);
    CGRect f = i->frame;
    return Project(&m, CGRectGetMinX(f), CGRectGetMinY(f), &corners[0]) &&
           Project(&m, CGRectGetMaxX(f), CGRectGetMinY(f), &corners[1]) &&
           Project(&m, CGRectGetMaxX(f), CGRectGetMaxY(f), &corners[2]) &&
           Project(&m, CGRectGetMinX(f), CGRectGetMaxY(f), &corners[3]);
}

long WXFExposeSessionGetBackgroundCount(WXFExposeSessionRef s) { return s->bgCount; }

WXFExposeBackgroundRef WXFExposeSessionGetBackgroundAtIndex(WXFExposeSessionRef s, long index) {
    return (index >= 0 && index < s->bgCount) ? &s->bg[index] : NULL;
}

CGXWindow *WXFExposeBackgroundGetWindow(WXFExposeBackgroundRef b) { return gWindowByID ? gWindowByID(b->windowID) : NULL; }
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
    return gRealTime ? gRealTime() - s->beginTime : 0;
}

CGPoint WXFExposeSessionGetCursor(WXFExposeSessionRef s) {
    (void)s;
    double p[2] = {0, 0};
    if (gGetCursor) gGetCursor(p);
    return CGPointMake(p[0], p[1]);
}

static double Cross(CGPoint a, CGPoint b, CGPoint p) {
    return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
}

static bool QuadContains(const CGPoint q[4], CGPoint p) {
    bool neg = false, pos = false;
    for (int i = 0; i < 4; i++) {
        double c = Cross(q[i], q[(i + 1) % 4], p);
        if (c < 0) neg = true;
        if (c > 0) pos = true;
    }
    return !(neg && pos);       // same side of every edge, either winding
}

WXFExposeItemRef WXFExposeSessionHitTest(WXFExposeSessionRef s, CGPoint point) {
    for (long k = 0; k < s->itemCount; k++) {
        struct __WXFExposeItem *item = &s->items[s->stack[k]];
        CGPoint q[4];
        if (WXFExposeItemGetQuad(item, q) && QuadContains(q, point))
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
    gSchedule(Tick, (void *)gGeneration, when);
}

void WXFExposeSessionSetNeedsLayout(WXFExposeSessionRef s) {
    if (s == gActive && gSchedule) ScheduleTick(s, gRealTime());
}

// The connection id of the window's owner, read as pkg_space_switch_for_window_order_top does:
// the presenter connection at +0x40 if there is one, else the connection at +0x30, then +0x50.
// (window+0x50 is not the id; it reads 0.)
static uint32_t OwnerConnectionID(const CGXWindow *w) {
    const char *conn = *(const char *const *)((const char *)w + 0x40);
    if (!conn) conn = (const char *)w->connection;
    return conn ? *(const uint32_t *)(conn + 0x50) : 0;
}

// Makes the owner of the window the front application, as clicking its Dock icon would.
static void Activate(uint32_t windowID) {
    CGXWindow *window = gWindowByID(windowID);
    if (!window || !gGetConnectionPSN || !gSetFrontProcess) return;
    uint64_t psn = 0;
    uint32_t cid = OwnerConnectionID(window);
    int64_t err = gGetConnectionPSN(cid, &psn);
    if (err == 0) err = gSetFrontProcess(psn, NULL, 0);
    os_log(Log(), "WXF expose: activate connection %u psn %llx: %lld", cid, (unsigned long long)psn, (long long)err);
}

static void Finish(struct __WXFExposeSession *s) {
    for (long i = 0; i < s->itemCount; i++) RestoreItem(&s->items[i]);
    RestoreBackground(s);
    RestoreStacking(s);
    if (s->endReason == WXFExposeEndReasonSelected && s->selectedWindowID) {
        Activate(s->selectedWindowID);
        OrderWindow(s->selectedWindowID, kOrderAbove, 0);
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
    now = gRealTime();

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
    s->endTime = gRealTime();
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
    if (!provider || gActive || !WXFIsFrameworkSetUp() || !ResolveSymbols()) return NULL;
    if (gHandler == WXFEventHandlerIDInvalid)
        gHandler = WXFEventAddHandler(WXFEventTypeAll, HandleEvent, NULL);
    if (gHandler == WXFEventHandlerIDInvalid) return NULL;

    // The display under the cursor.
    double cursor[2] = {0, 0};
    gGetCursor(cursor);
    const void *display = gDisplayForPoint(CGPointMake(cursor[0], cursor[1]));
    if (!display) display = gMainDisplay();
    if (!display) return NULL;
    CGRect bounds = gDisplayBounds(display);

    long count;
    CGXWindow *cursorWindow;
    CGXWindow **windows = CopyOrderedWindows(&count, &cursorWindow, false);
    if (!windows) return NULL;

    struct __WXFExposeItem *items = calloc(count, sizeof *items);
    struct __WXFExposeBackground *bg = calloc(count, sizeof *bg);
    long n = 0, nbg = 0;
    CGXConnection *front = NULL;
    uint32_t frontOwner = 0;        // fallback: the owner of the frontmost window that takes part
    if (scope == WXFExposeScopeFrontApplication && gForegroundConnection) front = gForegroundConnection();
    const WXFExposeCallbacks *cb = &provider->cb;
    for (long i = 0; items && bg && i < count; i++) {
        CGXWindow *w = windows[i];
        if (w == cursorWindow || gWindowGetDisplay(w) != display) continue;
        CGRect frame = gFrameBounds(w);
        if (frame.size.width < 1 || frame.size.height < 1) continue;
        bool takes = cb->includeWindow ? cb->includeWindow(w, cb->info) : w->level == 0;
        if (takes && scope == WXFExposeScopeFrontApplication) {
            if (front) {
                takes = w->connection == front;
            } else {
                if (!frontOwner) frontOwner = OwnerConnectionID(w);
                takes = OwnerConnectionID(w) == frontOwner;
            }
        }
        if (!takes) {
            struct __WXFExposeBackground *b = &bg[nbg++];
            b->windowID = w->window_id;
            b->level = w->level;
            b->originalAlpha = ((float *)((char *)w + kWindowAlphaOffset))[0];
            b->alpha = b->applied = 1.0f;
            continue;
        }
        struct __WXFExposeItem *item = &items[n];
        item->windowID = w->window_id;
        item->ownerID = OwnerConnectionID(w);
        item->index = n;
        item->frame = frame;
        item->originalAlpha = ((float *)((char *)w + kWindowAlphaOffset))[0];
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
    s->beginTime = gRealTime();
    gActive = s;
    gGeneration++;
    gSwallowMouseUp = false;
    os_log(Log(), "WXF expose: began with %ld windows on %.0fx%.0f at %.0f,%.0f (scope %d, front %p)", n,
           bounds.size.width, bounds.size.height, bounds.origin.x, bounds.origin.y, (int)scope, front);
    for (long i = 0; i < n; i++)
        os_log(Log(), "WXF expose: item %ld window %x frame %.0f,%.0f %.0fx%.0f", i, items[i].windowID,
               items[i].frame.origin.x, items[i].frame.origin.y, items[i].frame.size.width,
               items[i].frame.size.height);

    LogVisibleMode();
    if (cb->didBegin) cb->didBegin(s, cb->info);
    FlushDirty(s);
    ScheduleTick(s, s->beginTime);
    return s;
}
