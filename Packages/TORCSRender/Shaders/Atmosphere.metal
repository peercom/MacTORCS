// SPDX-License-Identifier: GPL-2.0-only
//
// Physical atmospheric scattering (Hillaire 2020, "A Scalable and Production
// Ready Sky and Atmosphere Rendering Technique").
//
// Replaces two separate classic-path approximations at once: the 36-sided sky
// cylinder with a painted texture, and the per-camera linear fog whose range
// was authored per view (300-600 m for driving cameras, 500-1000 m for
// exteriors). Both are gone. Sky radiance, horizon haze and distance fog now
// come from one medium, so they agree by construction and time of day is free.
//
// Distances are in kilometres. Working in metres puts the extinction
// coefficients around 1e-6 and loses float precision along a 100 km view ray.
#ifndef TORCS_ATMOSPHERE_METAL
#define TORCS_ATMOSPHERE_METAL

#include <metal_stdlib>
using namespace metal;

constant float kEarthRadius = 6360.0f;
constant float kAtmosphereRadius = 6460.0f;
constant float kAtmospherePi = 3.14159265358979323846f;

/// Earth-like medium. Rayleigh from molecular scattering, Mie from aerosols,
/// ozone as pure absorption in a band around 25 km — the last is what keeps a
/// low sun's sky blue at the zenith instead of washing to grey.
struct AtmosphereMedium {
    float3 rayleighScattering;  // per km
    float rayleighScaleHeight;
    float mieScattering;
    float mieAbsorption;
    float mieScaleHeight;
    float miePhaseG;
    float3 ozoneAbsorption;
    float ozoneCenter;
    float ozoneWidth;
};

inline AtmosphereMedium defaultMedium() {
    AtmosphereMedium m;
    m.rayleighScattering = float3(5.802e-3f, 13.558e-3f, 33.1e-3f);
    m.rayleighScaleHeight = 8.0f;
    m.mieScattering = 3.996e-3f;
    m.mieAbsorption = 4.4e-3f;
    m.mieScaleHeight = 1.2f;
    m.miePhaseG = 0.8f;
    m.ozoneAbsorption = float3(0.650e-3f, 1.881e-3f, 0.085e-3f);
    m.ozoneCenter = 25.0f;
    m.ozoneWidth = 15.0f;
    return m;
}

/// Scattering and extinction at a given altitude above sea level.
inline void sampleMedium(AtmosphereMedium m, float altitude,
                         thread float3 &rayleigh, thread float &mie, thread float3 &extinction) {
    float rayleighDensity = exp(-max(altitude, 0.0f) / m.rayleighScaleHeight);
    float mieDensity = exp(-max(altitude, 0.0f) / m.mieScaleHeight);
    // Tent function, the standard cheap stand-in for the ozone profile.
    float ozoneDensity = max(0.0f, 1.0f - abs(altitude - m.ozoneCenter) / m.ozoneWidth);

    rayleigh = m.rayleighScattering * rayleighDensity;
    mie = m.mieScattering * mieDensity;
    extinction = rayleigh + float3(mie + m.mieAbsorption * mieDensity) + m.ozoneAbsorption * ozoneDensity;
}

inline float rayleighPhase(float cosTheta) {
    return 3.0f / (16.0f * kAtmospherePi) * (1.0f + cosTheta * cosTheta);
}

/// Henyey-Greenstein, in the Cornette-Shanks normalization.
inline float miePhase(float cosTheta, float g) {
    float g2 = g * g;
    float denominator = 1.0f + g2 - 2.0f * g * cosTheta;
    return 3.0f / (8.0f * kAtmospherePi) * ((1.0f - g2) * (1.0f + cosTheta * cosTheta))
         / ((2.0f + g2) * max(pow(denominator, 1.5f), 1e-6f));
}

/// Distance from `origin` to the sphere of `radius` centred on the planet.
/// Returns -1 when the ray misses, so callers can distinguish it from a
/// zero-length hit.
inline float raySphere(float3 origin, float3 direction, float radius) {
    float b = dot(origin, direction);
    float c = dot(origin, origin) - radius * radius;
    if (c > 0.0f && b > 0.0f) { return -1.0f; }
    float discriminant = b * b - c;
    if (discriminant < 0.0f) { return -1.0f; }
    float d = sqrt(discriminant);
    float near = -b - d, far = -b + d;
    return near >= 0.0f ? near : far;
}

