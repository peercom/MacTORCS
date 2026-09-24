# Renderer replacement

The classic Metal raster path reproduced TORCS 1.3.9's fixed-function OpenGL
semantics: per-vertex Blinn-Phong, four MODULATE texture stages, arithmetic on
stored sRGB bytes clamped to `[0, 1]`, linear fog, and projected blob shadows.
It is being replaced by a physically based, linear-HDR path targeting fidelity
comparable to contemporary racing titles without ray tracing, at 60 Hz on a
fanless Apple M2 with 8 GB of unified memory and a 2560x1664 display.

The full design, per-pass GPU budget and phasing are in the approved plan. This
document records what the replacement costs in retired evidence, what replaces
it, and the decisions taken along the way.

## What is retired

The classic path's visual behaviour was pinned against unchanged upstream C++
through in-process oracles. A PBR/HDR renderer cannot satisfy those comparisons,
because the quantity being compared no longer exists: there is no MODULATE
stage, no per-vertex lighting result, and no clamped sRGB framebuffer to match.

Retired with this replacement:

- The graphics oracles in `Upstream/Reference`: `graphics-instrumentation.cpp`,
  `draw-order-instrumentation.cpp`, `alpha-state-instrumentation.cpp`,
  `carlight-instrumentation.cpp`, `height-instrumentation.cpp`.
- The test files that consume them.

Explicitly **kept**:

- `texture-instrumentation.cpp` and `png-instrumentation.cpp`. The SGI and PNG
  decoders still read original content, and their parity remains meaningful.
- `asset-instrumentation.cpp`. AC/ACC parsing parity is unaffected; the new path
  consumes the same parsed scenes.
- Every physics, track-query, collision and configuration oracle. 61 of 76 unit
  test files compare against `CReference`, and this work does not go near them.
  The ~30 "Parity verified" rows in `PORT_STATUS.md` are untouched.

This is a deliberate narrowing of the parity claim, not an abandonment of it.
The project still asserts bit-level agreement with upstream for simulation and
content parsing. It no longer asserts it for rasterization, because it no longer
rasterizes the same way.

## What replaces it

Rendering correctness moves from upstream comparison to self-referential
regression plus measured budgets:

1. Golden-image tests at fixed resolution, camera, jitter index and frame count
   from a cold temporal history, compared perceptually rather than byte-exactly.
   Temporal accumulation is not bit-reproducible across driver versions.
2. Repeat-render determinism, extending the existing run-to-run and
   process-to-process identity checks and the `lastSubmissionSHA256` submission
   digest to the new pipeline under a fixed-jitter protocol.
3. Per-pass GPU timing gates from `MTLCounterSampleBuffer`, asserted against the
   plan's budget.
4. A sustained thermal test, reporting median GPU time at minute 0 against
   minute 5. The fanless steady state is the real target and nothing measured it
   before.
5. A memory budget assertion, because 8 GB of unified memory is the binding
   constraint on texture resolution.

## Decisions

### Tangents are generated at load, not baked into the mesh cache

The plan proposed a mesh cache version 3 carrying tangents. They are instead
generated at load by `TangentGeneration` in `TORCSAssets`.

`ASSET_PIPELINE.md` describes the mesh cache as a lossless, faithful parse that
preserves float bit patterns, hierarchy and all four UV and state arrays.
Tangents are derived data; storing them there weakens that contract, invalidates
every existing compiled session, and forces a format bump on each algorithm
change. Generation for the 17,609 fixture vertices is sub-millisecond.

Revisit in Phase 8 if load time is ever measured to matter.

### Block compression is encoded on the CPU

The plan proposed a compute-shader encoder. Compression happens once, offline,
inside `torcs-assetc`, so the CPU encoder in `BlockCompression` is simpler,
directly unit-testable against a reference decoder, and sufficient. A GPU
encoder only earns its complexity if compression ever moves to runtime.

### Handedness is stored in a stolen low bit

The 32-byte vertex packs normal and tangent as octahedral `short2` pairs. The
bitangent handedness occupies the low bit of the tangent's y component rather
than a fifth byte, which would drag in padding.

Measured over 20,000 quasi-uniform directions: worst-case angular error is
0.0343 degrees for both normals and tangents — identical, because octahedral
projection error dominates the y quantization. The stolen bit costs nothing
observable.

Because hardware snorm conversion would destroy that bit before a shader could
read it, both attributes are fetched as raw `short2` and decoded in the shader.
`ShaderPackingParityTests` dispatches a compute kernel over 4,096 directions and
compares against the Swift encoder: worst divergence 2.6e-07, zero handedness
mismatches.

## Measured so far

| Property | Measurement |
|---|---|
| Octahedral normal round trip, worst case | 0.0343 deg |
| Octahedral tangent round trip, worst case | 0.0343 deg |
| GPU vs CPU decode divergence | 2.6e-07, 0 handedness mismatches |
| Tangent frames over both fixture meshes | 17,609 vertices, all orthonormal and finite |
| BC1 quality on original art | 33.1 to 45.3 dB PSNR |
| BC1 and BC4 size against RGBA8 | 8:1 |
| BC3 and BC5 size against RGBA8 | 4:1 |
| BC5 normal angular error | worst 1.07 deg, mean 0.34 deg |
| Packed vertex size | 32 bytes, against the classic path's 64 |
| Flattened fixture batches | 18 car + 1,315 track = 1,333 |
| Flattened fixture triangles | 5,698 car + 12,305 track = 18,003 |

