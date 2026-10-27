//Created by bedtime on 10/26/26.

#ifndef WXFDRAGANIMATION_H
#define WXFDRAGANIMATION_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <CoreGraphics/CoreGraphics.h>
#include <WindowServerFramework/WXFBase.h>
#include <WindowServerFramework/CGXWindow.h>

#ifdef __cplusplus
extern "C" {
#endif

struct __WXFDragAnimation;
typedef struct __WXFDragAnimation *WXFDragAnimationRef;

typedef enum {
    /// Ease in, ease out.
    WXFDragAnimationEasingEaseInEaseOut,
    /// Spring motion curve (overshoots, then settles).
    WXFDragAnimationEasingSpring,
    /// Linear motion curve.
    WXFDragAnimationEasingLinear
} WXFDragAnimationEasing;

/// Everything an animation needs to compute one frame.
typedef struct {
    CGXWindow *window;
    /// The window's frame in screen coordinates.
    CGRect     frame;
    /// Cursor in screen coordinates. Only meaningful when `cursorValid`.
    CGPoint    cursor;
    bool       cursorValid;
    /// Window velocity in points per second, derived from frame movement between frames.
    CGPoint    velocity;
    /// Eased 0..1 amount (the spring curve may overshoot). Rises from 0 while the window is held
    /// and falls back to 0 after release. Multiply your deformation by it.
    float      progress;
    /// Seconds since the drag began.
    double     elapsed;
    /// True once the window has been released and the animation is relaxing back to rest.
    bool       releasing;
    /// The animation's intensity setting (percent; 100 is normal), for your own use.
    float      intensity;
} WXFDragFrame;

/// How many floats a shader receives from its WXFDragShaderParamFunction each frame.
#define WXF_DRAG_SHADER_DATA_COUNT 40

/// Fills the floats (WXF_DRAG_SHADER_DATA_COUNT of them, zeroed first) a shader receives each frame (see WXFDragAnimationSetShader). Called on
/// WindowServer's main thread about every 1/60s while the animation is live; keep it fast.
///
/// Return true while your effect is still moving. Once the window is released, the animation's
/// duration is the minimum the overlay stays up; after that it stays up for as long as you keep
/// returning true (at most 10 seconds), so a spring can settle instead of being cut off. Return
/// false when you are done, ideally when the effect has come to rest so the hand-back to the real
/// window is invisible.
typedef bool (*WXFDragShaderParamFunction)(const WXFDragFrame *frame, float out[WXF_DRAG_SHADER_DATA_COUNT], void *userInfo);

/// Returns the type identifier for WXFDragAnimation objects.
WXFTypeID WXFDragAnimationGetTypeID(void);

/// Creates a new drag animation. Returned +1 retained; release with WXFRelease.
/// Defaults: 150ms, ease in/out, no delay, intensity 100, no shader (does nothing until one is set).
WXF_RETURNS_RETAINED
WXFDragAnimationRef WXFDragAnimationCreate(void);

/// Draws the dragged window through your own fragment shader.
///
/// `metallib` is a PRECOMPILED Metal library (WindowServer never compiles source): build one from
/// a .metal file that includes sdk/WXFDragShader.metal, and ship it with your tweak. It must
/// contain `fragmentName`, a fragment function with the signature that header documents. The
/// bytes are copied. `params`, if given, supplies WXF_DRAG_SHADER_DATA_COUNT floats per frame, readable
/// in the shader with wxf_param(extra, i); the shader also gets the drag's eased `progress` via wxf_progress.
///
/// The shader draws the snapshot overlay that stands in for the window (see
/// WXFDragAnimationSetMargin).
/// @return false if the library is empty or the arguments are invalid. Whether the library
/// actually builds is only known when the compositor first uses it; if it doesn't, the window is
/// simply drawn normally.
bool WXFDragAnimationSetShader(WXFDragAnimationRef animation, const void *metallib, size_t length,
                               const char *fragmentName, WXFDragShaderParamFunction params,
                               void *userInfo);
/// How far, in points, the shader may draw beyond the dragged window on every side (default 0).
///
/// While a window with a shader is dragged, the window is hidden and an overlay window stands in
/// for it: it covers the window and its shadow plus this margin, and the shader draws it. The
/// texture the shader samples is a SNAPSHOT of the window taken when the drag began, so the
/// window's contents do not update during the drag, and the shader is free to deform, tint,
/// dissolve or add to it. Margin is room for a deformation (or glow, trail) to reach past the
/// window's rectangle. Large margins cost fill rate.
bool WXFDragAnimationSetMargin(WXFDragAnimationRef animation, float points);
float WXFDragAnimationGetMargin(WXFDragAnimationRef animation);

/// As WXFDragAnimationSetShader, reading the library from a file (e.g. in your tweak's bundle).
bool WXFDragAnimationSetShaderFile(WXFDragAnimationRef animation, const char *path,
                                   const char *fragmentName, WXFDragShaderParamFunction params,
                                   void *userInfo);
/// As WXFDragAnimationSetShader, taking the library linked into the CALLING image: the
/// `__DATA,__wxf_shader` section your tweak's build embeds (see the DragShaderExample target's "Compile
/// drag shader" phase: `-sectcreate __DATA __wxf_shader <metallib>`). Installing the dylib alone is
/// then enough, with no resource path to find at runtime inside WindowServer.
/// Must be called directly from the image that embeds the library.
bool WXFDragAnimationSetEmbeddedShader(WXFDragAnimationRef animation, const char *fragmentName,
                                       WXFDragShaderParamFunction params, void *userInfo);

/// Returns the shader configuration, or false if the animation has none. The returned pointers
/// are owned by the animation.
bool WXFDragAnimationGetShader(WXFDragAnimationRef animation, const void **metallib, size_t *length,
                               const char **fragmentName, WXFDragShaderParamFunction *params,
                               void **userInfo);

/// @param nanoseconds Time for `progress` to go 0 -> 1 (and back after release). Must be > 0.
bool WXFDragAnimationSetDuration(WXFDragAnimationRef animation, float nanoseconds);
float WXFDragAnimationGetDuration(WXFDragAnimationRef animation);

bool WXFDragAnimationSetEasing(WXFDragAnimationRef animation, WXFDragAnimationEasing easing);
WXFDragAnimationEasing WXFDragAnimationGetEasing(WXFDragAnimationRef animation);

/// @param nanoseconds Delay before progress starts rising, must be >= 0.
bool WXFDragAnimationSetDelay(WXFDragAnimationRef animation, float nanoseconds);
float WXFDragAnimationGetDelay(WXFDragAnimationRef animation);

/// Intensity in percent (>= 0), passed through to your param function as `intensity`.
bool WXFDragAnimationSetIntensity(WXFDragAnimationRef animation, float intensity);
float WXFDragAnimationGetIntensity(WXFDragAnimationRef animation);

/// Applies this animation's easing curve to a linear 0..1 value.
float WXFDragAnimationEvaluateEasing(WXFDragAnimationRef animation, float t);

#ifdef __cplusplus
}
#endif

#endif /* WXFDRAGANIMATION_H */
