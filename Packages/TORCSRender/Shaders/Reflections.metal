// SPDX-License-Identifier: GPL-2.0-only
//
// Screen-space reflections.
//
// The forward pass reflects a sky probe: every smooth surface shows a
// horizon-to-horizon sky and nothing of the circuit. A screen-space march
// replaces that where the reflected point is on screen — barriers and trees in
// a windscreen, the pit wall in the paint, the sky and cars in a wet track.
//
// It serves only the sharp white lobe: the clear coat on paint, glass, and a
// smooth dielectric such as wet asphalt. The rough coloured base lobe of a
// metal is left to the probe, which is what a blurred reflection of a mostly
// off-screen world looks like anyway. That choice is what makes the specular
// weight a scalar and the composite a single additive pass.
#ifndef TORCS_REFLECTIONS_METAL
#define TORCS_REFLECTIONS_METAL

#include <metal_stdlib>
#include "Forward.metal"
#include "Atmosphere.metal"
using namespace metal;

struct ReflectionUniforms {
    float4x4 projection;
    float4x4 inverseProjection;
    float4x4 view;
    /// Sun direction in view space, w unused.
    float4 sunDirectionView;
    /// xy depth size in pixels, zw reciprocal.
    float4 depthSize;
    /// x maximum march distance in metres, y thickness in metres,
    /// z roughness above which no reflection is traced, w frame index.
    float4 parameters;
};

inline float reflectionLinearDepth(float deviceDepth, constant ReflectionUniforms &u) {
    return u.projection[3][2] / max(deviceDepth, 1e-7f);
}

inline float3 reflectionViewPosition(float2 uv, float deviceDepth, constant ReflectionUniforms &u) {
    float2 ndc = float2(uv.x * 2.0f - 1.0f, 1.0f - uv.y * 2.0f);
    float4 clip = u.inverseProjection * float4(ndc, deviceDepth, 1.0f);
    return clip.xyz / clip.w;
}

inline float reflectionNoise(float2 pixel, float frame) {
    pixel += frame * float2(47.0f, 17.0f) * 0.695f;
    return fract(52.9829189f * fract(dot(pixel, float2(0.06711056f, 0.00583715f))));
}

constant int kReflectionSteps = 24;
constant int kRefineSteps = 4;

/// rgb reflected radiance, a confidence in [0, 1]. Zero alpha where nothing
/// was traced or the ray left the screen; the composite then keeps the probe.
fragment float4 reflectionFragment(FullscreenVarying in [[stage_in]],
                                   depth2d<float> depth [[texture(0)]],
                                   texture2d<float> surface [[texture(1)]],
                                   texture2d<float> colour [[texture(2)]],
                                   constant ReflectionUniforms &u [[buffer(0)]]) {
    constexpr sampler pointSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);

    float deviceDepth = depth.sample(pointSampler, in.uv);
    if (deviceDepth <= 0.0f) { return float4(0.0f); }
    float4 s = surface.sample(pointSampler, in.uv);
    float roughness = s.z, weight = s.w;
    if (weight <= 1e-3f || roughness > u.parameters.z) { return float4(0.0f); }

    float3 position = reflectionViewPosition(in.uv, deviceDepth, u);
    float3 normal = normalize((u.view * float4(decodeReflectionNormal(s.xy), 0.0f)).xyz);
    float3 view = normalize(-position);
    float3 direction = reflect(-view, normal);
    // A ray toward the camera cannot be found on screen.
    if (direction.z > 0.0f && dot(direction, view) > 0.98f) { return float4(0.0f); }

    float maxDistance = u.parameters.x, thickness = u.parameters.y;
    float noise = reflectionNoise(floor(in.position.xy), u.parameters.w);
    // Start off the surface, further at distance where a depth texel spans
    // more metres. Without this the first sample lands inside the surface's
    // own depth footprint and every curved panel reflects itself.
    float3 origin = position + normal * (0.02f + 0.004f * -position.z);
    // Step in view space; small near the origin where contact reflections
    // live, growing outward. The jitter breaks the banding a fixed step
    // pattern leaves on flat surfaces.
    float3 ray = origin;
    float travelled = 0.0f;
    float3 last = origin;
    float lastGap = -1.0f;
    float2 hitUV = in.uv;
    bool hit = false;
    for (int i = 0; i < kReflectionSteps && !hit; ++i) {
        float t = (float(i) + 1.0f + noise) / float(kReflectionSteps);
        float distance = maxDistance * t * t;
        ray = origin + direction * distance;
        float4 clip = u.projection * float4(ray, 1.0f);
        if (clip.w <= 1e-4f) { break; }
        float3 ndc = clip.xyz / clip.w;
        float2 uv = float2(ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f);
        if (any(uv < 0.0f) || any(uv > 1.0f)) { break; }
        float sceneDepth = reflectionLinearDepth(depth.sample(pointSampler, uv), u);
        float rayDepth = -ray.z;
        float gap = rayDepth - sceneDepth;
        // A hit is a crossing: the previous sample was in front of the
        // scene and this one behind it. The crossing is refined first and
        // the thickness judged on the refined point — judging the coarse
        // sample threw away nearly every legitimate hit, because a step of
        // a metre overshoots a surface by far more than any thickness.
        if (lastGap <= 0.0f && gap > 0.0f) {
            float3 lo = last, hi = ray;
            float2 refinedUV = uv;
            float refinedGap = gap;
            for (int r = 0; r < kRefineSteps; ++r) {
                float3 mid = (lo + hi) * 0.5f;
                float4 mc = u.projection * float4(mid, 1.0f);
                float3 mn = mc.xyz / mc.w;
                float2 muv = float2(mn.x * 0.5f + 0.5f, 0.5f - mn.y * 0.5f);
                float md = reflectionLinearDepth(depth.sample(pointSampler, muv), u);
                float mg = -mid.z - md;
                if (mg > 0.0f) { hi = mid; refinedUV = muv; refinedGap = mg; } else { lo = mid; }
            }
            float3 hitNormal = normalize((u.view * float4(decodeReflectionNormal(surface.sample(pointSampler, refinedUV).xy), 0.0f)).xyz);
            // Behind something thin, or looking at the far side of an opaque
            // surface: the ray passed a silhouette, not a hit.
            bool thin = refinedGap > thickness + distance * 0.02f;
            bool farSide = dot(hitNormal, direction) > 0.15f;
            if (!thin && !farSide) {
                hitUV = refinedUV;
                hit = true;
                travelled = distance;
            }
        }
        last = ray;
        lastGap = gap;
    }
    if (!hit) { return float4(0.0f); }

    // Confidence falls off toward the screen edge, with distance, and with
    // roughness: a rough surface's reflection is a blur this pass does not
    // produce, so the probe takes over smoothly rather than at a cut.
    float2 edge = 1.0f - smoothstep(0.85f, 1.0f, abs(hitUV * 2.0f - 1.0f));
    float confidence = edge.x * edge.y;
    confidence *= 1.0f - smoothstep(0.6f, 1.0f, travelled / maxDistance);
    confidence *= 1.0f - smoothstep(u.parameters.z * 0.5f, u.parameters.z, roughness);
    // Sky at the hit: the probe already has the sky, and better.
    float hitDepth = depth.sample(pointSampler, hitUV);
    if (hitDepth <= 0.0f) { return float4(0.0f); }
    float3 radiance = colour.sample(linearSampler, hitUV).rgb;
    // Fireflies from a bloom-bright hit would flicker under the noise.
    radiance = min(radiance, float3(16.0f));
    return float4(radiance, confidence);
}