The flattening counts match the figures `ASSET_PIPELINE.md` records for the
original loader exactly — 1,333 mesh batches, 18,003 triangles including
degenerates, and 4,032 / 13,577 declared vertices. The new path reaches the same
geometry through its own traversal, which is what makes a flattening regression
detectable rather than merely plausible.

BC1 quality was measured on `tarmac-wall-1-g2`, `tr-asphalt-aa-l_n`, `grass-aa`
and `driver`. 30 dB is the conventional floor for visually acceptable BC1 on
photographic source.

### AgX output is display-encoded and must be decoded before an sRGB target

The first textured frames came out pale and flat. AgX's sigmoid produces
display-encoded values by construction, so writing them straight into an
`rgba8Unorm_srgb` render target applies the transfer function twice. The
reference chain ends with a 2.2 decode; without it, middle grey landed near 0.68
instead of 0.46.

Isolated by rendering with sun and ambient intensity at zero: the geometry came
back pure black, which ruled out a light leak and placed the fault in the
tonemapper rather than the lighting.

### Multiple-scattering compensation has to be bounded

`1 + f0 * (1 / dfg.y - 1)` is the standard multi-scatter term, but the bias
component of the environment BRDF approaches zero on smooth surfaces. Measured
at perceptual roughness 0.05 it reached a **7x** specular gain on a plain
dielectric, which is invented energy, not a correction. Now clamped at 2x, which
retains the genuine rough-metal recovery.

Both faults passed every unit test. They were found by looking at rendered
frames, which is the argument for `torcs-rendershot` existing at all.

### Front faces are counter-clockwise

AC/TORCS geometry comes from OpenGL, whose default front face is
counter-clockwise. Metal defaults to clockwise, and the renderer did not set
`setFrontFacing`, so every mesh drawn with culling enabled kept its **back**
faces and discarded its front ones.

The symptom was subtle enough to survive several milestones: the car rendered
as a dark shell with a visible roll cage and interior, which read as plausible
for a stripped DTM car. It was actually the inside of the bodywork, seen
through it. Setting `.counterClockwise` produced the correct red livery with
door numbers, badge and lights, and turned the pale track surface into dark
asphalt with lane markings.

Found only because generated terrain disappeared when back-face culling was
enabled on it — the terrain's winding was derived from geometry and therefore
correct, which made the renderer's convention the odd one out.

### Terrain winding is derived, not reasoned

The apron's two sides are mirror images, so their lateral parameterizations
have opposite handedness and no single winding rule covers both. Rather than
hand-deriving each, every triangle is oriented from its own geometric normal.
A first attempt at hand-reasoning produced 86% downward-facing normals; the
rendered frames looked plausible anyway, because the batch had culling
disabled. A unit test caught it.

### Mirrored transforms invert cull face

A negative-determinant transform reverses which side of every triangle faces the
camera. Handedness was already folded into the stored tangent, but cull face was
not, so once counter-clockwise front faces were correct for everything else the
mirrored wheel meshes became exactly wrong and disappeared.

The symptom was misleading: the draw count was unchanged, because the wheels were
being submitted and then culled. Mirroring now composes — a mirrored mesh inside
a mirrored instance faces the original way again, which is precisely how the left
and right wheels differ.

### Blending and transparency are separate flags

The AC render state carries both, and they are independent:

- bit 0 selects the alpha-blending pipeline
- bit 5 defers the draw to the sorted transparent phase

TORCS sets bit 0 on nearly every car surface, where it is a no-op at alpha 1, and
sets bit 5 only on genuinely see-through ones. Treating either bit as
"transparent" marks all 18 of the car's batches transparent; separating them
gives 6 deferred and 18 blending, which is correct. Glass is drawn back to front
with depth tested but not written, forced two-sided, and excluded from shadow
casting.

## First measurements

Offscreen, 1280x832, Apple M2, against a ~10.5 ms per-frame budget:

| Scene | GPU |
|---|---|
| Aalborg, forward PBR only | 1.005 ms |
| plus atmosphere and aerial perspective | 1.211 ms |
| plus sky spherical-harmonic IBL | 1.278 ms |
| plus four shadow cascades | 1.980 ms |
| plus generated terrain | 3.710 ms |
| 155-DTM, all of the above | 1.796 ms |

Against a ~10.5 ms budget at 1280x832. The terrain step is the largest single
increase: 6,736 triangles is negligible, but the apron fills the frame with a
fragment shader running eight aerial-perspective steps and eight shadow taps.

That was initially attributed to overdraw. It is not — see the depth prepass
measurement below. The terrain replaced cheap sky pixels with expensive shaded
ones, so the cost is in *visible* pixels, and the remedies are a cheaper
fragment shader or fewer pixels, not a prepass.

Atmosphere table construction costs about 12 ms once at load. It is startup
cost, not frame cost; measuring a single render rather than a warmed sequence
reports it as if it were the latter.

Twenty-two textures resolve for Aalborg; five do not. Those five —
`concrete.rgb`, `concrete2.rgb`, `pylon1.rgb`, `pylon2.rgb`, `pylon3.rgb` — are
exactly the shared files `ASSET_LICENSES.md` excludes for unresolved per-file
attribution. They render as obviously untextured rather than being substituted,
per the asset package's rule never to silently replace a missing dependency.

This is a correct pipeline, not yet a good-looking one: no shadows, no
atmosphere, no ambient occlusion, no reflections, and 256-square source art.

## Depth prepass: measured, and not worth shipping

Implemented behind `RenderSettings.depthPrepass`, off in every preset.

Interleaved A/B within one process, 20 warmup frames then 60 samples per
configuration alternating frame by frame, 1280x832:

