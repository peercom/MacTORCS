// SPDX-License-Identifier: GPL-2.0-only
// Skid marks: quads on the road, drawn as a multiplicative darkening.
#ifndef TORCS_SKIDMARKS_METAL
#define TORCS_SKIDMARKS_METAL
#include <metal_stdlib>
#include "Forward.metal"
using namespace metal;

struct SkidVertex {
    float4 positionIntensity;   // xyz world, w darkness 0–1
    float4 uv;                  // x metres along, y across 0–1
};

struct SkidVarying {
    float4 position [[position]];
    float2 uv;
    float intensity;
};

vertex SkidVarying skidVertex(uint id [[vertex_id]],
                              const device SkidVertex *vertices [[buffer(0)]],
                              constant FrameUniforms &frame [[buffer(1)]]) {
    SkidVertex v = vertices[id];
    SkidVarying out;
    out.position = frame.viewProjection * float4(v.positionIntensity.xyz, 1.0f);
    out.uv = v.uv.xy;
    out.intensity = v.positionIntensity.w;
    return out;
}

inline float skidHash(float2 p) {
    return fract(sin(dot(p, float2(127.1f, 311.7f))) * 43758.5453f);
}

/// Darkness: the tread's grooves as bands across the mark, broken up along
/// its length so it reads as rubber ground off rather than paint.
fragment float4 skidFragment(SkidVarying in [[stage_in]]) {
    float across = in.uv.y, along = in.uv.x;
    // Four tread bands, softened toward the edges of the tyre.
    float bands = 0.6f + 0.4f * sin(across * 4.0f * 2.0f * M_PI_F);
    float edge = smoothstep(0.0f, 0.12f, across) * smoothstep(1.0f, 0.88f, across);
    // Longitudinal breakup at two scales.
    float2 cell = float2(floor(along * 6.0f), floor(across * 5.0f));
    float grain = 0.7f + 0.3f * skidHash(cell);
    float streak = 0.75f + 0.25f * sin(along * 2.1f + skidHash(float2(cell.y, 0.0f)) * 6.0f);
    float darkness = saturate(in.intensity * 0.55f * bands * edge * grain * streak);
    return float4(darkness, darkness, darkness, 1.0f);
}

/// Painted outline: white where the fragment is within a line's width of
/// the box's edge, in metres along (uv.x of uv.z) and across (uv.y of
/// uv.w). Worn a little, like paint that has had cars over it.
fragment float4 roadPaintFragment(SkidVarying in [[stage_in]],
                                  constant float4 &paint [[buffer(2)]]) {
    // uv.x along in metres, uv.y across in metres; the box size travels in
    // the vertex's uv.zw, interpolated flat across the quad.
    float along = in.uv.x, across = in.uv.y;
    float lineWidth = paint.x;
    float edgeAlong = min(along, paint.z - along), edgeAcross = min(across, paint.w - across);
    float d = min(edgeAlong, edgeAcross);
    float coverage = 1.0f - smoothstep(lineWidth - 0.02f, lineWidth + 0.02f, d);
    float wear = 0.75f + 0.25f * skidHash(floor(float2(along, across) * 7.0f));
    float alpha = coverage * wear * paint.y;
    return float4(float3(0.85f, 0.85f, 0.82f), alpha);
}

#endif
