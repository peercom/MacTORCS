// SPDX-License-Identifier: GPL-2.0-only
#ifndef TORCS_RESOLVE_METAL
#define TORCS_RESOLVE_METAL

#include <metal_stdlib>
#include "Forward.metal"
#include "Post.metal"
using namespace metal;

/// Maps the HDR scene target to the display. Bloom, motion blur and temporal
/// upscaling insert themselves ahead of this in later phases.
fragment float4 resolveFragment(FullscreenVarying in [[stage_in]],
                                texture2d<float> scene [[texture(0)]],
                                constant float &exposureScale [[buffer(0)]]) {
    constexpr sampler pointSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    float3 radiance = scene.sample(pointSampler, in.uv).rgb;
    float3 mapped = tonemapAgX(radiance, exposureScale);
    uint2 pixel = uint2(in.position.xy);
    return float4(ditherForDisplay(mapped, pixel), 1.0f);
}

#endif
