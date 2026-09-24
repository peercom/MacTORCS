// SPDX-License-Identifier: GPL-2.0-only
//
// Forward opaque pass.
//
// Clustered forward rather than deferred, deliberately. Apple's tile-based GPUs
// pay for a fat G-buffer in bandwidth, which is the binding constraint on a
// 10-core M2; a racing scene has few dynamic lights and high material variety,
// which is exactly the case forward handles best.
#ifndef TORCS_FORWARD_METAL
#define TORCS_FORWARD_METAL

#include <metal_stdlib>
#include "Common.metal"
#include "BRDF.metal"
#include "Atmosphere.metal"
#include "Shadow.metal"
using namespace metal;

/// Every field is float4-aligned on purpose. MSL pads `float3` to 16 bytes and
/// each column of a `float3x3` likewise; mixing those with tighter Swift types
/// is a classic source of silent uniform corruption, so they are avoided.
struct FrameUniforms {
    /// Jittered, and therefore what geometry is rasterized with.
    float4x4 viewProjection;
    float4x4 view;
    /// Reconstructs world-space view rays in the fullscreen sky pass.
    float4x4 inverseViewProjection;
    /// Unjittered current and previous transforms, used only for motion
    /// vectors. Jitter is a sampling offset, not motion: including it would
    /// feed the upscaler the subpixel shimmer it exists to remove.
    float4x4 unjitteredViewProjection;
    float4x4 previousViewProjection;
    float4 cameraPosition;      // w unused
    float4 sunDirection;        // xyz points toward the sun, w unused
    float4 sunIlluminance;      // linear RGB, w holds the exposure scale
    float4 ambientIrradiance;   // flat ambient until real IBL lands, w unused
    /// xy input render size in pixels (motion vectors are in those pixels),
    /// z texture mip bias, w nonzero when a screen-space occlusion target is
    /// bound for this frame.
    float4 renderSize;
};

struct DrawUniforms {
    float4x4 model;
    /// Inverse transpose of the model's upper 3x3, promoted to 4x4. Required
    /// rather than reusing `model` because non-uniform scale would otherwise
    /// skew normals away from the surface.
    float4x4 normalMatrix;
    float4 baseColour;
    float4 material;            // x roughness, y metallic, z clearcoat, w clearcoat roughness
    float4 parameters;          // x normal strength, y alpha threshold, z uv0 scale, w metre-UV fold period or 0
    uint4 maps;                 // x albedo, y normal, z ORM, w bits: 1 receives occlusion, 2 paints road markings
};

/// Places a whole scene in the world, on top of each batch's own node-local
/// transform.
///
/// Kept separate from `DrawUniforms` rather than folded into it because a batch
/// transform is fixed at load while an instance transform changes every frame.
/// Composing them on the GPU means a moving car costs one 128-byte upload per
/// instance instead of recomputing an inverse-transpose for each of its batches.
struct InstanceUniforms {
    float4x4 model;
    float4x4 normalMatrix;
    /// Where this instance was last frame. Equal to `model` for static
    /// geometry, which makes its motion purely the camera's.
    float4x4 previousModel;
};

struct ForwardVarying {
    // Invariant so the depth prepass and this pass agree exactly, which the
    // temporal path depends on.
    float4 position [[position, invariant]];
    float3 worldPosition;
    float3 normal;
    float4 tangent;
    float2 uv0;
    float2 uv1;
    /// Per-vertex attributes, 0..1. The road generator writes lateral
    /// position, width and role here; see RoadGeneration.attributes.
    float4 attributes;
    /// Unjittered clip positions, for the motion vector.
    float4 currentClip;
    float4 previousClip;
};

/// Converts a pair of clip positions into the motion vector MetalFX expects:
/// the offset in input pixels from this pixel to where it was last frame, in
/// Metal's device coordinates with the origin at the upper left.
inline float2 motionVector(float4 currentClip, float4 previousClip, float2 renderSize) {
    // A vertex behind the eye has a degenerate projection; treat it as static
    // rather than emitting a wild vector the history would smear.
    if (abs(currentClip.w) < 1e-6f || abs(previousClip.w) < 1e-6f) { return float2(0.0f); }
    float2 current = currentClip.xy / currentClip.w;
    float2 previous = previousClip.xy / previousClip.w;
    // Clip to UV: x maps directly, y flips because clip space is y-up and
    // device coordinates are y-down.
    float2 currentUV = current * float2(0.5f, -0.5f) + 0.5f;
    float2 previousUV = previous * float2(0.5f, -0.5f) + 0.5f;
    return (previousUV - currentUV) * renderSize;
}

