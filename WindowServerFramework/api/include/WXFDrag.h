//Created by bedtime on 10/26/26.

#ifndef WXFDRAG_H
#define WXFDRAG_H

#include <stdint.h>
#include <stdbool.h>
#include <CoreGraphics/CoreGraphics.h>
#include <WindowServerFramework/WXFBase.h>
#include <WindowServerFramework/CGXWindow.h>
#include <WindowServerFramework/WXFDragAnimation.h>

#ifdef __cplusplus
extern "C" {
#endif

struct __WXFDragContext;
/// Describes one event in a window drag. Only valid for the duration of the callback;
/// do not retain it or keep the CGXWindow pointer past the callback's return.
typedef struct __WXFDragContext *WXFDragContextRef;

typedef enum {
    /// The user began dragging a window.
    WXFDragPhaseBegin          = 1 << 0,
    /// WindowServer is proposing a new position for the window (before it is committed).
    WXFDragPhasePropose        = 1 << 1,
    /// The window's drag movement was committed and the window has moved.
    WXFDragPhaseMove           = 1 << 2,
    /// The drag is about to end (delivered before WindowServer finalizes it).
    WXFDragPhaseWillEnd        = 1 << 3,
    /// The drag ended.
    WXFDragPhaseDidEnd         = 1 << 4,
    /// WindowServer applied a drag transform animation to the window.
    WXFDragPhaseAnimationBegin = 1 << 5,
    /// WindowServer removed the drag transform from the window.
    WXFDragPhaseAnimationEnd   = 1 << 6,
    WXFDragPhaseAll            = 0x7f,
} WXFDragPhase;

/// Called on WindowServer's thread for each matching drag event. Keep it fast.
typedef void (*WXFDragCallback)(WXFDragContextRef context, void *userInfo);

typedef uint32_t WXFDragObserverID;
#define WXFDragObserverIDInvalid ((WXFDragObserverID)0)

/// Registers a callback for the phases in `phaseMask`. Installs the WindowServer hooks the
/// first time it is called (requires SetupFramework to have been called).
/// @return an observer id, or WXFDragObserverIDInvalid on failure.
WXFDragObserverID WXFDragAddObserver(uint32_t phaseMask, WXFDragCallback callback, void *userInfo);

/// Everything the one-call setup (WXFDragInstallShader) needs. Zero any field you don't care about.
typedef struct {
    /// The fragment function in your embedded metallib. Required.
    const char                *fragment;
    /// Fills the shader's per-frame floats and says whether the effect is still moving. Optional.
    WXFDragShaderParamFunction params;
    void                      *userInfo;
    /// How far past the window, in points, the shader may draw (WXFDragAnimationSetMargin).
    float                      margin;
    /// Minimum time, in nanoseconds, the overlay lingers after the release; 0 means 150 ms.
    float                      durationNanoseconds;
    WXFDragAnimationEasing     easing;
} WXFDragShaderDescriptor;

/// The whole setup in one call: from now on, every window drag is drawn through your shader.
///
///     static const WXFDragShaderDescriptor jello = { .fragment = "my_jello", .params = MyParams,
///                                                    .margin = 120 };
///     WXFDragInstallShader(&jello);
///
/// The metallib is the one embedded in the calling image (WXFDragAnimationSetEmbeddedShader).
/// The descriptor is copied. Returns an observer id for WXFDragRemoveObserver, or
/// WXFDragObserverIDInvalid if the descriptor or the embedded library is unusable. For control
/// over which drags get a shader, build a WXFDragAnimation yourself and attach it from your own
/// WXFDragAddObserver callback.
WXFDragObserverID WXFDragInstallShader(const WXFDragShaderDescriptor *descriptor);

/// Removes a callback. @return true if the observer existed.
bool WXFDragRemoveObserver(WXFDragObserverID observer);

/// The drag phase that triggered this callback.
WXFDragPhase WXFDragContextGetPhase(WXFDragContextRef context);

/// The window being dragged. May be NULL for phases WindowServer reports without a window.
CGXWindow *WXFDragContextGetWindow(WXFDragContextRef context);

/// Whether this is a transformed-window drag (e.g. a window being dragged while transformed).
bool WXFDragContextIsTransformed(WXFDragContextRef context);

/// The animation attached to this drag, or NULL.
WXFDragAnimationRef WXFDragContextGetAnimation(WXFDragContextRef context);

/// Attaches an animation (retained) to the window drag in progress and starts it: from now until
/// the drag is released and the animation relaxes back to rest, the window is drawn through the
/// animation's shader. Pass NULL to stop immediately and
/// restore normal drawing. Ignored if `context` has no window or no drag is in progress, so call
/// it from a Begin (or later) callback. Replacing the animation mid-drag takes effect next frame.
void WXFDragContextSetAnimation(WXFDragContextRef context, WXFDragAnimationRef animation);

#ifdef __cplusplus
}
#endif

#endif /* WXFDRAG_H */
