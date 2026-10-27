//
//  Tweak.m
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// Live clones of windows. WXFCAContextRetriever says which CAContext an application window is
// drawn into; a clone is a window of the tweak's own bound to that same context, so it shows the
// application's live content next to the original without touching the original.
//
//   Control + Option + Command + C, with the cursor over a window: spawns a clone of it beside it;
//     over a clone, removes that clone.
//   Control + Option + Command + R removes every clone.
//
// The framework only reports the ids. The window is made here, from what docs/cacontext-internals.md
// records: CGXWindow::new_window(NULL, 5, region, 6145) as WS::create_shield_window_common makes
// one, then WSWindowBindRemoteCAClientContext, which is what _XCreateWindow does for an
// application's window. WindowServer does not repaint a window that only shows somebody else's
// commits (the source's commits invalidate the source's region), so a 60 Hz pulse invalidates each
// clone's region itself.

#include <WindowServerFramework/WindowServerFramework.h>
#include <WindowServerFramework/WXFEvent.h>
#include <WindowServerFramework/WXFMisc.h>
#include <WindowServerFramework/WXFCAContextRetriever.h>
#include <dlfcn.h>
#include <os/log.h>

enum { kVKR = 15, kVKC = 8 };
enum { kWindowTypeCA = 5, kCloneFlags = 6145 };

static WXFCAContextRetrieverRef gRetriever;

// --- Server functions -----------------------------------------------------------------------
typedef CGXWindow *(*NewWindowFn)(CGXConnection *connection, int type, const void *region, int flags);
typedef void (*BindFn)(CGXWindow *window, uint32_t contextID);
typedef void (*ReleaseFn)(CGXWindow *window);
typedef void (*UpdateWindowFn)(CGXConnection *connection, CGXWindow *window);
typedef const void *(*RegionFn)(CGRect rect);

static NewWindowFn gNewWindow;
static BindFn gBind;
static ReleaseFn gRelease;
static UpdateWindowFn gUpdateWindow;
static RegionFn gRegionWithRect;

static bool ResolveSymbols(void) {
    static bool tried, ok;
    if (tried) return ok;
    tried = true;
    gNewWindow = (NewWindowFn)WXFResolveServerSymbol(
        "__ZN9CGXWindow10new_windowEP13CGXConnection14CGSBackingTypeP15CGSRegionObjecti");
    gBind = (BindFn)WXFResolveServerSymbol("_WSWindowBindRemoteCAClientContext");
    gRelease = (ReleaseFn)WXFResolveServerSymbol("_WSSystemWindowRelease");
    gUpdateWindow = (UpdateWindowFn)WXFResolveServerSymbol("_updateWindow");
    gRegionWithRect = (RegionFn)dlsym(RTLD_DEFAULT, "CGRegionCreateWithRect");
    ok = gNewWindow && gBind && gRelease && gUpdateWindow && gRegionWithRect &&
         WXFMiscIsAvailable(WXFMiscFeatureCore | WXFMiscFeatureDisplays);
    os_log(OS_LOG_DEFAULT, "WXF cacontext example: symbols new_window %p bind %p release %p update %p region %p -> %d",
           gNewWindow, gBind, gRelease, gUpdateWindow, gRegionWithRect, ok);
    return ok;
}

// --- Contexts -------------------------------------------------------------------------------
static uint32_t ContextForWindow(uint32_t windowID) {
    uint32_t result = 0;
    CFDictionaryRef all = WXFCAContextRetrieverObtainContexts(gRetriever);
    if (!all) return 0;
    int64_t key = windowID, value = 0;
    CFNumberRef k = CFNumberCreate(NULL, kCFNumberSInt64Type, &key);
    CFNumberRef v = k ? CFDictionaryGetValue(all, k) : NULL;
    if (v && CFNumberGetValue(v, kCFNumberSInt64Type, &value)) result = (uint32_t)value;
    if (k) CFRelease(k);
    CFRelease(all);
    return result;
}

// --- Clones ---------------------------------------------------------------------------------
typedef struct {
    uint32_t   windowID;
    CGXWindow *window;             // only dereferenced after WXFWindowFromID confirms it is alive
    uint32_t   sourceID;
} Clone;

#define MAX_CLONES 16
static Clone gClones[MAX_CLONES];
static int gCloneCount;

static int FindClone(uint32_t windowID) {
    for (int i = 0; i < gCloneCount; i++)
        if (gClones[i].windowID == windowID) return i;
    return -1;
}

