//
//  WXFHooks.c
//  WindowServerFramework
//
//  Created by bedtime on 10/27/26.
//
// The one place WindowServer hooks are declared and installed. To hook something new:
//   1. Define the replacement and an original-function pointer in the feature's file, with
//      external linkage (WXFFeatureHook_x / WXFFeatureOrig_x).
//   2. Declare them below and add a row to kHooks under a group (add a group in
//      WXFHooks-Private.h if the feature should install on its own schedule).
// The row's symbol is the raw Mach-O name, resolved with WXFResolveServerSymbol.

#include "WXFHooks-Private.h"
#include "WXFBase.h"
#include <stddef.h>
#include <stdbool.h>
#include <os/log.h>

// --- Declarations ---------------------------------------------------------------------------
// Replacements are called with their real signatures by WindowServer; the table only needs their
// addresses, so they are declared untyped here.
#define HOOK_DECL(PREFIX, NAME) \
    extern void PREFIX##Hook_##NAME(void); \
    extern void *PREFIX##Orig_##NAME;

// Drag events (WXFDrag.m)
HOOK_DECL(WXFDrag, Begin)
HOOK_DECL(WXFDrag, Propose)
HOOK_DECL(WXFDrag, Commit)
HOOK_DECL(WXFDrag, WillEnd)
HOOK_DECL(WXFDrag, DidEnd)
HOOK_DECL(WXFDrag, MoveT)
HOOK_DECL(WXFDrag, WillEndT)
HOOK_DECL(WXFDrag, AnimBegin)
HOOK_DECL(WXFDrag, AnimEnd)

// Compositor (WXFDragShader.m)
HOOK_DECL(WXFShader, create_specialized)
HOOK_DECL(WXFShader, copy_pipeline)
HOOK_DECL(WXFShader, set_pipeline)
HOOK_DECL(WXFShader, composite_layer)
HOOK_DECL(WXFShader, uber_composite)

// Input events (WXFEvent.m)
HOOK_DECL(WXFEvent, CheckForHotKey)
HOOK_DECL(WXFEvent, Annotated)

// Menu bar placement (WXFMenuBar.m)
HOOK_DECL(WXFMenuBar, Bounds)

// Window <-> CAContext tracking (WXFCAContextRetriever.m)
HOOK_DECL(WXFCAContext, Bind)
HOOK_DECL(WXFCAContext, Destroy)

// --- Table ----------------------------------------------------------------------------------
typedef struct {
    WXFHookGroup group;
    const char  *symbol;
    void        *replacement;
    void       **original;
} WXFHookEntry;

