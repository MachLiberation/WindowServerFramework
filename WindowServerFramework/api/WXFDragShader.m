//Created by bedtime on 10/26/26.
//
// Custom fragment shaders for dragged windows.
//
// The compositor draws every window layer through its "ubershader". A window carrying a
// CIColorInvert-type filter (type 2) makes DetermineShaderOptions set option bit 0x10, which
// arrives in ShaderComposer::UberComposite as `options`. We answer that request with a pipeline
// built from the developer's own precompiled metallib -- same vertex descriptor, quad, pixel
// formats and uniform buffer as Apple's, only the two functions differ -- and bind a small
// per-window argument buffer (the filter's five floats) whenever one of our pipelines is set.
// WindowServer only ever loads a finished library; it never compiles shader source.

#include "WXFDragShader-Private.h"
#include "WXFBase-Private.h"
#include "WXFHooks-Private.h"
#include <WindowServerFramework/WXFBase.h>
#include <WindowServerFramework/WXFMisc.h>
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <os/log.h>
#include <os/lock.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <ptrauth.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// Symbols (raw Mach-O names).
#define kSymCreateShader \
    "__ZN14ShaderComposer13create_shaderEPU21objcproto10MTLLibrary11objc_objectP8NSStringS3_P19MTLVertexDescriptor"
#define kSymRenderEncoder "__ZN12MetalContext13RenderEncoderEv"
#define kSymWindowGetFilter "_WSWindowGetFilter"
#define kSymWindowSetFilter "_WSWindowSetFilter"

// Layout facts established by disassembly of the compositor (see SkyLightServer.h in the Vanish
// reference): the filter's type and params are copied onto the composite layer every frame.
#define kLayerFilterTypeOffset   0x228
#define kLayerFilterParamsOffset 0x230
#define kFilterTypeShaderTag     2
#define kUberOptionShaderTag     0x10
/// Fragment buffer index of the per-window arguments. Must match sdk/WXFDragShader.metal.
#define kExtraIndex              8
#define kMarker                  0x57584653u   /* 'WXFS' in filter_id, ours to use */

/// Mirrors the compositor's filter object (0x30 bytes, allocated by _XNewCIFilter).
typedef struct WXFWindowFilter {
    struct WXFWindowFilter *next;   // 0x00
    uint32_t refcount;              // 0x08
    uint32_t type;                  // 0x0c
    uint32_t _unknown10;            // 0x10
    uint32_t filter_id;             // 0x14
    float    params[5];             // 0x18
    uint32_t _pad_2c;
} WXFWindowFilter;
_Static_assert(sizeof(WXFWindowFilter) == 0x30, "filter must be the size _XNewCIFilter allocates");
_Static_assert(offsetof(WXFWindowFilter, params) == 0x18, "params offset");

/// Must match WXFDragExtra in sdk/WXFDragShader.metal.
typedef struct {
    float params[5];
    float bound;
    float phase;
    float frame_w, frame_h;     // the overlay, points
    float margin;               // frame minus the window's own frame, per side
    float content_x, content_y, content_w, content_h;   // the window's content within the overlay
    float data[kWXFDragShaderDataCount];                  // the developer's floats
} WXFDragExtra;

static WXFDragExtra gGeometry;   // frame/margin/content only; set before attaching
static float gData[kWXFDragShaderDataCount];   // the developer's floats, rebound every frame

typedef void *(*CreateSpecializedFn)(void *, void *, void *, void *, uint64_t, void *);
typedef void *(*UberCompositeFn)(void *, unsigned, uint64_t);
typedef void *(*CreateShaderFn)(void *, void *, void *, void *);
typedef uint64_t (*CompositeLayerFn)(void *, void *, void *, uint64_t);
typedef void (*SetPipelineFn)(void *, void *);
typedef void *(*RenderEncoderFn)(void *);
typedef void *(*CopyPipelineFn)(void *, void *, bool, bool);
typedef WXFWindowFilter *(*GetFilterFn)(CGXWindow *);
typedef void (*SetFilterFn)(CGXWindow *, WXFWindowFilter *);

CreateSpecializedFn WXFShaderOrig_create_specialized;
UberCompositeFn WXFShaderOrig_uber_composite;
CompositeLayerFn WXFShaderOrig_composite_layer;
SetPipelineFn WXFShaderOrig_set_pipeline;
CopyPipelineFn WXFShaderOrig_copy_pipeline;
static CreateShaderFn create_shader;
static RenderEncoderFn render_encoder;
static GetFilterFn window_get_filter;
static SetFilterFn window_set_filter;

static bool gHooksReady;

static struct {
    uint32_t windowID;
    WXFWindowFilter *filter;
} gAttached;

#define WXF_LOG(...) os_log(OS_LOG_DEFAULT, __VA_ARGS__)