/// Maps a transmittance LUT texel to (altitude, view zenith cosine).
inline void transmittanceParameters(float2 uv, thread float &altitude, thread float &cosZenith) {
    float x = uv.x, y = uv.y;
    float horizon = sqrt(kAtmosphereRadius * kAtmosphereRadius - kEarthRadius * kEarthRadius);
    float rho = horizon * y;
    float radius = sqrt(rho * rho + kEarthRadius * kEarthRadius);
    float dMin = kAtmosphereRadius - radius, dMax = rho + horizon;
    float d = dMin + x * (dMax - dMin);
    cosZenith = d == 0.0f ? 1.0f : clamp((horizon * horizon - rho * rho - d * d) / (2.0f * radius * d), -1.0f, 1.0f);
    altitude = radius - kEarthRadius;
}

inline float2 transmittanceUV(float altitude, float cosZenith) {
    float radius = kEarthRadius + clamp(altitude, 0.0f, kAtmosphereRadius - kEarthRadius);
    float horizon = sqrt(max(kAtmosphereRadius * kAtmosphereRadius - kEarthRadius * kEarthRadius, 0.0f));
    float rho = sqrt(max(radius * radius - kEarthRadius * kEarthRadius, 0.0f));
    float discriminant = radius * radius * (cosZenith * cosZenith - 1.0f)
                       + kAtmosphereRadius * kAtmosphereRadius;
    float d = max(0.0f, -radius * cosZenith + sqrt(max(discriminant, 0.0f)));
    float dMin = kAtmosphereRadius - radius, dMax = rho + horizon;
    return float2(clamp((d - dMin) / max(dMax - dMin, 1e-6f), 0.0f, 1.0f),
                  clamp(rho / max(horizon, 1e-6f), 0.0f, 1.0f));
}

/// Optical depth from a point to the top of the atmosphere.
inline float3 computeTransmittance(AtmosphereMedium m, float altitude, float cosZenith, uint steps) {
    float3 origin = float3(0.0f, 0.0f, kEarthRadius + altitude);
    float3 direction = float3(sqrt(max(1.0f - cosZenith * cosZenith, 0.0f)), 0.0f, cosZenith);
    float distance = raySphere(origin, direction, kAtmosphereRadius);
    if (distance < 0.0f) { return float3(1.0f); }

    float3 opticalDepth = float3(0.0f);
    float step = distance / float(steps);
    for (uint i = 0; i < steps; ++i) {
        float3 position = origin + direction * (float(i) + 0.5f) * step;
        float3 rayleigh; float mie; float3 extinction;
        sampleMedium(m, length(position) - kEarthRadius, rayleigh, mie, extinction);
        opticalDepth += extinction * step;
    }
    return exp(-opticalDepth);
}

kernel void atmosphereTransmittanceLUT(texture2d<float, access::write> target [[texture(0)]],
                                       uint2 id [[thread_position_in_grid]]) {
    if (id.x >= target.get_width() || id.y >= target.get_height()) { return; }
    float2 uv = (float2(id) + 0.5f) / float2(target.get_width(), target.get_height());
    float altitude, cosZenith;
    transmittanceParameters(uv, altitude, cosZenith);
    target.write(float4(computeTransmittance(defaultMedium(), altitude, cosZenith, 40u), 1.0f), id);
}

