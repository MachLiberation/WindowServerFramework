//
//  WXFMisc.m
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// Mid-level helpers shared by the features and exposed to tweaks (WXFMisc.h). Everything here was
// first written inside WXFExpose.m or WXFDrag.m; offsets and ABI are unchanged, see
// docs/expose-internals.md for how the session and workspace structures were read.

#include <WindowServerFramework/WXFMisc.h>
#include <dlfcn.h>
#include <math.h>
#include <os/log.h>
#include <pthread.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

// --- Symbols --------------------------------------------------------------------------------
typedef CGXWindow *(*WindowByIDFn)(uint32_t);
typedef CGRect (*WindowRectFn)(CGXWindow *);
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
typedef void (*MoveWindowListFn)(CGXConnection *, const uint32_t *, unsigned, uint64_t, float, float);
typedef CGXConnection *(*ForegroundConnectionFn)(void);
typedef int64_t (*GetConnectionPSNFn)(uint64_t connectionID, uint64_t *psn);
typedef int64_t (*SetFrontProcessFn)(uint64_t psn, const void *event, uint32_t flags);
typedef void (*DidChangeOrderFn)(int type, void *data, uint32_t length, void *ctx);
typedef void *(*GetWorkspaceDataFn)(void *session);
typedef void (*UpdateVisibleWorkspaceOrderingFn)(void);

static WindowByIDFn gWindowByID;
static WindowRectFn gFrameBounds, gClippedFrameBounds, gScreenRect;
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
static MoveWindowListFn gMoveWindowList;
static ForegroundConnectionFn gForegroundConnection;
static GetConnectionPSNFn gGetConnectionPSN;
static SetFrontProcessFn gSetFrontProcess;
static DidChangeOrderFn gDidChangeOrder;
static GetWorkspaceDataFn gGetWorkspaceData;
static UpdateVisibleWorkspaceOrderingFn gUpdateVisibleWorkspaceOrdering;
static void *const *gSessionControlRef;     // the data symbol ___sessionControlRef (3 underscores)

static os_log_t Log(void) {
    static os_log_t log;
    if (!log) log = os_log_create("com.windowserverframework", "misc");
    return log;
}

// One row per function. A feature is available when every row tagged with it resolved.
typedef struct {
    const char *name;
    void      **slot;
    uint32_t    feature;
} SymbolRow;

#define ROW(NAME, SLOT, FEATURE) { NAME, (void **)&SLOT, FEATURE }

static const SymbolRow kSymbols[] = {
    ROW("__ZL12window_by_idj",                    gWindowByID,        WXFMiscFeatureCore),
    ROW("_WSCurrentUntransformedWindowBounds",    gFrameBounds,       WXFMiscFeatureCore),
    ROW("_WSScheduleCallbackOnCurrentSession",    gSchedule,          WXFMiscFeatureCore),
    ROW("__ZN9CGXWindow13update_alphasEP13CGXConnectionfffb", gUpdateAlphas, WXFMiscFeatureCore),
    ROW("__ZL36CGXOrderWindowListSpaceSwitchOptionsP13CGXConnectionPKjPK10CGSOrderOpS2_jb",
                                                  gOrderWindowList,   WXFMiscFeatureCore),
    // Not a hard requirement: the framework updates the window when it can.
    ROW("_updateWindow",                          gUpdateWindow,      0),
    ROW("_CGXGetCurrentCursorLocation",           gGetCursor,         WXFMiscFeatureCursor),
    ROW("_PKGWindowGetDisplay",                   gWindowGetDisplay,  WXFMiscFeatureDisplays),
    ROW("_PKGDisplayBestMatchingPoint",           gDisplayForPoint,   WXFMiscFeatureDisplays),
    ROW("_PKGDisplayGetMain",                     gMainDisplay,       WXFMiscFeatureDisplays),
    ROW("_PKGDisplayGetBounds",                   gDisplayBounds,     WXFMiscFeatureDisplays),
    ROW("_CGXSetWindowTransform3DList",           gSetTransform3D,    WXFMiscFeatureTransform),
    ROW("_CGXMoveWindowList",                     gMoveWindowList,    WXFMiscFeatureMove),
    ROW("__ZN9CGXWindow20clipped_frame_boundsEv", gClippedFrameBounds, WXFMiscFeatureShape),
    ROW("__ZNK9CGXWindow11screen_rectEv",         gScreenRect,        WXFMiscFeatureShape),
    // Activation: CPXSetFrontProcess(psn, event, flags), as PKGSetFrontProcessForCurrentSpaceSwitch
    // calls it. The front process's connection is what _WSWindowHitTest compares with
    // window->connection.
    ROW("_CPXGetConnectionPSN",                   gGetConnectionPSN,  WXFMiscFeatureActivation),
    ROW("_CPXSetFrontProcess",                    gSetFrontProcess,   WXFMiscFeatureActivation),
    ROW("_WSForegroundProcessConnection",         gForegroundConnection, WXFMiscFeatureActivation),
    // Ordering: only used to make the renderer follow, each is skipped if it is missing.
    ROW("__ZL38update_visible_workspace_ordering_infov", gUpdateVisibleWorkspaceOrdering, 0),
    ROW("_CGSessionGetWorkspaceData",             gGetWorkspaceData,  0),
    ROW("__ZL39spaces_did_change_window_order_callback19CGSNotificationTypePvjS0_",
                                                  gDidChangeOrder,    WXFMiscFeatureReorder),
};

