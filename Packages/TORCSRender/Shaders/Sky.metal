// SPDX-License-Identifier: GPL-2.0-only
#ifndef TORCS_SKY_METAL
#define TORCS_SKY_METAL

#include <metal_stdlib>
#include "Atmosphere.metal"
#include "Forward.metal"
using namespace metal;

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
    if (cosAngle > cosAngularRadius) {
        float limb = smoothstep(cosAngularRadius, 1.0f, cosAngle);
        float altitude = max(frame.cameraPosition.z / kMetresPerKilometre, 0.0005f);
        float3 transmittance = transmittanceLUT.sample(clamped, transmittanceUV(altitude, sun.z)).rgb;
        // Bright enough that the tonemapper has something to roll off, which is
        // most of what makes a sun read as a sun.
        radiance += frame.sunIlluminance.rgb * transmittance * limb * 40.0f;
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
