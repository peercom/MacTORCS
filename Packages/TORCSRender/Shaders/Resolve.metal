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


/// The rear-view mirror: a quad at a pixel rectangle of the drawable,
/// showing a separately rendered and tonemapped view looking backward,
/// flipped left to right — a camera looking back puts the car's left on the
/// image's right, and a mirror puts it back on the left.
struct MirrorVarying {
    float4 position [[position]];
    float2 uv;
};

/// x, y, width, height of the quad in normalized device coordinates.
vertex MirrorVarying mirrorVertex(uint id [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
    float2 corner = float2(id & 1u, (id >> 1) & 1u);   // 0,0  1,0  0,1  1,1
    MirrorVarying out;
    out.position = float4(rect.x + corner.x * rect.z, rect.y + corner.y * rect.w, 0.0f, 1.0f);
    // Flipped horizontally; v runs top-down like the texture.
    out.uv = float2(1.0f - corner.x, 1.0f - corner.y);
    return out;
}

fragment float4 mirrorFragment(MirrorVarying in [[stage_in]], texture2d<float> mirror [[texture(0)]]) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    // The mirror texture is display-encoded sRGB; sampling decodes it to
    // linear and the drawable re-encodes it once. A thin dark frame.
    float2 edge = min(in.uv, 1.0f - in.uv);
    float frame = min(edge.x * mirror.get_width(), edge.y * mirror.get_height()) < 2.0f ? 0.15f : 1.0f;
    return float4(mirror.sample(linearSampler, in.uv).rgb * frame, 1.0f);
}

#endif