// ---------------------------------------------------------------------------------------------
// Objective-C access without importing Metal: the framework only needs a handful of messages.

static void *(*msg_id)(void *, void *);
static void *(*msg_new_library)(void *, void *, void *, void **);
static void (*msg_set_bytes)(void *, void *, const void *, unsigned long, unsigned long);
static void *(*sel)(const char *);

static bool ObjCReady(void) {
    static bool tried, ok;
    if (tried) return ok;
    tried = true;
    void *send = dlsym(RTLD_DEFAULT, "objc_msgSend");
    sel = (void *(*)(const char *))sel_registerName;
    msg_id = (void *(*)(void *, void *))send;
    msg_new_library = (void *(*)(void *, void *, void *, void **))send;
    msg_set_bytes = (void (*)(void *, void *, const void *, unsigned long, unsigned long))send;
    ok = send != NULL;
    return ok;
}

// ---------------------------------------------------------------------------------------------
// The shader table. Entries are immutable once published and never freed (bounded by the table
// size), so the compositor threads can read the active one without a lock.

typedef struct {
    void *bytes;           // our copy of the metallib
    size_t length;
    char *fragment;
    void *library;         // built lazily from `bytes`, on the compositor's device
    void *shader;          // MetalShader* from ShaderComposer::create_shader
    bool failed;
} ShaderEntry;

#define MAX_SHADERS 8
static ShaderEntry *gEntries[MAX_SHADERS];
static os_unfair_lock gEntryLock = OS_UNFAIR_LOCK_INIT;
static _Atomic(ShaderEntry *) gActive;
static _Atomic int gAttachedCount;

// Pipeline states made from our MetalShaders, recorded as CopyPipelineState hands them out.
static _Atomic(void *) gPipelines[16];

// The ubershader's own library and vertex descriptor, taken from the first
// create_specialized_shader the compositor runs. Retained so they outlive Apple's references.
static _Atomic(void *) gUberLibrary;
static _Atomic(void *) gUberVertexDescriptor;

static __thread void *tl_layer;

static bool IsOurShader(void *shader) {
    if (!shader) return false;
    bool found = false;
    os_unfair_lock_lock(&gEntryLock);
    for (int i = 0; i < MAX_SHADERS && gEntries[i]; i++) {
        if (gEntries[i]->shader == shader) { found = true; break; }
    }
    os_unfair_lock_unlock(&gEntryLock);
    return found;
}

static bool IsOurPipeline(void *pipeline) {
    for (size_t i = 0; i < sizeof gPipelines / sizeof gPipelines[0]; i++) {
        void *p = atomic_load_explicit(&gPipelines[i], memory_order_acquire);
        if (!p) return false;
        if (p == pipeline) return true;
    }
    return false;
}