static uint32_t gMissing;       // features with a symbol that wasn't found, set by Resolve

static void Resolve(void) {
    for (size_t i = 0; i < sizeof kSymbols / sizeof kSymbols[0]; i++) {
        void *symbol = WXFResolveServerSymbol(kSymbols[i].name);
        *kSymbols[i].slot = symbol;
        if (!symbol) gMissing |= kSymbols[i].feature;
    }
    // The clock is exported; the server's own copy is the fallback.
    gRealTime = (RealTimeFn)dlsym(RTLD_DEFAULT, "SLSCurrentRealTime");
    if (!gRealTime) gRealTime = (RealTimeFn)WXFResolveServerSymbol("_SLSCurrentRealTime");
    if (!gRealTime) gMissing |= WXFMiscFeatureCore;
    // Where the session lives; the control block is reached through it.
    gSessionControlRef = (void *const *)WXFResolveServerData("___sessionControlRef");
    if (!gSessionControlRef) gMissing |= WXFMiscFeatureWindowList | WXFMiscFeatureReorder;
}

// Resolution waits for SetupFramework (nothing resolves before it), so it is retried until then.
static bool EnsureResolved(void) {
    static bool resolved;
    if (resolved) return true;
    if (!WXFIsFrameworkSetUp()) return false;
    Resolve();
    resolved = true;
    return true;
}

bool WXFMiscIsAvailable(uint32_t features) {
    if (!EnsureResolved()) return false;
    uint32_t missing = gMissing & features;
    static uint32_t reported;
    if (missing & ~reported) {
        reported |= missing;
        char names[600] = "";
        int len = 0;
        for (size_t i = 0; i < sizeof kSymbols / sizeof kSymbols[0] && len < (int)sizeof names - 80; i++)
            if ((kSymbols[i].feature & missing) && !*kSymbols[i].slot)
                len += snprintf(names + len, sizeof names - len, "%s ", kSymbols[i].name);
        os_log_error(Log(), "WXF misc: features %#x unavailable, missing: %s%s", missing, names,
                     gSessionControlRef || !(missing & WXFMiscFeatureWindowList) ? "" : "___sessionControlRef ");
    }
    return missing == 0;
}

// Wrappers call this so the first use resolves, even if the caller never asked about availability.
#define NEED(...) do { if (!EnsureResolved()) return __VA_ARGS__; } while (0)

// --- Matrices -------------------------------------------------------------------------------
WXFMat4 WXFMat4Identity(void) {
    WXFMat4 r = {{1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0,  0, 0, 0, 1}};
    return r;
}

WXFMat4 WXFMat4Multiply(WXFMat4 a, WXFMat4 b) {
    WXFMat4 r = {{0}};
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++) {
            double s = 0;
            for (int k = 0; k < 4; k++) s += a.m[i * 4 + k] * b.m[k * 4 + j];
            r.m[i * 4 + j] = s;
        }
    return r;
}

WXFMat4 WXFMat4MakeTranslation(double x, double y, double z) {
    WXFMat4 r = WXFMat4Identity();
    r.m[12] = x; r.m[13] = y; r.m[14] = z;
    return r;
}

WXFMat4 WXFMat4MakeScale(double x, double y, double z) {
    WXFMat4 r = WXFMat4Identity();
    r.m[0] = x; r.m[5] = y; r.m[10] = z;
    return r;
}

