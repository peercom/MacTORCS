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
    float4 cameraPosition;      // w scene wetness, 0 dry to 1 soaked
    float4 sunDirection;        // xyz points toward the sun, w unused
    float4 sunIlluminance;      // linear RGB, w holds the exposure scale
    float4 ambientIrradiance;   // xyz flat ambient until real IBL lands, w animation time in seconds
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
    uint4 maps;                 // x albedo, y structure (normal, roughness, occlusion), z unused, w bits: 1 receives occlusion, 2 paints road markings, 4 foliage, 8 receives weather
    float4 emissive;
    /// x coverage of a detail cross-fade, y +1 leaving / −1 arriving,
    /// z extra UV scale of the structure map over the albedo's, w how far
    /// the ground's colour drifts over tens of metres (0 for none).
    float4 fade;            // rgb radiance when lit, w channel: 0 never, 1 brake, 2 headlight, 3 any light
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
    /// x brake lights lit, y headlights lit, z rear lights lit, w unused.
    float4 lightState;
};

/// Interleaved gradient noise per pixel, for the detail cross-fade: stable
/// frame to frame, and the two builds of one switch keep complementary
/// halves of it.
inline float ditherNoise(float2 pixel) {
    return fract(52.9829189f * fract(dot(pixel, float2(0.06711056f, 0.00583715f))));
}
/// True when this fragment belongs to the other build of a detail switch.
inline bool detailDithered(constant DrawUniforms &draw, float2 pixel) {
    if (draw.fade.x >= 1.0f) { return false; }
    float n = ditherNoise(pixel);
    return draw.fade.y > 0.0f ? (n >= draw.fade.x) : (n < 1.0f - draw.fade.x);
}

/// Value noise on an integer lattice, for the puddle mask.
inline float groundHash(float2 p) {
    return fract(sin(dot(p, float2(127.1f, 311.7f))) * 43758.5453f);
}
inline float groundNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0f - 2.0f * f);
    float a = groundHash(i), b = groundHash(i + float2(1, 0));
    float c = groundHash(i + float2(0, 1)), d = groundHash(i + float2(1, 1));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

/// `skyViewUV` for a direction already of unit length, with the two inverse
/// trigonometric functions as polynomials (Abramowitz and Stegun 4.4.45 and
/// a degree-eleven odd fit). They are within a ten-thousandth of a radian,
/// a few thousandths of a texel of the sky table, and the lookup runs once
/// or twice for every pixel of the scene.
inline float2 skyViewUVFast(float3 d) {
    float ax = abs(d.x), ay = abs(d.y);
    float z = min(ax, ay) / max(max(ax, ay), 1e-12f);
    float z2 = z * z;
    float a = z * (0.99997726f + z2 * (-0.33262347f + z2 * (0.19354346f + z2 * (-0.11643287f
            + z2 * (0.05265332f - 0.01172120f * z2)))));
    a = ay > ax ? kAtmospherePi * 0.5f - a : a;
    a = d.x < 0.0f ? kAtmospherePi - a : a;
    float azimuth = d.y < 0.0f ? -a : a;
    float c = clamp(d.z, -1.0f, 1.0f), ac = abs(c);
    float zenith = sqrt(1.0f - ac) * (1.5707288f + ac * (-0.2121144f + ac * (0.0742610f - 0.0187293f * ac)));
    zenith = c < 0.0f ? kAtmospherePi - zenith : zenith;
    float v = (zenith - kAtmospherePi * 0.5f) / (kAtmospherePi * 0.5f);
    float mapped = sqrt(abs(v)) * (v < 0.0f ? -1.0f : 1.0f);
    return float2(azimuth / (2.0f * kAtmospherePi) + 0.5f, mapped * 0.5f + 0.5f);
}

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
    /// How lit this draw's emissive channel is on this instance, 0 or 1.
    float lit;
    /// Unjittered clip positions, for the motion vector.
    float4 currentClip;
    float4 previousClip;
    /// Aerial perspective between the eye and this vertex: the light the air
    /// scatters into the ray, and what it lets through. See forwardVertex.
    float3 inScatter;
    float3 transmittance;
    /// The rubber's slow variation along the lap, on the main road only:
    /// x how heavily it lies, y the phase its streaks wander by.
    float2 lap;
    /// The ground's drift of colour here, -1 to 1 by the draw's amount: see
    /// forwardVertex.
    float drift;
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