struct ForwardOutput {
    float4 colour [[color(0)]];
    float2 velocity [[color(1)]];
    /// See encodeReflectionSurface. Memoryless and discarded when screen-space
    /// reflections are off.
    float4 reflectionSurface [[color(2)]];
};

/// Set when the material needs an alpha cutout. Specialized as a function
/// constant rather than branched at runtime: RASTER_STABILITY.md documents an
/// M2 repeat-render instability caused by an *inactive* discard path, and that
/// reasoning still applies.
constant bool forwardAlphaTest [[function_constant(0)]];

vertex ForwardVarying forwardVertex(uint id [[vertex_id]],
                                    const device PackedVertex *vertices [[buffer(0)]],
                                    constant FrameUniforms &frame [[buffer(1)]],
                                    constant DrawUniforms &draw [[buffer(2)]],
                                    constant InstanceUniforms &instance [[buffer(5)]]) {
    PackedVertex v = vertices[id];
    float4 world = instance.model * draw.model * float4(float3(v.position), 1.0f);

    ForwardVarying out;
    out.position = frame.viewProjection * world;
    out.worldPosition = world.xyz;
    out.normal = (instance.normalMatrix * draw.normalMatrix * float4(decodeNormal(v.normal), 0.0f)).xyz;
    float4 tangent = decodeTangent(v.tangent);
    // The tangent is a direction in the surface, so it transforms by the model
    // matrix, not the inverse transpose. Handedness rides along untouched.
    out.tangent = float4((instance.model * draw.model * float4(tangent.xyz, 0.0f)).xyz, tangent.w);
    // Generated geometry folds its metre UVs to fit a half (see
    // RenderMesh.build); unfold in float before interpolation. Baked
    // artwork has a zero period and passes through.
    out.uv0 = float2(v.uv0) + float2(v.uv1) * draw.parameters.w;
    out.uv1 = float2(v.uv1);
    out.attributes = float4(v.blend) * (1.0f / 255.0f);
    out.currentClip = frame.unjitteredViewProjection * world;
    out.previousClip = frame.previousViewProjection * instance.previousModel * draw.model
                     * float4(float3(v.position), 1.0f);
    return out;
}