| View | Off | On | Delta |
|---|---|---|---|
| Trackside, terrain filling the frame | 3.765 ms | 3.676 ms | -0.089 ms (-2.4%) |
| Overhead, maximum geometry | 3.293 ms | 3.340 ms | +0.047 ms (+1.4%) |

Both within noise, in opposite directions. This is what Apple's guidance
predicts: the GPU removes hidden surfaces in hardware, so the prepass that pays
for itself on immediate-mode architectures is redundant here and only adds a
geometry submission.

It also is not free in correctness. An equal-depth shading pass draws every
surface that matches the stored depth, where a plain depth-ordered pass lets the
comparison decide, so coplanar geometry and alpha-tested edges resolve
differently: 1,867 of 1,064,960 pixels differ (0.175%), worst channel delta 55.

The code and the setting are retained rather than deleted so the question does
not have to be re-litigated from scratch, and so it can be re-measured if the
forward fragment shader becomes substantially heavier.

### The measurement methodology matters more than the result

The first attempt measured a 39-46% improvement. That was a broken frame: the
prepass ordering left the sky undrawn, and a black sky is cheap. Every
performance claim now requires the rendered image to be checked, and the
comparison to be pixel-diffed against the reference configuration.

The second attempt, with correct images, produced contradictory results between
views and a 3.3 to 5.2 ms spread for the *same* configuration minutes apart.
This machine is fanless and its GPU clock falls under sustained load, so two
configurations measured at different times are not comparable — the thermal
drift was larger than the effect. Interleaving the configurations frame by frame
within one process cancels it. The classic path's benchmarks already worked this
way; this one did not, until it did.

## The renderer is submission-bound, not pixel-bound

The finding that reframes every performance decision so far. The same scene,
same camera, same settings, varying only resolution:

| Resolution | Pixels | GPU |
|---|---|---|
| 320x208 | 0.07 MP | 1.338 ms |
| 640x416 | 0.27 MP | 1.306 ms |
| 1280x832 | 1.06 MP | 1.305 ms |
| 2560x1664 | 4.26 MP | 1.290 ms |

A sixty-four-fold change in pixel count for no change in time. Shading is not
the cost; 1,366 draw calls with per-draw uniform uploads are.

This explains three earlier results that looked unrelated:

- The depth prepass measured neutral. It reduces shaded pixels, and shaded
  pixels are free here.
- Terrain's 1.7 ms was attributed first to overdraw, then to visible pixels
  running an expensive shader. Both were wrong. It added roughly 1,300 batches.
- MetalFX temporal upscaling measures as a **net loss**: about 6.1 ms upscaled
  from 1280x832 against 4.5 ms native at 2560x1664. Halving the render
  resolution saves nothing, and the upscaler's fixed cost is pure addition.

The work that would actually help is reducing submissions: merging the static
track's batches, argument buffers, and indirect command buffers with GPU
culling. Upscaling becomes the largest available lever only after that, which
is why it is implemented and left switchable rather than deferred.

### Temporal upscaling, implemented and off

`MTLFXTemporalScaler` with Halton jitter, per-pixel motion vectors from
unjittered current and previous transforms, a `log2` mip bias, and
`isDepthReversed` set because this renderer maps near to 1.

One correctness note worth keeping. The jitter offset applied to the projection
is inverted twice over, for two independent reasons that compose: the projection
divides by `w = -z`, so a term added to the z column arrives negated, and clip
space is y-up while device pixels are y-down. A unit test asserts the resulting
normalized offset is constant with depth, and caught the sign error — which
would have shown up only as a subtly unstable image.

## Bloom, and a settings struct that stopped lying

`RenderSettings` shipped with `bloom`, `motionBlur`, `contactShadows`,
`ambientOcclusion` and `screenSpaceReflections` all switched on in every
preset, and none of them existed. A budget table built on those flags would
have been fiction. They now sit at their inert values, pinned by
`EffectAvailabilityTests`, and each flips on in the commit that lands its pass.
Bloom is the first.

### The pass

Jimenez's progressive pyramid: a soft-kneed threshold prefilter into a level a
quarter of the source on each axis, thirteen-tap halvings down to an 8 px
floor or six levels, then three-by-three tent upsamples blended additively
back up. Ten small passes at 1280x832. The first level started at half
resolution and was moved to a quarter after measuring: at native output it
alone cost more than every other pass together.

Two decisions worth recording.

**The threshold is in exposed units, not radiance.** The first version
thresholded raw scene radiance at 1.6 and changed zero pixels of a track
render — and at strength 1.0, threshold 0, still zero. The pass was not
reaching the resolve at all? No: the resolve was fine, the pyramid was simply
empty. The scene's exposure scale is far below 1, so nothing in linear
radiance came near 1.6 after the sun illuminance and EV100 were accounted for.
A camera blooms where its *sensor* saturates, and exposure decides where that
is; a fixed radiance threshold blooms nothing at one exposure and everything
at another. The prefilter now exposes before thresholding, the resolve
exposes the scene to match, and the tonemapper is handed unit scale.

**Added, not mixed.** The energy-conserving formulation — `mix(scene, pyramid,
strength)` — is correct only when the pyramid is unthresholded. With a
threshold, most pixels contribute nothing to the pyramid, and mixing darkens
the entire frame by the blend weight: a global error bought for local
correctness. Adding overstates energy slightly around highlights, which is
also what a lens does — its point spread function keeps a bright core and
adds a halo rather than draining the core into it. `testBloomNeverDarkensAPixel`
pins this.

### One real bug found on the way

