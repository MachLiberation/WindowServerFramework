#ifndef WXF_DRAG_SHADER_METAL
#define WXF_DRAG_SHADER_METAL

// Include this from your own .metal file to write a fragment shader for a dragged window
// (WXFDragAnimationSetShader, WXFDragAnimationSetMargin). The shader draws an overlay that stands
// in for the window: the texture is a snapshot of it, and the overlay extends `margin` points past
// the window's frame on every side. Compile it to a .metallib at build time and ship that with your
// tweak -- WindowServer loads finished libraries only, it never compiles source.
//
//   #include "WXFDragShader.metal"
//
//   fragment float4 my_effect(WXFDragStage in [[stage_in]],
//                             texture2d<float> tex2D [[texture(0)]],
//                             constant WXFDragArgs &args [[buffer(0)]],
//                             constant WXFDragExtra &extra [[buffer(WXF_EXTRA_INDEX)]],
//                             sampler samp [[sampler(0)]]) {
//       float2 uv = wxf_window_uv(in);                  // 0..1 over the overlay
//       float  p  = wxf_progress(extra);                // 0 at rest -> ~1 while held
//       return tex2D.sample(samp, uv) * (1.0 - 0.4 * p); // the snapshot, dimmed
//   }
//
// The signatures are not a design choice: they mirror SkyLight's own UberCompositeVertex and
// UberCompositeFragment, because the compositor builds that pipeline and the framework only swaps
// the library it is built from. A fragment that disagrees with this ABI produces a pipeline that
// fails to build (the window is then drawn normally) or samples garbage. Keep the argument list
// exactly as above; you may leave out arguments you don't use only by keeping their indices.
//
// The fragment returns a PREMULTIPLIED color.

#include <metal_stdlib>
using namespace metal;

struct WXFDragIn {
    float2 pos               [[attribute(0)]];
    float2 tex               [[attribute(1)]];
    float  perspective_scale [[attribute(2)]];
};

struct WXFDragStage {
    float4 pos [[position]];
    float4 tex;
};

/// Bound at buffer(0) by the compositor.
struct WXFDragArgs {
    float brightness;
    float fade;
    float hdr_scale;
};

/// Bound at buffer(WXF_EXTRA_INDEX) by the framework. Must match the framework's layout.
#define WXF_EXTRA_INDEX 8
#define WXF_DATA_COUNT 512
struct WXFDragExtra {
    /// params[0] is the drag's eased progress (framework-owned). Read it, and your own floats
    /// (`data`), with the helpers below.
    float params[5];
    /// 1 when the params came from the window being drawn; 0 means "use defaults" (the window
    /// is being drawn by the framework's pipeline but is not the dragged window).
    float bound;
    /// The drag's progress for this frame, or -1 when unbound.
    float phase;
    /// The overlay's size in points; `margin` is how far it extends past the window's frame
    /// (WXFDragAnimationSetMargin); `content` is the window's own rectangle inside it.
    float frame_w, frame_h;
    float margin;
    float content_x, content_y, content_w, content_h;
    /// The floats your WXFDragShaderParamFunction filled in this frame.
    float data[WXF_DATA_COUNT];
};

/// 0 when unbound, so a shader leaves other windows untouched.
static inline float wxf_progress(constant WXFDragExtra &extra) {
    return extra.phase >= 0.0 ? extra.phase : 0.0;
}

/// The i-th developer float (0...WXF_DATA_COUNT-1), 0 when unbound.
static inline float wxf_param(constant WXFDragExtra &extra, int i) {
    return extra.bound > 0.5 ? extra.data[clamp(i, 0, WXF_DATA_COUNT - 1)] : 0.0;
}

/// This fragment's coordinate over the whole overlay, 0..1, top-left origin. Sample the
/// window snapshot with this.
static inline float2 wxf_window_uv(WXFDragStage in) {
    return in.tex.xy / max(in.tex.w, 1e-6);
}

/// The overlay's size in points.
static inline float2 wxf_frame_size(constant WXFDragExtra &extra) {
    return float2(extra.frame_w, extra.frame_h);
}

/// This fragment's position within the overlay, in points, top-left origin.
static inline float2 wxf_point(WXFDragStage in, constant WXFDragExtra &extra) {
    return wxf_window_uv(in) * wxf_frame_size(extra);
}

/// The window's frame (its content plus shadow) within the overlay: (min.x, min.y, max.x, max.y),
/// in points. The overlay is this rectangle grown by `extra.margin` on every side.
static inline float4 wxf_window_frame(constant WXFDragExtra &extra) {
    const float2 lo = float2(extra.margin);
    const float2 hi = wxf_frame_size(extra) - lo;
    return float4(lo, hi);
}

/// The window's own pixels' rectangle (no shadow) within the overlay: (min.x, min.y, max.x, max.y).
static inline float4 wxf_window_content(constant WXFDragExtra &extra) {
    return float4(extra.content_x, extra.content_y,
                  extra.content_x + extra.content_w, extra.content_y + extra.content_h);
}

/// True over the window's frame (content plus shadow).
static inline bool wxf_in_frame(float2 p, constant WXFDragExtra &extra) {
    const float4 f = wxf_window_frame(extra);
    return all(p >= f.xy) && all(p <= f.zw);
}

/// True over the window's own pixels (no shadow), in the snapshot's frame.
static inline bool wxf_in_window(float2 p, constant WXFDragExtra &extra) {
    const float4 c = wxf_window_content(extra);
    return all(p >= c.xy) && all(p <= c.zw);
}

/// The framework builds the pipeline with this vertex function, so it must exist in your library.
vertex WXFDragStage wxf_uber_vertex(WXFDragIn in [[stage_in]],
                                    constant float4x4 &mvp [[buffer(1)]]) {
    WXFDragStage out;
    out.pos = mvp * float4(in.pos, 0.0, 1.0);
    // Texcoords travel homogeneous so perspective interpolates correctly; wxf_window_uv divides.
    out.tex = float4(in.tex * in.perspective_scale, 0.0, in.perspective_scale);
    return out;
}

#endif // WXF_DRAG_SHADER_METAL
