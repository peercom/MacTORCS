// SPDX-License-Identifier: GPL-2.0-only
//
// Depth of field for the television and photo views: a thin-lens circle of
// confusion from the depth buffer, a half-resolution gather over a disc
// whose taps are weighted by their own circles (scatter as gather), and a
// composite in the resolve by the full-resolution circle. Never in the
// driver's views: a driver's eyes focus where they look, and a blurred
// mirror or dashboard is a fault, not a look.
#ifndef TORCS_DEPTHOFFIELD_METAL
#define TORCS_DEPTHOFFIELD_METAL

#include <metal_stdlib>
#include "Forward.metal"
using namespace metal;

struct DepthOfFieldUniforms {
    /// x focus distance in metres, y circle scale in target pixels for a
    /// subject at infinity, z largest circle in target pixels, w projection
    /// near for the reversed depth.
    float4 focus;
    /// xy one target texel in uv.
    float4 size;
};

/// Signed circle of confusion in pixels: negative in front of the focus,
/// positive behind, zero at it. Thin lens: proportional to (d − f) / d.
inline float circleOfConfusion(float deviceDepth, float4 focus) {
    // The reversed depth clears to zero: the sky, at infinity.
    float linear = deviceDepth > 0.0f ? focus.w / deviceDepth : 1e9f;
    float circle = focus.y * (linear - focus.x) / max(linear, 1e-3f);
    return clamp(circle, -focus.z, focus.z);
}

/// Half resolution: the scene colour with its circle in the alpha.
fragment float4 dofPrefilterFragment(FullscreenVarying in [[stage_in]],
                                     texture2d<float> scene [[texture(0)]],
                                     texture2d<float> depth [[texture(1)]],
                                     constant DepthOfFieldUniforms &u [[buffer(0)]]) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    constexpr sampler pointSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    float3 colour = scene.sample(linearSampler, in.uv).rgb;
    // The circle of the nearest of the four depth texels under this pixel,
    // so a thin near edge keeps its blur rather than averaging into focus.
    float2 texel = u.size.xy * 0.5f;
    float d0 = depth.sample(pointSampler, in.uv + float2(-texel.x, -texel.y)).x;
    float d1 = depth.sample(pointSampler, in.uv + float2(texel.x, -texel.y)).x;
    float d2 = depth.sample(pointSampler, in.uv + float2(-texel.x, texel.y)).x;
    float d3 = depth.sample(pointSampler, in.uv + float2(texel.x, texel.y)).x;
    // Reversed depth: the largest value is the nearest.
    float nearest = max(max(d0, d1), max(d2, d3));
    return float4(colour, circleOfConfusion(nearest, u.focus));
}

constant int kDofRings = 3;

/// The gather. Every pixel reads the same disc, as wide as the largest
/// circle; each tap counts when its own circle reaches this pixel, and a
/// tap behind the pixel counts no further than the pixel's own circle, so
/// a sharp subject keeps its edge against a blurred background while a
/// blurred foreground still spreads over a sharp one.
fragment float4 dofGatherFragment(FullscreenVarying in [[stage_in]],
                                  texture2d<float> prefiltered [[texture(0)]],
                                  constant DepthOfFieldUniforms &u [[buffer(0)]]) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 centre = prefiltered.sample(linearSampler, in.uv);
    float centreCircle = abs(centre.a);
    float radius = u.focus.z;
    // Most of a photograph is sharp, and a sharp pixel only needs the disc
    // if something blurred can reach it. Eight looks around the rim of the
    // disc, plus the centre: when none carries a circle, nothing does, and
    // the forty-nine taps are skipped. A thin blurred object between the
    // looks is missed, which shows as a slightly harder edge on it.
    if (centreCircle < 0.5f) {
        float widest = centreCircle;
        for (int i = 0; i < 8; ++i) {
            float angle = 0.7853982f * float(i);
            float2 offset = float2(cos(angle), sin(angle)) * radius * u.size.xy;
            widest = max(widest, abs(prefiltered.sample(linearSampler, in.uv + offset).a));
            widest = max(widest, abs(prefiltered.sample(linearSampler, in.uv + offset * 0.5f).a));
        }
        if (widest < 0.5f) { return centre; }
    }
    float3 sum = centre.rgb;
    float weightSum = 1.0f;
    // A small per-pixel rotation turns the rings' residual into noise.
    float angle0 = fract(52.9829189f * fract(dot(in.position.xy, float2(0.06711056f, 0.00583715f)))) * 6.2831853f;
    for (int ring = 1; ring <= kDofRings; ++ring) {
        int taps = ring * 8;
        float distance = radius * float(ring) / float(kDofRings);
        for (int t = 0; t < taps; ++t) {
            float angle = angle0 + 6.2831853f * float(t) / float(taps);
            float2 offset = float2(cos(angle), sin(angle)) * distance;
            float4 tap = prefiltered.sample(linearSampler, in.uv + offset * u.size.xy);
            float tapCircle = abs(tap.a);
            // Behind the pixel (a larger signed circle): limited to the
            // pixel's own circle. In front: its own.
            float reach = tap.a > centre.a ? min(tapCircle, centreCircle) : tapCircle;
            float weight = saturate(reach - distance + 1.0f);
            sum += tap.rgb * weight;
            weightSum += weight;
        }
    }
    return float4(sum / weightSum, centre.a);
}

#endif