`FrameTargets.tonemapSource` returned `upscaled ?? colour`. When the upscaler
threw mid-frame the renderer set itself to nil and the comment promised "the
tonemap source follows" — but the upscaled *texture* still existed, so the
resolve would have tonemapped a never-written target. The choice now lives on
the renderer, keyed on whether the upscale actually ran this frame. Dormant
while upscaling is off, which is exactly how it went unnoticed.

### Measured

Interleaved A/B, Aalborg with generated materials, sixty pairs after twenty
warmups:

| Resolution | Bloom off | Bloom on | Delta |
|---|---|---|---|
| 1280x832 | 1.408 ms | 1.529 ms | +0.121 ms |
| 1920x1248 | 2.815 ms | 3.203 ms | +0.389 ms |
| 2560x1664 | 4.2–9.2 ms | 5.7–6.3 ms | unmeasurable, see below |

At native — which is what the default preset renders, upscaling being off —
three interleaved runs gave +4.3, +1.6 and +0.3 ms, and two sequential runs
put bloom *on* below bloom *off*. Every native run had a p95 above 12 ms
against medians of 4–9. The chip was throttling, and at that point
interleaving no longer cancels the drift because the clock is moving within a
single pair. The honest number is "somewhere under a millisecond, probably,"
and the honest method is to measure again cold.

### The frame is no longer submission-bound at native

The larger finding in that table is the *off* column. The earlier resolution
sweep showed 1.29 ms at 2560x1664 and concluded the renderer was
submission-bound — and it was, with flat 256² textures. With generated
materials every pixel now samples albedo, a BC5 normal, ORM, three atmosphere
tables and a filtered shadow, and native costs three to six times what
1280x832 does. Pixels have a price again.

That reopened the decision this document made two sections up, so it was
re-measured properly: block-interleaved (eight blocks of thirty frames,
alternating, the first ten of each discarded — per-frame alternation would
have measured target reallocation and a cold history), in the default
configuration with materials, bloom and occlusion, at 2560x1664 output:

| Configuration | Native | Upscaled from 1280x832 | Delta |
|---|---|---|---|
| default preset, on-track camera | 5.997 ms | 8.501 ms | +2.50 ms |
| materials only | 5.328 ms | 8.707 ms | +3.38 ms |
| default preset, aerial framing | 6.370 ms | 8.134 ms | +1.76 ms |

Still a loss. Halving the resolution now does save around three
milliseconds, but the temporal scaler costs about six at this output size on
this GPU, and that is the whole story. Upscaling stays implemented and off.
Two things would change it: a cheaper scaler — `MTLFXSpatialScaler` is a
fraction of the cost at lower quality, untested here — or a frame expensive
enough that the saving exceeds six milliseconds, which the remaining passes
may yet produce.

One methodological note for that re-measurement, learned the hard way here:
`for res in "1280 832"; do set -- $res` does not split words in zsh. A sweep
written that way rendered 1280x832 three times and labelled them 640, 1280 and
2560, and the "cool native 4.3 ms" it produced was wrong. Sweeps go in a
`#!/bin/bash` script now.

## Screen-space occlusion: GTAO and contact shadows

One pass, one `rg8` target, two answers to the same question — is this
pixel's surroundings blocking light from reaching it — for two lights. Red
is the fraction of the sky hemisphere visible (ground-truth ambient occlusion,
Jimenez et al. 2016); green is the fraction of the sun visible over the first
35 cm toward it, from a short march through the depth buffer, for the gap
between a tyre and the tarmac that a cascade spanning hundreds of metres
cannot resolve. Both come from the same depth fetches and the same
reconstructed normal, so they share a pass; a depth-aware 4×4 blur follows.

The depth prepass becomes a prerequisite: the pass reads the frame's opaque
depth before anything shades, so the prepass runs as its own encoder, stored,
and the scene pass loads it. Without occlusion the prepass stays inside the
scene encoder where tile memory never leaves the chip. The prepass measured
neutral, so making it mandatory for the effect costs nothing.

The forward pass multiplies its sun term by green and the surface's ambient
occlusion by red. Only opaque geometry receives either: a window would
otherwise pick up the occlusion of the seat behind it.

### Four faults, in the order they were found

The first render was almost entirely white, and it took four distinct fixes
to arrive at a correct image. Each is the kind of thing that survives in a
codebase as "AO looks a bit weak" if the intermediate texture is never
looked at directly, which is why `torcs-rendershot --occlusion-view` now
dumps both channels.

**Horizons started at the view plane.** For a surface seen at a grazing
angle — every road at distance — half of its hemisphere lies behind the
screen. Initialising the horizon search at −1 counted all of that as
occluded, and the road came out a uniform grey. The search now starts at the
hemisphere's own edge, `cos(n ± π/2)`, as XeGTAO does; a sample can only
raise a horizon from there.

**Linear falloff from zero.** A sample at half the radius had half the weight
and contributed almost nothing. Full weight to 0.4 of the radius, then a fade.

