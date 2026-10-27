//
//  WXFEvent.m
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// Input events as WindowServer processes them (docs/expose-internals.md, "Events"). Two stages
// are hooked, and between them they see every event once:
//
//   CGXCheckForHotKey          button down/up, key down/up, flags changed, gestures. Runs before
//                              the event is annotated, so a consumed click never focuses or raises
//                              anything, and before the hot key table is consulted.
//   sAnnotatedContinuation     the rest: mouse moved / dragged and scrolling.
//
// Consuming is "do not call the original": stages don't own the event, the poster frees it.

#include <WindowServerFramework/WXFEvent.h>
#include "WXFBase-Private.h"
#include "WXFHooks-Private.h"
#include <pthread.h>
#include <string.h>

// SLSEventRecord offsets (docs/expose-internals.md).
enum {
    kRecType     = 0x08,   // u32
    kRecLocation = 0x10,   // 2 x double
    kRecStamp    = 0x30,   // u64
    kRecFlags    = 0x38,   // u32
    kRecSubtype  = 0x88,   // i32, system defined events
    kRecScrollLine  = 0x88, // i16 axis1, i16 axis2, i16 axis3 (create_scroll_wheel_event)
    kRecScrollFixed = 0x90, // i32 16.16 lines: axis1, axis2, axis3
    kRecKeyCode  = 0x90,   // u16
    kRecButton   = 0x91,   // u8
    kRecHotKey   = 0xa4,   // u32
    kRecPressed  = 0xa8,   // u32
    kRecPhase    = 0x96,   // u8, gestures (IOHIDEventGetPhase)
    kRecSwipeMotion   = 0xa8,  // u32, dock swipes (IOHID DockSwipe motion)
    kRecSwipeProgress = 0xb0,  // float, dock swipes
};
enum { kSymbolicHotKeySubtype = 24 };

struct __WXFEvent {
    WXFBase base;
    const uint8_t *record;
    uint32_t raw;
    WXFEventType type;
};

#define RECORD(T, event, off) (*(const T *)((event)->record + (off)))

static WXFEventType TypeFor(const uint8_t *rec, uint32_t raw) {
    switch (raw) {
        case 1: case 3: case 25:        return WXFEventTypeMouseDown;
        case 2: case 4: case 26:        return WXFEventTypeMouseUp;
        case 5:                         return WXFEventTypeMouseMoved;
        case 6: case 7: case 27:        return WXFEventTypeMouseDragged;
        case 10:                        return WXFEventTypeKeyDown;
        case 11:                        return WXFEventTypeKeyUp;
        case 12:                        return WXFEventTypeFlagsChanged;
        case 22:                        return WXFEventTypeScrollWheel;
        case 30:                        return WXFEventTypeDockSwipe;
        case 28: case 31:               return WXFEventTypeGesture;
        case 29:
            return *(const int32_t *)(rec + kRecSubtype) == kSymbolicHotKeySubtype
                 ? WXFEventTypeSymbolicHotKey : WXFEventTypeGesture;
        default:                        return 0;
    }
}

// Which hook an event is delivered through: the same classification, so no event is offered twice.
static bool SeenByCheckForHotKey(uint32_t raw) {
    switch (raw) {
        case 1: case 2: case 3: case 4: case 25: case 26:
        case 10: case 11: case 12:
        case 29: case 30: case 31:
            return true;
        default:
            return false;
    }
}

// --- Handlers -------------------------------------------------------------------------------
#define MAX_HANDLERS 64
static struct {
    WXFEventHandlerID id;
    uint32_t mask;
    WXFEventCallback cb;
    void *userInfo;
} gHandlers[MAX_HANDLERS];
static int gHandlerCount;   // newest last
static WXFEventHandlerID gNextHandlerID = 1;
static pthread_mutex_t gHandlerLock = PTHREAD_MUTEX_INITIALIZER;