WXFMat4 WXFMat4MakeRotationX(double a) {
    WXFMat4 r = WXFMat4Identity();
    r.m[5] = cos(a);  r.m[6] = sin(a);
    r.m[9] = -sin(a); r.m[10] = cos(a);
    return r;
}

WXFMat4 WXFMat4MakeRotationY(double a) {
    WXFMat4 r = WXFMat4Identity();
    r.m[0] = cos(a);  r.m[2] = -sin(a);
    r.m[8] = sin(a);  r.m[10] = cos(a);
    return r;
}

WXFMat4 WXFMat4MakeRotationZ(double a) {
    WXFMat4 r = WXFMat4Identity();
    r.m[0] = cos(a);  r.m[1] = sin(a);
    r.m[4] = -sin(a); r.m[5] = cos(a);
    return r;
}

bool WXFMat4Invert(WXFMat4 a, WXFMat4 *out) {
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

bool WXFMat4ProjectPoint(const WXFMat4 *m, double x, double y, CGPoint *out) {
    double X = x * m->m[0] + y * m->m[4] + m->m[12];
    double Y = x * m->m[1] + y * m->m[5] + m->m[13];
    double W = x * m->m[3] + y * m->m[7] + m->m[15];
    if (W < 1e-4) return false;
    *out = CGPointMake(X / W, Y / W);
    return true;
}

// WindowServer projects a screen point to the window as (x, y, 0, 1) times the stored matrix, so the
// stored matrix has to be the inverse of the window plane's homography, not of the full 4x4: the
// full inverse would need the screen point's depth, which WindowServer takes as 0 (that skewed
// every rotated card). Dropping the z row and column leaves the plane's 3x3 map; z passes through.
WXFMat4 WXFMat4FlattenToPlane(WXFMat4 m) {
    for (int i = 0; i < 4; i++) {
        m.m[i * 4 + 2] = 0;
        m.m[8 + i] = 0;
    }
    m.m[10] = 1;
    return m;
}

static double Cross(CGPoint a, CGPoint b, CGPoint p) {
    return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x);
}

bool WXFQuadContainsPoint(const CGPoint q[4], CGPoint p) {
    bool neg = false, pos = false;
    for (int i = 0; i < 4; i++) {
        double c = Cross(q[i], q[(i + 1) % 4], p);
        if (c < 0) neg = true;
        if (c > 0) pos = true;
    }
    return !(neg && pos);       // same side of every edge, either winding
}

// --- Clock, cursor, displays ----------------------------------------------------------------
double WXFCurrentTime(void) {
    NEED(0);
    return gRealTime ? gRealTime() : 0;
}

void WXFScheduleCallback(void (*callback)(void *, double), void *info, double when) {
    NEED();
    if (gSchedule) gSchedule(callback, info, when);
}

bool WXFGetCursorLocation(CGPoint *location) {
    NEED(false);
    double p[2] = {0, 0};
    bool ok = gGetCursor && gGetCursor(p) == 0;
    if (location) *location = CGPointMake(p[0], p[1]);
    return ok;
}

WXFDisplayRef WXFDisplayForPoint(CGPoint point) {
    NEED(NULL);
    return gDisplayForPoint ? gDisplayForPoint(point) : NULL;
}

WXFDisplayRef WXFDisplayGetMain(void) {
    NEED(NULL);
    return gMainDisplay ? gMainDisplay() : NULL;
}

CGRect WXFDisplayGetBounds(WXFDisplayRef display) {
    NEED(CGRectZero);
    return display && gDisplayBounds ? gDisplayBounds(display) : CGRectZero;
}

WXFDisplayRef WXFWindowGetDisplay(CGXWindow *window) {
    NEED(NULL);
    return window && gWindowGetDisplay ? gWindowGetDisplay(window) : NULL;
}

// --- Windows --------------------------------------------------------------------------------
CGXWindow *WXFWindowFromID(uint32_t windowID) {
    NEED(NULL);
    return gWindowByID ? gWindowByID(windowID) : NULL;
}

CGRect WXFWindowGetFrame(CGXWindow *window) {
    NEED(CGRectZero);
    return window && gFrameBounds ? gFrameBounds(window) : CGRectZero;
}

CGRect WXFWindowGetClippedFrame(CGXWindow *window) {
    NEED(CGRectZero);
    return window && gClippedFrameBounds ? gClippedFrameBounds(window) : CGRectZero;
}