**Raw GTAO is faint.** One horizon at 45° on one side of one slice removes a
quarter of that slice's light, and most cavities present exactly that. Every
shipping implementation applies a final exponent (XeGTAO's default is 2.2);
this one uses 2, and it is what made wheel arches read as wheel arches.

**A sub-pixel first step.** With the exponent on, every flat panel carried a
diagonal hatch. The first sample's offset could be under half a pixel, which
snapped to the pixel's *own* texel: a zero-length horizon vector has a cosine
of zero, which reads as an occluder at 90° on any surface whose real horizon
sits lower. It fired at noise-dependent pixels, hence the hatch. The offset
now has a one-pixel floor.

Contact shadows had their own version: a 0.5 m thickness let a ray passing
*behind* the body count as occluded, and the whole shadowed side of the car
went black in the map. Thickness is 8 cm now, surfaces facing away from the
sun are skipped outright (the cosine term already gives zero there and
marching only adds speckle along the terminator), and the ray starts a short
way off the surface, further at distance.

### A test that was measuring the wrong thing

`testAmbientOcclusionDarkensWithoutBrightening` kept failing with a few
hundred pixels three levels *brighter* with AO on. AO only multiplies by a
value at most one, and the tonemapper simulated monotonic for the colour in
question, so this was chased for a while. It was neither: the occlusion
target's resolution was keyed on `ambientOcclusion == .full`, so the "off"
baseline — which still had contact shadows on — ran contact at *half*
resolution, and its blurrier edges were the difference. Contact resolution
now follows only the `.half` setting. The lesson is the usual one: when an
A/B differs by more than the thing being toggled, the toggle is not what you
think it is.

### Measured

Interleaved A/B, no bloom, sixty pairs after twenty warmups. "Off" also
skips the prepass, so this is the whole cost of enabling the feature:

| Scene | Resolution | Quality | Off | On | Delta |
|---|---|---|---|---|---|
| Aalborg | 1280x832 | half + contact | 2.238 ms | 2.260 ms | +0.02 ms |
| Aalborg | 1280x832 | full + contact | 2.140 ms | 2.785 ms | +0.65 ms |
| Car | 1280x832 | half + contact | 1.358 ms | 1.538 ms | +0.18 ms |
| Car | 1280x832 | full + contact | 1.251 ms | 2.201 ms | +0.95 ms |
| Aalborg | 2560x1664 | half + contact | 5.324 ms | 5.539 ms | +0.22 ms |

The default preset runs half + contact: about 0.2 ms at native. The first
version, before the radius clamp came down from 256 to 96 pixels, cost 5.9 ms
on the car scene — samples scattered across hundreds of pixels of near
ground missed the cache on every fetch. That clamp is the cost control, and
it is why the pass is affordable at all.

Not done here, and worth doing: a depth mip chain for the outer samples,
which is how XeGTAO keeps a wide radius cheap; and bent normals feeding the
diffuse IBL, which the plan lists and this pass does not yet produce.

## The road is generated, not read

Phase 5 begins with the surface the cars drive on. `RoadGeneration.road`
walks every segment of the parity-verified physics model — main road, side
strips, curb borders — and emits a ribbon per segment: a grid of `rows ×
spans` quads with positions from `localToGlobal`, heights from `height`
(which already carries banking, longitudinal slope, curb ramps and the
surface roughness sine), and normals from `surfaceNormal`, so adjacent
segments shade continuously without welding. UVs are metres along and across
the circuit. Barriers hang off the outermost strip on each hand as three
faces: inner, top, outer.

Output is grouped by surface material name. Aalborg becomes 17 groups,
98,000 triangles, 71,000 vertices; the renderer binds one generated set per
group and the 396 baked trackgen batches it replaces become 17 draws. Every
baked `tr-*` texture is trackgen output from the same segment model, so
stripping them loses nothing hand-authored.

`TrackSurfaceAssembly` does the batch building for both the interactive
session and `torcs-rendershot --generate-track`, so they cannot disagree.
The session had also never been handed a material library — the app was
still driving on original artwork after R6 — and now looks for a
`materials` folder beside the session or the directory `TORCS_MATERIALS`
names.

### Three faults, two of a familiar kind

**Winding reasoned, not derived.** The ribbon quads were ordered "forward,
then left", whose cross product points down, and the whole road was culled
from every camera on it. The aerial shot still showed a dark strip along the
circuit, which was taken as the road and was not — the barriers and their
shadows are enough to draw the outline from overhead, and that is what
delayed noticing. The terrain generator hit the same fault in R2 and the fix
is the same: derive the winding from the stored normals, per triangle.
`testDrivableSurfacesWindUpward` pins it.

**One tile per metre.** The first correct render was flat grey. The
generated asphalt set is 2 m per tile, and sampled once per metre its
aggregate sits at half a millimetre. The generator's manifest already
recorded `worldSize` per material and nothing read it; the library now
exposes it on the binding, a batch can declare its UVs are metres, and the
draw carries the scale. The terrain had the same latent fault: grass at one
tile per metre instead of three.

**Metres in a half.** The app's chase camera showed the road behind the car
as alternating one-metre bands of streaks and aggregate, and rendershot
never did. The chase camera looks back from the start line, at the *end* of
the lap, 2,500 m from the origin; `uv0` is stored as a half, whose quantum
at 2,048–4,096 is 2 m. One row's two ends rounded to the same texel column
and the next jumped a full quantum. Every rendershot camera had looked
forward from low distances. The fix keeps the 32-byte vertex: metres are
stored folded, `uv0 = u mod 8`, `uv1 = ⌊u / 8⌋`, both exact enough in a
half, and the vertex shader unfolds in float before interpolation — so
there is no seam, no duplicated rows, and no constraint tying the fold to
material tile sizes. The terrain's world-metre UVs had the same fault at
900 m and take the same path. `testMetreUVsSurviveHalfPrecisionPacking`
checks that the naive packing really does lose it, so the test guards
something.

A correction to R6 falls out of this. The "aggregate" on the substituted
baked road was never the generated material's; it was the original 256²
tarmac texture's pattern leaking through the marking compositor as painted
detail. The generated road, sampled at the right scale, shows what the
material actually contains — finer, and closer to tarmac.

### Tooling

`torcs-rendershot --road-camera D` places a driver's-eye camera D metres
from the start line on the main road, looking 40 m ahead; `--road-lateral`
moves it across the width. `--list-segments` prints every main segment with
its borders, which is how one finds a curb to look at. Both exist because
the two hand-placed cameras used before this were, respectively, a strip on
the horizon and a wall.

Not done: decals (lane lines, the start grid, curb paint as paint rather
than a material), the racing-line rubber mask, and profile geometry for
curbs where a track declares a height. Aalborg's curbs are 2 m wide and
0 m high — painted strips — and render exactly as such.

## Road markings are painted, not textured

The generated road arrived with no markings at all. The lines that had
survived R6 lived in the baked 256² textures the marking compositor read,
and those textures are gone with the trackgen batches. The plan's answer
was a decal layer; what landed is cheaper and sharper.

The ribbon already carries `(along, toRight)` in metres, and the packed
vertex had an unused `uchar4` slot reserved for material blend weights. The
road generator now writes there: lateral position across the segment,
segment width in eighths of a metre, and the segment's role. From those
three bytes the fragment shader knows how many metres it is from either
edge, from the centre, and from the start line, and paints:

- edge lines, 12 cm wide, 26 cm in from each edge;
- a dashed centre line, 3 m on and 6 m off, phased by distance along the lap
  so the dashes are continuous across segment boundaries;
- the start line, half a metre across the road at the origin;
- rubber: a soft band on the middle of the road, darkening albedo by up to
  30 % and lowering roughness, with a slow variation along the lap so it
  does not read as a stripe.

Every edge is antialiased with `fwidth` of the lateral coordinate, so the
lines are crisp at a metre and at four hundred, and the whole thing costs a
few ALU per road pixel and no draws. Only role 0 (the main road) paints
lines; sides and borders receive rubber only. `testAttributesEncodeLateralPositionWidthAndRole`
pins the encoding, because a wrong lateral coordinate puts the edge line in
the middle of the road.

The rubber band is centred on the road rather than on the racing line. The
racing line is the AI's, computed in the robot, and the renderer does not
see it; a later increment can hand it across as a per-row lateral offset in
the same attribute channel.

Kerb paint is still a material rather than paint, and tracks whose surface
names declare which edges carry lines (`asphalt-l-left`, `asphalt-l-both`)
are not yet honoured — Aalborg's do not, and its original texture painted
both edges and the centre, which is what this reproduces.

## The car is not one material

A TORCS car model is one texture atlas and one AC material — `spec 0.5,
shi 50` — for paint, glass, lights, interior and driver alike, so the
Blinn-Phong bridge gave the whole car a roughness of 0.78 and it shaded
like a red plastic toy. Nothing in the render state distinguishes the
parts; the node names do, and `grcar` itself relies on that (`WI` for
windows). `CarMaterials` applies the same conventions: `CARBODY*` and the
rest are paint, `WI*WINDOW`/`WISIDE` glass, `WI*LIGHT*` lenses,
`*INTERIOR*` matte, `DRIVER` cloth, and the procedurally built wheels, which
have no names worth reading, are identified by their `tex-wheel` texture.

Paint is metallic flake under a smooth clear coat: base roughness 0.42 and
metallic 0.3 for a broad coloured reflection, a coat at roughness 0.05 for
the sharp one. That is the two-lobe response ACC's paint has, and it is
what makes a sun glint on the roof read as a glint rather than a smear.
Glass is a smooth dielectric; the deferred, blended pipeline supplies its
transparency and this supplies its reflection. The atlas colour is kept
throughout.

`RenderScene` takes a `car` flag rather than sniffing names on every scene:
the session knows the scenery package from the car packages, and
`torcs-rendershot --car` already existed. Tests pin the name conventions,
that the flag changes materials without changing which batches are
transparent, and that the frame actually changes.

What the reflections show is still the sky probe: the car reflects a
horizon-to-horizon sky and nothing of the circuit. That is the next pass.

## Screen-space reflections, and an attachment that was never bound

The forward pass reflected a sky probe: every smooth surface showed a
horizon-to-horizon sky and nothing of the circuit. A screen-space march now
replaces that where the reflected point is on screen.

### The lobe it serves

Only the sharp white one: the clear coat on paint, glass, and a smooth
dielectric such as wet asphalt. A metal's coloured base lobe is left to the
probe — at the roughness those lobes have, a blurred reflection of a mostly
off-screen world is what the probe already is. That choice is what makes
the specular weight a *scalar*, and the scalar is what makes the composite
a single additive pass: the forward pass writes a thin `rgba16f` surface
(octahedral normal, roughness, weight) alongside colour, the march finds a
radiance and a confidence, and the composite adds
`confidence · weight · (found − probe)` onto colour with one/one blending,
re-evaluating the probe from the sky table so it is taken back exactly. No
second colour target, no subtraction ambiguity, and the sign is free to go
negative where the probe overstated.

Along the way the clear coat gained an environment term it never had:
`evaluateImageBasedLight` omitted the coat entirely, so paint reflected the
sun sharply and the sky not at all, and car roofs read as matte between
glints. The coat now sees the sky, and the base sees it through the coat.

### Three faults, one of them older than the pass

**Self-intersection.** The first march started on the surface and accepted
the first sample behind the depth buffer; every curved panel reflected
itself and the confidence map was white over the whole car. The ray now
starts off the surface, a hit is a *crossing* — the previous sample in
front, this one behind — and the crossing is refined before the thickness
is judged, because judging the coarse sample threw away nearly every
legitimate hit at a 15 cm thickness and a metre step. A hit whose surface
faces along the ray is rejected as the far side of an opaque object.

**Thickness.** At 0.6 m every wheel arch a ray passed behind in screen space
counted as a hit. It is 15 cm now, growing with distance.

**The attachment that shifted.** With the gate set at roughness 0.45,
grass, trees and the concrete wall were being traced and the wall came out
orange. The G-buffer dump showed why: `x, y` were zero at every pixel and
`z, w` ranged over [−1, 1], which no roughness does but a static frame's
motion vectors do. With upscaling off the scene pass bound no velocity
attachment, while every pipeline declared one — and on this GPU the later
attachment slid down a slot, so the reflection surface received `color(1)`.
That was undefined behaviour from R2 onward; it went unnoticed because
nothing read the missing attachment. The velocity attachment now always
exists, memoryless and discarded when upscaling is off, exactly as the
reflection surface is when reflections are off. A test reads the surface
back and fails on any roughness outside [0, 1].

`torcs-rendershot --surface-view` dumps the G-buffer and prints four raw
texels, and `--reflection-view` the traced radiance and confidence. Both
exist because the images alone could not answer the question.

### Measured

Interleaved A/B, no bloom, sixty pairs after twenty warmups, taken directly
after a ten-minute test run on a chip that was visibly throttling (the
track's off column reads 6.3 ms where a cool run gives 2.2), so only the
deltas carry information:

| Scene | Resolution | Quality | Delta |
|---|---|---|---|
| Aalborg | 1280x832 | half | +0.20 ms |
| Aalborg | 1280x832 | full | −0.36 ms (noise) |
| Aalborg | 2560x1664 | half | +1.03 ms |
| Car | 1280x832 | full | +0.69 ms |

The default preset runs half resolution. The march is twenty-four steps
with four refinements and a maximum reach of sixty metres; the cost is in
the steps, and a depth pyramid would let the reach grow without them.

### Filtered

The march jitters its steps per pixel to avoid banding, and unfiltered that
jitter is a dither that crawls with the camera. A depth-aware 4×4 blur at
the traced resolution — the occlusion pass's filter, reused — removes it;
confidence is blurred with the radiance so the two agree at the edge of a
hit region, and samples across a depth discontinuity are rejected so a
reflection cannot bleed off its surface.

### Not done

Temporal reuse would let the march take fewer steps for the same result.
Rough surfaces get no reflection, by design, and glass traces
from the depth of what is behind it, since the prepass is opaque-only —
visually a few tens of centimetres off, and acceptable.

## Motion blur

The last Phase 3 pass. The velocity the forward pass writes for the
upscaler — the offset in render pixels from a pixel to where it was last
frame, camera motion for static geometry and the car's own on top — is
integrated along, half a shutter each side of the current position, eight
jittered taps, after the upscaler and before bloom so the glow streaks with
the object and the tonemapper sees the blur. A 180° shutter, the film
convention, so motion reads as motion without the frame going to soup; the
radius is capped at three percent of the frame height, because a wheel or a
close barrier can exceed a whole frame of travel and past that cap it
smears rather than reads faster.

Velocity is now stored whenever motion blur is on, not only under
upscaling — which is also what fixed the unbound-attachment fault in R12,
since the attachment now always exists. The blurred image lands in a
post-colour target the tonemap source switches to; nothing else in the
frame moves.

It is the cheap form: one gather along the centre pixel's velocity. It
smears silhouettes slightly, which at racing speeds is invisible and at
rest does not happen — a still camera gives zero velocity everywhere, and
`testStillFramesAreUnblurredAndRepeatable` pins that a still frame is
byte-identical with the pass on. The tile-max form that keeps silhouettes
crisp is the known upgrade.

`torcs-rendershot --orbit-speed D` turns the framing camera D degrees per
frame, so a still tool can show what only exists between frames.

Measured interleaved on a throttling chip (baselines of 8 and 18 ms where a
cool run gives 2.2 and 6): +0.25 ms at 1280x832 and about +2 ms at
2560x1664. At native the pass touches every output pixel eight times and
writes a second 34 MB colour target, and that is what two milliseconds
buys. The default preset renders native, so this is the first post pass
whose cost is not negligible there; it goes on the Phase 8 list next to
the upscaler question, since at half render resolution it would cost a
quarter.

## Sustained: the number every earlier measurement stood in for

Every timing in this document was taken on a fanless chip somewhere on its
way down from a cold start, and several were visibly throttled. The plan's
§9.4 asked for the steady state; `torcs-rendershot --sustain S` now renders
continuously for S seconds, orbiting so no frame is a cached best case, and
reports the median per fifteen-second window.

Default preset, generated Aalborg, 2560x1664:

| Window | Median | p95 |
|---|---|---|
| 0–15 s | 6.63 ms | 13.7 ms |
| 60 s | 6.68 ms | 13.6 ms |
| 120 s | 6.61 ms | 7.8 ms |
| 180 s | 6.60 ms | 7.9 ms |
| 210 s | 7.41 ms | 9.2 ms |
| 225 s | 8.32 ms | 10.0 ms |

Flat at 6.6 ms for three and a half minutes, then +26 % as the chip
throttles; a twenty-minute race will go further. 1280x832 sits flat at
2.6 ms for the whole run. Both are GPU time in a tool loop with no physics
and no presentation; the app adds both.

### The spatial scaler

The temporal scaler lost twice, so `MTLFXSpatialScaler` — a single-frame
sharpening upsample with no jitter, no history and no motion vectors — is
the fallback, selectable with `upscalingMode`. Block-interleaved against
native in the default configuration, motion blur moved ahead of it so the
blur costs a quarter:

| Render scale | Native | Spatial | Delta |
|---|---|---|---|
| 0.5 (1280x832) | 6.13 ms | 4.56 ms | −1.57 ms |
| 0.67 (1715x1115) | 6.11 ms | 5.53 ms | −0.58 ms |
| 0.75 (1920x1248) | 6.11 ms | 6.08 ms | −0.03 ms |

A 1280x832 render is 2.6 ms and comes back as 4.6 through the scaler, so
the scaler and the output-resolution passes behind it cost about two
milliseconds, and that fixed cost is why 0.75 saves nothing. At 0.5 the
saving is real and the kerb edges are visibly softer. Native stays the
default; the spatial scaler is the thermal valve, and the right shape for
it is dynamic resolution stepping down through the ladder as the sustained
GPU time rises, which the controller already models and presentation does
not yet drive.

### A half-resolution fault found by the comparison

The 0.75 crops carried dark bands across the road that native did not, and
the raw occlusion map showed why: alternating-row stripes over the whole
surface. At half resolution the occlusion pixel's centre lies between depth
texels; reconstructing its position at the un-snapped coordinate with a
neighbour's depth put it off the surface by half a texel of slope,
alternating by row. R8 had snapped the *samples* and not the centre — at
full resolution the two coincide, so it never showed there, and the default
preset's half-resolution occlusion had been faintly banded all along. The
reflection trace at half resolution had the same origin error. Both snap
now.

## Dynamic resolution, driven at last

The controller existed since R2 and nothing drove it. Presentation now
feeds it the previous frame's measured GPU time, and the default preset is
native at rest with the spatial scaler available: `renderScale` 1.0,
`upscaling` on, `upscalingMode` spatial, `dynamicResolution` on. At scale
1.0 the scaler is bypassed — a native frame is not scaled to itself — so
at rest the frame is exactly what it was. `upscaling` replaced
`temporalUpscaling` as the setting's name, since it no longer means the
temporal scaler.

### The controller oscillated

The first dynamic run stepped 1.0 → 0.60 in its opening seconds, climbed
back, and then swung between 0.60 and 1.00 every half minute while the
median GPU time sat at 6.4 ms against an 11 ms target. Two causes, both in
the controller: it discarded its average after every step, so the next
frame — which reallocates the render targets and is slow for that reason
alone — seeded the next decision; and four over-budget frames sufficed to
step, which the bursts a throttling chip delivers at clock transitions
supply routinely. So each legitimate step cascaded, and each recovery met
the same bursts.

Now: each sample is clamped to twice the running average before it enters,
twelve frames after a step are ignored, a step down takes half a second
over budget, and a step up takes three seconds below seventy percent of
it. Two tests pin the spike bursts and the post-step hitch.

### The valve, watched opening

Default preset, dynamic, 2560x1664, four minutes:

| Window | Median | p95 | Scale |
|---|---|---|---|
| 15–195 s | 6.34–6.43 ms | 7.5–8.9 ms | 1.00 |
| 210 s | 6.66 ms | 14.5 ms | 0.85 |
| 225 s | 7.83 ms | 11.4 ms | 0.85 |

Native for three and a half minutes, one step down as throttling begins,
no oscillation. The step was taken on the spikes rather than the median —
a p95 of 14.5 ms is what the onset looks like — and one notch is the
proportionate response. Whether it should have waited for the median is a
tuning question for a longer run than four minutes; the tool for that run
now exists.

## Trees with volume

Phase 6 begins with what was left of 1999 in every frame: TORCS places
trees as pairs of crossed alpha-cutout cards, two sheets at right angles
per tree, and from anywhere but the road they look like it. The classic
path already carried the fix — a recovery of Aalborg's 169 placements by
the cards' exact numerical signatures (three species by atlas column, card
height and width), and a volumetric replacement built from the same atlas:
trunk, branches, and a crown of small individually oriented leaf cards
sampling a foliage-dense patch of the species' own region. That is ported
here. The art is the track's own atlas, so nothing new needs a licence.

Recovery runs during flattening, at float precision: the packed vertex's
half UVs could not tell the atlas columns apart at the 2e-5 tolerance the
signatures need. Each tree becomes two batches — the dense build within
seventy metres of the camera, the lighter one beyond — switched by a
per-batch distance range the draw loops now honour, and only the lighter
one casts into the cascades. The leaves sway: a per-vertex height in the
attribute channel, two slow sines phased by position, and a frame time in
a uniform slot that verification renders leave at zero so they repeat.

### Measured

Road camera, generated track, 1280x832, thirty frames, on a chip drifting
between runs (the cards' own baseline read 8.1 and then 4.1 ms):

| Forest | Scene batches | Drawn | GPU |
|---|---|---|---|
| Original cards | 937 | 937 | 4.06–8.12 ms |
| Merged near detail, everywhere | 264 | 264 | 13.0 ms |
| Merged middle detail, everywhere | 264 | 264 | 4.22 ms |
| Level of detail (default) | 599 | 430 | 5.08 ms |

Near detail everywhere is 1.2 million triangles and unaffordable; it was
the cascades as much as the crowns, four passes of alpha-tested leaves. The
level-of-detail forest costs about a millisecond over the cards for dense
trees beside the road and light ones behind them, and the trees now cast
real shadows across the track, which the cards never did in either path.

Not done: grass, trackside furniture and crowds from the plan's scatter
list; a depth-sorted or dithered transition at the seventy-metre switch,
which currently pops; and wind in the shadow pass, which is still.

## Licensing

No third-party artwork is imported by this work. New render source is
GPL-2.0-only, consistent with the rest of the application. Generated material
sets authored by project code follow the project's CC BY-SA 4.0 default for new
non-code assets; see `ASSET_LICENSES.md`.
