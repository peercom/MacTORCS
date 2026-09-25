// SPDX-License-Identifier: GPL-2.0-only
#ifndef TORCS_SKY_METAL
#define TORCS_SKY_METAL

#include <metal_stdlib>
#include "Atmosphere.metal"
#include "Forward.metal"
using namespace metal;

// MARK: - Clouds

/// Value noise on a lattice, smooth enough for a cloud edge.
inline float cloudNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0f - 2.0f * f);
    float a = fract(sin(dot(i, float2(127.1f, 311.7f))) * 43758.5453f);
    float b = fract(sin(dot(i + float2(1.0f, 0.0f), float2(127.1f, 311.7f))) * 43758.5453f);
    float c = fract(sin(dot(i + float2(0.0f, 1.0f), float2(127.1f, 311.7f))) * 43758.5453f);
    float d = fract(sin(dot(i + float2(1.0f, 1.0f), float2(127.1f, 311.7f))) * 43758.5453f);
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

/// Four octaves; the layer is seen at a distance and needs no more.
inline float cloudField(float2 p) {
    float value = 0.0f, amplitude = 0.5f;
    for (int i = 0; i < 4; ++i) {
        value += cloudNoise(p) * amplitude;
        p = p * 2.03f + float2(17.0f, 9.0f);
        amplitude *= 0.5f;
    }
    return value;
}

/// The cloud layer's altitude and the scale of one noise cell, in metres.
constant float kCloudAltitude = 1500.0f;
constant float kCloudCell = 2200.0f;
/// Drift, metres per second along +x.
constant float kCloudWind = 12.0f;

/// Cloud density in [0, 1] along `direction` for a sky of `coverage`.
///
/// A single layer at `kCloudAltitude`, so the sky ray hits it at one point
/// and its noise value thresholded by the coverage is the density there.
/// A ray at or below the horizon never reaches it.
inline float cloudDensity(float3 direction, float3 cameraPosition, float coverage, float time) {
    if (coverage <= 0.0f || direction.z <= 0.02f) { return 0.0f; }
    float t = (kCloudAltitude - cameraPosition.z) / direction.z;
    float2 p = (cameraPosition.xy + direction.xy * t + float2(kCloudWind * time, 0.0f)) / kCloudCell;
    float field = cloudField(p);
    // The threshold falls as the coverage rises: at 1 the whole field is
    // cloud, at 0.5 the upper half of it. The edge is soft and a little
    // wider where the field is dense, so a full sky is not one flat wall.
    float threshold = 0.72f - coverage * 0.5f;
    float density = smoothstep(threshold, threshold + 0.18f, field);
    // Thinner toward the horizon, where the layer is seen edge-on through
    // the most air and reads as haze rather than cloud.
    return density * smoothstep(0.02f, 0.18f, direction.z);
}

/// The clouds composited over the clear sky. Lit from above by the sun
/// through the atmosphere's transmittance, and from all sides by the sky:
/// a thin cloud is bright, a thick one shows its shadowed underside.
inline float3 cloudLayer(float3 skyRadiance, float3 direction, float3 cameraPosition, float coverage,
                         float time, float3 sunDirection, float3 sunIlluminance, float3 sunTransmittance,
                         float3 skyIrradiance) {
    float density = cloudDensity(direction, cameraPosition, coverage, time);
    if (density <= 0.0f) { return skyRadiance; }
    // A cloud is bright: most of the sunlight that falls on it comes out
    // again, diffused, and an overcast sky is a large grey lamp, not a dark
    // ceiling. The light seen from below is the sun's, scattered through
    // the layer, plus the skylight; a thick cloud lets less of the sun
    // through and shows a darker underside, a thin one glows with it.
    float3 sunlight = sunIlluminance * sunTransmittance * max(sunDirection.z, 0.0f);
    float3 thin = (sunlight * 0.65f + skyIrradiance * 1.4f) / M_PI_F;
    float3 thick = (sunlight * 0.25f + skyIrradiance * 1.0f) / M_PI_F;
    float3 cloud = mix(thin, thick, smoothstep(0.1f, 0.9f, density));
    // Toward the sun the thin edges glow: forward scattering.
    float forward = pow(max(dot(direction, sunDirection), 0.0f), 8.0f);
    cloud += sunIlluminance * sunTransmittance * forward * (1.0f - density) * 0.08f;
    return mix(skyRadiance, cloud, density);
}

/// Fullscreen sky. Replaces the classic 36-sided textured cylinder.
fragment ForwardOutput skyFragment(FullscreenVarying in [[stage_in]],
                            constant FrameUniforms &frame [[buffer(1)]],
                            texture2d<float> skyViewLUT [[texture(0)]],
                            texture2d<float> transmittanceLUT [[texture(1)]]) {
    constexpr sampler lut(coord::normalized, address::repeat, filter::linear);
    constexpr sampler clamped(coord::normalized, address::clamp_to_edge, filter::linear);

    // Reconstruct the view ray. Reversed depth puts the far plane at 0.
    float4 near = frame.inverseViewProjection * float4(in.uv * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f), 1.0f, 1.0f);
    float4 far = frame.inverseViewProjection * float4(in.uv * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f), 0.0001f, 1.0f);
    float3 direction = normalize(far.xyz / far.w - near.xyz / near.w);

    float3 radiance = skyViewLUT.sample(lut, skyViewUV(direction)).rgb;

    // Sun disc, about half a degree across, softened at the limb. Drawn here
    // rather than as geometry so it is occluded by depth like everything else.
    float3 sun = normalize(frame.sunDirection.xyz);
    float cosAngle = dot(direction, sun);
    constexpr float cosAngularRadius = 0.9999619f;   // cos(0.5 deg)
    float altitude = max(frame.cameraPosition.z / kMetresPerKilometre, 0.0005f);
    float3 sunTransmittance = transmittanceLUT.sample(clamped, transmittanceUV(altitude, sun.z)).rgb;
    // The clouds' coverage rides in the sun direction's w; the drift in the
    // animation time. Behind cloud the disc is hidden by the cloud's density
    // along the sun's own direction, so a gap shows it and a bank does not.
    float coverage = frame.sunDirection.w;
    if (cosAngle > cosAngularRadius) {
        float limb = smoothstep(cosAngularRadius, 1.0f, cosAngle);
        float hidden = cloudDensity(sun, frame.cameraPosition.xyz, coverage, frame.ambientIrradiance.w);
        // Bright enough that the tonemapper has something to roll off, which is
        // most of what makes a sun read as a sun.
        radiance += frame.sunIlluminance.rgb * sunTransmittance * limb * 40.0f * (1.0f - hidden);
    }
    if (coverage > 0.0f) {
        // The skylight the clouds are lit by: the zenith of the clear sky,
        // which the layer sees from above and below alike.
        float3 skyIrradiance = skyViewLUT.sample(lut, skyViewUV(float3(0.0f, 0.0f, 1.0f))).rgb * M_PI_F;
        radiance = cloudLayer(radiance, direction, frame.cameraPosition.xyz, coverage, frame.ambientIrradiance.w,
                              sun, frame.sunIlluminance.rgb, sunTransmittance, skyIrradiance);
    }

    ForwardOutput out;
    out.colour = float4(radiance, 1.0f);
    // The sky sits at infinity, so only camera rotation moves it. Projecting
    // the view direction as a point at infinity (w = 0) gives exactly that,
    // with the camera's translation correctly having no effect.
    out.velocity = motionVector(frame.unjitteredViewProjection * float4(direction, 0.0f),
                                frame.previousViewProjection * float4(direction, 0.0f),
                                frame.renderSize.xy);
    return out;
}

#endif