/// Second-order scattering, stored as an isotropic term per (altitude, sun
/// zenith). Without it the sky's ground bounce is missing and a hazy horizon
/// reads far too dark.
kernel void atmosphereMultiScatterLUT(texture2d<float, access::write> target [[texture(0)]],
                                      texture2d<float> transmittance [[texture(1)]],
                                      uint2 id [[thread_position_in_grid]]) {
    if (id.x >= target.get_width() || id.y >= target.get_height()) { return; }
    constexpr sampler lut(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(id) + 0.5f) / float2(target.get_width(), target.get_height());
    AtmosphereMedium m = defaultMedium();

    float sunCosZenith = uv.x * 2.0f - 1.0f;
    float altitude = uv.y * (kAtmosphereRadius - kEarthRadius);
    float3 sunDirection = float3(sqrt(max(1.0f - sunCosZenith * sunCosZenith, 0.0f)), 0.0f, sunCosZenith);
    float3 origin = float3(0.0f, 0.0f, kEarthRadius + altitude);

    // A small fixed direction set; this LUT is low frequency by nature.
    const uint directionCount = 8;
    float3 luminance = float3(0.0f), scatteredFraction = float3(0.0f);
    for (uint d = 0; d < directionCount; ++d) {
        float theta = (float(d) + 0.5f) / float(directionCount) * 2.0f * kAtmospherePi;
        float cosPhi = (float(d % 4) + 0.5f) / 4.0f * 2.0f - 1.0f;
        float sinPhi = sqrt(max(1.0f - cosPhi * cosPhi, 0.0f));
        float3 direction = float3(sinPhi * cos(theta), sinPhi * sin(theta), cosPhi);

        float top = raySphere(origin, direction, kAtmosphereRadius);
        float ground = raySphere(origin, direction, kEarthRadius);
        float distance = ground > 0.0f ? ground : max(top, 0.0f);
        if (distance <= 0.0f) { continue; }

        const uint steps = 16;
        float step = distance / float(steps);
        float3 throughput = float3(1.0f);
        for (uint i = 0; i < steps; ++i) {
            float3 position = origin + direction * (float(i) + 0.5f) * step;
            float radius = length(position);
            float3 rayleigh; float mie; float3 extinction;
            sampleMedium(m, radius - kEarthRadius, rayleigh, mie, extinction);
            float3 stepTransmittance = exp(-extinction * step);

            float sunCos = dot(normalize(position), sunDirection);
            float3 sunTransmittance = transmittance.sample(lut, transmittanceUV(radius - kEarthRadius, sunCos)).rgb;
            float3 scattering = rayleigh + float3(mie);

            // Isotropic phase, which is the assumption the LUT encodes.
            float3 inScatter = scattering * (1.0f / (4.0f * kAtmospherePi));
            float3 integrated = (inScatter - inScatter * stepTransmittance) / max(extinction, 1e-6f);
            luminance += throughput * integrated * sunTransmittance;
            scatteredFraction += throughput * integrated;
            throughput *= stepTransmittance;
        }
    }
    luminance /= float(directionCount);
    scatteredFraction /= float(directionCount);
    // Geometric series over infinite scattering orders.
    float3 result = luminance / max(1.0f - scatteredFraction, 1e-4f);
    target.write(float4(result, 1.0f), id);
}

/// Non-linear zenith mapping: horizon detail is where the eye looks, so give it
/// most of the texels.
inline float3 skyViewDirection(float2 uv) {
    float azimuth = (uv.x * 2.0f - 1.0f) * kAtmospherePi;
    float v = uv.y * 2.0f - 1.0f;
    float zenith = (v < 0.0f ? -1.0f : 1.0f) * v * v * (kAtmospherePi * 0.5f) + kAtmospherePi * 0.5f;
    return float3(sin(zenith) * cos(azimuth), sin(zenith) * sin(azimuth), cos(zenith));
}

inline float2 skyViewUV(float3 direction) {
    float3 d = normalize(direction);
    float azimuth = atan2(d.y, d.x);
    float zenith = acos(clamp(d.z, -1.0f, 1.0f));
    float v = (zenith - kAtmospherePi * 0.5f) / (kAtmospherePi * 0.5f);
    float mapped = sqrt(abs(v)) * (v < 0.0f ? -1.0f : 1.0f);
    return float2(azimuth / (2.0f * kAtmospherePi) + 0.5f, mapped * 0.5f + 0.5f);
}

struct SkyUniforms {
    float4 sunDirection;     // xyz toward the sun, w camera altitude in km
    float4 sunIlluminance;   // linear RGB, w unused
};

