// SPDX-License-Identifier: GPL-2.0-only
//
// Physically based BRDF for the modern render path.
//
// Replaces the classic path's per-vertex Blinn-Phong with a metal-roughness
// microfacet model plus a clearcoat lobe. Clearcoat is what makes car paint
// read correctly: a smooth dielectric layer over a coloured metallic-flake
// base, which is the single most recognisable material in a racing game.
//
// All arithmetic is in linear space. The classic path did its lighting on
// stored sRGB bytes and clamped to [0, 1], which is why it could never produce
// a believable highlight.
#ifndef TORCS_BRDF_METAL
#define TORCS_BRDF_METAL

#include <metal_stdlib>
using namespace metal;

constant float kPi = 3.14159265358979323846f;
/// Below this, the GGX denominator loses all its precision and highlights
/// alias into single pixels that temporal upscaling then smears.
constant float kMinPerceptualRoughness = 0.045f;

struct SurfaceMaterial {
    float3 albedo;          // linear base colour
    float  perceptualRoughness;
    float  metallic;
    float  ambientOcclusion;
    float3 normal;          // world space, unit
    float3 emissive;        // linear
    float  clearcoat;       // 0 = none, 1 = full coat
    float  clearcoatRoughness;
    float3 clearcoatNormal; // world space, usually the geometric normal
};

/// Trowbridge-Reitz normal distribution, in Filament's reassociated form.
/// The naive expression loses precision badly at low roughness in half floats.
inline float distributionGGX(float NoH, float roughness) {
    float a = NoH * roughness;
    float k = roughness / max(1.0f - NoH * NoH + a * a, 1e-8f);
    return k * k * (1.0f / kPi);
}

/// Height-correlated Smith visibility (Heitz 2014). Already divided by the
/// 4 * NoL * NoV factor of the Cook-Torrance denominator.
inline float visibilitySmithGGXCorrelated(float NoV, float NoL, float roughness) {
    float a2 = roughness * roughness;
    float lambdaV = NoL * sqrt(NoV * NoV * (1.0f - a2) + a2);
    float lambdaL = NoV * sqrt(NoL * NoL * (1.0f - a2) + a2);
    return 0.5f / max(lambdaV + lambdaL, 1e-6f);
}

/// Kelemen's approximation, accurate enough for the thin clearcoat layer and
/// far cheaper than a second Smith term.
inline float visibilityKelemen(float LoH) {
    return 0.25f / max(LoH * LoH, 1e-6f);
}

inline float3 fresnelSchlick(float3 f0, float VoH) {
    float f = pow(saturate(1.0f - VoH), 5.0f);
    return f0 + (1.0f - f0) * f;
}

inline float fresnelSchlick(float f0, float f90, float VoH) {
    return f0 + (f90 - f0) * pow(saturate(1.0f - VoH), 5.0f);
}

/// Lambert. Burley's model is more correct at grazing angles but costs two
/// extra Fresnel evaluations per light for a difference that does not survive
/// tonemapping on these materials.
inline float3 diffuseLambert(float3 albedo) {
    return albedo * (1.0f / kPi);
}

/// Split-sum environment BRDF, Lazarov's analytic fit. Avoids binding a LUT
/// texture in every pass; a precomputed LUT can replace this if measurement
/// ever shows the approximation costing visible accuracy at grazing angles.
inline float2 environmentBRDF(float perceptualRoughness, float NoV) {
    const float4 c0 = float4(-1.0f, -0.0275f, -0.572f, 0.022f);
    const float4 c1 = float4(1.0f, 0.0425f, 1.04f, -0.04f);
    float4 r = perceptualRoughness * c0 + c1;
    float a004 = min(r.x * r.x, exp2(-9.28f * NoV)) * r.x + r.y;
    return float2(-1.04f, 1.04f) * a004 + r.zw;
}

/// Multiple-scattering compensation (Fdez-Agüera). Single-scattering GGX loses
/// energy at high roughness, leaving rough metals — brushed trim, worn armco —
/// noticeably too dark. This restores it for the cost of one multiply.
inline float3 energyCompensation(float3 f0, float2 dfg) {
    // The bias term approaches zero on smooth surfaces, so the reciprocal has
    // to be bounded or a near-mirror dielectric picks up a several-fold
    // specular gain that is pure energy invention. Clamping at 2x keeps the
    // genuine rough-metal correction while ruling that out.
    float3 gain = 1.0f + f0 * (1.0f / max(dfg.y, 1e-2f) - 1.0f);
    return min(gain, float3(2.0f));
}