#define HOOK(GROUP, PREFIX, NAME, SYMBOL) \
    { GROUP, SYMBOL, (void *)PREFIX##Hook_##NAME, (void **)&PREFIX##Orig_##NAME },

static const WXFHookEntry kHooks[] = {
    // -- Window drags: PKGEvents*, and the transform animation around them.
    HOOK(WXFHookGroupDrag, WXFDrag, Begin,   "_PKGEventsBeginWindowDrag")
    HOOK(WXFHookGroupDrag, WXFDrag, Propose, "_PKGEventsProposeWindowDragMovement")
    HOOK(WXFHookGroupDrag, WXFDrag, Commit,  "_PKGEventsCommitWindowDragMovement")
    HOOK(WXFHookGroupDrag, WXFDrag, WillEnd, "_PKGEventsWillEndWindowDrag")
    HOOK(WXFHookGroupDrag, WXFDrag, DidEnd,  "_PKGEventsDidEndWindowDrag")
    HOOK(WXFHookGroupDrag, WXFDrag, MoveT,   "_PKGEventsMoveTransformedWindowDrag")
    HOOK(WXFHookGroupDrag, WXFDrag, WillEndT, "_PKGEventsWillEndTransformedWindowDrag")
    // animate_drag_transform(sessionData, connection, window, ...) / remove_drag_transform(sessionData, window, bool)
    HOOK(WXFHookGroupDrag, WXFDrag, AnimBegin,
         "__ZL22animate_drag_transformP21CGXSessionPackageDataP13CGXConnectionP9CGXWindow27CGSAffineTransformPlacementxdbU13block_pointerFvS4_S4_P17WSWindowTransformS7_EU13block_pointerFvbE")
    HOOK(WXFHookGroupDrag, WXFDrag, AnimEnd,
         "__ZL21remove_drag_transformP21CGXSessionPackageDataP9CGXWindowb")

    // -- Metal compositor, for drag shaders. Installed together or not at all.
    HOOK(WXFHookGroupDragShader, WXFShader, create_specialized,
         "__ZN14ShaderComposer25create_specialized_shaderEPU21objcproto10MTLLibrary11objc_objectP8NSStringS3_PFP25MTLFunctionConstantValuesyEyP19MTLVertexDescriptor")
    HOOK(WXFHookGroupDragShader, WXFShader, copy_pipeline,
         "__ZN11MetalShader17CopyPipelineStateEP12MetalContextbb")
    HOOK(WXFHookGroupDragShader, WXFShader, set_pipeline,
         "__ZN12MetalContext16SetPipelineStateEPU33objcproto22MTLRenderPipelineState11objc_object")
    HOOK(WXFHookGroupDragShader, WXFShader, composite_layer, "_MetalCompositeLayer")
    HOOK(WXFHookGroupDragShader, WXFShader, uber_composite,
         "__ZN14ShaderComposer13UberCompositeE14MTLPixelFormaty")

    // -- Input events. Two stages, so a missing symbol on a future OS only loses the events it carries.
    // CGXCheckForHotKey(SLSEventRecord *): buttons, keys, gestures; returns 0 to consume.
    HOOK(WXFHookGroupEventKeys, WXFEvent, CheckForHotKey, "_CGXCheckForHotKey")
    // sAnnotatedContinuation(SLSEventRecord *, void *): mouse moved / dragged and scrolling.
    HOOK(WXFHookGroupEventPointer, WXFEvent, Annotated,
         "__ZL22sAnnotatedContinuationP14SLSEventRecordPv")

    // -- Menu bar. menu_bar_bounds_for_space(PKGManagedMenuSpace *) -> CGRect: the bar's rect for
    // the window, the drag region, the status items and what clients are told.
    HOOK(WXFHookGroupMenuBar, WXFMenuBar, Bounds,
         "__ZL25menu_bar_bounds_for_spaceP19PKGManagedMenuSpace")

    // -- CAContext tracking. WSWindowBindRemoteCAClientContext(CGXWindow *, uint32_t contextID) is
    // where _XCreateWindow and _XSetWindowLayerContext hand an app's context to its window (both
    // reach CGXWindow::initialize_ca_content_for_context, or WSCALayerBackingInitialize when the
    // CAWindowContent feature is off). ~CGXWindow(CGXWindow *) ends the window's life.
    HOOK(WXFHookGroupCAContext, WXFCAContext, Bind, "_WSWindowBindRemoteCAClientContext")
    HOOK(WXFHookGroupCAContext, WXFCAContext, Destroy, "__ZN9CGXWindowD2Ev")
};

// --- Installation ---------------------------------------------------------------------------
static bool gInstalled[WXFHookGroupCount];

bool WXFHooksInstall(WXFHookGroup group) {
    if (group >= WXFHookGroupCount) return false;
    if (gInstalled[group]) return true;
    if (!WXFIsFrameworkSetUp()) return false;

    const size_t n = sizeof kHooks / sizeof kHooks[0];
    for (size_t i = 0; i < n; i++)    // all or none: check every symbol first
        if (kHooks[i].group == group && !WXFResolveServerSymbol(kHooks[i].symbol))
            return false;
    for (size_t i = 0; i < n; i++)
        if (kHooks[i].group == group)
            HookServer(kHooks[i].symbol, kHooks[i].replacement, kHooks[i].original);
    gInstalled[group] = true;
    return true;
}

void WXFHooksInstallAll(void) {
    WXFHooksInstall(WXFHookGroupDrag);
    if (!WXFHooksInstall(WXFHookGroupCAContext))
        os_log(OS_LOG_DEFAULT, "WXF hooks: CAContext hooks not available on this build");
}
