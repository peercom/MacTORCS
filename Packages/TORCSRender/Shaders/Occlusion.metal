// SPDX-License-Identifier: GPL-2.0-only
//
// Screen-space occlusion: ground-truth ambient occlusion (Jimenez et al.,
// "Practical Realtime Strategies for Accurate Indirect Occlusion", 2016) and
// contact shadows, from the depth prepass alone.
//
// Both answer the same question — is this pixel's surroundings blocking light
// from reaching it — for two different lights. GTAO integrates the visible
// horizon over the hemisphere for the sky; the contact shadow marches one ray
// toward the sun for the gap between a tyre and the tarmac that a 2048² cascade
// spanning hundreds of metres cannot resolve. They share the depth fetches and
// the position reconstruction, so they live in one pass and one `rg8` target.
#ifndef TORCS_OCCLUSION_METAL
#define TORCS_OCCLUSION_METAL

#include <metal_stdlib>
#include "Forward.metal"
using namespace metal;

struct OcclusionUniforms {
    /// Jittered projection, and its inverse, of the frame whose depth this is.
    float4x4 projection;
    float4x4 inverseProjection;
    /// Sun direction in view space, w unused.
    float4 sunDirectionView;
    /// x AO world radius in metres, y contact ray length in metres,
    /// z contact thickness in metres, w frame index for noise rotation.
    float4 parameters;
    /// xy size of the depth texture in pixels, zw its reciprocal.
    float4 depthSize;
    /// x exponent applied to ambient visibility, yzw unused.
    float4 shaping;
};

/// Snaps a coordinate to the centre of the texel a point sampler would fetch.
/// A position reconstructed at the un-snapped coordinate but with the texel's
/// depth sits off the surface by up to half a texel of slope, which on any
/// slanted surface reads as a small occluder and put diagonal stripes on every
/// car body.
inline float2 texelCentre(float2 uv, constant OcclusionUniforms &u) {
    return (floor(uv * u.depthSize.xy) + 0.5f) * u.depthSize.zw;
}

/// Reversed infinite-far projection: near maps to 1, far to 0, and the linear
/// distance falls straight out of the third row.
inline float linearDepth(float deviceDepth, constant OcclusionUniforms &u) {
    // projection[3][2] is `near`; the perspective divide yields depth = near / z.
    return u.projection[3][2] / max(deviceDepth, 1e-7f);
}

/// View-space position of a pixel from its device depth.
inline float3 viewPosition(float2 uv, float deviceDepth, constant OcclusionUniforms &u) {
    float2 ndc = float2(uv.x * 2.0f - 1.0f, 1.0f - uv.y * 2.0f);
    float4 clip = u.inverseProjection * float4(ndc, deviceDepth, 1.0f);
    return clip.xyz / clip.w;
}

/// Normal reconstructed from depth, picking the smaller derivative on each axis
/// so a depth discontinuity beside the pixel does not tilt the normal across it.
inline float3 reconstructNormal(depth2d<float> depth, sampler pointSampler, float2 uv,
                                float3 centre, constant OcclusionUniforms &u) {
    float2 texel = u.depthSize.zw;
    float3 left = viewPosition(uv - float2(texel.x, 0), depth.sample(pointSampler, uv - float2(texel.x, 0)), u);
    float3 right = viewPosition(uv + float2(texel.x, 0), depth.sample(pointSampler, uv + float2(texel.x, 0)), u);
    float3 down = viewPosition(uv + float2(0, texel.y), depth.sample(pointSampler, uv + float2(0, texel.y)), u);
    float3 up = viewPosition(uv - float2(0, texel.y), depth.sample(pointSampler, uv - float2(0, texel.y)), u);
    float3 dx = (length(centre - left) < length(right - centre)) ? (centre - left) : (right - centre);
    float3 dy = (length(centre - up) < length(down - centre)) ? (centre - up) : (down - centre);
    return normalize(cross(dy, dx));
}

/// Interleaved gradient noise: a per-pixel rotation that varies smoothly enough
/// for a small bilateral blur to remove, unlike white noise.
inline float gradientNoise(float2 pixel, float frame) {
    pixel += frame * float2(47.0f, 17.0f) * 0.695f;
    return fract(52.9829189f * fract(dot(pixel, float2(0.06711056f, 0.00583715f))));
}

constant int kSliceCount = 3;
constant int kStepCount = 4;

