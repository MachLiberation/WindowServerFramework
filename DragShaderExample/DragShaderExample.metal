// DragShaderExample: jello, after compiz-windows-effect's wobbly model. The tweak runs a 4x4 grid of
// springs and hands the shader the 16 control points as offsets from their rest positions; the
// window's snapshot is the bicubic Bezier patch those points define. The DragShaderExample target's
// "Compile drag shader" build phase turns this into a metallib linked into the dylib.

#include "../sdk/WXFDragShader.metal"

// data[2 * (4 * row + column)] and the next float: that control point's offset, in points, from
// where it sits when the window is at rest.
static inline float2 jello_point(constant WXFDragExtra &extra, int i, int j, float2 size) {
    const float2 rest = float2(float(i), float(j)) / 3.0 * size;
    const int k = 2 * (4 * j + i);
    return rest + float2(wxf_param(extra, k), wxf_param(extra, k + 1));
}

static inline float4 bernstein(float t) {
    const float s = 1.0 - t;
    return float4(s * s * s, 3.0 * t * s * s, 3.0 * t * t * s, t * t * t);
}

static inline float4 bernstein_d(float t) {
    const float s = 1.0 - t;
    return float4(-3.0 * s * s, 3.0 * s * s - 6.0 * t * s, 6.0 * t * s - 3.0 * t * t, 3.0 * t * t);
}

// The deformed patch's position at (u, v), and its derivatives in u and v.
static inline float2 jello_surface(constant WXFDragExtra &extra, float2 uv, float2 size,
                                   thread float2 &du, thread float2 &dv) {
    const float4 bu = bernstein(uv.x), bv = bernstein(uv.y);
    const float4 du4 = bernstein_d(uv.x), dv4 = bernstein_d(uv.y);
    float2 s = 0.0;
    du = 0.0;
    dv = 0.0;
    for (int j = 0; j < 4; j++) {
        for (int i = 0; i < 4; i++) {
            const float2 p = jello_point(extra, i, j, size);
            s  += bu[i] * bv[j] * p;
            du += du4[i] * bv[j] * p;
            dv += bu[i] * dv4[j] * p;
        }
    }
    return s;
}

fragment float4 wxf_example_jello(WXFDragStage in [[stage_in]],
                                  texture2d<float> tex2D [[texture(0)]],
                                  constant WXFDragArgs &args [[buffer(0)]],
                                  constant WXFDragExtra &extra [[buffer(WXF_EXTRA_INDEX)]],
                                  sampler samp [[sampler(0)]]) {
    const float2 frame = wxf_frame_size(extra);
    const float2 p = wxf_point(in, extra);
    if (extra.bound < 0.5)
        return tex2D.sample(samp, p / frame);

    // Work in the window's frame; the overlay extends `margin` past it on every side.
    const float4 fr = wxf_window_frame(extra);
    const float2 size = fr.zw - fr.xy;
    const float2 target = p - fr.xy;

    // Invert the patch: find (u, v) whose deformed position is this pixel. Seed from the nearest
    // of a coarse grid so a strongly bent patch still converges, then refine with Newton's method.
    float2 uv = target / size, du, dv;
    float best = 1e20;
    for (int j = 0; j <= 4; j++) {
        for (int i = 0; i <= 4; i++) {
            const float2 c = float2(i, j) * 0.25;
            const float2 d = jello_surface(extra, c, size, du, dv) - target;
            const float e = dot(d, d);
            if (e < best) { best = e; uv = c; }
        }
    }
    float2 err = 0.0;
    for (int n = 0; n < 6; n++) {
        err = jello_surface(extra, uv, size, du, dv) - target;
        const float det = du.x * dv.y - du.y * dv.x;
        if (abs(det) < 1e-3)
            break;
        const float2 step = float2(dv.y * err.x - dv.x * err.y,
                                   -du.y * err.x + du.x * err.y) / det;
        uv = clamp(uv - step, -0.25, 1.25);
    }
    err = jello_surface(extra, uv, size, du, dv) - target;
    if (dot(err, err) > 1.0 || any(uv < 0.0) || any(uv > 1.0))
        return float4(0.0);

    // The snapshot is of the window's frame, which sits `margin` into the overlay.
    return tex2D.sample(samp, (fr.xy + uv * size) / frame);   // premultiplied
}
