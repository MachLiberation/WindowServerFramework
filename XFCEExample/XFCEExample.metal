//
//  XFCEExample.metal
//  WindowServerFramework
//
//  Created by bedtime on 10/28/26.
//
// Draws the X server's screen (a BGRA texture) onto the display, scaled and centred, with an arrow
// for the pointer on top: the X server doesn't draw its own cursor into its framebuffer.

#include <metal_stdlib>
using namespace metal;

struct XfceUniforms {
    float2 screen;        // display surface, pixels
    float2 xSize;         // X screen, pixels
    float2 origin;        // top-left of the X screen on the display, pixels
    float2 pointer;       // pointer on the display, pixels
    float  scale;         // display pixels per X pixel
    float  cursorScale;   // size of the arrow, as a multiple of its 19-pixel design
    float  nearest;       // nonzero: sample without filtering
    float  showPointer;
};

struct XfceVertex {
    float4 position [[position]];
};

vertex XfceVertex xfce_vertex(uint vid [[vertex_id]]) {
    const float2 p = float2((vid << 1) & 2, vid & 2);
    XfceVertex out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

// 1 inside the arrow's triangle (0,0) (0,19) (13,14), with the pointer's hot spot at (0,0).
static float arrow(float2 d) {
    const float2 a = float2(0.0, 0.0), b = float2(0.0, 19.0), c = float2(13.0, 14.0);
    const float2 v0 = c - a, v1 = b - a, v2 = d - a;
    const float d00 = dot(v0, v0), d01 = dot(v0, v1), d11 = dot(v1, v1);
    const float d20 = dot(v2, v0), d21 = dot(v2, v1);
    const float inv = 1.0 / (d00 * d11 - d01 * d01);
    const float u = (d11 * d20 - d01 * d21) * inv;
    const float v = (d00 * d21 - d01 * d20) * inv;
    return (u >= 0.0 && v >= 0.0 && u + v <= 1.0) ? 1.0 : 0.0;
}

fragment float4 xfce_fragment(XfceVertex in [[stage_in]],
                              texture2d<float> screen [[texture(0)]],
                              constant XfceUniforms &u [[buffer(0)]]) {
    const float2 p = in.position.xy;
    float3 color = float3(0.0);
    const float2 xy = (p - u.origin) / u.scale;
    if (all(xy >= 0.0) && all(xy < u.xSize)) {
        constexpr sampler linear(filter::linear, address::clamp_to_edge, coord::pixel);
        color = (u.nearest != 0.0 ? screen.read(uint2(xy)).rgb
                                  : screen.sample(linear, xy).rgb);
    }
    if (u.showPointer != 0.0) {
        const float2 d = (p - u.pointer) / u.cursorScale;
        const float inner = arrow(d);
        // Outline: inside a one-pixel-fatter arrow, i.e. any neighbour is inside the arrow.
        float outer = 0.0;
        const float2 offsets[8] = { float2(1, 0), float2(-1, 0), float2(0, 1), float2(0, -1),
                                    float2(1, 1), float2(-1, 1), float2(1, -1), float2(-1, -1) };
        for (int i = 0; i < 8; i++) outer = max(outer, arrow(d + offsets[i]));
        color = mix(color, float3(0.0), outer * (1.0 - inner));
        color = mix(color, float3(1.0), inner);
    }
    return float4(color, 1.0);
}
