// SPDX-License-Identifier: GPL-2.0-only
// Tyre smoke and dust: instanced camera-facing quads, hand depth-tested
// against the opaque depth and faded where they meet it.
#ifndef TORCS_PARTICLES_METAL
#define TORCS_PARTICLES_METAL
#include <metal_stdlib>
#include "Forward.metal"
using namespace metal;

struct Particle {
    float4 positionSize;    // xyz world, w half-width in metres
    float4 colourAlpha;     // rgb linear tint, a opacity
    float4 attributes;      // x rotation, y age fraction, z kind, w seed
};

struct ParticleUniforms {
    float4 parameters;      // x near, y soft fade distance, zw render size
};

struct ParticleVarying {
    float4 position [[position]];
    float2 local;           // -1 … 1 across the quad
    float4 colourAlpha;
    float4 attributes;
    float viewDepth;        // metres in front of the camera
};

vertex ParticleVarying particleVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                                      const device Particle *particles [[buffer(0)]],
                                      constant FrameUniforms &frame [[buffer(1)]]) {
    Particle p = particles[instanceID];
    float2 corner = float2((vertexID & 1u) ? 1.0f : -1.0f, (vertexID & 2u) ? 1.0f : -1.0f);
    float s = sin(p.attributes.x), c = cos(p.attributes.x);
    float2 rotated = float2(corner.x * c - corner.y * s, corner.x * s + corner.y * c) * p.positionSize.w;
    // Camera axes from the view matrix's rows: right and up in world space.
    float3 right = float3(frame.view[0][0], frame.view[1][0], frame.view[2][0]);
    float3 up = float3(frame.view[0][1], frame.view[1][1], frame.view[2][1]);
    float3 world = p.positionSize.xyz + right * rotated.x + up * rotated.y;
    ParticleVarying out;
    out.position = frame.viewProjection * float4(world, 1.0f);
    out.local = corner;
    out.colourAlpha = p.colourAlpha;
    out.attributes = p.attributes;
    float4 view = frame.view * float4(p.positionSize.xyz, 1.0f);
    out.viewDepth = -view.z;
    return out;
}

/// Value noise from an integer-lattice hash: cheap, no texture, and enough
/// structure to make a disc read as a puff.
inline float particleHash(float2 p) {
    return fract(sin(dot(p, float2(127.1f, 311.7f))) * 43758.5453f);
}
inline float particleNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0f - 2.0f * f);
    float a = particleHash(i), b = particleHash(i + float2(1, 0));
    float c = particleHash(i + float2(0, 1)), d = particleHash(i + float2(1, 1));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

fragment float4 particleFragment(ParticleVarying in [[stage_in]],
                                 constant FrameUniforms &frame [[buffer(1)]],
                                 constant ParticleUniforms &u [[buffer(2)]],
                                 texture2d<float> depth [[texture(0)]],
                                 sampler pointSampler [[sampler(0)]]) {
    float r = length(in.local);
    if (r > 1.0f) discard_fragment();

    // Manual depth test and soft fade. The opaque depth is reversed and
    // infinite: linear = near / device.
    float2 uv = in.position.xy / u.parameters.zw;
    float deviceDepth = depth.sample(pointSampler, uv).x;
    float sceneDepth = deviceDepth > 0.0f ? u.parameters.x / deviceDepth : 1e9f;
    float behind = sceneDepth - in.viewDepth;
    if (behind < -0.02f) discard_fragment();
    float soft = saturate(behind / u.parameters.y);
    // Also fade the last metre before the camera so a puff never fills
    // the screen with a flat edge.
    soft *= saturate((in.viewDepth - 0.3f) / 0.6f);

    // A cloudy disc: radial falloff eaten into by two octaves of noise that
    // drift with age so the puff churns rather than scales.
    float age = in.attributes.y, seed = in.attributes.w * 37.0f;
    float2 n = in.local * 2.6f + seed;
    float cloud = particleNoise(n + age * 0.7f) * 0.6f + particleNoise(n * 2.9f - age * 1.1f) * 0.4f;
    float edge = 1.0f - smoothstep(0.15f, 1.0f, r);
    // High contrast: a puff is lumps with gaps, not a gradient disc.
    float coverage = saturate(edge * (cloud * 2.2f - 0.55f)) * in.colourAlpha.a * soft;
    if (coverage <= 0.002f) discard_fragment();

    // Lighting: treat the puff as a sphere and light its normal, mostly
    // ambient with a rim toward the sun. Dust is opaque and takes more sun.
    float3 normal = float3(in.local, sqrt(saturate(1.0f - r * r)));
    float3 sunView = (frame.view * float4(frame.sunDirection.xyz, 0.0f)).xyz;
    float facing = dot(normal, normalize(float3(sunView.xy, max(sunView.z, 0.0f) + 0.2f)));
    // Smoke and spray are lit as mist; dust is opaque and takes more sun.
    float smoke = abs(in.attributes.z - 1.0f) > 0.5f ? 1.0f : 0.0f;
    float wrap = mix(0.3f, 0.4f, smoke) + 0.6f * saturate(facing * 0.5f + 0.5f);
    float3 sun = frame.sunIlluminance.xyz * wrap * mix(0.16f, 0.09f, smoke);
    float3 ambient = frame.ambientIrradiance.xyz * mix(0.6f, 0.75f, smoke);
    float3 colour = in.colourAlpha.rgb * (sun + ambient);
    return float4(colour * coverage, coverage);
}

/// The half-resolution cloud over the scene: premultiplied colour and its
/// coverage, bilinearly enlarged. Smoke has no edge that this blurs.
fragment float4 particleCompositeFragment(FullscreenVarying in [[stage_in]],
                                          texture2d<float> cloud [[texture(0)]],
                                          sampler linearSampler [[sampler(0)]]) {
    return cloud.sample(linearSampler, in.uv);
}

#endif