/// Integrates one view ray. Shared by the sky LUT and aerial perspective so the
/// two cannot disagree.
inline float3 integrateScattering(AtmosphereMedium m, float3 origin, float3 direction,
                                  float3 sunDirection, float3 sunIlluminance,
                                  float maxDistance, uint steps,
                                  texture2d<float> transmittanceLUT,
                                  texture2d<float> multiScatterLUT,
                                  thread float3 &throughputOut) {
    constexpr sampler lut(coord::normalized, address::clamp_to_edge, filter::linear);

    float top = raySphere(origin, direction, kAtmosphereRadius);
    float ground = raySphere(origin, direction, kEarthRadius);
    float distance = ground > 0.0f ? ground : max(top, 0.0f);
    distance = min(distance, maxDistance);
    if (distance <= 0.0f) { throughputOut = float3(1.0f); return float3(0.0f); }

    float cosTheta = dot(direction, sunDirection);
    float rayleighPhaseValue = rayleighPhase(cosTheta);
    float miePhaseValue = miePhase(cosTheta, m.miePhaseG);

    // Whether the view ray terminates on the planet rather than in space.
    // Hillaire's technique includes this; without it every downward ray returns
    // black, and any part of the frame not covered by scene geometry reads as a
    // void rather than as ground.
    bool hitsGround = ground > 0.0f && ground <= maxDistance;

    float3 luminance = float3(0.0f), throughput = float3(1.0f);
    float step = distance / float(steps);
    for (uint i = 0; i < steps; ++i) {
        float3 position = origin + direction * (float(i) + 0.5f) * step;
        float radius = length(position);
        float altitude = radius - kEarthRadius;
        float3 rayleigh; float mie; float3 extinction;
        sampleMedium(m, altitude, rayleigh, mie, extinction);

        float sunCos = dot(normalize(position), sunDirection);
        float3 sunTransmittance = transmittanceLUT.sample(lut, transmittanceUV(altitude, sunCos)).rgb;
        float3 multiScatter = multiScatterLUT.sample(lut, float2(sunCos * 0.5f + 0.5f,
            clamp(altitude / (kAtmosphereRadius - kEarthRadius), 0.0f, 1.0f))).rgb;

        float3 phased = rayleigh * rayleighPhaseValue + float3(mie * miePhaseValue);
        float3 isotropic = (rayleigh + float3(mie)) * multiScatter;
        float3 inScatter = (phased * sunTransmittance + isotropic) * sunIlluminance;

        // Analytic integration over the step, which is what lets the step count
        // stay low without banding.
        float3 stepTransmittance = exp(-extinction * step);
        float3 integrated = (inScatter - inScatter * stepTransmittance) / max(extinction, 1e-6f);
        luminance += throughput * integrated;
        throughput *= stepTransmittance;
    }
    if (hitsGround) {
        // Lambertian bounce off a mid-grey earth. A stand-in for real terrain,
        // which TORCS generates from the track's Terrain Generation parameters
        // and which the scene meshes do not contain.
        constexpr float3 groundAlbedo = float3(0.24f, 0.23f, 0.20f);
        float3 surface = origin + direction * distance;
        float3 normal = normalize(surface);
        float sunCos = dot(normal, sunDirection);
        float3 sunTransmittance = transmittanceLUT.sample(lut, transmittanceUV(0.0f, sunCos)).rgb;
        float3 reflected = groundAlbedo * (1.0f / kAtmospherePi) * max(sunCos, 0.0f)
                         * sunIlluminance * sunTransmittance;
        luminance += throughput * reflected;
    }
    throughputOut = throughput;
    return luminance;
}

kernel void atmosphereSkyViewLUT(texture2d<float, access::write> target [[texture(0)]],
                                 texture2d<float> transmittanceLUT [[texture(1)]],
                                 texture2d<float> multiScatterLUT [[texture(2)]],
                                 constant SkyUniforms &sky [[buffer(0)]],
                                 uint2 id [[thread_position_in_grid]]) {
    if (id.x >= target.get_width() || id.y >= target.get_height()) { return; }
    float2 uv = (float2(id) + 0.5f) / float2(target.get_width(), target.get_height());
    float3 direction = skyViewDirection(uv);
    float3 origin = float3(0.0f, 0.0f, kEarthRadius + max(sky.sunDirection.w, 0.0005f));
    float3 throughput;
    float3 luminance = integrateScattering(defaultMedium(), origin, direction,
                                           normalize(sky.sunDirection.xyz), sky.sunIlluminance.rgb,
                                           1e7f, 32u, transmittanceLUT, multiScatterLUT, throughput);
    target.write(float4(luminance, 1.0f), id);
}

/// Scene metres to atmosphere kilometres. The track sits near z = 0 in TORCS
/// world space, which is taken as sea level.
constant float kMetresPerKilometre = 1000.0f;

inline float3 atmospherePosition(float3 worldMetres) {
    return float3(worldMetres.x / kMetresPerKilometre,
                  worldMetres.y / kMetresPerKilometre,
                  kEarthRadius + max(worldMetres.z / kMetresPerKilometre, 0.0005f));
}

/// Aerial perspective: what the atmosphere between the eye and a surface adds
/// and removes.
///
/// Returns in-scattered radiance and writes the transmittance to the surface.
/// This is the same integrator the sky LUT uses, so haze on a distant barrier
/// and the sky just above it agree by construction — which per-camera linear
/// fog could never do.
inline float3 aerialPerspective(float3 worldPosition, float3 cameraPosition,
                                float3 sunDirection, float3 sunIlluminance,
                                texture2d<float> transmittanceLUT,
                                texture2d<float> multiScatterLUT,
                                thread float3 &transmittanceOut) {
    float3 offset = worldPosition - cameraPosition;
    float distance = length(offset) / kMetresPerKilometre;
    if (distance < 1e-5f) { transmittanceOut = float3(1.0f); return float3(0.0f); }

    // Eight steps is enough because the step integration is analytic; more only
    // matters across tens of kilometres, which a circuit never spans. Over the
    // first few hundred metres — most of the pixels of a driver's view — the
    // medium is so nearly uniform that two steps integrate it exactly enough,
    // and the forward pass is where the frame's milliseconds are.
    uint steps = distance < 0.3f ? 2u : (distance < 1.0f ? 4u : 8u);
    return integrateScattering(defaultMedium(), atmospherePosition(cameraPosition),
                               normalize(offset), sunDirection, sunIlluminance,
                               distance, steps, transmittanceLUT, multiScatterLUT, transmittanceOut);
}


