//
//  WXFCard.m
//  WindowServerFramework
//
//  Created by bedtime on 10/28/26.
//
// The display "card". Connectors come from QuartzCore (-[CAWindowServer displays]); the
// SkyLight half (modes, the hotplug state machine, presenting) comes from WS::Displays::CAWSManager's
// hardware list. Everything below is written from docs/display-internals.md:
//
//   * CAManager() (a function-local static, __ZZN2WS8Displays9CAManagerEvE7manager) is the
//     CAWSManager. It is read, never called: calling CAManager() before SkyLight has made it would
//     construct it early.
//   * CAWSManager+1384 is an os_unfair_lock over the vector<shared_ptr<Display>> at +1392 of the
//     hardware displays; each element is {SLCADisplay *, control block} (16 bytes), and
//     SLCADisplay+808 is its display id (vtable +40, display_id).
//   * SLCADisplay+1880/+1888 is the ordinary vector<Mode> (184 bytes per Mode); +1928 is a copy of
//     the current Mode.
//   * process_hotplug_event(manager, displayId, state, reason, bool) -> bool is where a connect or
//     disconnect is carried out; inject_hotplug(manager, state, displayId, reason) feeds it.
//
// Offsets were read from the OS build in docs/display-internals.md. They are checked for
// plausibility before use, but a different build needs them re-read.

#include <WindowServerFramework/WXFCard.h>
#include <WindowServerFramework/WXFBase.h>
#include <WindowServerFramework/WXFMisc.h>
#include "WXFHooks-Private.h"
#import <Foundation/Foundation.h>
#include <os/lock.h>
#include <os/log.h>
#include <stdlib.h>
#include <string.h>

// --- QuartzCore (public enough to message, not to import) ------------------------------------
@protocol WXFCAServerClass <NSObject>
+ (id)serverIfRunning;
@end

@protocol WXFCAServer <NSObject>
- (NSArray *)displays;
@end

@protocol WXFCADisplay <NSObject>
- (unsigned)displayId;
- (NSInteger)displayType;
- (NSString *)name;
- (NSString *)uniqueId;
- (CGRect)bounds;
- (CGSize)nativeSize;
- (CGSize)panelPhysicalSize;
- (BOOL)enabled;
- (void)setEnabled:(BOOL)enabled;
- (BOOL)isBlanked;
- (void)setBlanked:(BOOL)blanked;
- (IOSurfaceRef)displayedSurface;
- (unsigned)framebufferFormat;
- (BOOL)disablesUpdates;
- (void)setDisablesUpdates:(BOOL)disables;
- (unsigned long long)previousVBL;
- (unsigned long long)vblDelta;
@end

static NSArray *CADisplays(void) {
    Class cls = NSClassFromString(@"CAWindowServer");
    if (!cls || ![cls respondsToSelector:@selector(serverIfRunning)]) return nil;
    id<WXFCAServer> server = [(Class<WXFCAServerClass>)cls serverIfRunning];
    return [server respondsToSelector:@selector(displays)] ? [server displays] : nil;
}

static id<WXFCADisplay> CADisplayForID(WXFConnectorID connector) {
    for (id<WXFCADisplay> d in CADisplays())
        if ([d displayId] == connector) return d;
    return nil;
}

// --- SkyLight's hardware display list ---------------------------------------------------------
#define MANAGER_HARDWARE_LOCK   1384
#define MANAGER_HARDWARE_VECTOR 1392
#define DISPLAY_ID              808
#define DISPLAY_MODES_BEGIN     1880
#define DISPLAY_MODES_END       1888
#define DISPLAY_CURRENT_MODE    1928
#define DISPLAY_PRESENT_FLAGS   2300
#define MANAGER_CONFIG_ENGINE   952     // a configuration_engine embedded in the manager
#define ENGINE_FLAGS            116     // bit 0: a configuration is open (begin without commit)
#define MODE_SIZE               184
#define MODE_MAX_COUNT          4096