/// What else a forward pipeline is compiled for: the paths only some
/// materials, or only some weather, take. As branches on a draw's flags they
/// cost every draw: this shader is bound by its arithmetic, and what a
/// branch not taken holds is worked out ahead of it all the same. At
/// 2880x1720 the leaf's three lines cost a frame without a leaf in it
/// 0.13 ms, the clear coat 0.12, the cloud cover 0.06 and the road paint
/// 0.06 off the road. Compiled in only for the draws that use them, they
/// cost the others nothing. (The indices follow the tonemap pass's, 1 to 3.)
///
/// Leaf cards, lit from both sides and through.
constant bool forwardFoliage [[function_constant(4)]];
/// Paint under a clear coat: a second lobe on the sun and on the sky.
constant bool forwardClearcoat [[function_constant(5)]];
/// The main road's markings and the rubber on its racing line.
constant bool forwardRoadPaint [[function_constant(6)]];
/// A frame under cloud or on wet ground.
constant bool forwardWeather [[function_constant(7)]];

vertex ForwardVarying forwardVertex(uint id [[vertex_id]],
                                    const device PackedVertex *vertices [[buffer(0)]],
                                    constant FrameUniforms &frame [[buffer(1)]],
                                    constant DrawUniforms &draw [[buffer(2)]],
                                    constant InstanceUniforms &instance [[buffer(5)]],
                                    texture2d<float> transmittanceLUT [[texture(3)]],
                                    texture2d<float> multiScatterLUT [[texture(4)]]) {
    PackedVertex v = vertices[id];
    float4 world = instance.model * draw.model * float4(float3(v.position), 1.0f);
    if (draw.maps.w & 4u) {
        // Foliage sway: two slow sines phased by position so neighbouring
        // plants do not move in step, scaled by the square of height so the
        // base stays put. The amplitude at the top comes from the geometry
        // (blend.y, 255 = a quarter metre): a tree top moves decimetres, a
        // grass tip centimetres.
        float h = float(v.blend.x) * (1.0f / 255.0f);
        float amplitude = float(v.blend.y) * (0.25f / 255.0f);
        float t = frame.ambientIrradiance.w;
        float2 sway = float2(sin(t * 1.1f + world.x * 0.05f + world.y * 0.07f),
                             cos(t * 0.9f + world.y * 0.06f - world.x * 0.04f)) * (h * h * amplitude);
        world.xy += sway;
    }

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
    // Resolved here so the fragment stage needs no instance binding.
    float channel = draw.emissive.w;
    out.lit = channel > 2.5f ? instance.lightState.z : (channel > 1.5f ? instance.lightState.y
            : (channel > 0.5f ? instance.lightState.x : 0.0f));
    // The racing line's rubber varies along the lap with wavelengths of
    // fifty metres and more. Between two rows of the road that is a
    // straight line, so three of its five sines are taken here. On the
    // draw's flag, not the pipeline's constant: every scene pipeline and the
    // depth prepass share this one vertex function, and with it positions
    // that agree to the bit.
    out.lap = float2(1.0f, 0.0f);
    if (draw.maps.w & 2u) {
        float along = out.uv0.x;
        out.lap = float2(0.8f + 0.2f * sin(along * 0.037f) * sin(along * 0.011f + 1.7f),
                         sin(along * 0.13f) * 0.8f);
    }
    // A field is not one green. A tile of grass repeats every few metres and
    // can hold nothing larger than a metre without the repeat showing, so
    // what changes over tens of metres, a lighter rise or a darker hollow,
    // is laid over it here from the place itself: two scales of noise in
    // world space, which never repeats, taken at the vertices because the
    // ground's triangles are no coarser than the drifts are.
    out.drift = 0.0f;
    if (draw.fade.w > 0.0f) {
        float broad = groundNoise(world.xy * (1.0f / 38.0f)) * 0.6f + groundNoise(world.xy * (1.0f / 117.0f) + 17.3f) * 0.4f;
        out.drift = (broad - 0.5f) * 2.0f * draw.fade.w;
    }
    out.currentClip = frame.unjitteredViewProjection * world;
    out.previousClip = frame.previousViewProjection * instance.previousModel * draw.model
                     * float4(float3(v.position), 1.0f);
    // Aerial perspective, from the same medium the sky uses, in place of the
    // classic path's per-camera linear fog. Evaluated here and interpolated
    // rather than per pixel: over the length of a circuit the air's effect is
    // within a part in a thousand of linear in distance, so the two agree to
    // less than a display step, and this was a sixth of the scene pass at
    // five million pixels. The widest error is the forward-scattering peak a
    // few degrees round the sun, which a triangle wider than that smooths.
    out.inScatter = aerialPerspective(world.xyz, frame.cameraPosition.xyz,
                                      normalize(frame.sunDirection.xyz), frame.sunIlluminance.rgb,
                                      transmittanceLUT, multiScatterLUT, out.transmittance);
    return out;
}