WXFEventHandlerID WXFEventAddHandler(uint32_t typeMask, WXFEventCallback callback, void *userInfo) {
    if (!callback || !(typeMask & WXFEventTypeAll)) return WXFEventHandlerIDInvalid;
    // Both stages, but a missing one only costs the events it carries.
    bool keys = WXFHooksInstall(WXFHookGroupEventKeys);
    bool pointer = WXFHooksInstall(WXFHookGroupEventPointer);
    if (!keys && !pointer) return WXFEventHandlerIDInvalid;

    WXFEventHandlerID id = WXFEventHandlerIDInvalid;
    pthread_mutex_lock(&gHandlerLock);
    if (gHandlerCount < MAX_HANDLERS) {
        id = gNextHandlerID++;
        gHandlers[gHandlerCount].id = id;
        gHandlers[gHandlerCount].mask = typeMask;
        gHandlers[gHandlerCount].cb = callback;
        gHandlers[gHandlerCount].userInfo = userInfo;
        gHandlerCount++;
    }
    pthread_mutex_unlock(&gHandlerLock);
    return id;
}

bool WXFEventRemoveHandler(WXFEventHandlerID handler) {
    bool found = false;
    pthread_mutex_lock(&gHandlerLock);
    for (int i = 0; i < gHandlerCount; i++) {
        if (gHandlers[i].id != handler) continue;
        memmove(&gHandlers[i], &gHandlers[i + 1], (gHandlerCount - i - 1) * sizeof gHandlers[0]);
        gHandlerCount--;
        found = true;
        break;
    }
    pthread_mutex_unlock(&gHandlerLock);
    return found;
}

// --- Dispatch -------------------------------------------------------------------------------
static const WXFClass kEventClass = {
    .name = "WXFEvent",
    .destructor = NULL,
    .equal = NULL,
};

static struct __WXFEvent *gEvent;
static pthread_once_t gEventOnce = PTHREAD_ONCE_INIT;

static void RegisterEventClass(void) {
    WXFTypeID id = WXFRegisterClass(&kEventClass);
    gEvent = (struct __WXFEvent *)WXFCreateInstance(id, sizeof *gEvent);
    WXFMakeImmortal(gEvent);
}

// The last event offered, so an event that reaches a stage twice is only offered once.
static struct { const uint8_t *record; uint64_t stamp; uint32_t raw; bool consumed; } gLast;

// Returns true if a handler consumed the event.
static bool Dispatch(const void *record) {
    if (!record) return false;
    const uint8_t *rec = record;
    uint32_t raw = *(const uint32_t *)(rec + kRecType);
    WXFEventType type = TypeFor(rec, raw);
    if (!type) return false;

    uint64_t stamp = *(const uint64_t *)(rec + kRecStamp);
    if (gLast.record == rec && gLast.stamp == stamp && gLast.raw == raw)
        return gLast.consumed;

    pthread_once(&gEventOnce, RegisterEventClass);
    if (!gEvent) return false;

    // Copy the table: a handler is allowed to add or remove handlers.
    typeof(gHandlers) copy;
    int n;
    pthread_mutex_lock(&gHandlerLock);
    n = gHandlerCount;
    memcpy(copy, gHandlers, n * sizeof copy[0]);
    pthread_mutex_unlock(&gHandlerLock);

    struct __WXFEvent *saved = gEvent;
    struct __WXFEvent ctx = *saved;
    ctx.record = rec;
    ctx.raw = raw;
    ctx.type = type;

    bool consumed = false;
    for (int i = n - 1; i >= 0 && !consumed; i--) {
        if (!(copy[i].mask & type)) continue;
        consumed = copy[i].cb(&ctx, copy[i].userInfo) == WXFEventDispositionConsume;
    }

    gLast.record = rec;
    gLast.stamp = stamp;
    gLast.raw = raw;
    gLast.consumed = consumed;
    return consumed;
}