/// Geometric specular antialiasing (Kaplanyan et al.). Widens roughness where
/// the normal varies fast within a pixel. This matters much more than usual
/// here: temporal upscaling renders at half resolution, so specular aliasing
/// that would merely shimmer at native resolution becomes a crawling artifact
/// the history buffer preserves.
inline float filteredPerceptualRoughness(float perceptualRoughness, float3 worldNormal) {
    constexpr float variance = 0.15f;
    constexpr float threshold = 0.25f;
    float3 du = dfdx(worldNormal);
    float3 dv = dfdy(worldNormal);
    float kernelRoughness = variance * (dot(du, du) + dot(dv, dv));
    float roughness = perceptualRoughness * perceptualRoughness;
    float squared = saturate(roughness * roughness + min(2.0f * kernelRoughness, threshold));
    return clamp(sqrt(sqrt(squared)), kMinPerceptualRoughness, 1.0f);
}

/// Evaluates one punctual or directional light.
///
/// `lightColour` is expected in linear photometric units already scaled by the
/// light's intensity and any shadow or attenuation term.
inline float3 evaluateLight(SurfaceMaterial material, float3 viewDirection,
                            float3 lightDirection, float3 lightColour) {
    float3 n = material.normal;
    float NoL = saturate(dot(n, lightDirection));
    if (NoL <= 0.0f) { return float3(0.0f); }

    float3 h = normalize(viewDirection + lightDirection);
    float NoV = saturate(dot(n, viewDirection)) + 1e-5f;
    float NoH = saturate(dot(n, h));
    float LoH = saturate(dot(lightDirection, h));

    float perceptualRoughness = max(material.perceptualRoughness, kMinPerceptualRoughness);
    float roughness = perceptualRoughness * perceptualRoughness;

    // Dielectrics reflect 4% at normal incidence; metals tint their specular
    // with the base colour and have no diffuse lobe at all.
    float3 f0 = mix(float3(0.04f), material.albedo, material.metallic);
    float3 diffuseColour = material.albedo * (1.0f - material.metallic);

    float D = distributionGGX(NoH, roughness);
    float V = visibilitySmithGGXCorrelated(NoV, NoL, roughness);
    float3 F = fresnelSchlick(f0, LoH);

    float3 specular = D * V * F;
    specular *= energyCompensation(f0, environmentBRDF(perceptualRoughness, NoV));

    // Energy leaving through the specular lobe cannot also diffuse.
    float3 diffuse = diffuseLambert(diffuseColour) * (1.0f - F);
    float3 result = (diffuse + specular) * lightColour * NoL;

    if (material.clearcoat > 0.0f) {
        float3 cn = material.clearcoatNormal;
        float ccNoL = saturate(dot(cn, lightDirection));
        float ccNoH = saturate(dot(cn, h));
        float ccRoughness = max(material.clearcoatRoughness, kMinPerceptualRoughness);
        ccRoughness *= ccRoughness;

        float ccD = distributionGGX(ccNoH, ccRoughness);
        float ccV = visibilityKelemen(LoH);
        // Polyurethane clearcoat, IOR about 1.5.
        float ccF = fresnelSchlick(0.04f, 1.0f, LoH) * material.clearcoat;

        // Light reaching the base passes through the coat twice.
        result *= (1.0f - ccF);
        result += ccD * ccV * ccF * lightColour * ccNoL;
    }
    return result;
}

/// Image-based lighting from spherical-harmonic irradiance and a prefiltered
/// specular cube. `prefiltered` must already be sampled at the mip matching
/// the surface roughness.
inline float3 evaluateImageBasedLight(SurfaceMaterial material, float3 viewDirection,
                                      float3 irradiance, float3 prefiltered) {
    float NoV = saturate(dot(material.normal, viewDirection)) + 1e-5f;
    float perceptualRoughness = max(material.perceptualRoughness, kMinPerceptualRoughness);

    float3 f0 = mix(float3(0.04f), material.albedo, material.metallic);
    float3 diffuseColour = material.albedo * (1.0f - material.metallic);

    float2 dfg = environmentBRDF(perceptualRoughness, NoV);
    float3 specular = prefiltered * (f0 * dfg.x + dfg.y) * energyCompensation(f0, dfg);
    float3 diffuse = diffuseColour * irradiance;

    // Ambient occlusion applies to the ambient terms only; applying it to
    // direct light is the classic way to make shadowed geometry read as dirty.
    return (diffuse + specular) * material.ambientOcclusion;
}

#endif
