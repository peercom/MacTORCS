// SPDX-License-Identifier: GPL-2.0-only
//
// What the tonemap pass reads the scene through: per-pixel motion blur from
// the velocity buffer, and the filter that scales a scene rendered below the
// picture's resolution up to it.
//
// The velocity the forward pass writes is the offset, in render pixels, from
// a pixel to where it was last frame — for static geometry that is the
// camera's own motion, for cars and wheels their own on top. Integrating
// colour along that offset is what turns a sharp frame at 200 km/h into one
// that reads as 200 km/h. A single gather along the centre pixel's velocity
// is the cheap form; it smears silhouettes slightly, which at racing speeds
// is invisible and at rest does not happen.
//
// Both used to be passes of their own, each writing five million HDR pixels
// for the next to read back: the blur into a second scene-sized target, the
// scale through MetalFX, which at 2880x1720 cost more than rendering at 85%
// saved. Here they are a few more samples in the pass that was reading the
// scene anyway.
#ifndef TORCS_MOTIONBLUR_METAL
#define TORCS_MOTIONBLUR_METAL

#include <metal_stdlib>
#include "Forward.metal"
using namespace metal;

struct MotionBlurUniforms {
    /// xy reciprocal of the scene texture's size, z shutter fraction of a
    /// frame, w maximum blur radius in scene pixels.
    float4 parameters;
    /// xy ratio of scene pixels to velocity pixels (an upscaler ahead of
    /// this changes it), z tap count or 0 for no blur, w nonzero when the
    /// scene is smaller than the picture and is to be filtered up to it.
    float4 scale;
    /// The half-resolution copy of the scene: x nonzero when one is bound,
    /// y and z the streak lengths in scene pixels between which the taps
    /// move over to it.
    float4 coarse;
};

/// The scene at half its size each way, for the blur's long streaks: one
/// bilinear sample at the middle of each two-by-two block. Bright values are
/// clamped here as the blur clamps its taps, so a sun glint does not streak
/// across the frame with more energy than it had.
fragment float4 sceneHalveFragment(FullscreenVarying in [[stage_in]],
                                   texture2d<float> scene [[texture(0)]]) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    return float4(min(scene.sample(linearSampler, in.uv, level(0.0f)).rgb, float3(64.0f)), 1.0f);
}

/// Catmull-Rom from five bilinear taps: the cross of the nine-tap form, the
/// corners left out and the weights renormalised. Sharper than a bilinear
/// stretch, which is what makes 85% read as nearly native.
///
/// Filtered on exposed values through a reversible tonemap: the kernel has
/// negative lobes, and next to the sun's disc or a glint they would
/// otherwise cut a dark ring into the picture.
inline float3 sampleSceneFiltered(texture2d<float> scene, float2 uv, float2 size, float exposure) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 position = uv * size;
    float2 centre = floor(position - 0.5f) + 0.5f;
    float2 f = position - centre;
    float2 w0 = f * (-0.5f + f * (1.0f - 0.5f * f));
    float2 w1 = 1.0f + f * f * (-2.5f + 1.5f * f);
    float2 w2 = f * (0.5f + f * (2.0f - 1.5f * f));
    float2 w3 = f * f * (-0.5f + 0.5f * f);
    float2 w12 = w1 + w2;
    float2 texel = 1.0f / size;
    float2 p0 = (centre - 1.0f) * texel;
    float2 p3 = (centre + 2.0f) * texel;
    float2 p12 = (centre + w2 / w12) * texel;
    float4 total = float4(0.0f);
    #define TORCS_SCENE_TAP(u, v, weight) { \
        float3 s = scene.sample(linearSampler, float2(u, v), level(0.0f)).rgb * exposure; \
        s /= 1.0f + max(s.r, max(s.g, s.b)); \
        total += float4(s, 1.0f) * (weight); }
    TORCS_SCENE_TAP(p12.x, p0.y, w12.x * w0.y)
    TORCS_SCENE_TAP(p0.x, p12.y, w0.x * w12.y)
    TORCS_SCENE_TAP(p12.x, p12.y, w12.x * w12.y)
    TORCS_SCENE_TAP(p3.x, p12.y, w3.x * w12.y)
    TORCS_SCENE_TAP(p12.x, p3.y, w12.x * w3.y)
    #undef TORCS_SCENE_TAP
    float3 mapped = clamp(total.rgb / total.a, 0.0f, 0.999f);
    return mapped / (1.0f - max(mapped.r, max(mapped.g, mapped.b))) / max(exposure, 1e-20f);
}

