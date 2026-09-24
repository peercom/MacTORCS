// SPDX-License-Identifier: GPL-2.0-only
//
// Per-pixel motion blur from the velocity buffer.
//
// The velocity the forward pass writes for the upscaler is the offset, in
// render pixels, from a pixel to where it was last frame — for static
// geometry that is the camera's own motion, for cars and wheels their own on
// top. Integrating colour along that offset is what turns a sharp frame at
// 200 km/h into one that reads as 200 km/h. A single gather along the centre
// pixel's velocity is the cheap form; it smears silhouettes slightly, which
// at racing speeds is invisible and at rest does not happen.
#ifndef TORCS_MOTIONBLUR_METAL
#define TORCS_MOTIONBLUR_METAL

#include <metal_stdlib>
#include "Forward.metal"
using namespace metal;

struct MotionBlurUniforms {
    /// xy reciprocal of the colour size, z shutter fraction of a frame,
    /// w maximum blur radius in pixels.
    float4 parameters;
    /// xy ratio of velocity pixels to colour pixels (the upscaler changes
    /// it), z tap count, w frame index for the jitter.
    float4 scale;
};

fragment float4 motionBlurFragment(FullscreenVarying in [[stage_in]],
                                   texture2d<float> colour [[texture(0)]],
                                   texture2d<float> velocity [[texture(1)]],
                                   constant MotionBlurUniforms &u [[buffer(0)]]) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    constexpr sampler pointSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    float4 centre = colour.sample(pointSampler, in.uv);
    // Velocity points to where the pixel *was*; the blur spans both ways
    // around the current position, half a shutter each side.
    float2 v = velocity.sample(pointSampler, in.uv).xy * u.scale.xy * u.parameters.z;
    float length2 = dot(v, v);
    if (length2 < 0.25f) { return centre; }
    float lengthPixels = sqrt(length2);
    if (lengthPixels > u.parameters.w) { v *= u.parameters.w / lengthPixels; }
    float2 stepUV = v * u.parameters.xy;

    int taps = max(int(u.scale.z), 2);
    // Jittered start so the taps do not band; the pattern is smooth enough
    // that a temporal history would average it, and coarse enough not to
    // need one.
    float jitter = fract(52.9829189f * fract(dot(floor(in.position.xy), float2(0.06711056f, 0.00583715f))));
    float3 total = 0.0f;
    float weight = 0.0f;
    for (int i = 0; i < taps; ++i) {
        float t = (float(i) + jitter) / float(taps) - 0.5f;
        float3 sample = colour.sample(linearSampler, in.uv + stepUV * t).rgb;
        // Bright taps are clamped so a sun glint does not streak across the
        // whole frame with more energy than it had.
        total += min(sample, float3(64.0f));
        weight += 1.0f;
    }
    return float4(total / weight, centre.a);
}

#endif
