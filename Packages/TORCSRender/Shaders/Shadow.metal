// SPDX-License-Identifier: GPL-2.0-only
//
// Cascaded shadow maps.
//
// The classic path cast no real shadows: a car had a projected textured blob
// refitted to the terrain, and track shadows were a baked texture projected
// onto car bodies. Nothing cast onto anything else. This casts everything onto
// everything.
#ifndef TORCS_SHADOW_METAL
#define TORCS_SHADOW_METAL

#include <metal_stdlib>
#include "Common.metal"
using namespace metal;

constant uint kMaxCascades = 4;

struct ShadowUniforms {
    float4x4 cascadeViewProjection[kMaxCascades];
    /// View-space distance where each cascade stops being used.
    float4 splitDistances;
    /// World size of one texel per cascade; scales bias and filter radius.
    float4 texelWorldSizes;
    /// Metres per unit of normalized depth, per cascade.
    float4 depthRanges;
    /// x cascade count, y depth bias in shadow texels, z normal bias scale, w filter radius in texels.
    float4 parameters;
};

struct ShadowVarying {
    float4 position [[position, invariant]];
};

/// Depth-only. No fragment shader is bound, so this is as cheap as the geometry
/// allows.
vertex ShadowVarying shadowVertex(uint id [[vertex_id]],
                                  const device PackedVertex *vertices [[buffer(0)]],
                                  constant float4x4 &modelViewProjection [[buffer(1)]]) {
    ShadowVarying out;
    out.position = modelViewProjection * float4(float3(vertices[id].position), 1.0f);
    return out;
}

struct ShadowSwayUniforms {
    float4x4 viewProjection;
    float4x4 model;
    float4 time;    // x animation time in seconds
};

/// Foliage: the forward vertex shader's sway, applied in world space before
/// the cascade projection, so the shadow of a tree moves with the tree.
/// The formula must stay identical to Forward.metal's.
vertex ShadowVarying shadowSwayVertex(uint id [[vertex_id]],
                                      const device PackedVertex *vertices [[buffer(0)]],
                                      constant ShadowSwayUniforms &u [[buffer(1)]]) {
    PackedVertex v = vertices[id];
    float4 world = u.model * float4(float3(v.position), 1.0f);
    float h = float(v.blend.x) * (1.0f / 255.0f);
    float amplitude = float(v.blend.y) * (0.25f / 255.0f);
    float t = u.time.x;
    float2 sway = float2(sin(t * 1.1f + world.x * 0.05f + world.y * 0.07f),
                         cos(t * 0.9f + world.y * 0.06f - world.x * 0.04f)) * (h * h * amplitude);
    world.xy += sway;
    ShadowVarying out;
    out.position = u.viewProjection * world;
    return out;
}

/// Selects the tightest cascade that still contains this fragment.
inline uint selectCascade(constant ShadowUniforms &shadow, float viewDepth) {
    uint count = uint(shadow.parameters.x);
    for (uint i = 0; i < count && i < kMaxCascades; ++i) {
        if (viewDepth < shadow.splitDistances[i]) { return i; }
    }
    return count > 0 ? count - 1 : 0;
}

/// Percentage-closer filtering with a rotated Poisson disc.
///
/// The rotation is per-pixel, from interleaved gradient noise, so the residual
/// error is high-frequency noise rather than a fixed pattern. A fixed kernel
/// leaves a visible grid on large flat surfaces, which is most of a racetrack.
inline float sampleShadow(constant ShadowUniforms &shadow,
                          depth2d_array<float> shadowMap,
                          sampler shadowSampler,
                          float3 worldPosition, float3 normal, float3 lightDirection,
                          float viewDepth, float2 screenPixel) {
    uint count = uint(shadow.parameters.x);
    if (count == 0) { return 1.0f; }
    uint cascade = selectCascade(shadow, viewDepth);
    float texelWorldSize = shadow.texelWorldSizes[cascade];

    // Offset along the normal by about one texel before projecting. This is
    // what removes acne on surfaces at a grazing angle to the sun without the
    // peter-panning a large constant bias causes.
    float slope = 1.0f - abs(dot(normal, lightDirection));
    float3 offset = normal * texelWorldSize * (1.0f + slope * 2.0f) * shadow.parameters.z;
    float4 lightClip = shadow.cascadeViewProjection[cascade] * float4(worldPosition + offset, 1.0f);
    float3 projected = lightClip.xyz / lightClip.w;

    float2 uv = projected.xy * float2(0.5f, -0.5f) + 0.5f;
    // Outside the cascade, or behind the light: unshadowed rather than wrong.
    if (any(uv < 0.0f) || any(uv > 1.0f) || projected.z > 1.0f || projected.z < 0.0f) { return 1.0f; }

    // Scaled by the cascade's own texel size, then converted to normalized
    // depth. Cascade 3's texels are eleven times cascade 0's, so a single
    // metre value cannot suit both; a texel-relative one does.
    float biasMetres = shadow.parameters.y * texelWorldSize * (1.0f + slope * 4.0f);
    float bias = biasMetres / shadow.depthRanges[cascade];
    float reference = projected.z - bias;

    constexpr float2 poisson[8] = {
        float2(-0.7071f, 0.7071f), float2(0.0f, -0.8750f), float2(0.5303f, 0.5303f),
        float2(-0.625f, 0.0f), float2(0.3536f, -0.3536f), float2(0.75f, 0.0f),
        float2(-0.4243f, -0.4243f), float2(0.0f, 0.875f)
    };
    float angle = fract(52.9829189f * fract(dot(screenPixel, float2(0.06711056f, 0.00583715f)))) * 6.2831853f;
    float sinAngle = sin(angle), cosAngle = cos(angle);
    float2x2 rotation = float2x2(float2(cosAngle, sinAngle), float2(-sinAngle, cosAngle));

    float radius = shadow.parameters.w / float(shadowMap.get_width());
    float sum = 0.0f;
    for (uint i = 0; i < 8; ++i) {
        float2 tap = uv + rotation * poisson[i] * radius;
        // Hardware comparison gives a free 2x2 within each tap.
        sum += shadowMap.sample_compare(shadowSampler, tap, cascade, reference);
    }
    float visibility = sum * (1.0f / 8.0f);

    // Fade the last cascade out rather than ending it with a hard line.
    float lastSplit = shadow.splitDistances[count - 1];
    float fade = saturate((viewDepth - lastSplit * 0.85f) / max(lastSplit * 0.15f, 1e-3f));
    return mix(visibility, 1.0f, fade);
}

#endif