// MARK: - Sky irradiance

/// Nine spherical-harmonic coefficients, packed as float4 for alignment.
/// Order 2 captures a sky's low-frequency distribution almost exactly, which is
/// why it is the standard basis for diffuse image-based lighting.
struct SkyIrradiance {
    float4 coefficients[9];
};

/// Projects the sky-view table onto SH9.
///
/// Replaces the classic path's fixed 0.2 global ambient. That constant could
/// not know whether the sun was overhead or on the horizon, so every surface
/// out of direct light read the same regardless of time of day — the single
/// biggest reason the old frames looked flat.
///
/// One threadgroup, 64 threads, each integrating a stratified share of the
/// sphere, then a threadgroup reduction. Runs only when the sky table does.
kernel void atmosphereIrradianceSH(device SkyIrradiance &output [[buffer(0)]],
                                   texture2d<float> skyViewLUT [[texture(0)]],
                                   uint threadIndex [[thread_position_in_threadgroup]],
                                   uint threadCount [[threads_per_threadgroup]]) {
    constexpr sampler lut(coord::normalized, address::repeat, filter::linear);
    threadgroup float3 partial[64][9];

    const uint samples = 2048;
    float3 local[9];
    for (uint i = 0; i < 9; ++i) { local[i] = float3(0.0f); }

    for (uint s = threadIndex; s < samples; s += threadCount) {
        // Fibonacci sphere: even coverage without a random source, so the
        // result is identical run to run.
        float z = 1.0f - 2.0f * (float(s) + 0.5f) / float(samples);
        float r = sqrt(max(0.0f, 1.0f - z * z));
        float phi = 2.39996323f * float(s);
        float3 d = float3(r * cos(phi), r * sin(phi), z);

        float3 radiance = skyViewLUT.sample(lut, skyViewUV(d)).rgb;
        // Real-valued SH basis, bands 0 through 2.
        local[0] += radiance * 0.282095f;
        local[1] += radiance * (0.488603f * d.y);
        local[2] += radiance * (0.488603f * d.z);
        local[3] += radiance * (0.488603f * d.x);
        local[4] += radiance * (1.092548f * d.x * d.y);
        local[5] += radiance * (1.092548f * d.y * d.z);
        local[6] += radiance * (0.315392f * (3.0f * d.z * d.z - 1.0f));
        local[7] += radiance * (1.092548f * d.x * d.z);
        local[8] += radiance * (0.546274f * (d.x * d.x - d.y * d.y));
    }
    for (uint i = 0; i < 9; ++i) { partial[threadIndex][i] = local[i]; }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (threadIndex != 0) { return; }
    float weight = 4.0f * kAtmospherePi / float(samples);
    for (uint i = 0; i < 9; ++i) {
        float3 total = float3(0.0f);
        for (uint t = 0; t < threadCount; ++t) { total += partial[t][i]; }
        output.coefficients[i] = float4(total * weight, 0.0f);
    }
}

/// Evaluates SH9 irradiance for a normal, with the Ramamoorthi-Hanrahan
/// convolution constants that turn radiance coefficients into irradiance.
inline float3 evaluateSkyIrradiance(constant SkyIrradiance &sh, float3 n) {
    constexpr float a0 = 3.141593f, a1 = 2.094395f, a2 = 0.785398f;
    float3 result = sh.coefficients[0].rgb * 0.282095f * a0;
    result += sh.coefficients[1].rgb * (0.488603f * n.y) * a1;
    result += sh.coefficients[2].rgb * (0.488603f * n.z) * a1;
    result += sh.coefficients[3].rgb * (0.488603f * n.x) * a1;
    result += sh.coefficients[4].rgb * (1.092548f * n.x * n.y) * a2;
    result += sh.coefficients[5].rgb * (1.092548f * n.y * n.z) * a2;
    result += sh.coefficients[6].rgb * (0.315392f * (3.0f * n.z * n.z - 1.0f)) * a2;
    result += sh.coefficients[7].rgb * (1.092548f * n.x * n.z) * a2;
    result += sh.coefficients[8].rgb * (0.546274f * (n.x * n.x - n.y * n.y)) * a2;
    // A sky cannot deliver negative irradiance; ringing can.
    return max(result / kAtmospherePi, 0.0f);
}

#endif
