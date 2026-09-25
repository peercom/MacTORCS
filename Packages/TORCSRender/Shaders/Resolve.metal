// SPDX-License-Identifier: GPL-2.0-only
#ifndef TORCS_RESOLVE_METAL
#define TORCS_RESOLVE_METAL

#include <metal_stdlib>
#include "Forward.metal"
#include "Post.metal"
#include "Bloom.metal"
#include "DepthOfField.metal"
using namespace metal;

struct GlareUniforms {
    float4 sun;         // xy sun position in uv space, z aspect (width / height), w strength (0 = off)
    float4 colour;      // rgb exposed sun colour, w unused
    /// Heat haze: x strength (0 = off), y animation time, z projection near,
    /// w one pixel in uv (1 / height).
    float4 haze;
    /// Depth of field: x focus distance, y circle scale and z largest circle
    /// in the half-resolution target's pixels, w on (0 = off). Uses haze.z.
    float4 focus;
};

/// Heat haze: the far road shimmers. A rising two-octave value noise
/// displaces the sample by a couple of pixels where the opaque depth is a
/// hundred metres or more and not yet at the horizon, and only when the
/// displaced sample is itself far, so a car or a post ahead is never
/// smeared into the road. Strength follows the sun's height.
inline float2 heatHaze(float2 uv, texture2d<float> depth, constant GlareUniforms &g) {
    constexpr sampler pointSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    float deviceDepth = depth.sample(pointSampler, uv).x;
    if (deviceDepth <= 0.0f) { return uv; }
    float linear = g.haze.z / deviceDepth;
    float amount = smoothstep(60.0f, 220.0f, linear) * (1.0f - smoothstep(500.0f, 1400.0f, linear)) * g.haze.x;
    if (amount <= 0.001f) { return uv; }
    float t = g.haze.y;
    float2 n = float2(groundNoise(uv * float2(42.0f, 95.0f) + float2(0.0f, -t * 1.4f)),
                      groundNoise(uv * float2(39.0f, 88.0f) + float2(7.3f, -t * 1.1f))) - 0.5f;
    float2 displaced = uv + n * amount * 2.5f * g.haze.w;
    float other = depth.sample(pointSampler, displaced).x;
    float otherLinear = other > 0.0f ? g.haze.z / other : 1e9f;
    return otherLinear > 45.0f ? displaced : uv;
}

/// Whether the sun is unoccluded: the fraction of a small disc of depth
/// taps around its position that see sky. The depth is reversed and
/// infinite, so sky is exactly zero.
inline float sunVisibility(texture2d<float> depth, float2 sunUV, float aspect) {
    constexpr sampler pointSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    float visible = 0.0f;
    float radius = 0.012f;
    for (int i = 0; i < 12; ++i) {
        float a = float(i) * (2.0f * M_PI_F / 12.0f);
        float2 uv = sunUV + float2(cos(a) / aspect, sin(a)) * radius;
        if (uv.x < 0.0f || uv.x > 1.0f || uv.y < 0.0f || uv.y > 1.0f) { continue; }
        visible += depth.sample(pointSampler, uv).x <= 0.0f ? 1.0f : 0.0f;
    }
    return visible / 12.0f;
}

/// A halo, an anamorphic streak and a six-point starburst around the sun.
inline float3 sunGlare(float2 uv, constant GlareUniforms &g, float visibility) {
    float2 d = (uv - g.sun.xy) * float2(g.sun.z, 1.0f);
    float r = length(d);
    // Nothing reaches further than this; skip the transcendentals.
    if (r > 1.3f) { return float3(0.0f); }
    float halo = exp(-r * 7.0f) * 0.6f;
    float streak = exp(-abs(d.y) * 70.0f) * exp(-abs(d.x) * 2.2f) * 0.7f;
    float theta = atan2(d.y, d.x);
    // Six soft rays, faint: a hint of a starburst, not a drawn asterisk.
    float star = pow(max(cos(theta * 3.0f), 0.0f), 14.0f) * exp(-r * 5.0f) * 0.12f;
    return g.colour.rgb * (halo + streak + star) * g.sun.w * visibility;
}

struct ResolveVarying {
    float4 position [[position]];
    float2 uv;
    /// The sun's visibility, decided once per triangle rather than once per
    /// pixel: twelve depth taps at three vertices instead of at four
    /// million fragments, which is what made the first version cost 0.4 ms.
    float sunVisibility [[flat]];
};

vertex ResolveVarying resolveVertex(uint id [[vertex_id]],
                                    texture2d<float> depth [[texture(2)]],
                                    constant GlareUniforms &glare [[buffer(2)]]) {
    float2 uv = float2((id << 1) & 2, id & 2);
    ResolveVarying out;
    out.position = float4(uv * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f), 0.0f, 1.0f);
    out.uv = uv;
    out.sunVisibility = glare.sun.w > 0.0f ? sunVisibility(depth, glare.sun.xy, glare.sun.z) : 0.0f;
    return out;
}

/// Maps the HDR scene target to the display. Bloom, motion blur and temporal
/// upscaling insert themselves ahead of this in later phases.
fragment float4 resolveFragment(ResolveVarying in [[stage_in]],
                                texture2d<float> scene [[texture(0)]],
                                texture2d<float> bloom [[texture(1)]],
                                texture2d<float> depth [[texture(2)]],
                                texture2d<float> blurred [[texture(3)]],
                                constant float &exposureScale [[buffer(0)]],
                                constant float &bloomStrength [[buffer(1)]],
                                constant GlareUniforms &glare [[buffer(2)]]) {
    constexpr sampler pointSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 sceneUV = glare.haze.x > 0.0f ? heatHaze(in.uv, depth, glare) : in.uv;
    // The pyramid was built from exposed values (see bloomPrefilter), so the
    // scene is exposed here to match and the tonemapper is given unit scale.
    float3 radiance = scene.sample(pointSampler, sceneUV).rgb * exposureScale;
    if (glare.focus.w > 0.0f) {
        // The blurred half-resolution image where this pixel's own circle is
        // wider than a texel of it; the sharp one where it is not.
        float circle = abs(circleOfConfusion(depth.sample(pointSampler, sceneUV).x,
                                             float4(glare.focus.xyz, glare.haze.z)));
        float blend = saturate(circle - 0.5f);
        radiance = mix(radiance, blurred.sample(linearSampler, sceneUV).rgb * exposureScale, blend);
    }
    if (glare.sun.w > 0.0f && in.sunVisibility > 0.0f) {
        radiance += sunGlare(in.uv, glare, in.sunVisibility);
    }
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
