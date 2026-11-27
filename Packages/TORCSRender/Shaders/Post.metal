// SPDX-License-Identifier: GPL-2.0-only
//
// Tonemapping and display encoding.
//
// The classic path had no tonemapper at all: it clamped sRGB-space arithmetic
// to [0, 1], so any highlight brighter than white simply flattened to white.
// That is the single most visible reason it could not look modern. Scene
// radiance here is unbounded and mapped to the display by AgX.
#ifndef TORCS_POST_METAL
#define TORCS_POST_METAL

#include <metal_stdlib>
using namespace metal;

/// AgX (Troy Sobotka). Chosen over Reinhard and filmic ACES because of how it
/// handles the two things a racing frame is full of: a low sun blowing out a
/// large area of sky, and small intense specular glints on clearcoat paint.
/// Reinhard desaturates both into grey; AgX keeps hue while rolling off, which
/// is what reads as photographic.
///
/// Matrices are column-major, matching the reference formulation.
constant float3x3 kAgXTransform = float3x3(
    float3(0.842479062253094f, 0.0423282422610123f, 0.0423756549057051f),
    float3(0.0784335999999992f, 0.878468636469772f, 0.0784336f),
    float3(0.0792237451477643f, 0.0791661274605434f, 0.879142973793104f));

constant float3x3 kAgXTransformInverse = float3x3(
    float3(1.19687900512017f, -0.0528968517574562f, -0.0529716355144438f),
    float3(-0.0980208811401368f, 1.15190312990417f, -0.0980434501171241f),
    float3(-0.0990297440797205f, -0.0989611768448433f, 1.15107367264116f));

/// Sixth-order fit of the AgX sigmoid. Cheaper than evaluating it directly and
/// visually indistinguishable. In Horner's form: six multiply-adds a channel.
inline float3 agxContrast(float3 x) {
    return (((((15.5f * x - 40.14f) * x + 31.96f) * x - 6.868f) * x + 0.4298f) * x + 0.1191f) * x - 0.00232f;
}

inline float3 agxTonemap(float3 radiance) {
    // The usable exposure window, in stops around middle grey.
    constexpr float minimumEV = -12.47393f;
    constexpr float maximumEV = 4.026069f;
    // The same window as values, so one clamp ahead of the logarithm does
    // what a floor ahead of it and a clamp after it did, and black is finite.
    constexpr float minimumValue = 1.7578e-4f;   // 2^minimumEV
    constexpr float maximumValue = 16.2917f;     // 2^maximumEV

    float3 value = kAgXTransform * max(radiance, 0.0f);
    value = log2(clamp(value, minimumValue, maximumValue));
    value = (value - minimumEV) * (1.0f / (maximumEV - minimumEV));
    return saturate(agxContrast(value));
}

/// Optional grade applied in AgX's working space. Slight saturation and a
/// contrast push; without it AgX is correct but reads flat next to the
/// saturated look these games ship with. Expects what `agxTonemap` returns,
/// which is never negative.
inline float3 agxLook(float3 value) {
    constexpr float3 luminanceWeights = float3(0.2126f, 0.7152f, 0.0722f);
    constexpr float saturation = 1.25f;
    constexpr float power = 1.15f;
    float luma = dot(value, luminanceWeights);
    float3 graded = powr(value, float3(power));
    return max(luma + saturation * (graded - luma), 0.0f);
}

/// Scene radiance to display-encoded colour, before the range is clamped:
/// what the sigmoid produces by construction.
inline float3 agxEncoded(float3 radiance) {
    return kAgXTransformInverse * agxLook(agxTonemap(radiance));
}

/// Full chain: scene radiance to *linear* display-referred colour.
///
/// The final decode is load-bearing. AgX's sigmoid produces display-encoded
/// values by construction, so writing them straight into an `_srgb` render
/// target encodes a second time and the frame comes out pale and flat. The
/// reference implementations end with a 2.2 decode to return to linear, and the
/// hardware then applies the transfer function exactly once.
///
/// 2.2 rather than the exact sRGB EOTF because that is what the reference AgX
/// chain specifies; the difference lives entirely in the near-black toe.
inline float3 tonemapAgX(float3 radiance, float exposureScale) {
    return powr(saturate(agxEncoded(radiance * exposureScale)), float3(2.2f));
}

/// Interleaved gradient noise (Jimenez) for the pixel at `position`: one
/// multiply-add and two fracts, 0 to 1.
inline float interleavedGradientNoise(float2 position) {
    return fract(52.9829189f * fract(dot(floor(position), float2(0.06711056f, 0.00583715f))));
}

/// `tonemapAgX` for an 8-bit display, dithered by `noise` (0 to 1) to break
/// up banding in the large smooth sky gradient.
///
/// The dither is half a display level either way, and a display level is a
/// step of the *encoded* value, so it is added before the decode. Added
/// after it, to the linear value, the same offset is a fifth of a level
/// near white and seven levels in the shadows, where the encoding is
/// steepest: grain in every dark corner and banding left in the sky.
inline float3 tonemapAgXDithered(float3 radiance, float noise) {
    float3 encoded = saturate(agxEncoded(radiance) + (noise - 0.5f) * (1.0f / 255.0f));
    return powr(encoded, float3(2.2f));
}

#endif