fragment ForwardOutput forwardFragment(ForwardVarying in [[stage_in]],
                                constant FrameUniforms &frame [[buffer(1)]],
                                constant DrawUniforms &draw [[buffer(2)]],
                                texture2d<float> albedoMap [[texture(0)]],
                                texture2d<float> normalMap [[texture(1)]],
                                texture2d<float> ormMap [[texture(2)]],
                                texture2d<float> transmittanceLUT [[texture(3)]],
                                texture2d<float> multiScatterLUT [[texture(4)]],
                                texture2d<float> skyViewLUT [[texture(5)]],
                                constant SkyIrradiance &skyIrradiance [[buffer(3)]],
                                constant ShadowUniforms &shadow [[buffer(4)]],
                                depth2d_array<float> shadowMap [[texture(6)]],
                                texture2d<float> occlusionMap [[texture(7)]],
                                sampler surfaceSampler [[sampler(0)]],
                                sampler shadowSampler [[sampler(1)]]) {
    float4 albedo = draw.baseColour;
    if (draw.maps.x != 0) {
        // The albedo texture is bound as sRGB, so hardware returns linear.
        // The negative mip bias is what gives temporal upscaling something to
        // reconstruct: sampling at the render resolution would otherwise select
        // mips for that resolution and the upscaled image would just be a
        // blurry half-resolution one.
        albedo *= albedoMap.sample(surfaceSampler, (in.uv0 * draw.parameters.z), bias(frame.renderSize.z));
    }
    if (forwardAlphaTest && albedo.a <= draw.parameters.y) { discard_fragment(); }

    float3x3 basis = tangentBasis(in.normal, in.tangent);
    float3 normal = basis[2];
    if (draw.maps.y != 0) {
        float2 encoded = normalMap.sample(surfaceSampler, (in.uv0 * draw.parameters.z), bias(frame.renderSize.z)).xy;
        normal = normalize(basis * unpackNormalMap(encoded, draw.parameters.x));
    }

    float roughness = draw.material.x, metallic = draw.material.y, occlusion = 1.0f;
    if (draw.maps.z != 0) {
        float3 orm = ormMap.sample(surfaceSampler, (in.uv0 * draw.parameters.z), bias(frame.renderSize.z)).xyz;
        occlusion = orm.x;
        roughness *= orm.y;
        metallic *= orm.z;
    }

    // Road markings, painted procedurally from the generator's lateral
    // coordinate rather than baked into a 256² texture: crisp at every
    // distance, and the racing line's rubber comes for free from the same
    // coordinate. Only the main road paints; sides and borders carry role 1
    // and 2 and get rubber alone.
    if (draw.maps.w & 2u) {
        float width = in.attributes.y * 255.0f / 8.0f;
        float fromRight = in.attributes.x * width;
        float fromLeft = width - fromRight;
        float along = (in.uv0 * draw.parameters.z).x / max(draw.parameters.z, 1e-6f);  // metres
        float role = in.attributes.z * 255.0f;
        // Screen-space width of one metre, for antialiased edges.
        float aa = max(fwidth(fromRight), 1e-4f);
        float paint = 0.0f;
        if (role < 0.5f) {
            // Edge lines 12 cm wide, 20 cm in from the edge.
            float edge = 0.06f, inset = 0.26f;
            paint = max(paint, 1.0f - smoothstep(edge - aa, edge + aa, abs(fromRight - inset)));
            paint = max(paint, 1.0f - smoothstep(edge - aa, edge + aa, abs(fromLeft - inset)));
            // Dashed centre line: 3 m on, 6 m off.
            float dash = step(fract(along / 9.0f) * 9.0f, 3.0f);
            paint = max(paint, dash * (1.0f - smoothstep(0.05f - aa, 0.05f + aa, abs(fromRight - width * 0.5f))));
            // Start line across the road at the origin.
            paint = max(paint, 1.0f - smoothstep(0.0f, aa, along - 0.5f)) * step(-aa, along);
        }
        // Worn white paint: not quite white, and smoother than the tarmac.
        albedo.rgb = mix(albedo.rgb, float3(0.78f, 0.78f, 0.74f), paint * 0.85f);
        roughness = mix(roughness, 0.55f, paint);
        // Rubber laid down on the racing line, approximated as a soft band on
        // the middle of the road with a little low-frequency variation.
        if (role < 1.5f) {
            float offset = (fromRight - width * 0.5f) / max(width, 1e-3f);
            float band = exp(-offset * offset * 18.0f);
            float wander = 0.75f + 0.25f * sin(along * 0.037f) * sin(along * 0.011f + 1.7f);
            float rubber = band * wander * 0.3f;
            albedo.rgb *= 1.0f - rubber;
            roughness *= 1.0f - rubber * 0.35f;
        }
    }

    SurfaceMaterial surface;
    surface.albedo = albedo.rgb;
    // Widen roughness where the normal varies fast within this pixel. This
    // matters more than usual because rendering happens at half resolution and
    // the temporal history would otherwise preserve the aliasing as crawl.
    surface.perceptualRoughness = filteredPerceptualRoughness(saturate(roughness), normal);
    surface.metallic = saturate(metallic);
    surface.ambientOcclusion = occlusion;
    surface.normal = normal;
    surface.emissive = float3(0.0f);
    surface.clearcoat = draw.material.z;
    surface.clearcoatRoughness = draw.material.w;
    // The coat is a separate flat layer over the base, so it uses the
    // geometric normal, not the detail-mapped one.
    surface.clearcoatNormal = basis[2];

    float3 view = normalize(frame.cameraPosition.xyz - in.worldPosition);
    float3 sunDirection = normalize(frame.sunDirection.xyz);

    // View-space depth selects the cascade. The camera looks down -Z.
    float viewDepth = -(frame.view * float4(in.worldPosition, 1.0f)).z;
    float visibility = sampleShadow(shadow, shadowMap, shadowSampler, in.worldPosition,
                                    basis[2], sunDirection, viewDepth, in.position.xy);

    // Screen-space occlusion, computed from the depth prepass: red is sky
    // visibility, green is sun visibility over the first few decimetres. Only
    // opaque geometry receives it — a transparent surface would pick up the
    // occlusion of whatever is behind it, which is not its own.
    if (frame.renderSize.w > 0.0f && (draw.maps.w & 1u)) {
        constexpr sampler occlusionSampler(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 occluded = occlusionMap.sample(occlusionSampler, in.position.xy / frame.renderSize.xy).rg;
        visibility *= occluded.g;
        surface.ambientOcclusion *= occluded.r;
    }

    float3 colour = evaluateLight(surface, view, sunDirection, frame.sunIlluminance.rgb) * visibility;

    // Ambient comes from the sky itself, not a constant. SH9 for diffuse, and
    // the sky table sampled along the reflection vector at a roughness-selected
    // mip as a cheap specular probe.
    constexpr sampler skySampler(coord::normalized, address::repeat, filter::linear, mip_filter::linear);
    float3 irradiance = evaluateSkyIrradiance(skyIrradiance, normal);
    float3 reflection = reflect(-view, normal);
    float mipCount = float(max(skyViewLUT.get_num_mip_levels(), 1u) - 1u);
    float3 prefiltered = skyViewLUT.sample(skySampler, skyViewUV(reflection),
                                           level(surface.perceptualRoughness * mipCount)).rgb;
    // The sharp white lobe: the clear coat where there is one, otherwise the
    // base lobe of a dielectric. Screen-space reflections replace this lobe's
    // probe where they hit; a metal's coloured base lobe is never traced.
    float3 sharpNormal = surface.clearcoat > 0.0f ? surface.clearcoatNormal : normal;
    float sharpRoughness = surface.clearcoat > 0.0f
        ? max(surface.clearcoatRoughness, kMinPerceptualRoughness) : surface.perceptualRoughness;
    float3 prefilteredCoat = prefiltered;
    if (surface.clearcoat > 0.0f) {
        prefilteredCoat = skyViewLUT.sample(skySampler, skyViewUV(reflect(-view, sharpNormal)),
                                            level(sharpRoughness * mipCount)).rgb;
    }
    colour += evaluateImageBasedLight(surface, view, irradiance, prefiltered, prefilteredCoat);
    colour += surface.emissive;
    float sharpWeight;
    if (surface.clearcoat > 0.0f) {
        sharpWeight = clearcoatEnvironmentWeight(surface, view);
    } else {
        float NoVs = saturate(dot(normal, view)) + 1e-5f;
        float2 sdfg = environmentBRDF(sharpRoughness, NoVs);
        sharpWeight = (0.04f * sdfg.x + sdfg.y) * (1.0f - surface.metallic);
    }
    sharpWeight *= surface.ambientOcclusion;

    // Aerial perspective, from the same medium the sky uses. This replaces the
    // classic path's per-camera linear fog, whose range was authored separately
    // for each of the 31 cameras and could never agree with the sky behind it.
    float3 transmittance;
    float3 inScatter = aerialPerspective(in.worldPosition, frame.cameraPosition.xyz,
                                         normalize(frame.sunDirection.xyz), frame.sunIlluminance.rgb,
                                         transmittanceLUT, multiScatterLUT, transmittance);
    colour = colour * transmittance + inScatter;

    ForwardOutput out;
    out.colour = float4(colour, albedo.a);
    // The composite adds onto the blended result, so a translucent draw's
    // weight carries its alpha; and the probe it replaces was attenuated by
    // the medium, so the weight carries that too.
    out.reflectionSurface = encodeReflectionSurface(sharpNormal, sharpRoughness,
        sharpWeight * albedo.a * dot(transmittance, float3(0.2126f, 0.7152f, 0.0722f)));
    out.velocity = motionVector(in.currentClip, in.previousClip, frame.renderSize.xy);
    return out;
}

/// Depth-only fragment for alpha-tested geometry.
///
/// Cutouts cannot be depth-only with a nil fragment function: visibility
/// depends on the texture, so the prepass has to sample and discard exactly as
/// the forward pass will, or foliage writes depth where it is transparent.
fragment void depthOnlyFragment(ForwardVarying in [[stage_in]],
                                constant DrawUniforms &draw [[buffer(2)]],
                                texture2d<float> albedoMap [[texture(0)]],
                                sampler surfaceSampler [[sampler(0)]]) {
    float alpha = draw.baseColour.a;
    if (draw.maps.x != 0) { alpha *= albedoMap.sample(surfaceSampler, (in.uv0 * draw.parameters.z)).a; }
    if (alpha <= draw.parameters.y) { discard_fragment(); }
}

// MARK: - Fullscreen resolve

struct FullscreenVarying {
    float4 position [[position]];
    float2 uv;
};

/// Three-vertex fullscreen triangle: no vertex buffer, no index buffer.
vertex FullscreenVarying fullscreenVertex(uint id [[vertex_id]]) {
    float2 uv = float2((id << 1) & 2, id & 2);
    FullscreenVarying out;
    out.position = float4(uv * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f), 0.0f, 1.0f);
    out.uv = uv;
    return out;
}

#endif