#define MODE_ID           0
#define MODE_WIDTH        4
#define MODE_HEIGHT       8
#define MODE_SCALE        20
#define MODE_POINT_WIDTH  24
#define MODE_POINT_HEIGHT 28
#define MODE_REFRESH      56
#define MODE_FLAGS        124
#define MODE_FLAG_DEFAULT 4

static inline uint8_t *At(void *base, size_t offset) { return (uint8_t *)base + offset; }

static void *Manager(void) {
    static void *const *slot;
    if (!slot) slot = (void *const *)WXFResolveServerData("__ZZN2WS8Displays9CAManagerEvE7manager");
    return slot ? *slot : NULL;
}

// Calls `block` with the SLCADisplay for `connector` while the hardware list is locked; returns
// whether there was one. The list holds shared_ptrs, so the object stays alive for the call.
static bool WithManagedDisplay(WXFConnectorID connector, void (^block)(void *display)) {
    uint8_t *manager = Manager();
    if (!manager) return false;
    os_unfair_lock_t lock = (os_unfair_lock_t)At(manager, MANAGER_HARDWARE_LOCK);
    bool found = false;
    os_unfair_lock_lock(lock);
    uint8_t **begin = *(uint8_t ***)At(manager, MANAGER_HARDWARE_VECTOR);
    uint8_t **end   = *(uint8_t ***)At(manager, MANAGER_HARDWARE_VECTOR + 8);
    if (begin && end >= begin && (size_t)(end - begin) < 1024)
        for (uint8_t **e = begin; e < end; e += 2)    // {object, control block}
            if (*e && *(uint32_t *)At(*e, DISPLAY_ID) == connector) {
                block(*e);
                found = true;
                break;
            }
    os_unfair_lock_unlock(lock);
    return found;
}

// The ordinary mode list of a display object, or false if it doesn't look like one.
static bool ModeList(void *display, uint8_t **begin, size_t *count) {
    uint8_t *b = *(uint8_t **)At(display, DISPLAY_MODES_BEGIN);
    uint8_t *e = *(uint8_t **)At(display, DISPLAY_MODES_END);
    if (!b || e < b || (size_t)(e - b) % MODE_SIZE) return false;
    size_t n = (size_t)(e - b) / MODE_SIZE;
    if (n > MODE_MAX_COUNT) return false;
    *begin = b;
    *count = n;
    return true;
}

// --- Availability and connectors --------------------------------------------------------------

bool WXFCardAvailable(void) {
    return CADisplays() != nil && Manager() != NULL;
}

static WXFConnectorType ConnectorType(NSInteger raw) {
    switch (raw) {
        case 0: return WXFConnectorTypeInternal;
        case 1: return WXFConnectorTypeExternal;
        case 3: return WXFConnectorTypeVirtual;
        case 4: return WXFConnectorTypeDFR;
        default: return WXFConnectorTypeUnknown;
    }
}

static void CopyString(char *out, size_t size, NSString *s) {
    out[0] = 0;
    if (s) strlcpy(out, s.UTF8String ?: "", size);
}

static void FillConnector(id<WXFCADisplay> d, WXFConnectorInfo *info) {
    memset(info, 0, sizeof *info);
    info->id           = [d displayId];
    info->type         = ConnectorType([d displayType]);
    info->enabled      = [d enabled];
    info->blanked      = [d isBlanked];
    NSString *unique   = [d uniqueId];
    info->hasUniqueID  = unique != nil;
    info->bounds       = [d bounds];
    info->nativeSize   = [d nativeSize];
    info->physicalSize = [d panelPhysicalSize];
    CopyString(info->name, sizeof info->name, [d name]);
    CopyString(info->uniqueID, sizeof info->uniqueID, unique);
    WithManagedDisplay(info->id, ^(void *display) {
        uint8_t *begin; size_t count;
        if (!ModeList(display, &begin, &count)) return;
        info->managed       = true;
        info->modeCount     = (uint32_t)count;
        info->currentModeID = *(uint32_t *)At(display, DISPLAY_CURRENT_MODE + MODE_ID);
    });
}