/// GTAO visibility in [0, 1]; one is unoccluded.
inline float groundTruthOcclusion(depth2d<float> depth, sampler pointSampler, float2 uv,
                                  float3 position, float3 normal, float noise,
                                  constant OcclusionUniforms &u) {
    float3 view = normalize(-position);
    // World radius projected to pixels: metres times focal length over depth.
    float focalPixels = u.projection[1][1] * u.depthSize.y * 0.5f;
    float radiusPixels = u.parameters.x * focalPixels / max(-position.z, 1e-3f);
    // Below a couple of pixels the horizon search has nothing to find. The
    // upper clamp is the cost control: samples scattered across hundreds of
    // pixels of the near ground miss the cache on every fetch, and measured
    // as most of the pass.
    radiusPixels = clamp(radiusPixels, 2.0f, 96.0f);
    float falloffRadius = u.parameters.x;

    float visibility = 0.0f;
    for (int slice = 0; slice < kSliceCount; ++slice) {
        float phi = (float(slice) + noise) * (M_PI_F / float(kSliceCount));
        float2 direction = float2(cos(phi), sin(phi));
        // The slice plane contains the view vector and the screen direction.
        float3 sliceDirection = float3(direction, 0.0f);
        float3 axis = normalize(cross(sliceDirection, view));
        float3 projectedNormal = normal - axis * dot(normal, axis);
        float projectedLength = length(projectedNormal);
        if (projectedLength < 1e-4f) { continue; }
        float3 tangent = cross(view, axis);
        float cosN = clamp(dot(projectedNormal, view) / projectedLength, -1.0f, 1.0f);
        float n = -sign(dot(projectedNormal, tangent)) * acos(cosN);

        // Horizons start at the edge of the hemisphere around the *normal*,
        // not at the view plane. For a surface seen at a grazing angle half
        // of its hemisphere lies behind the screen; starting the search at
        // the view plane would count all of that as occluded, and every
        // road at distance came out a uniform grey.
        float lowHorizon[2] = { cos(n - M_PI_2_F), cos(n + M_PI_2_F) };
        float horizons[2];
        for (int side = 0; side < 2; ++side) {
            float sideSign = side == 0 ? 1.0f : -1.0f;
            float maxCos = lowHorizon[side];
            for (int step = 0; step < kStepCount; ++step) {
                // Quadratic step distribution: dense near the pixel where
                // occluders matter most, sparse at the rim.
                float t = (float(step) + fract(noise * 7.13f + float(step) * 0.37f)) / float(kStepCount);
                // Never closer than a whole pixel. A sub-pixel offset snaps to
                // the pixel's own texel, and a zero-length horizon vector has
                // a cosine of zero — which reads as an occluder at 90° on any
                // surface whose real horizon lies lower. That one sample, at
                // noise-dependent pixels, hatched every flat panel.
                float2 offset = sideSign * direction * max(t * t * radiusPixels, 1.0f) * u.depthSize.zw;
                float2 sampleUV = texelCentre(uv + float2(offset.x, -offset.y), u);
                if (any(sampleUV < 0.0f) || any(sampleUV > 1.0f)) { break; }
                float3 samplePosition = viewPosition(sampleUV, depth.sample(pointSampler, sampleUV), u);
                float3 horizon = samplePosition - position;
                float distance = length(horizon);
                if (distance < 1e-4f) { continue; }
                float cosH = dot(horizon, view) / max(distance, 1e-5f);
                // Distant geometry does not occlude; fade it out so the
                // effect has a physical radius instead of a screen-space one.
                // Full weight over the inner part, then a fade: a linear
                // ramp from zero halved the effect of everything mid-radius.
                float weight = saturate((falloffRadius - distance) / (falloffRadius * 0.6f));
                maxCos = max(maxCos, mix(lowHorizon[side], cosH, weight));
            }
            horizons[side] = maxCos;
        }
        float h0 = -acos(clamp(horizons[0], -1.0f, 1.0f));
        float h1 = acos(clamp(horizons[1], -1.0f, 1.0f));
        // Clamp each horizon to the hemisphere around the normal.
        h0 = n + max(h0 - n, -M_PI_2_F);
        h1 = n + min(h1 - n, M_PI_2_F);
        float sinN = sin(n);
        float arc0 = -cos(2.0f * h0 - n) + cosN + 2.0f * h0 * sinN;
        float arc1 = -cos(2.0f * h1 - n) + cosN + 2.0f * h1 * sinN;
        visibility += projectedLength * 0.25f * (arc0 + arc1);
    }
    // Raw GTAO is faint: a horizon at 45° on one side of one slice removes a
    // quarter of that slice's light, and most cavities present that. The
    // exponent is the standard shaping (XeGTAO's "final value power"); it
    // deepens what is already dark without touching open surfaces.
    return pow(saturate(visibility / float(kSliceCount)), u.shaping.x);
}

constant int kContactSteps = 8;

