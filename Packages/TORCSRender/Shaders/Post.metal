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
/// visually indistinguishable.
inline float3 agxContrast(float3 x) {
    float3 x2 = x * x;
    float3 x4 = x2 * x2;
    return 15.5f * x4 * x2 - 40.14f * x4 * x + 31.96f * x4
         - 6.868f * x2 * x + 0.4298f * x2 + 0.1191f * x - 0.00232f;
}

inline float3 agxTonemap(float3 radiance) {
    // The usable exposure window, in stops around middle grey.
    constexpr float minimumEV = -12.47393f;
    constexpr float maximumEV = 4.026069f;

    float3 value = kAgXTransform * max(radiance, 0.0f);
    // log2 of zero is -inf; the clamp is what keeps black finite.
    value = clamp(log2(max(value, 1e-10f)), minimumEV, maximumEV);
    value = (value - minimumEV) / (maximumEV - minimumEV);
    return saturate(agxContrast(value));
}

/// Optional grade applied in AgX's working space. Slight saturation and a
/// contrast push; without it AgX is correct but reads flat next to the
/// saturated look these games ship with.
inline float3 agxLook(float3 value) {
    constexpr float3 luminanceWeights = float3(0.2126f, 0.7152f, 0.0722f);
    constexpr float saturation = 1.25f;
    constexpr float power = 1.15f;
    float luma = dot(value, luminanceWeights);
    float3 graded = pow(max(value, 0.0f), float3(power));
    return max(luma + saturation * (graded - luma), 0.0f);
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
    float3 mapped = agxTonemap(radiance * exposureScale);
    mapped = agxLook(mapped);
    mapped = saturate(kAgXTransformInverse * mapped);
    return pow(max(mapped, 0.0f), float3(2.2f));
}

/// Ordered dithering to break up banding in the large smooth sky gradient,
/// which 8-bit output quantizes visibly.
inline float3 ditherForDisplay(float3 colour, uint2 pixel) {
    // Interleaved gradient noise (Jimenez), one multiply-add and a fract.
    float noise = fract(52.9829189f * fract(dot(float2(pixel), float2(0.06711056f, 0.00583715f))));
    return colour + (noise - 0.5f) / 255.0f;
}

#endif