size_t WXFCardCopyConnectors(WXFConnectorInfo *out, size_t capacity) {
    NSArray *displays = CADisplays();
    size_t n = 0;
    for (id<WXFCADisplay> d in displays) {
        if (out && n < capacity) FillConnector(d, &out[n]);
        n++;
    }
    return n;
}

bool WXFCardGetConnector(WXFConnectorID connector, WXFConnectorInfo *out) {
    id<WXFCADisplay> d = CADisplayForID(connector);
    if (!d) return false;
    if (out) FillConnector(d, out);
    return true;
}

size_t WXFCardCopyModes(WXFConnectorID connector, WXFModeInfo *out, size_t capacity) {
    __block size_t total = 0;
    WithManagedDisplay(connector, ^(void *display) {
        uint8_t *begin; size_t count;
        if (!ModeList(display, &begin, &count)) return;
        uint32_t current = *(uint32_t *)At(display, DISPLAY_CURRENT_MODE + MODE_ID);
        total = count;
        for (size_t i = 0; out && i < count && i < capacity; i++) {
            uint8_t *m = begin + i * MODE_SIZE;
            out[i] = (WXFModeInfo){
                .id          = *(uint32_t *)At(m, MODE_ID),
                .width       = *(uint32_t *)At(m, MODE_WIDTH),
                .height      = *(uint32_t *)At(m, MODE_HEIGHT),
                .pointWidth  = *(uint32_t *)At(m, MODE_POINT_WIDTH),
                .pointHeight = *(uint32_t *)At(m, MODE_POINT_HEIGHT),
                .scale       = *(float *)At(m, MODE_SCALE),
                .refreshRate = *(float *)At(m, MODE_REFRESH),
                .isDefault   = (*(uint32_t *)At(m, MODE_FLAGS) & MODE_FLAG_DEFAULT) != 0,
                .isCurrent   = *(uint32_t *)At(m, MODE_ID) == current,
            };
        }
    });
    return total;
}

// --- Modeset ----------------------------------------------------------------------------------

typedef void (*ConfigCurrentModeFn)(void *engine, int displayId, unsigned modeId, bool flag);

typedef struct { WXFConnectorID connector; uint32_t mode; } ModesetRequest;

static bool HasMode(WXFConnectorID connector, uint32_t mode, uint32_t *current) {
    __block bool has = false;
    WithManagedDisplay(connector, ^(void *display) {
        uint8_t *begin; size_t count;
        if (!ModeList(display, &begin, &count)) return;
        if (current) *current = *(uint32_t *)At(display, DISPLAY_CURRENT_MODE + MODE_ID);
        for (size_t i = 0; i < count; i++)
            if (*(uint32_t *)At(begin + i * MODE_SIZE, MODE_ID) == mode) { has = true; break; }
    });
    return has;
}

// configuration_engine::begin asserts that no configuration is open; check the flag it checks.
static bool EngineIdle(void *manager) {
    return (*At(manager, MANAGER_CONFIG_ENGINE + ENGINE_FLAGS) & 1) == 0;
}

static void RunModeset(void *info, double now) {
    (void)now;
    ModesetRequest *request = info;
    static ConfigCurrentModeFn configure;
    if (!configure) configure = WXFResolveServerSymbol("__ZN2WS8Displays20configuration_engine19config_current_modeEijb");
    void *manager = Manager();
    uint32_t current = 0;
    // Looked at again here: the list can change between the call and this callback.
    if (configure && manager && EngineIdle(manager) && HasMode(request->connector, request->mode, &current)
        && current != request->mode) {
        os_log(OS_LOG_DEFAULT, "WXF card: connector %u mode %u -> %u", request->connector, current, request->mode);
        configure(At(manager, MANAGER_CONFIG_ENGINE), (int)request->connector, request->mode, false);
    } else {
        os_log(OS_LOG_DEFAULT, "WXF card: modeset of connector %u to %u skipped", request->connector, request->mode);
    }
    free(request);
}