fragment ForwardOutput forwardFragment(ForwardVarying in [[stage_in]],
                                bool frontFacing [[front_facing]],
                                constant FrameUniforms &frame [[buffer(1)]],
                                constant DrawUniforms &draw [[buffer(2)]],
                                texture2d<float> albedoMap [[texture(0)]],
                                texture2d<float> structureMap [[texture(1)]],
                                texture2d<float> roadWear [[texture(2)]],
                                texture2d<float> skyViewLUT [[texture(5)]],
                                constant SkyIrradiance &skyIrradiance [[buffer(3)]],
                                constant ShadowUniforms &shadow [[buffer(4)]],
                                depth2d_array<float> shadowMap [[texture(6)]],
                                texture2d<float> occlusionMap [[texture(7)]],
                                sampler surfaceSampler [[sampler(0)]],
                                sampler shadowSampler [[sampler(1)]],
                                sampler detailSampler [[sampler(2)]]) {
    float4 albedo = draw.baseColour;
    if (draw.maps.x != 0) {
        // The albedo texture is bound as sRGB, so hardware returns linear.
        // The negative mip bias is what gives temporal upscaling something to
        // reconstruct: sampling at the render resolution would otherwise select
        // mips for that resolution and the upscaled image would just be a
        // blurry half-resolution one.
        albedo *= albedoMap.sample(surfaceSampler, (in.uv0 * draw.parameters.z), bias(frame.renderSize.z));
    }
    // Lighter and a little yellower one way, darker the other.
    albedo.rgb *= 1.0f + in.drift * float3(0.22f, 0.15f, 0.02f);
    if (forwardAlphaTest && albedo.a <= draw.parameters.y) { discard_fragment(); }
    if (forwardAlphaTest && detailDithered(draw, in.position.xy)) { discard_fragment(); }

    float3x3 basis = tangentBasis(in.normal, in.tangent);
    float3 normal = basis[2];
    float roughness = draw.material.x, metallic = draw.material.y, occlusion = 1.0f;
    if (draw.maps.y != 0) {
        // The surface's structure in one sample: roughness in red, the
        // normal's y in green, occlusion in blue, the normal's x in alpha
        // (see StructureMap in MaterialLibrary.swift). They were a normal
        // map and a roughness map, a sample each, which at five million
        // pixels was 0.13 ms for the second.
        //
        // It takes the cheaper sampler: at the road's grazing angles the
        // albedo's anisotropy is what keeps the surface legible, and this
        // at a quarter of it measured a millisecond less with no visible
        // change (see RENDERER_REPLACEMENT.md).
        float4 structure = structureMap.sample(detailSampler, (in.uv0 * draw.parameters.z * draw.fade.z),
                                               bias(frame.renderSize.z));
        // Green is stored two steps of 255 up, so that flat is a value its
        // six bits can hold.
        float2 encoded = float2(structure.a, structure.g - 2.0f / 255.0f);
        normal = normalize(basis * unpackNormalMap(encoded, draw.parameters.x));
        occlusion = structure.b;
        roughness *= structure.r;
    }

    // Leaf cards are visible from both sides. Their reverse face needs the
    // reverse normal as well; otherwise half the crown lights as black paper.
    const bool foliage = forwardFoliage && (draw.maps.w & 4u);
    if (foliage && !frontFacing) { normal = -normal; }

    // Per-leaf tint from the tree builder, so a crown is not one flat colour.
    if (foliage) { albedo.rgb *= mix(0.55f, 1.05f, in.attributes.w); }

    // Road markings, painted procedurally from the generator's lateral
    // coordinate rather than baked into a 256² texture: crisp at every
    // distance, and the racing line's rubber comes from the same coordinate
    // and the line the generator wrote. Only the main road paints; sides and
    // borders carry role 1 and 2 and stay clean.
    if (forwardRoadPaint && (draw.maps.w & 2u)) {
        float width = in.attributes.y * 255.0f / 8.0f;
        float fromRight = in.attributes.x * width;
        float along = in.uv0.x;  // metres
        float role = in.attributes.z * 255.0f;
        // Screen-space width of one metre, for antialiased edges. Taken
        // ahead of the branch on the role: a derivative wants every pixel
        // of the quad to have got here.
        float aa = max(fwidth(fromRight), 1e-4f);
        if (role < 0.5f) {
            // What years of use have left on the road, under its paint: a
            // map laid along the road and across it, a repeat every 96 m
            // and edge to edge (see RoadWear). Its red is the surface's
            // tone about mid grey, joints and patches and spills; green its
            // roughness; blue tar, in a sealed joint or crack, near black
            // and glossy; alpha the dust and clippings along the edges.
            // Taken with the albedo's sampler: seen down the road it is
            // foreshortened many times over, and a seam is two fingers wide.
            float4 wear = roadWear.sample(surfaceSampler, float2(along * (1.0f / 96.0f), in.attributes.x));
            // Heavier on some stretches of the lap than on others, by the
            // ground's own drift: the same joints come round every 96 m,
            // and a stretch where they are faint is what keeps the eye from
            // counting them.
            float worn = saturate(0.72f + in.drift * 1.5f);
            albedo.rgb *= 1.0f + (wear.r - 0.5f) * 2.4f * worn;
            roughness = saturate(roughness + (wear.g - 0.5f) * 0.8f * worn);
            albedo.rgb = mix(albedo.rgb, float3(0.012f, 0.012f, 0.013f), wear.b * 0.78f * worn);
            roughness = mix(roughness, 0.32f, wear.b * 0.7f * worn);
            albedo.rgb = mix(albedo.rgb, float3(0.110f, 0.100f, 0.075f), wear.a * 0.55f);
            roughness = mix(roughness, 0.95f, wear.a * 0.6f);
            // Every line is a band about a centre, and the paint is the
            // nearest band: one signed distance to the nearest edge of any
            // of them and one smooth step across it, where each line used to
            // take a step of its own. Edge lines 12 cm wide, 20 cm in from
            // either edge.
            float line = abs(min(fromRight, width - fromRight) - 0.26f) - 0.06f;
            // Dashed centre line: 3 m on, 6 m off.
            float dash = fract(along * (1.0f / 9.0f)) * 9.0f <= 3.0f ? abs(fromRight - width * 0.5f) - 0.05f : 1e6f;
            // Start line across the road at the origin.
            float start = 2.0f * (along - 0.5f) - aa;
            float t = saturate((min(min(line, dash), start) + aa) / (2.0f * aa));
            float paint = (1.0f - t * t * (3.0f - 2.0f * t)) * step(-aa, along);
            // Worn white paint: not quite white, and smoother than the tarmac.
            albedo.rgb = mix(albedo.rgb, float3(0.78f, 0.78f, 0.74f), paint * 0.85f);
            roughness = mix(roughness, 0.55f, paint);
            // Rubber laid down on the racing line. The generator wrote the
            // line's lateral position per row; the band is a metre or so wide
            // either side of it, heavier than the surrounding tarmac and
            // glossier, with a slow variation along the lap so it does not read
            // as a painted stripe. Only the main road carries it.
            float lineFromRight = in.attributes.w * width;
            float offset = fromRight - lineFromRight;
            // A metre-wide core where the tyres actually run, in a wider
            // halo of lighter deposits. The core is the halo's bell to the
            // sixth power, so one exponential serves both; it had one of
            // its own, a thirtieth wider.
            float halo = exp(-offset * offset * 0.25f);
            float halo2 = halo * halo;
            float core = halo2 * halo2 * halo2;
            // Rubber goes down in streaks along the road, not as a wash:
            // fine lateral variation, stretched longitudinally. What varies
            // only along the lap, over tens of metres, comes from the
            // vertices (see forwardVertex).
            float streaks = 0.75f + 0.25f * sin(fromRight * 23.0f + in.lap.y)
                                  * sin(fromRight * 7.3f + along * 0.02f);
            float rubber = saturate((core * 0.6f + halo * 0.25f) * in.lap.x * streaks);
            // Rubbered tarmac is near-black and glossy against the grey of
            // the exposed aggregate around it.
            albedo.rgb = mix(albedo.rgb, albedo.rgb * 0.28f, rubber);
            roughness = mix(roughness, roughness * 0.6f, rubber);
        }
    }

    // Wet ground. A film of water darkens every surface it covers and
    // makes it glossy; where the surface is near-horizontal and low, water
    // collects into puddles that are flat and mirror-smooth. The puddle
    // mask is a two-octave value noise of the world position, thresholded
    // by the wetness, and on the road biased toward the edges, where the
    // crown drains.
    float wet = forwardWeather ? frame.cameraPosition.w : 0.0f;
    if (wet > 0.0f && (draw.maps.w & 8u)) {
        float film = wet * 0.85f;
        albedo.rgb *= mix(1.0f, 0.55f, film);
        // A sheen, not a mirror: kept above the reflection trace's roughness
        // cutoff so only the puddles are traced. Tracing the whole road cost
        // 0.8 ms at 1280x832 and looked like a lake.
        roughness = mix(roughness, 0.5f, film);
        float2 wp = in.worldPosition.xy;
        float n = groundNoise(wp * 0.33f) * 0.6f + groundNoise(wp * 1.05f + 7.3f) * 0.4f;
        float bias = 0.0f;
        if (draw.maps.w & 2u) {
            float lateral = in.attributes.x;
            bias = mix(0.16f, -0.06f, smoothstep(0.0f, 0.22f, min(lateral, 1.0f - lateral)));
        }
        float threshold = 0.7f - wet * 0.2f + bias;
        float puddle = smoothstep(threshold, threshold + 0.08f, n) * wet;
        // Only where water can stand: flat ground, not walls or banks.
        puddle *= saturate(basis[2].z * 6.0f - 5.0f);
        albedo.rgb *= mix(1.0f, 0.7f, puddle);
        roughness = mix(roughness, 0.03f, puddle);
        metallic = mix(metallic, 0.0f, puddle);
        normal = normalize(mix(normal, basis[2], puddle));
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
    // A lens is drawn blended with its own alpha; dividing the emission by
    // that alpha lets the glow through the blend at full strength.
    surface.emissive = draw.emissive.rgb * in.lit
        / (draw.emissive.w > 0.0f ? max(albedo.a, 0.25f) : 1.0f);
    surface.clearcoat = forwardClearcoat ? draw.material.z : 0.0f;
    surface.clearcoatRoughness = draw.material.w;
    // The coat is a separate flat layer over the base, so it uses the
    // geometric normal, not the detail-mapped one.
    surface.clearcoatNormal = basis[2];

    float3 view = normalize(frame.cameraPosition.xyz - in.worldPosition);
    float3 sunDirection = normalize(frame.sunDirection.xyz);

    // View-space depth selects the cascade. The camera looks down -Z.
    float viewDepth = -(frame.view * float4(in.worldPosition, 1.0f)).z;
    // Only where the sun can reach: a surface turned away from it has no
    // direct light for a shadow to remove, and the filter is the dearest
    // thing in this shader. A leaf is the exception, lit through its back.
    float visibility = 1.0f;
    if (foliage || dot(normal, sunDirection) > 0.0f) {
        visibility = sampleShadow(shadow, shadowMap, shadowSampler, in.worldPosition,
                                  basis[2], sunDirection, viewDepth, in.position.xy);
        // The sun cannot light a face turned away from it, whatever its
        // normal map says. A crack's wall leans toward the sun where the
        // face it is cut into leans away, and a face with nothing between
        // it and the sun but itself is in no shadow the map knows of: every
        // joint of a cliff in shade lit up as a bright thread. Faded in over
        // the last few degrees, so a grazing sun does not end on a line.
        if (!foliage) { visibility *= saturate(dot(basis[2], sunDirection) * 8.0f); }
    }

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

    SurfaceView seen = surfaceView(surface, view);
    float3 colour = evaluateLight(surface, seen, view, sunDirection, frame.sunIlluminance.rgb) * visibility;

    // A thin leaf transmits a little light from its back face. Keep this
    // diffuse, shadowed and energy-limited rather than adding a glossy lobe.
    if (foliage) {
        colour += albedo.rgb * frame.sunIlluminance.rgb *
                  (0.12f / M_PI_F) * max(0.0f, dot(-normal, sunDirection)) * visibility;
    }

    // Ambient comes from the sky itself, not a constant. SH9 for diffuse, and
    // the sky table sampled along the reflection vector at a roughness-selected
    // mip as a cheap specular probe.
    constexpr sampler skySampler(coord::normalized, address::repeat, filter::linear, mip_filter::linear);
    float3 irradiance = evaluateSkyIrradiance(skyIrradiance, normal);
    float3 reflection = reflect(-view, normal);
    float mipCount = float(max(skyViewLUT.get_num_mip_levels(), 1u) - 1u);
    float3 prefiltered = skyViewLUT.sample(skySampler, skyViewUVFast(reflection),
                                           level(surface.perceptualRoughness * mipCount)).rgb;
    // Under cloud the skylight is the sun's light diffused by the layer:
    // greyer than the clear sky's blue and, with the sun dimmed to match,
    // the larger part of what lights the scene. The tables describe the
    // clear sky; the coverage lane says how much of it is covered.
    float coverage = forwardWeather ? frame.sunDirection.w : 0.0f;
    if (coverage > 0.0f) {
        constexpr float3 luma = float3(0.2126f, 0.7152f, 0.0722f);
        irradiance = mix(irradiance, float3(dot(irradiance, luma)) * 2.4f, coverage);
        prefiltered = mix(prefiltered, float3(dot(prefiltered, luma)) * 1.8f, coverage);
    }
    // The sharp white lobe: the clear coat where there is one, otherwise the
    // base lobe of a dielectric. Screen-space reflections replace this lobe's
    // probe where they hit; a metal's coloured base lobe is never traced.
    float3 sharpNormal = surface.clearcoat > 0.0f ? surface.clearcoatNormal : normal;
    float sharpRoughness = surface.clearcoat > 0.0f
        ? max(surface.clearcoatRoughness, kMinPerceptualRoughness) : surface.perceptualRoughness;
    float3 prefilteredCoat = prefiltered;
    if (surface.clearcoat > 0.0f) {
        prefilteredCoat = skyViewLUT.sample(skySampler, skyViewUVFast(reflect(-view, sharpNormal)),
                                            level(sharpRoughness * mipCount)).rgb;
    }
    colour += evaluateImageBasedLight(surface, seen, view, irradiance, prefiltered, prefilteredCoat);
    colour += surface.emissive;
    float sharpWeight;
    if (surface.clearcoat > 0.0f) {
        sharpWeight = clearcoatEnvironmentWeight(surface, view);
    } else {
        // The base lobe of a dielectric, at the roughness and the angle
        // the lighting above already took the environment term for.
        sharpWeight = (0.04f * seen.dfg.x + seen.dfg.y) * (1.0f - surface.metallic);
    }
    sharpWeight *= surface.ambientOcclusion;

    // Aerial perspective, evaluated per vertex. It replaces the classic
    // path's per-camera linear fog, whose range was authored separately for
    // each of the 31 cameras and could never agree with the sky behind it.
    float3 transmittance = in.transmittance;
    colour = colour * transmittance + in.inScatter;

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
    if (detailDithered(draw, in.position.xy)) { discard_fragment(); }
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