CGRect WXFWindowGetScreenRect(CGXWindow *window) {
    NEED(CGRectZero);
    return window && gScreenRect ? gScreenRect(window) : CGRectZero;
}

// The connection id of the window's owner, read as pkg_space_switch_for_window_order_top does:
// the presenter connection at +0x40 if there is one, else the connection at +0x30, then +0x50.
// (window+0x50 is not the id; it reads 0.)
uint32_t WXFWindowGetOwnerConnectionID(const CGXWindow *w) {
    if (!w) return 0;
    const char *conn = *(const char *const *)((const char *)w + 0x40);
    if (!conn) conn = (const char *)w->connection;
    return conn ? *(const uint32_t *)(conn + 0x50) : 0;
}

// --- Window list ----------------------------------------------------------------------------
// session = __sessionControlRef+32; its window data (+144) holds the ordered CGXWindow* array
// (+56) and its length (+64); **(session+256) is the cursor window. docs/expose-internals.md.
// The stacking list is the one the ordering code edits (data+32, length data+40, as
// start_order_window and highest_window_at_effective_level do) instead of data+56 / +64.
CGXWindow **WXFCopyWindowList(WXFWindowListKind kind, long *count, CGXWindow **cursorWindow) {
    CGXWindow *cursor = NULL;
    long n0 = 0;
    CGXWindow **result = NULL;
    if (EnsureResolved() && gSessionControlRef) {
        uintptr_t control = (uintptr_t)*gSessionControlRef;
        uintptr_t session = control ? *(uintptr_t *)(control + 32) : 0;
        uintptr_t data = session ? *(uintptr_t *)(session + 144) : 0;
        if (data) {
            bool stacking = kind == WXFWindowListStacking;
            CGXWindow **array = *(CGXWindow ***)(data + (stacking ? 32 : 56));
            int n = *(int *)(data + (stacking ? 40 : 64));
            uintptr_t *cursorRef = *(uintptr_t **)(session + 256);
            if (cursorRef) cursor = (CGXWindow *)*cursorRef;
            if (array && n > 0) {
                CGXWindow **copy = calloc(n, sizeof *copy);
                if (copy) {
                    for (int i = 0; i < n; i++)
                        if (array[i]) copy[n0++] = array[i];
                    result = copy;
                }
            }
        }
    }
    if (count) *count = n0;
    if (cursorWindow) *cursorWindow = cursor;
    return result;
}

// --- Alpha ----------------------------------------------------------------------------------
// The three float alpha factors start at CGXWindow.alpha (+488). For a CoreAnimation-backed
// window, the root layer (CAWindowContent+136, the parent of its "Shadow", "Hosting", "Window" and
// client-content layers) has its opacity set on every ingestion to their product, clamped to
// 0...1 (defenestrator3::ca_window_prep_ingestion_phase), so alpha 0 hides the window and its
// shadow. CGXWindow::update_alphas stores the factors whether or not the window is set up for
// server-side fades (CGXSetWindowListAlpha is gated on that, update_alphas is not), and its commit
// flag bumps the window's change count; _updateWindow then dirties it so the change is picked up
// even if nothing else moves the window.
static const float *AlphaFactors(const CGXWindow *window) {
    return (const float *)((const char *)window + offsetof(CGXWindow, alpha));
}

float WXFWindowGetAlphaFactor(const CGXWindow *window, int index) {
    return window && index >= 0 && index < 3 ? AlphaFactors(window)[index] : 1.0f;
}

void WXFWindowUpdate(CGXWindow *window) {
    NEED();
    if (window && gUpdateWindow) gUpdateWindow(window->connection, window);
}

void WXFWindowSetAlpha(CGXWindow *window, float alpha) {
    NEED();
    if (!window || !gUpdateAlphas) return;
    const float *factors = AlphaFactors(window);
    gUpdateAlphas(window, window->connection, alpha, factors[1], factors[2], true);
    WXFWindowUpdate(window);
}

// --- Transforms -----------------------------------------------------------------------------
// The key the Dock uses for its Exposé transforms (PKGTransactionSetWindowTransform3D).
#define kPlacement 0x30000000u

void WXFWindowSetTransform(CGXWindow *window, const WXFMat4 *stored) {
    NEED();
    if (!window || !stored || !gSetTransform3D) return;
    uint32_t wid = window->window_id, placement = kPlacement;
    gSetTransform3D(window->connection, &wid, &placement, stored->m);
}