bool WXFCardSetMode(WXFConnectorID connector, uint32_t mode) {
    void *manager = Manager();
    id<WXFCADisplay> d = CADisplayForID(connector);
    // config_current_mode edits the session's configuration, which only holds displays that are up.
    if (!manager || !d || ![d enabled] || ![d uniqueId]) return false;
    uint32_t current = 0;
    if (!HasMode(connector, mode, &current)) return false;
    if (current == mode) return true;
    if (!EngineIdle(manager)) return false;
    if (!WXFResolveServerSymbol("__ZN2WS8Displays20configuration_engine19config_current_modeEijb")) return false;

    ModesetRequest *request = malloc(sizeof *request);
    if (!request) return false;
    *request = (ModesetRequest){ connector, mode };
    // WindowServer's own caller (virtual display apply) and the reconfigure that commit starts both
    // run on the main thread.
    WXFScheduleCallback(RunModeset, request, WXFCurrentTime());
    return true;
}

// --- Hotplug ----------------------------------------------------------------------------------

typedef bool (*HotplugFn)(void *manager, int displayId, int state, unsigned reason, bool flag);
typedef bool (*InjectFn)(void *manager, bool state, int displayId, unsigned reason);

void *WXFCardOrig_Hotplug;

typedef struct {
    uint32_t id;
    WXFCardHotplugFunction function;
    void *info;
} Observer;

static os_unfair_lock gObserversLock = OS_UNFAIR_LOCK_INIT;
static Observer *gObservers;
static size_t gObserverCount;
static uint32_t gNextObserver = 1;

bool WXFCardHook_Hotplug(void *manager, int displayId, int state, unsigned reason, bool flag) {
    bool handled = ((HotplugFn)WXFCardOrig_Hotplug)(manager, displayId, state, reason, flag);

    os_unfair_lock_lock(&gObserversLock);
    size_t n = gObserverCount;
    Observer *copy = n ? malloc(n * sizeof *copy) : NULL;
    if (copy) memcpy(copy, gObservers, n * sizeof *copy);
    else n = 0;
    os_unfair_lock_unlock(&gObserversLock);

    for (size_t i = 0; i < n; i++)
        copy[i].function((WXFConnectorID)displayId, state == 1, (WXFHotplugReason)reason, handled, copy[i].info);
    free(copy);
    return handled;
}

uint32_t WXFCardAddHotplugObserver(WXFCardHotplugFunction function, void *info) {
    if (!function) return 0;
    if (!WXFHooksInstall(WXFHookGroupCardHotplug)) {
        os_log(OS_LOG_DEFAULT, "WXF card: hotplug hook not available on this build");
        return 0;
    }
    os_unfair_lock_lock(&gObserversLock);
    Observer *grown = realloc(gObservers, (gObserverCount + 1) * sizeof *grown);
    uint32_t id = 0;
    if (grown) {
        gObservers = grown;
        id = gNextObserver++;
        gObservers[gObserverCount++] = (Observer){ id, function, info };
    }
    os_unfair_lock_unlock(&gObserversLock);
    return id;
}

void WXFCardRemoveObserver(uint32_t observer) {
    os_unfair_lock_lock(&gObserversLock);
    for (size_t i = 0; i < gObserverCount; i++)
        if (gObservers[i].id == observer) {
            memmove(&gObservers[i], &gObservers[i + 1], (gObserverCount - i - 1) * sizeof *gObservers);
            gObserverCount--;
            break;
        }
    os_unfair_lock_unlock(&gObserversLock);
}

typedef struct { WXFConnectorID connector; bool connected; } InjectRequest;

static void RunInject(void *info, double now) {
    (void)now;
    InjectRequest *request = info;
    static InjectFn inject;
    if (!inject) inject = WXFResolveServerSymbol("__ZN2WS8Displays11CAWSManager14inject_hotplugEbij");
    void *manager = Manager();
    if (inject && manager)
        inject(manager, request->connected, (int)request->connector, WXFHotplugReasonInjected);
    free(request);
}

