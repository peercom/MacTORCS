// SPDX-License-Identifier: GPL-2.0-only
//
// Bloom, by progressive downsample and upsample (Jimenez, "Next Generation
// Post Processing in Call of Duty: Advanced Warfare").
//
// The classic path clamped to [0, 1], so there was never anything brighter
// than white to bleed. Now that radiance is unbounded, the very bright parts of
// a frame — sun glints on paint, the sun disc itself, sky through foliage —
// should spread into their surroundings the way a real lens makes them.
//
// A chain of halvings rather than a wide blur: each step is a small filter, and
// the pyramid gives a very wide kernel for a cost that is dominated by the
// first, largest level.
#ifndef TORCS_BLOOM_METAL
#define TORCS_BLOOM_METAL

#include <metal_stdlib>
#include "Forward.metal"
using namespace metal;

struct BloomUniforms {
    /// xy source texel size, z threshold in exposed units, w exposure scale.
    float4 parameters;
};

/// Thirteen-tap downsample. The partial overlapping boxes are what stop the
/// pyramid from flickering: a naive bilinear halving aliases, and with a
/// temporal history that aliasing becomes visible crawling.
inline float3 downsampleThirteen(texture2d<float> source, sampler linearSampler, float2 uv, float2 texel) {
    float3 a = source.sample(linearSampler, uv + texel * float2(-2, -2)).rgb;
    float3 b = source.sample(linearSampler, uv + texel * float2( 0, -2)).rgb;
    float3 c = source.sample(linearSampler, uv + texel * float2( 2, -2)).rgb;
    float3 d = source.sample(linearSampler, uv + texel * float2(-1, -1)).rgb;
    float3 e = source.sample(linearSampler, uv + texel * float2( 1, -1)).rgb;
    float3 f = source.sample(linearSampler, uv + texel * float2(-2,  0)).rgb;
    float3 g = source.sample(linearSampler, uv).rgb;
    float3 h = source.sample(linearSampler, uv + texel * float2( 2,  0)).rgb;
    float3 i = source.sample(linearSampler, uv + texel * float2(-1,  1)).rgb;
    float3 j = source.sample(linearSampler, uv + texel * float2( 1,  1)).rgb;
    float3 k = source.sample(linearSampler, uv + texel * float2(-2,  2)).rgb;
    float3 l = source.sample(linearSampler, uv + texel * float2( 0,  2)).rgb;
    float3 m = source.sample(linearSampler, uv + texel * float2( 2,  2)).rgb;

    float3 result = (d + e + i + j) * 0.125f;
    result += (a + b + g + f) * 0.03125f;
    result += (b + c + h + g) * 0.03125f;
    result += (f + g + l + k) * 0.03125f;
    result += (g + h + m + l) * 0.03125f;
    return result;
}

/// Soft-kneed threshold. A hard cutoff makes bloom pop on and off as a
/// highlight crosses it, which is far more noticeable than the bloom itself.
inline float3 thresholded(float3 colour, float threshold) {
    float brightness = max(colour.r, max(colour.g, colour.b));
    float knee = threshold * 0.5f;
    float soft = clamp(brightness - threshold + knee, 0.0f, 2.0f * knee);
    soft = soft * soft / (4.0f * knee + 1e-5f);
    float contribution = max(soft, brightness - threshold) / max(brightness, 1e-5f);
    return colour * contribution;
}

fragment float4 bloomPrefilter(FullscreenVarying in [[stage_in]],
                               texture2d<float> source [[texture(0)]],
                               constant BloomUniforms &bloom [[buffer(0)]]) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    // Four-to-one, not two-to-one: the first level is where the cost is, and
    // at native resolution a half-size level costs more than every other pass
    // combined. Four bilinear taps at ±1 source texel cover a 4×4 box exactly,
    // which is a coarser filter than the thirteen-tap halving but the pyramid
    // below blurs far wider than any aliasing this leaves.
    float2 texel = bloom.parameters.xy;
    float3 colour = source.sample(linearSampler, in.uv + texel * float2(-1, -1)).rgb
                  + source.sample(linearSampler, in.uv + texel * float2( 1, -1)).rgb
                  + source.sample(linearSampler, in.uv + texel * float2(-1,  1)).rgb
                  + source.sample(linearSampler, in.uv + texel * float2( 1,  1)).rgb;
    // Exposed first, so the threshold is relative to the frame's own white
    // point rather than to absolute radiance. A camera blooms where its sensor
    // saturates, and exposure is what decides where that is; a fixed radiance
    // threshold would bloom nothing at a bright exposure and everything at a
    // dim one.
    colour *= 0.25f * bloom.parameters.w;
    // Clamped before thresholding: one extremely bright texel, such as the sun
    // disc, would otherwise dominate the whole pyramid and produce a flat wash.
    colour = min(colour, float3(64.0f));
    return float4(thresholded(colour, bloom.parameters.z), 1.0f);
}

fragment float4 bloomDownsample(FullscreenVarying in [[stage_in]],
                                texture2d<float> source [[texture(0)]],
                                constant BloomUniforms &bloom [[buffer(0)]]) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    return float4(downsampleThirteen(source, linearSampler, in.uv, bloom.parameters.xy), 1.0f);
}

/// Three-by-three tent upsample, added onto the level above. The tent is what
/// makes the result smooth: a bilinear upsample leaves the pyramid's structure
/// visible as soft square blocks.
fragment float4 bloomUpsample(FullscreenVarying in [[stage_in]],
                              texture2d<float> source [[texture(0)]],
                              constant BloomUniforms &bloom [[buffer(0)]]) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 texel = bloom.parameters.xy;
    float3 result = source.sample(linearSampler, in.uv + texel * float2(-1,  1)).rgb;
    result += source.sample(linearSampler, in.uv + texel * float2( 0,  1)).rgb * 2.0f;
    result += source.sample(linearSampler, in.uv + texel * float2( 1,  1)).rgb;
    result += source.sample(linearSampler, in.uv + texel * float2(-1,  0)).rgb * 2.0f;
    result += source.sample(linearSampler, in.uv).rgb * 4.0f;
    result += source.sample(linearSampler, in.uv + texel * float2( 1,  0)).rgb * 2.0f;
    result += source.sample(linearSampler, in.uv + texel * float2(-1, -1)).rgb;
    result += source.sample(linearSampler, in.uv + texel * float2( 0, -1)).rgb * 2.0f;
    result += source.sample(linearSampler, in.uv + texel * float2( 1, -1)).rgb;
    return float4(result * (1.0f / 16.0f), 1.0f);
}

#endif
