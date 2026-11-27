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

// MARK: - The sky from its maps

/// Compiled in when the sky has a cloud map or a horizon to be drawn from
/// (see `ForwardRenderer.cloudMap`). A constant, not a uniform: the noise
/// above is paid for at every pixel of sky whether its branch is taken or not.
constant bool skyMapped [[function_constant(8)]];

struct SkyDress {
    /// x how much of a fair sky is cumulus, y how much cirrus is above it,
    /// z and w the sines of the elevation at the horizon map's bottom and top.
    float4 clouds;
};

/// The side of one tile of the cloud map at the cumulus layer, the height
/// of the cirrus, and the side of a tile there, in metres.
constant float kCumulusTile = 16000.0f;
constant float kCirrusAltitude = 9000.0f;
constant float kCirrusTile = 60000.0f;

/// Where a ray from the camera meets a level layer, in tiles of the map.
inline float2 layerPoint(float3 direction, float3 cameraPosition, float altitude, float tile, float2 drift) {
    float t = (altitude - cameraPosition.z) / max(direction.z, 0.02f);
    return (cameraPosition.xy + direction.xy * t + drift) / tile;
}

/// Cumulus from the map: its density in x and how thick the heap is there
/// in y. The broad shape is thresholded by the coverage as the noise was;
/// the fine channel, sampled five times smaller, eats at the edge it leaves,
/// which is what makes a heap and not a blob.
///
/// z is how much more cloud there is here than a little way toward the sun:
/// the side of a heap the sun is on is bright and the other is not, and a
/// layer with no height can still say which side a texel is on.
inline float3 mappedCumulus(texture2d<float> map, sampler tiled, float3 direction, float3 cameraPosition,
                            float coverage, float time, float2 sunward) {
    float2 p = layerPoint(direction, cameraPosition, kCloudAltitude, kCumulusTile, float2(kCloudWind * time, 0.0f));
    float4 broad = map.sample(tiled, p);
    float fine = map.sample(tiled, p * 4.3f + float2(0.31f, 0.17f)).g;
    float field = broad.r - (1.0f - fine) * 0.17f;
    float threshold = 0.86f - coverage * 0.74f;
    float density = smoothstep(threshold, threshold + 0.14f, field);
    float seen = coverage > 0.0f ? smoothstep(0.02f, 0.18f, direction.z) : 0.0f;
    float toward = map.sample(tiled, p + sunward * 0.018f).r;
    return float3(density * seen, broad.a, broad.r - toward);
}