/// Builds (once) the pipeline for an entry. Called from the compositor with the library/vertex
/// descriptor the compositor itself uses, so the pipeline matches its pixel formats and quad.
static void *ShaderForEntry(ShaderEntry *e) {
    os_unfair_lock_lock(&gEntryLock);
    if (e->shader || e->failed) {
        void *s = e->shader;
        os_unfair_lock_unlock(&gEntryLock);
        return s;
    }
    void *their = atomic_load(&gUberLibrary);
    void *vdesc = atomic_load(&gUberVertexDescriptor);
    if (!their || !vdesc || !create_shader || !ObjCReady()) {
        os_unfair_lock_unlock(&gEntryLock);
        return NULL;   // not yet; try again on the next request
    }

    // A pipeline is bound to the device that made it; take the device from Apple's library.
    void *device = msg_id(their, sel("device"));
    dispatch_data_t data = dispatch_data_create(e->bytes, e->length, NULL, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    void *err = NULL;
    void *lib = device ? msg_new_library(device, sel("newLibraryWithData:error:"),
                                         (__bridge void *)data, &err) : NULL;
    CFStringRef frag = CFStringCreateWithCString(NULL, e->fragment, kCFStringEncodingUTF8);
    void *shader = (lib && frag) ? create_shader(lib, (void *)CFSTR("wxf_uber_vertex"), (void *)frag, vdesc) : NULL;
    if (frag) CFRelease(frag);

    WXF_LOG("WXF shader: '%{public}s' device=%p library=%p pipeline=%p", e->fragment, device, lib, shader);
    e->library = lib;
    e->shader = shader;
    e->failed = shader == NULL;   // bad library or missing function: stop retrying, run stock
    void *result = shader;
    os_unfair_lock_unlock(&gEntryLock);
    return result;
}

// ---------------------------------------------------------------------------------------------
// Hooks

void *WXFShaderHook_create_specialized(void *library, void *vtx, void *frag, void *constants_fn,
                                     uint64_t options, void *vdesc) {
    // Capture, don't substitute: the swap happens in UberComposite, ahead of Apple's cache.
    if (library && vdesc && !atomic_load(&gUberLibrary)) {
        CFRetain(library);
        CFRetain(vdesc);
        atomic_store(&gUberVertexDescriptor, vdesc);
        atomic_store(&gUberLibrary, library);
    }
    return WXFShaderOrig_create_specialized ? WXFShaderOrig_create_specialized(library, vtx, frag, constants_fn, options, vdesc) : NULL;
}

void *WXFShaderHook_uber_composite(void *composer, unsigned fmt, uint64_t options) {
    ShaderEntry *active = atomic_load_explicit(&gActive, memory_order_acquire);
    if (options & kUberOptionShaderTag) {
        static _Atomic int logged;
        if (atomic_fetch_add(&logged, 1) < 6)
            WXF_LOG("WXF shader: uber options=0x%llx active=%p attached=%d vdesc=%p", options, active,
                    atomic_load(&gAttachedCount), atomic_load(&gUberVertexDescriptor));
    }
    if ((options & kUberOptionShaderTag) && gHooksReady && active &&
        atomic_load_explicit(&gAttachedCount, memory_order_acquire) > 0) {
        void *shader = ShaderForEntry(active);
        if (!shader && WXFShaderOrig_uber_composite && !atomic_load(&gUberVertexDescriptor)) {
            // The library and descriptor only arrive when the compositor builds an ubershader of
            // its own. Run the original once to make that happen, then build ours.
            (void)WXFShaderOrig_uber_composite(composer, fmt, options);
            shader = ShaderForEntry(active);
        }
        if (shader) return shader;
    }
    return WXFShaderOrig_uber_composite ? WXFShaderOrig_uber_composite(composer, fmt, options) : NULL;
}

void *WXFShaderHook_copy_pipeline(void *shader, void *context, bool a, bool b) {
    void *pipeline = WXFShaderOrig_copy_pipeline(shader, context, a, b);
    if (!pipeline || !IsOurShader(shader) || IsOurPipeline(pipeline)) return pipeline;
    for (size_t i = 0; i < sizeof gPipelines / sizeof gPipelines[0]; i++) {
        void *expected = NULL;
        if (atomic_compare_exchange_strong_explicit(&gPipelines[i], &expected, pipeline,
                                                    memory_order_acq_rel, memory_order_acquire))
            break;
        if (expected == pipeline) break;
    }
    return pipeline;
}

void WXFShaderHook_set_pipeline(void *context, void *pipeline) {
    WXFShaderOrig_set_pipeline(context, pipeline);
    // Every layer of every window comes through here every frame; only while a tagged window
    // exists can one of our pipelines be among them.
    if (atomic_load_explicit(&gAttachedCount, memory_order_acquire) <= 0) return;
    if (!pipeline || !IsOurPipeline(pipeline)) return;

    WXFDragExtra extra = gGeometry;
    extra.phase = -1.0f;
    void *layer = tl_layer;
    if (layer && *(uint32_t *)((char *)layer + kLayerFilterTypeOffset) == kFilterTypeShaderTag) {
        memcpy(extra.params, (char *)layer + kLayerFilterParamsOffset, sizeof extra.params);
        extra.bound = 1.0f;
        extra.phase = extra.params[0];   // params[0] is the drag's progress, set by the driver
        memcpy(extra.data, gData, sizeof extra.data);
    }
    void *encoder = render_encoder(context);
    if (encoder && ObjCReady())
        msg_set_bytes(encoder, sel("setFragmentBytes:length:atIndex:"), &extra, sizeof extra, kExtraIndex);
}

uint64_t WXFShaderHook_composite_layer(void *context, void *layer, void *destination, uint64_t flags) {
    void *outer = tl_layer;
    tl_layer = layer;
    uint64_t result = WXFShaderOrig_composite_layer(context, layer, destination, flags);
    tl_layer = outer;
    return result;
}

static bool EnsureHooks(void) {
    static bool done;
    if (done) return gHooksReady;
    if (!WXFIsFrameworkSetUp() || !ObjCReady()) return false;   // retry once set up

    create_shader   = (CreateShaderFn)WXFResolveServerSymbol(kSymCreateShader);
    render_encoder  = (RenderEncoderFn)WXFResolveServerSymbol(kSymRenderEncoder);
    window_get_filter = (GetFilterFn)WXFResolveServerSymbol(kSymWindowGetFilter);
    window_set_filter = (SetFilterFn)WXFResolveServerSymbol(kSymWindowSetFilter);

    // The compositor hooks (WXFHooks.c) install all or none: a partial set would substitute a
    // shader whose arguments never get bound, and an unbound argument buffer reads GPU garbage.
    bool all = create_shader && render_encoder && window_get_filter && window_set_filter &&
               WXFMiscIsAvailable(WXFMiscFeatureCore);
    done = true;
    if (!all)
        WXF_LOG("WXF shader: required WindowServer symbols missing, shader hooks not installed");
    if (!all) return false;


    if (!WXFHooksInstall(WXFHookGroupDragShader)) return false;
    gHooksReady = WXFShaderOrig_create_specialized && WXFShaderOrig_copy_pipeline && WXFShaderOrig_set_pipeline &&
                  WXFShaderOrig_composite_layer && WXFShaderOrig_uber_composite;
    WXF_LOG("WXF shader: hooks ready=%d", gHooksReady);
    return gHooksReady;
}

// ---------------------------------------------------------------------------------------------
// Private API

bool WXFDragShaderActivate(const void *metallib, size_t length, const char *fragment) {
    if (!metallib || !length || !fragment || !EnsureHooks())
        return false;

    ShaderEntry *entry = NULL;
    os_unfair_lock_lock(&gEntryLock);
    int i = 0;
    for (; i < MAX_SHADERS && gEntries[i]; i++) {
        if (gEntries[i]->length == length && strcmp(gEntries[i]->fragment, fragment) == 0 &&
            memcmp(gEntries[i]->bytes, metallib, length) == 0) {
            entry = gEntries[i];
            break;
        }
    }
    if (!entry && i < MAX_SHADERS) {
        entry = calloc(1, sizeof *entry);
        if (entry) {
            entry->bytes = malloc(length);
            entry->fragment = strdup(fragment);
            if (entry->bytes && entry->fragment) {
                memcpy(entry->bytes, metallib, length);
                entry->length = length;
                gEntries[i] = entry;
            } else {
                free(entry->bytes);
                free(entry->fragment);
                free(entry);
                entry = NULL;
            }
        }
    }
    os_unfair_lock_unlock(&gEntryLock);
    if (!entry) return false;

    atomic_store_explicit(&gActive, entry, memory_order_release);
    return true;
}

void WXFDragShaderDeactivate(void) {
    atomic_store_explicit(&gActive, NULL, memory_order_release);
}

void WXFDragShaderSetGeometry(float width, float height, float margin,
                              float contentX, float contentY, float contentW, float contentH) {
    gGeometry = (WXFDragExtra){ .frame_w = width, .frame_h = height, .margin = margin,
                                .content_x = contentX, .content_y = contentY,
                                .content_w = contentW, .content_h = contentH };
}

bool WXFDragShaderAttach(CGXWindow *window, const float params[kWXFFilterParamCount]) {
    if (!window || !gHooksReady || gAttached.filter || !window_get_filter || !window_set_filter)
        return false;
    if (window_get_filter(window) != NULL) {
        WXF_LOG("WXF shader: wid=%u already has a filter, not attaching", window->window_id);
        return false;   // the app set a filter of its own; leave it alone
    }

    WXFWindowFilter *f = calloc(1, sizeof *f);
    if (!f) return false;
    f->refcount = 1;                // so a server-side release frees it exactly once
    f->type = kFilterTypeShaderTag;
    f->filter_id = kMarker;
    if (params) memcpy(f->params, params, sizeof f->params);

    gAttached.windowID = window->window_id;
    gAttached.filter = f;
    atomic_fetch_add_explicit(&gAttachedCount, 1, memory_order_acq_rel);
    window_set_filter(window, f);
    WXF_LOG("WXF shader: attached filter to wid=%u kind=%d", window->window_id, *(int *)((char *)window + 4));
    WXFWindowUpdate(window);
    return true;
}

void WXFDragShaderUpdate(CGXWindow *window, const float params[kWXFFilterParamCount],
                         const float data[kWXFDragShaderDataCount]) {
    if (!window || !gAttached.filter || window->window_id != gAttached.windowID)
        return;
    if (window_get_filter(window) != gAttached.filter)
        return;
    memcpy(gAttached.filter->params, params, sizeof gAttached.filter->params);
    if (data) memcpy(gData, data, sizeof gData);
    // Writing the params alone leaves the window clean, so the compositor would never re-read them.
    WXFWindowUpdate(window);
}

void WXFDragShaderDetach(CGXWindow *window) {
    if (!gAttached.filter)
        return;
    if (!window)
        window = WXFWindowFromID(gAttached.windowID);

    if (window && window_get_filter(window) == gAttached.filter) {
        window_set_filter(window, NULL);
        free(gAttached.filter);
        WXFWindowUpdate(window);
    }
    // else: the window is gone, and releasing it already freed the filter.
    gAttached.filter = NULL;
    atomic_fetch_sub_explicit(&gAttachedCount, 1, memory_order_acq_rel);
}