/// The scene's radiance at `uv` as the tonemapper should see it: blurred
/// along the pixel's motion where it moves, filtered up where the scene is
/// smaller than the picture, and otherwise the texel itself.
inline float3 sceneRadiance(texture2d<float> scene, texture2d<float> sceneHalf, texture2d<float> velocity,
                            float2 uv, float2 pixel, constant MotionBlurUniforms &u, float exposure) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    constexpr sampler pointSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    // Every sample here names its level. None of these textures has mips,
    // and a sample that has to work its level out from derivatives cannot
    // sit inside a branch: the compiler takes it for every pixel, which
    // made the blur's taps and the filter's the cost of a still frame too.
    if (u.scale.z > 0.0f) {
        // Velocity points to where the pixel *was*; the blur spans both ways
        // around the current position, half a shutter each side.
        float2 v = velocity.sample(pointSampler, uv, level(0.0f)).xy * u.scale.xy * u.parameters.z;
        float length2 = dot(v, v);
        if (length2 >= 0.25f) {
            float lengthPixels = sqrt(length2);
            if (lengthPixels > u.parameters.w) { v *= u.parameters.w / lengthPixels; }
            float2 stepUV = v * u.parameters.xy;
            int most = max(int(u.scale.z), 2);
            // Jittered start so the taps do not band; the pattern is smooth
            // enough that a temporal history would average it, and coarse
            // enough not to need one.
            float jitter = fract(52.9829189f * fract(dot(floor(pixel), float2(0.06711056f, 0.00583715f))));
            float3 total = 0.0f;
            // A long streak is gathered from the half-resolution copy, with
            // half the taps. A tap costs the same from either texture — the
            // copy with all eight measured slower than no copy, by the
            // copy's own pass — so the saving is in needing fewer: a texel
            // there is already the average of four, and four taps cover the
            // longest streak as closely as eight did on the scene. Short
            // streaks stay on the scene itself, which a copy at half size
            // would only soften. Between the two lengths the choice is
            // dithered per pixel, so no line shows where one takes over.
            float choose = fract(jitter * 7.31f + 0.37f);
            if (u.coarse.x > 0.0f && lengthPixels >= mix(u.coarse.y, u.coarse.z, choose)) {
                int taps = clamp(int(ceil(lengthPixels * 0.25f)) + 1, 2, max(most / 2, 2));
                for (int i = 0; i < taps; ++i) {
                    float t = (float(i) + jitter) / float(taps) - 0.5f;
                    total += sceneHalf.sample(linearSampler, uv + stepUV * t, level(0.0f)).rgb;
                }
                return total / float(taps);
            }
            // As many taps as the streak is long: one every two pixels is as
            // fine as linear sampling resolves.
            int taps = clamp(int(ceil(lengthPixels * 0.5f)) + 1, 2, most);
            for (int i = 0; i < taps; ++i) {
                float t = (float(i) + jitter) / float(taps) - 0.5f;
                float3 sample = scene.sample(linearSampler, uv + stepUV * t, level(0.0f)).rgb;
                // Bright taps are clamped so a sun glint does not streak
                // across the whole frame with more energy than it had.
                total += min(sample, float3(64.0f));
            }
            return total / float(taps);
        }
    }
    if (u.scale.w > 0.0f) { return sampleSceneFiltered(scene, uv, 1.0f / u.parameters.xy, exposure); }
    return scene.sample(pointSampler, uv, level(0.0f)).rgb;
}

#endif
