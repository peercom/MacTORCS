// SPDX-License-Identifier: GPL-2.0-only
#ifndef TORCS_RESOLVE_METAL
#define TORCS_RESOLVE_METAL

#include <metal_stdlib>
#include "Forward.metal"
#include "Post.metal"
#include "Bloom.metal"
using namespace metal;

/// Maps the HDR scene target to the display. Bloom, motion blur and temporal
/// upscaling insert themselves ahead of this in later phases.
fragment float4 resolveFragment(FullscreenVarying in [[stage_in]],
                                texture2d<float> scene [[texture(0)]],
                                texture2d<float> bloom [[texture(1)]],
                                constant float &exposureScale [[buffer(0)]],
                                constant float &bloomStrength [[buffer(1)]]) {
    constexpr sampler pointSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    // The pyramid was built from exposed values (see bloomPrefilter), so the
    // scene is exposed here to match and the tonemapper is given unit scale.
    float3 radiance = scene.sample(pointSampler, in.uv).rgb * exposureScale;
    if (bloomStrength > 0.0f) {
        // Added rather than mixed. Mixing with a *thresholded* pyramid would
        // darken the entire frame by the blend weight, since most pixels
        // contribute nothing to the pyramid — a global error in exchange for
        // energy conservation. Adding instead overstates total energy slightly,
        // which is also what a real lens does: its point spread function keeps a
        // bright core and adds a halo rather than draining the core into it.
        radiance += bloom.sample(linearSampler, in.uv).rgb * bloomStrength;
    }
    float3 mapped = tonemapAgX(radiance, 1.0f);
    uint2 pixel = uint2(in.position.xy);
    return float4(ditherForDisplay(mapped, pixel), 1.0f);
}

#endif