bool WXFWindowApplyTransform(CGXWindow *window, WXFMat4 forward) {
    WXFMat4 inverse;
    if (!WXFMat4Invert(WXFMat4FlattenToPlane(forward), &inverse)) return false;
    WXFWindowSetTransform(window, &inverse);
    return true;
}

void WXFWindowResetTransform(CGXWindow *window) {
    WXFMat4 identity = WXFMat4Identity();
    WXFWindowSetTransform(window, &identity);
}

// --- Moving and ordering --------------------------------------------------------------------
void WXFWindowMoveBy(CGXWindow *window, float dx, float dy) {
    NEED();
    if (!window || !gMoveWindowList) return;
    uint32_t wid = window->window_id;
    gMoveWindowList(window->connection, &wid, 1, 0, dx, dy);
}

void WXFOrderWindowList(CGXConnection *connection, const uint32_t *windowIDs, const WXFOrderOp *ops,
                        const uint32_t *relativeIDs, unsigned count) {
    NEED();
    if (!gOrderWindowList || !count) return;
    _Static_assert(sizeof(WXFOrderOp) == sizeof(int32_t), "WXFOrderOp is passed as CGSOrderOp");
    gOrderWindowList(connection, windowIDs, (const int32_t *)ops, relativeIDs, count, false);
}

void WXFOrderWindow(uint32_t windowID, WXFOrderOp op, uint32_t relativeID) {
    CGXWindow *window = WXFWindowFromID(windowID);
    if (window) WXFOrderWindowList(window->connection, &windowID, &op, &relativeID, 1);
}

// Ordering edits the window list (data+32) but the renderer draws from the visible window list
// (data+56). WindowServer builds that one in one of two ways (see IsWMOnly): by merging the
// workspaces, whose order comes from the data+32 positions, or from the window manager's own
// visibility list (WorkspaceData+64). Reordering windows that stay ordered in does not run either
// rebuild, so after ordering `ids` (front first) we make both follow, then run the handler for
// notification 1002 (spaces_did_change_window_order_callback), which rebuilds the visible list.
static bool IsWMOnly(uintptr_t *workspaceData) {
    uintptr_t control = gSessionControlRef ? (uintptr_t)*gSessionControlRef : 0;
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
    CGXWindow **visible = WXFCopyWindowList(WXFWindowListVisible, &count, &cursor);
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

void WXFRebuildVisibleOrder(const uint32_t *ids, long n) {
    NEED();
    if (!gSessionControlRef) return;
    uintptr_t ws = 0;
    if (IsWMOnly(&ws) && ws) SetVisibilityListOrder(ws, ids, n);
    if (ws) SetOverrideMapOrder(ws, ids, n);
    if (gUpdateVisibleWorkspaceOrdering) gUpdateVisibleWorkspaceOrdering();     // sort the workspaces
    if (gDidChangeOrder) gDidChangeOrder(1002, NULL, 0, NULL);
}

// Which way WindowServer builds the visible list: from the window manager's visibility list
// (WorkspaceData+64, "wmonly") when session+176 has +24 bit 7 and +20 set, else by merging the
// workspaces.
void WXFLogVisibleOrderMode(void) {
    NEED();
    uintptr_t control = gSessionControlRef ? (uintptr_t)*gSessionControlRef : 0;
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
    os_log(Log(), "WXF misc: visible list mode %s (flags byte24 %02x dword20 %u), override list %ld: %s",
           wm ? "wmonly" : "merging", flags ? *(uint8_t *)(flags + 24) : 0, flags ? *(uint32_t *)(flags + 20) : 0, n, ids);
}

// --- Applications ---------------------------------------------------------------------------
CGXConnection *WXFForegroundConnection(void) {
    NEED(NULL);
    return gForegroundConnection ? gForegroundConnection() : NULL;
}

bool WXFActivateWindowOwner(const CGXWindow *window) {
    NEED(false);
    if (!window || !gGetConnectionPSN || !gSetFrontProcess) return false;
    uint64_t psn = 0;
    uint32_t cid = WXFWindowGetOwnerConnectionID(window);
    int64_t err = gGetConnectionPSN(cid, &psn);
    if (err == 0) err = gSetFrontProcess(psn, NULL, 0);
    os_log(Log(), "WXF misc: activate connection %u psn %llx: %lld", cid, (unsigned long long)psn, (long long)err);
    return err == 0;
}