/// Sun visibility in [0, 1] from a short march toward the sun through the
/// depth buffer. Only nearby occluders count: anything further than the
/// thickness is treated as a thin object the ray passes behind.
inline float contactShadow(depth2d<float> depth, sampler pointSampler, float2 uv,
                           float3 position, float3 normal, float noise,
                           constant OcclusionUniforms &u) {
    float3 sun = u.sunDirectionView.xyz;
    // Facing away from the sun: the BRDF's cosine term already gives zero,
    // and marching from here only produces speckle along the terminator.
    if (dot(normal, sun) <= 0.0f) { return 1.0f; }
    float rayLength = u.parameters.y, thickness = u.parameters.z;
    float3 stride = sun * (rayLength / float(kContactSteps));
    // Start off the surface, by more at distance where a depth texel spans
    // more metres, so the ray does not intersect its own pixel.
    float3 ray = position + normal * (0.01f + 0.002f * -position.z) + stride * noise;
    for (int step = 0; step < kContactSteps; ++step) {
        float4 clip = u.projection * float4(ray, 1.0f);
        if (clip.w <= 1e-4f) { break; }
        float3 ndc = clip.xyz / clip.w;
        float2 sampleUV = float2(ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f);
        if (any(sampleUV < 0.0f) || any(sampleUV > 1.0f)) { break; }
        float sceneDepth = linearDepth(depth.sample(pointSampler, texelCentre(sampleUV, u)), u);
        float rayDepth = -ray.z;
        float gap = rayDepth - sceneDepth;
        // Occluded when the scene surface is in front of the ray, but not so
        // far in front that the ray is behind something thin and unrelated.
        // The lower bound grows with distance for the same reason the start
        // offset does.
        if (gap > 0.005f + 0.002f * rayDepth && gap < thickness) {
            // Soften with distance along the ray so the shadow fades rather
            // than ending in a hard line at the march length.
            return 1.0f - (1.0f - float(step) / float(kContactSteps)) * 0.9f;
        }
        ray += stride;
    }
    return 1.0f;
}

/// R ambient visibility, G sun visibility.
fragment float4 occlusionFragment(FullscreenVarying in [[stage_in]],
                                  depth2d<float> depth [[texture(0)]],
                                  constant OcclusionUniforms &u [[buffer(0)]],
                                  constant uint &features [[buffer(1)]]) {
    constexpr sampler pointSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    // The centre pixel snapped to a depth texel too. At half resolution this
    // pixel's centre lies between depth texels; reconstructing the position at
    // the un-snapped coordinate with a neighbour's depth put it off the
    // surface by half a texel of slope, alternating by row, and the whole road
    // striped. At full resolution the two coincide and it never showed.
    float2 uv = texelCentre(in.uv, u);
    float deviceDepth = depth.sample(pointSampler, uv);
    // Sky: the reversed clear value. Nothing to occlude.
    if (deviceDepth <= 0.0f) { return float4(1.0f, 1.0f, 0.0f, 1.0f); }

    float3 position = viewPosition(uv, deviceDepth, u);
    float noise = gradientNoise(floor(in.position.xy), u.parameters.w);
    float ambient = 1.0f, sun = 1.0f;
    float3 normal = reconstructNormal(depth, pointSampler, uv, position, u);
    if (features & 1u) {
        ambient = groundTruthOcclusion(depth, pointSampler, uv, position, normal, noise, u);
    }
    if (features & 2u) {
        sun = contactShadow(depth, pointSampler, uv, position, normal, noise, u);
    }
    return float4(ambient, sun, 0.0f, 1.0f);
}

/// Depth-aware 4×4 box blur that removes the per-pixel rotation noise without
/// bleeding occlusion across silhouettes. Applied once; the interleaved
/// gradient pattern is designed for exactly this footprint.
fragment float4 occlusionBlurFragment(FullscreenVarying in [[stage_in]],
                                      texture2d<float> occlusion [[texture(0)]],
                                      depth2d<float> depth [[texture(1)]],
                                      constant OcclusionUniforms &u [[buffer(0)]]) {
    constexpr sampler pointSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    float centreDepth = linearDepth(depth.sample(pointSampler, in.uv), u);
    if (centreDepth > 1e6f) { return float4(1.0f, 1.0f, 0.0f, 1.0f); }
    // In the occlusion target's own texels, not the depth buffer's: at half
    // resolution the footprint should still be 4×4 of what was computed.
    float2 texel = 1.0f / float2(occlusion.get_width(), occlusion.get_height());
    float2 total = 0.0f;
    float weightSum = 0.0f;
    for (int y = -2; y < 2; ++y) {
        for (int x = -2; x < 2; ++x) {
            float2 sampleUV = in.uv + float2(float(x) + 0.5f, float(y) + 0.5f) * texel;
            float sampleDepth = linearDepth(depth.sample(pointSampler, sampleUV), u);
            // Reject samples whose depth differs by more than a few percent:
            // that is another surface, and its occlusion is not ours.
            float weight = saturate(1.0f - abs(sampleDepth - centreDepth) / (centreDepth * 0.05f));
            total += occlusion.sample(pointSampler, sampleUV).rg * weight;
            weightSum += weight;
        }
    }
    float2 result = weightSum > 0.0f ? total / weightSum : occlusion.sample(pointSampler, in.uv).rg;
    return float4(result, 0.0f, 1.0f);
}

#endif
