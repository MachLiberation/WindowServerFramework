// DragShaderExample: jello, after compiz-windows-effect's wobbly model. The tweak runs a 16x16 grid of
// springs and hands the shader the 256 control points as offsets from their rest positions; the
// window's snapshot is the Catmull-Rom surface those offsets define (each sample only touches its
// 4x4 neighborhood, so cost doesn't grow with the grid). The DragShaderExample target's
// "Compile drag shader" build phase turns this into a metallib linked into the dylib.

#include "../sdk/WXFDragShader.metal"

#define JELLO_GRID 16

// data[2 * (JELLO_GRID * row + column)] and the next float: that node's offset, in points, from
// where it sits when the window is at rest.
static inline float2 jello_offset(constant WXFDragExtra &extra, int i, int j) {
    const int k = 2 * (JELLO_GRID * j + i);
    return float2(wxf_param(extra, k), wxf_param(extra, k + 1));
}

// Catmull-Rom weights for the four nodes around t, and their derivatives in t.
static inline void catmull(float t, thread float4 &w, thread float4 &dw) {
    const float t2 = t * t, t3 = t2 * t;
    w  = 0.5 * float4(-t3 + 2.0 * t2 - t,  3.0 * t3 - 5.0 * t2 + 2.0,
                      -3.0 * t3 + 4.0 * t2 + t,  t3 - t2);
    dw = 0.5 * float4(-3.0 * t2 + 4.0 * t - 1.0,  9.0 * t2 - 10.0 * t,
                      -9.0 * t2 + 8.0 * t + 1.0,  3.0 * t2 - 2.0 * t);
}

// The deformed surface's position at (u, v), and its derivatives in u and v.
static inline float2 jello_surface(constant WXFDragExtra &extra, float2 uv, float2 size,
                                   thread float2 &du, thread float2 &dv) {
    const float n1 = float(JELLO_GRID - 1);
    const float2 g = uv * n1;
    const float2 gc = clamp(g, 0.0, n1);
    // Outside the grid the offsets hold their edge value, so they stop changing.
    const float2 live = float2(g.x >= 0.0 && g.x <= n1 ? 1.0 : 0.0,
                               g.y >= 0.0 && g.y <= n1 ? 1.0 : 0.0);
    const int i0 = min(int(gc.x), JELLO_GRID - 2), j0 = min(int(gc.y), JELLO_GRID - 2);

    float4 wx, dwx, wy, dwy;
    catmull(gc.x - float(i0), wx, dwx);
    catmull(gc.y - float(j0), wy, dwy);

    float2 s = 0.0, sdu = 0.0, sdv = 0.0;
    for (int b = 0; b < 4; b++) {
        const int j = clamp(j0 - 1 + b, 0, JELLO_GRID - 1);
        for (int a = 0; a < 4; a++) {
            const int i = clamp(i0 - 1 + a, 0, JELLO_GRID - 1);
            const float2 o = jello_offset(extra, i, j);
            s   += wx[a]  * wy[b]  * o;
            sdu += dwx[a] * wy[b]  * o;
            sdv += wx[a]  * dwy[b] * o;
        }
    }
    du = float2(size.x, 0.0) + sdu * n1 * live.x;
    dv = float2(0.0, size.y) + sdv * n1 * live.y;
    return uv * size + s;
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

    // Invert the surface: find (u, v) whose deformed position is this pixel. Seed from the nearest
    // of a coarse grid so a strongly bent surface still converges, then refine with Newton's method.
    float2 uv = target / size, du, dv;
    float best = 1e20;
    for (int j = 0; j <= 5; j++) {
        for (int i = 0; i <= 5; i++) {
            const float2 c = float2(i, j) * 0.2;
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
