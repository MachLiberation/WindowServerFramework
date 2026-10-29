//
//  CubeExample.metal
//  WindowServerFramework
//
//  Created by bedtime on 10/28/26.
//
// A lit, spinning cube over a slow gradient, drawn straight into the IOSurface the tweak hands to
// WXFCardPresent. The CubeExample target's "Compile cube shader" build phase turns this into a
// metallib linked into the dylib.

#include <metal_stdlib>
using namespace metal;

struct CubeUniforms {
    float4x4 mvp;
    float4x4 model;
    float    time;
    float    aspect;
    float2   padding;
};

struct CubeVertex {
    float4 position [[position]];
    float3 normal;
    float3 color;
    float3 local;    // position on the unit cube, for the edge lines
};

// Corner i is (x, y, z) = (bit 0, bit 1, bit 2) of i, mapped to -1 / +1.
constant uint kQuads[24] = {
    1, 3, 7, 5,   // +X
    0, 4, 6, 2,   // -X
    2, 6, 7, 3,   // +Y
    0, 1, 5, 4,   // -Y
    4, 5, 7, 6,   // +Z
    0, 2, 3, 1,   // -Z
};
constant uint kTriangleCorner[6] = { 0, 1, 2, 0, 2, 3 };
constant float3 kFaceNormal[6] = {
    float3( 1, 0, 0), float3(-1, 0, 0), float3(0,  1, 0), float3(0, -1, 0), float3(0, 0,  1), float3(0, 0, -1),
};
constant float3 kFaceColor[6] = {
    float3(0.95, 0.30, 0.30), float3(0.95, 0.60, 0.20), float3(0.30, 0.85, 0.40),
    float3(0.20, 0.80, 0.85), float3(0.30, 0.45, 0.95), float3(0.75, 0.40, 0.95),
};

vertex CubeVertex cube_vertex(uint vid [[vertex_id]], constant CubeUniforms &u [[buffer(0)]]) {
    const uint face = vid / 6;
    const uint corner = kQuads[face * 4 + kTriangleCorner[vid % 6]];
    const float3 p = float3((corner & 1) ? 1.0 : -1.0, (corner & 2) ? 1.0 : -1.0, (corner & 4) ? 1.0 : -1.0);
    CubeVertex out;
    out.position = u.mvp * float4(p, 1.0);
    out.normal = (u.model * float4(kFaceNormal[face], 0.0)).xyz;
    out.color = kFaceColor[face];
    out.local = p;
    return out;
}

fragment float4 cube_fragment(CubeVertex in [[stage_in]]) {
    const float3 n = normalize(in.normal);
    const float3 light = normalize(float3(-0.4, 0.7, 0.6));
    const float diffuse = max(dot(n, light), 0.0);
    float3 color = in.color * (0.25 + 0.85 * diffuse);
    // A dark line where two of the three coordinates are near their extremes, i.e. along an edge.
    const float3 a = abs(in.local);
    const float edge = step(0.94, a.x) + step(0.94, a.y) + step(0.94, a.z);
    color = mix(color, float3(0.05), step(1.5, edge) * 0.85);
    return float4(color, 1.0);
}

struct BackgroundVertex {
    float4 position [[position]];
    float2 uv;
};

vertex BackgroundVertex background_vertex(uint vid [[vertex_id]]) {
    // One triangle that covers the screen.
    const float2 p = float2((vid << 1) & 2, vid & 2);
    BackgroundVertex out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(p.x, 1.0 - p.y);
    return out;
}

fragment float4 background_fragment(BackgroundVertex in [[stage_in]], constant CubeUniforms &u [[buffer(0)]]) {
    const float t = u.time * 0.25;
    const float3 a = float3(0.06, 0.07, 0.12);
    const float3 b = float3(0.16, 0.10, 0.24);
    const float k = 0.5 + 0.5 * sin(in.uv.x * 2.0 + in.uv.y * 3.0 + t);
    return float4(mix(a, b, k * in.uv.y), 1.0);
}
