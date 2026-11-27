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
    /// Each cascade as seen from the first. The sun's light is parallel, so
    /// the cascades are one view of the world at four sizes and places:
    /// `cascadeScale[i].xyz` and `cascadeOffset[i].xyz` take the first
    /// cascade's clip position to cascade i's shadow-map uv and depth. The
    /// spare lanes hold what else is looked up per cascade, already
    /// multiplied out: in the scale's w the distance to step along the
    /// normal on a surface facing the sun, in metres (a texel's world size
    /// by the normal bias), and in the offset's w the depth bias there, in
    /// the cascade's normalized depth.
    float4 cascadeScale[kMaxCascades];
    float4 cascadeOffset[kMaxCascades];
    /// x the view distance where the last cascade starts to fade, y the
    /// reciprocal of the distance it fades over, z the filter's radius in
    /// the map's uv, w unused.
    float4 filter;
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

inline float4 shadowSwayPosition(PackedVertex v, constant ShadowSwayUniforms &u) {
    float4 world = u.model * float4(float3(v.position), 1.0f);
    float h = float(v.blend.x) * (1.0f / 255.0f);
    float amplitude = float(v.blend.y) * (0.25f / 255.0f);
    float t = u.time.x;
    float2 sway = float2(sin(t * 1.1f + world.x * 0.05f + world.y * 0.07f),
                         cos(t * 0.9f + world.y * 0.06f - world.x * 0.04f)) * (h * h * amplitude);
    world.xy += sway;
    return world;
}

/// Foliage: the forward vertex shader's sway, applied in world space before
/// the cascade projection, so the shadow of a tree moves with the tree.
/// The formula must stay identical to Forward.metal's.
vertex ShadowVarying shadowSwayVertex(uint id [[vertex_id]],
                                      const device PackedVertex *vertices [[buffer(0)]],
                                      constant ShadowSwayUniforms &u [[buffer(1)]]) {
    float4 world = shadowSwayPosition(vertices[id], u);
    ShadowVarying out;
    out.position = u.viewProjection * world;
    return out;
}

// Cutout casters need the same alpha threshold as their visible surface.
// Opaque geometry keeps the fragment-free fast path above.
struct ShadowCutoutVarying {
    float4 position [[position, invariant]];
    float2 uv;
};
vertex ShadowCutoutVarying shadowCutoutVertex(uint id [[vertex_id]],
        const device PackedVertex *vertices [[buffer(0)]],
        constant float4x4 &modelViewProjection [[buffer(1)]]) {
    ShadowCutoutVarying out;
    out.position = modelViewProjection * float4(float3(vertices[id].position), 1.0f);
    out.uv = float2(vertices[id].uv0);
    return out;
}
vertex ShadowCutoutVarying shadowSwayCutoutVertex(uint id [[vertex_id]],
        const device PackedVertex *vertices [[buffer(0)]],
        constant ShadowSwayUniforms &u [[buffer(1)]]) {
    ShadowCutoutVarying out;
    out.position = u.viewProjection * shadowSwayPosition(vertices[id], u);
    out.uv = float2(vertices[id].uv0);
    return out;
}
fragment void shadowCutoutFragment(ShadowCutoutVarying in [[stage_in]],
        constant float4 &cutout [[buffer(0)]], texture2d<float> albedo [[texture(0)]]) {
    constexpr sampler leaves(coord::normalized, address::repeat, filter::linear, mip_filter::linear);
    float alpha = cutout.y;
    if (cutout.w > 0.0f) { alpha *= albedo.sample(leaves, in.uv * cutout.z).a; }
    if (alpha <= cutout.x) { discard_fragment(); }
}

/// Selects the tightest cascade that still contains this fragment: the
/// number of splits it lies beyond. Counted rather than searched, so there
/// is no loop to leave early; splits past the count are infinitely far.
inline uint selectCascade(constant ShadowUniforms &shadow, float viewDepth) {
    uint count = uint(shadow.parameters.x);
    bool3 beyond = float3(viewDepth) >= shadow.splitDistances.xyz;
    return min(uint(beyond.x) + uint(beyond.y) + uint(beyond.z), max(count, 1u) - 1u);
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
    // Two vectors by the cascade's index, not its matrix: what is read from
    // a place only known per pixel is paid for per pixel, and sixteen
    // floats of matrix with a division by a w that is always one were a
    // quarter of this function's cost.
    float4 scale = shadow.cascadeScale[cascade], shift = shadow.cascadeOffset[cascade];

    // Offset along the normal by about one texel before projecting. This is
    // what removes acne on surfaces at a grazing angle to the sun without the
    // peter-panning a large constant bias causes.
    float slope = 1.0f - abs(dot(normal, lightDirection));
    float3 offset = normal * (scale.w * (1.0f + slope * 2.0f));
    float3 first = (shadow.cascadeViewProjection[0] * float4(worldPosition + offset, 1.0f)).xyz;
    float3 projected = first * scale.xyz + shift.xyz;
    float2 uv = projected.xy;

    // The bias is a number of the cascade's own texels, as normalized depth:
    // cascade 3's texels are eleven times cascade 0's, so a single metre
    // value cannot suit both. A point off the map, or beyond the light's
    // far plane, is unshadowed rather than wrong, and without a branch: the
    // sampler's border is the far plane, and no reference is beyond it. (A
    // slice kept from an earlier frame does not reach all of this frame's.)
    float reference = min(projected.z - shift.w * (1.0f + slope * 4.0f), 1.0f);

    // Fade the last cascade out rather than ending it with a hard line.
    float fade = saturate((viewDepth - shadow.filter.x) * shadow.filter.y);
    if (fade >= 1.0f) { return 1.0f; }

    // The disc turned by the pixel's noise: its two axes, at the filter's
    // radius. Eight taps on it; the first four ring it, one to a quadrant,
    // and the last four fill it in. Written out along the axes, which is
    // half the arithmetic of turning each tap by a matrix.
    float angle = fract(52.9829189f * fract(dot(screenPixel, float2(0.06711056f, 0.00583715f)))) * 6.2831853f;
    float sinAngle = sin(angle), cosAngle = cos(angle);
    float2 across = float2(cosAngle, sinAngle) * shadow.filter.z;
    float2 along = float2(-sinAngle, cosAngle) * shadow.filter.z;

    // Hardware comparison gives a free 2x2 within each tap.
    float sum = shadowMap.sample_compare(shadowSampler, uv + (along - across) * 0.7071f, cascade, reference)
              + shadowMap.sample_compare(shadowSampler, uv - along * 0.875f, cascade, reference)
              + shadowMap.sample_compare(shadowSampler, uv + across * 0.75f, cascade, reference)
              + shadowMap.sample_compare(shadowSampler, uv - across * 0.625f, cascade, reference);
    // Most of a frame is nowhere near a shadow's edge. When the ring agrees,
    // sixteen texels round this point are all lit or all dark and the inner
    // taps would only say so again; they are taken in the penumbra alone,
    // where the result is the same eight-tap average as before.
    float visibility = sum * 0.25f;
    if (sum > 0.0f && sum < 4.0f) {
        sum += shadowMap.sample_compare(shadowSampler, uv + (across + along) * 0.5303f, cascade, reference)
             + shadowMap.sample_compare(shadowSampler, uv + (across - along) * 0.3536f, cascade, reference)
             + shadowMap.sample_compare(shadowSampler, uv - (across + along) * 0.4243f, cascade, reference)
             + shadowMap.sample_compare(shadowSampler, uv + along * 0.875f, cascade, reference);
        visibility = sum * (1.0f / 8.0f);
    }
    return mix(visibility, 1.0f, fade);
}

#endif