// The front-most ordinary window (level 0, as Exposé counts them) under the cursor that either has a
// context or is one of our clones, or 0. Windows at other levels are skipped: the Dock and other
// overlays have contexts and cover the screen. Every window that contains the cursor is logged, so a
// wrong pick can be read from the log.
static uint32_t WindowUnderCursor(void) {
    CGPoint cursor;
    if (!WXFGetCursorLocation(&cursor)) return 0;
    long count = 0;
    CGXWindow *cursorWindow = NULL;
    CGXWindow **list = WXFCopyWindowList(WXFWindowListVisible, &count, &cursorWindow);
    if (!list) return 0;
    uint32_t found = 0;
    os_log(OS_LOG_DEFAULT, "WXF cacontext example: cursor (%.0f, %.0f), %ld windows", cursor.x, cursor.y, count);
    for (long i = 0; i < count; i++) {
        CGXWindow *w = list[i];
        if (!w || w == cursorWindow) continue;
        CGRect frame = WXFWindowGetFrame(w);
        if (!CGRectContainsPoint(frame, cursor)) continue;
        uint32_t context = ContextForWindow(w->window_id);
        bool pick = !found && w->level == 0 && (context || FindClone(w->window_id) >= 0);
        os_log(OS_LOG_DEFAULT, "WXF cacontext example:   [%ld] window %u level %d type %u context %u frame (%.0f, %.0f %.0fx%.0f)%s",
               i, w->window_id, w->level, w->window_type, context,
               frame.origin.x, frame.origin.y, frame.size.width, frame.size.height, pick ? " <- picked" : "");
        if (pick) found = w->window_id;
    }
    free(list);
    return found;
}

// Beside the source: to its right if that is on the display, else to its left, else offset down
// and right. Whole points, like the server places windows.
static CGRect ClonePlacement(CGXWindow *source) {
    CGRect f = WXFWindowGetFrame(source);
    CGRect bounds = WXFDisplayGetBounds(WXFWindowGetDisplay(source));
    const CGFloat gap = 24;
    CGRect r = CGRectMake(floor(CGRectGetMaxX(f) + gap), floor(f.origin.y), ceil(f.size.width), ceil(f.size.height));
    if (!CGRectIsEmpty(bounds) && CGRectGetMaxX(r) > CGRectGetMaxX(bounds)) {
        r.origin.x = floor(f.origin.x - gap - r.size.width);
        if (r.origin.x < bounds.origin.x) {
            r.origin.x = floor(f.origin.x + 40);
            r.origin.y = floor(f.origin.y + 40);
        }
    }
    return r;
}

static void StartPulse(void);