bool WXFCardSetConnected(WXFConnectorID connector, bool connected) {
    id<WXFCADisplay> d = CADisplayForID(connector);
    if (!d || ConnectorType([d displayType]) == WXFConnectorTypeDFR) return false;
    if (!WithManagedDisplay(connector, ^(void *display) { (void)display; })) return false;
    if (!WXFResolveServerSymbol("__ZN2WS8Displays11CAWSManager14inject_hotplugEbij")) return false;

    InjectRequest *request = malloc(sizeof *request);
    if (!request) return false;
    *request = (InjectRequest){ connector, connected };
    // CAWSManager's own softplug enqueues the same call on the main thread.
    WXFScheduleCallback(RunInject, request, WXFCurrentTime());
    return true;
}

// --- Power ------------------------------------------------------------------------------------

bool WXFCardSetBlanked(WXFConnectorID connector, bool blanked) {
    id<WXFCADisplay> d = CADisplayForID(connector);
    if (!d) return false;
    [d setBlanked:blanked];
    return true;
}

bool WXFCardSetEnabled(WXFConnectorID connector, bool enabled) {
    id<WXFCADisplay> d = CADisplayForID(connector);
    if (!d) return false;
    [d setEnabled:enabled];
    return true;
}

// --- Frames -----------------------------------------------------------------------------------

typedef int64_t (*PresentFn)(void *display, IOSurfaceRef surface, bool vsync);

bool WXFCardPresent(WXFConnectorID connector, IOSurfaceRef surface, bool vsync) {
    static PresentFn present;
    if (!present) present = WXFResolveServerSymbol("__ZN2WS8Displays11SLCADisplay17present_iosurfaceEP11__IOSurfaceb");
    if (!present || !surface) return false;
    // present_iosurface takes the display's own locks and may look at the manager's lists, so the
    // hardware list lock is not held across it. The display stays alive: it is only released by
    // process_display_disconnect, which also runs on the main thread this is called from.
    __block void *target = NULL;
    WithManagedDisplay(connector, ^(void *display) { target = display; });
    return target && (present(target, surface, vsync) & 1) != 0;
}

bool WXFCardGetScanout(WXFConnectorID connector, WXFScanoutInfo *out) {
    id<WXFCADisplay> d = CADisplayForID(connector);
    if (!d || !out) return false;
    // displayedSurface is not retained for us; read it straight away on the main thread.
    IOSurfaceRef surface = [d displayedSurface];
    if (!surface) return false;
    *out = (WXFScanoutInfo){
        .width             = (uint32_t)IOSurfaceGetWidth(surface),
        .height            = (uint32_t)IOSurfaceGetHeight(surface),
        .pixelFormat       = IOSurfaceGetPixelFormat(surface),
        .framebufferFormat = [d framebufferFormat],
    };
    WithManagedDisplay(connector, ^(void *display) {
        out->presentFlags = *(uint32_t *)At(display, DISPLAY_PRESENT_FLAGS);
    });
    return true;
}

bool WXFCardSetUpdatesDisabled(WXFConnectorID connector, bool disabled) {
    id<WXFCADisplay> d = CADisplayForID(connector);
    if (!d) return false;
    [d setDisablesUpdates:disabled];
    return true;
}

bool WXFCardGetUpdatesDisabled(WXFConnectorID connector, bool *disabled) {
    id<WXFCADisplay> d = CADisplayForID(connector);
    if (!d) return false;
    if (disabled) *disabled = [d disablesUpdates];
    return true;
}

bool WXFCardPresentExclusive(WXFConnectorID connector, IOSurfaceRef surface, bool vsync) {
    id<WXFCADisplay> d = CADisplayForID(connector);
    if (!d) return false;
    bool was = [d disablesUpdates];
    if (was) [d setDisablesUpdates:NO];
    bool ok = WXFCardPresent(connector, surface, vsync);
    if (was) [d setDisablesUpdates:YES];
    return ok;
}

bool WXFCardGetVBlank(WXFConnectorID connector, uint64_t *previous, uint64_t *interval) {
    id<WXFCADisplay> d = CADisplayForID(connector);
    if (!d) return false;
    if (previous) *previous = [d previousVBL];
    if (interval) *interval = [d vblDelta];
    return true;
}