/// Fullscreen sky. Replaces the classic 36-sided textured cylinder.
fragment ForwardOutput skyFragment(FullscreenVarying in [[stage_in]],
                            constant FrameUniforms &frame [[buffer(1)]],
                            constant SkyDress &dress [[buffer(2), function_constant(skyMapped)]],
                            texture2d<float> skyViewLUT [[texture(0)]],
                            texture2d<float> transmittanceLUT [[texture(1)]],
                            texture2d<float> cloudMap [[texture(2), function_constant(skyMapped)]],
                            texture2d<float> horizonMap [[texture(3), function_constant(skyMapped)]]) {
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
    constexpr sampler tiled(coord::normalized, address::repeat, filter::linear, mip_filter::linear);
    if (cosAngle > cosAngularRadius) {
        float limb = smoothstep(cosAngularRadius, 1.0f, cosAngle);
        // Only the weather's cloud hides the sun. A fair sky's cumulus keeps
        // clear of it: the ground is lit as under a clear sky, and a sun
        // behind a cloud over ground in full sun would be a lie.
        float hidden = skyMapped
            ? mappedCumulus(cloudMap, tiled, sun, frame.cameraPosition.xyz, coverage, frame.ambientIrradiance.w, float2(0.0f)).x
            : cloudDensity(sun, frame.cameraPosition.xyz, coverage, frame.ambientIrradiance.w);
        // Bright enough that the tonemapper has something to roll off, which is
        // most of what makes a sun read as a sun.
        radiance += frame.sunIlluminance.rgb * sunTransmittance * limb * 40.0f * (1.0f - hidden);
    }
    if (skyMapped) {
        // The skylight the clouds and the land are lit by: the zenith of
        // the clear sky. And the sun's, on a level surface under it.
        float3 skyIrradiance = skyViewLUT.sample(lut, skyViewUV(float3(0.0f, 0.0f, 1.0f))).rgb * M_PI_F;
        float3 sunlight = frame.sunIlluminance.rgb * sunTransmittance * max(sun.z, 0.0f);
        float time = frame.ambientIrradiance.w;

        // Cirrus first: it is behind everything. Ice, thin, and white.
        float2 high = layerPoint(direction, frame.cameraPosition.xyz, kCirrusAltitude, kCirrusTile, float2(kCloudWind * 2.5f * time, 0.0f));
        float streak = cloudMap.sample(tiled, high).b;
        float ice = dress.clouds.y * smoothstep(0.50f, 0.95f, streak) * 0.55f * smoothstep(0.05f, 0.30f, direction.z);
        // A cloud is white: it sends on all of the sun's light, and the sun's
        // own yellow, which the blue sky beside it is the other half of,
        // reads on it as dirt. So its light is taken most of the way to grey.
        constexpr float3 luma = float3(0.2126f, 0.7152f, 0.0722f);
        float3 white = mix(sunlight, float3(dot(sunlight, luma)), 0.9f);
        radiance = mix(radiance, (white * 0.55f + skyIrradiance * 1.3f) / M_PI_F, ice);

        // Cumulus: the weather's cover, or a fair day's heaps, which stand
        // clear of the sun for twenty degrees round it.
        float fair = dress.clouds.x * (1.0f - smoothstep(0.90f, 0.97f, cosAngle));
        float cover = max(coverage, fair);
        float2 sunward = sun.xy / max(length(sun.xy), 1e-3f);
        float3 heap = mappedCumulus(cloudMap, tiled, direction, frame.cameraPosition.xyz, cover, time, sunward);
        // A cloud's light is the sun's come through it, and the sky's. Its
        // sunward side and its thin edges are white; its far side is in its
        // own shade; and the middle of a thick one is grey underneath.
        float3 bright = (white * 1.05f + skyIrradiance * 1.4f) / M_PI_F;
        float3 shaded = (white * 0.42f + skyIrradiance * 1.05f) / M_PI_F;
        float side = saturate(0.55f - heap.z * 5.0f);
        float under = smoothstep(0.55f, 0.95f, heap.y) * smoothstep(0.5f, 1.0f, heap.x) * 0.6f;
        float3 cloud = mix(shaded, bright, saturate(side - under));
        float forward = pow(max(cosAngle, 0.0f), 8.0f);
        cloud += frame.sunIlluminance.rgb * sunTransmittance * forward * (1.0f - heap.x) * 0.08f;
        radiance = mix(radiance, cloud, heap.x);

        // The land round the horizon, in front of all of it. Its alpha is
        // what the air between leaves it to hide. Below its bottom row the
        // plain goes on down: the row is repeated.
        float low = dress.clouds.z, top = dress.clouds.w;
        if (direction.z < top) {
            constexpr sampler round(coord::normalized, s_address::repeat, t_address::clamp_to_edge, filter::linear);
            float u = atan2(direction.y, direction.x) * (0.5f / M_PI_F) + 0.5f;
            // The picture's rows are kept bottom first.
            float v = saturate((direction.z - low) / (top - low));
            float4 land = horizonMap.sample(round, float2(u, v), level(0.0f));
            radiance = mix(radiance, land.rgb * (sunlight * 0.9f + skyIrradiance) / M_PI_F, land.a);
        }
    } else if (coverage > 0.0f) {
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