static void SpawnClone(uint32_t sourceID) {
    CGXWindow *source = WXFWindowFromID(sourceID);
    uint32_t context = ContextForWindow(sourceID);
    if (!source || !context || gCloneCount >= MAX_CLONES || !ResolveSymbols()) {
        os_log(OS_LOG_DEFAULT, "WXF cacontext example: can't clone window %u", sourceID);
        return;
    }
    CGRect frame = ClonePlacement(source);
    if (frame.size.width < 1 || frame.size.height < 1) return;

    // The window is made with no connection, like the shield windows. The framework's Bind hook
    // does not report a window without one, so a clone is not mistaken for an application window.
    const void *region = gRegionWithRect(frame);
    if (!region) return;
    CGXWindow *clone = gNewWindow(NULL, kWindowTypeCA, region, kCloneFlags);
    CFRelease(region);
    if (!clone) {
        os_log(OS_LOG_DEFAULT, "WXF cacontext example: new_window failed");
        return;
    }
    os_log(OS_LOG_DEFAULT, "WXF cacontext example: created window %u type %u level %d, binding context %u",
           clone->window_id, clone->window_type, clone->level, context);
    gBind(clone, context);

    uint32_t wid = clone->window_id, relative = sourceID;
    WXFOrderOp op = WXFOrderAbove;
    WXFOrderWindowList(source->connection, &wid, &op, &relative, 1);

    Clone *c = &gClones[gCloneCount++];
    c->windowID = wid;
    c->window = clone;
    c->sourceID = sourceID;
    StartPulse();
    os_log(OS_LOG_DEFAULT, "WXF cacontext example: clone %u of window %u at (%.0f, %.0f %.0fx%.0f)",
           wid, sourceID, frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
}

// Released a moment after it is ordered out, as the drag code does with its snapshot: the server may
// still have a frame of it in flight.
static void ReleaseLater(void *info, double now) {
    (void)now;
    gRelease((CGXWindow *)info);
}

static void DestroyClone(int index) {
    Clone *c = &gClones[index];
    if (WXFWindowFromID(c->windowID) == c->window) {
        uint32_t wid = c->windowID, relative = 0;
        WXFOrderOp op = WXFOrderOut;
        WXFOrderWindowList(NULL, &wid, &op, &relative, 1);
        WXFScheduleCallback(ReleaseLater, c->window, WXFCurrentTime() + 0.1);
    }
    os_log(OS_LOG_DEFAULT, "WXF cacontext example: clone %u removed", c->windowID);
    gClones[index] = gClones[--gCloneCount];
    gClones[gCloneCount] = (Clone){0};
}

static void DestroyAllClones(void) {
    while (gCloneCount > 0) DestroyClone(gCloneCount - 1);
}

// --- Pulse ----------------------------------------------------------------------------------
// updateWindow(connection, window) invalidates the window's on-screen shape and schedules a display
// update. WindowServer does that for an application's window when the application commits; a clone
// shows somebody else's commits, so it is done here for as long as any clone exists. A clone whose
// source is gone is removed.
static const double kPulseInterval = 1.0 / 60.0;
static bool gPulsing;
static unsigned gTicks;

static void Pulse(void *info, double now) {
    (void)info; (void)now;
    for (int i = gCloneCount - 1; i >= 0; i--) {
        Clone *c = &gClones[i];
        CGXWindow *source = WXFWindowFromID(c->sourceID);
        if (!source) { DestroyClone(i); continue; }
        gUpdateWindow(source->connection, c->window);
    }
    if (gCloneCount == 0) {
        gPulsing = false;
        return;
    }
    if (++gTicks % 600 == 0)
        os_log(OS_LOG_DEFAULT, "WXF cacontext example: pulse %u, %d clones", gTicks, gCloneCount);
    WXFScheduleCallback(Pulse, NULL, WXFCurrentTime() + kPulseInterval);
}

static void StartPulse(void) {
    if (gPulsing) return;
    gPulsing = true;
    WXFScheduleCallback(Pulse, NULL, WXFCurrentTime() + kPulseInterval);
}

// A source that is handed a new context (the application swapped it) has new content, so its
// clones are bound to the new context.
static void NewContext(CGWindowID window, WXF_CAContextID context) {
    for (int i = 0; i < gCloneCount; i++)
        if (gClones[i].sourceID == window && WXFWindowFromID(gClones[i].windowID) == gClones[i].window)
            gBind(gClones[i].window, context);
}

// --- Keys -----------------------------------------------------------------------------------
static WXFEventDisposition HandleKey(WXFEventRef event, void *info) {
    (void)info;
    const uint32_t chord = WXFEventFlagControl | WXFEventFlagOption | WXFEventFlagCommand;
    uint32_t mods = WXFEventGetFlags(event) &
                    (WXFEventFlagShift | WXFEventFlagControl | WXFEventFlagOption | WXFEventFlagCommand);
    uint16_t key = WXFEventGetKeyCode(event);
    if (mods != chord || (key != kVKC && key != kVKR)) return WXFEventDispositionPass;
    // Act on the press and swallow the release, so the app underneath never sees half a chord.
    if (WXFEventGetType(event) != WXFEventTypeKeyDown) return WXFEventDispositionConsume;

    if (key == kVKR) {
        DestroyAllClones();
        return WXFEventDispositionConsume;
    }

    uint32_t window = WindowUnderCursor();
    int clone = window ? FindClone(window) : -1;
    if (!window)
        os_log(OS_LOG_DEFAULT, "WXF cacontext example: no application window under the cursor");
    else if (clone >= 0)
        DestroyClone(clone);
    else
        SpawnClone(window);
    return WXFEventDispositionConsume;
}

__attribute__((visibility("default")))
void LoadFunction(void *gum_interceptor) {
    SetupFramework(gum_interceptor);

    gRetriever = WXFCAContextRetrieverCreate();
    bool registered = gRetriever && WXFCAContextRetrieverRegisterNewContextCallback(gRetriever, NewContext);
    WXFEventHandlerID handler = WXFEventAddHandler(WXFEventTypeKeyDown | WXFEventTypeKeyUp, HandleKey, NULL);
    os_log(OS_LOG_DEFAULT, "WXF cacontext example: loaded, retriever %p, callback %d, key handler %u",
           gRetriever, registered, handler);
}