// --- Hooks (installed from WXFHooks.c) ------------------------------------------------------
int64_t (*WXFEventOrig_CheckForHotKey)(const void *record);
void    (*WXFEventOrig_Annotated)(void *record, void *context);

// Returning 0 is how CGXCheckForHotKey says "a hot key took this event": the processors that call
// it then drop it (mouse) or give it no destination (keys).
int64_t WXFEventHook_CheckForHotKey(const void *record) {
    if (record && SeenByCheckForHotKey(*(const uint32_t *)((const uint8_t *)record + kRecType)) &&
        Dispatch(record))
        return 0;
    return WXFEventOrig_CheckForHotKey(record);
}

void WXFEventHook_Annotated(void *record, void *context) {
    if (record) {
        uint32_t raw = *(const uint32_t *)((const uint8_t *)record + kRecType);
        if (!SeenByCheckForHotKey(raw) && Dispatch(record))
            return;
    }
    WXFEventOrig_Annotated(record, context);
}

// --- Accessors ------------------------------------------------------------------------------
WXFEventType WXFEventGetType(WXFEventRef e) { return e->type; }
uint32_t WXFEventGetRawType(WXFEventRef e) { return e->raw; }

CGPoint WXFEventGetLocation(WXFEventRef e) {
    return CGPointMake(RECORD(double, e, kRecLocation), RECORD(double, e, kRecLocation + 8));
}

uint32_t WXFEventGetFlags(WXFEventRef e) { return RECORD(uint32_t, e, kRecFlags) & WXFEventFlagMask; }

uint16_t WXFEventGetKeyCode(WXFEventRef e) {
    return (e->type & (WXFEventTypeKeyDown | WXFEventTypeKeyUp)) ? RECORD(uint16_t, e, kRecKeyCode) : 0;
}

uint32_t WXFEventGetButton(WXFEventRef e) {
    if (!(e->type & (WXFEventTypeMouseDown | WXFEventTypeMouseUp | WXFEventTypeMouseDragged))) return 0;
    switch (e->raw) {
        case 1: case 2: case 6: return 0;
        case 3: case 4: case 7: return 1;
        default:                return RECORD(uint8_t, e, kRecButton);
    }
}

CGPoint WXFEventGetScrollDelta(WXFEventRef e) {
    if (e->type != WXFEventTypeScrollWheel) return CGPointZero;
    // The 16.16 field holds fractional lines (trackpads, accelerated wheels); the s16 field is the
    // same amount rounded away from zero, used only if the fixed one is empty.
    int32_t fixed1 = RECORD(int32_t, e, kRecScrollFixed), fixed2 = RECORD(int32_t, e, kRecScrollFixed + 4);
    int16_t line1 = RECORD(int16_t, e, kRecScrollLine), line2 = RECORD(int16_t, e, kRecScrollLine + 2);
    return CGPointMake(fixed2 ? fixed2 / 65536.0 : line2, fixed1 ? fixed1 / 65536.0 : line1);
}

WXFEventPhase WXFEventGetPhase(WXFEventRef e) {
    if (e->raw < 29 || e->raw > 31 || e->type == WXFEventTypeSymbolicHotKey) return WXFEventPhaseNone;
    return (WXFEventPhase)RECORD(uint8_t, e, kRecPhase);
}

bool WXFEventGetDockSwipe(WXFEventRef e, WXFEventSwipeMotion *motion, double *progress) {
    if (e->type != WXFEventTypeDockSwipe) return false;
    if (motion) *motion = (WXFEventSwipeMotion)RECORD(uint32_t, e, kRecSwipeMotion);
    if (progress) *progress = RECORD(float, e, kRecSwipeProgress);
    return true;
}

uint32_t WXFEventGetSymbolicHotKey(WXFEventRef e, bool *pressed) {
    if (e->type != WXFEventTypeSymbolicHotKey) return 0;
    if (pressed) *pressed = RECORD(uint32_t, e, kRecPressed) != 0;
    return RECORD(uint32_t, e, kRecHotKey);
}