/// Depth-aware 4×4 blur of the traced result, at the traced resolution. The
/// march jitters its steps per pixel to avoid banding; unfiltered, that
/// jitter is a dither that crawls as the camera moves. Samples across a
/// depth discontinuity are rejected so a reflection does not bleed off its
/// surface; confidence is blurred with the radiance so the two stay
/// consistent at the edges of a hit region.
fragment float4 reflectionBlurFragment(FullscreenVarying in [[stage_in]],
                                       texture2d<float> traced [[texture(0)]],
                                       depth2d<float> depth [[texture(1)]],
                                       constant ReflectionUniforms &u [[buffer(0)]]) {
    constexpr sampler pointSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    float centreDepth = reflectionLinearDepth(depth.sample(pointSampler, in.uv), u);
    if (centreDepth > 1e6f) { return float4(0.0f); }
    float2 texel = 1.0f / float2(traced.get_width(), traced.get_height());
    float4 total = 0.0f;
    float weightSum = 0.0f;
    for (int y = -2; y < 2; ++y) {
        for (int x = -2; x < 2; ++x) {
            float2 uv = in.uv + float2(float(x) + 0.5f, float(y) + 0.5f) * texel;
            float sampleDepth = reflectionLinearDepth(depth.sample(pointSampler, uv), u);
            float weight = saturate(1.0f - abs(sampleDepth - centreDepth) / (centreDepth * 0.04f));
            total += traced.sample(pointSampler, uv) * weight;
            weightSum += weight;
        }
    }
    return weightSum > 0.0f ? total / weightSum : traced.sample(pointSampler, in.uv);
}

/// Adds `confidence · weight · (reflected − probe)` onto the scene colour.
/// Bound with one/one additive blending, so a negative difference darkens
/// the pixel exactly where the probe overstated it.
fragment float4 reflectionCompositeFragment(FullscreenVarying in [[stage_in]],
                                            texture2d<float> reflection [[texture(0)]],
                                            texture2d<float> surface [[texture(1)]],
                                            depth2d<float> depth [[texture(2)]],
                                            texture2d<float> skyViewLUT [[texture(3)]],
                                            constant ReflectionUniforms &u [[buffer(0)]]) {
    constexpr sampler pointSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    constexpr sampler skySampler(coord::normalized, address::repeat, filter::linear, mip_filter::linear);
    float4 r = reflection.sample(linearSampler, in.uv);
    if (r.a <= 1e-3f) { return float4(0.0f); }
    float4 s = surface.sample(pointSampler, in.uv);
    float deviceDepth = depth.sample(pointSampler, in.uv);
    if (deviceDepth <= 0.0f) { return float4(0.0f); }
    float3 position = reflectionViewPosition(in.uv, deviceDepth, u);
    float3 normal = decodeReflectionNormal(s.xy);
    // The probe the forward pass added for this lobe, so it can be taken back.
    float3 viewDirectionWorld = normalize((transpose(u.view) * float4(-normalize(position), 0.0f)).xyz);
    float3 reflected = reflect(-viewDirectionWorld, normal);
    float mipCount = float(max(skyViewLUT.get_num_mip_levels(), 1u) - 1u);
    float3 probe = skyViewLUT.sample(skySampler, skyViewUV(reflected), level(s.z * mipCount)).rgb;
    return float4((r.rgb - probe) * (r.a * s.w), 0.0f);
}

#endif
