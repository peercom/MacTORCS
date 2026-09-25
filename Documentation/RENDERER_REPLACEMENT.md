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

- The graphics oracles in `Upstream/Reference`: `draw-order-instrumentation.cpp`,
  `alpha-state-instrumentation.cpp`, `carlight-instrumentation.cpp`,
  `height-instrumentation.cpp`, and the rasterization oracles in
  `graphics-instrumentation.cpp` (shadow vertices, background geometry and
  camera, car reflections, track shadows, shadow scale order, mirror capture,
  fly camera, shadow visibility). The camera, TV director, wheel and brake
  geometry oracles in that file stay: they pin presentation logic that the new
  path still runs unchanged.
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

The rubber band was first centred on the road; it now follows a racing line
derived from the segment model, carried per row in the fourth attribute
channel. See "Rubber on the racing line" below.

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

## Grass on the verges

The terrain is a textured plane, and at driver height its edge against
the road was the flattest thing left in the frame. Clumps of crossed
blade cards now line both verges: scattered outward from the outermost
strip on each hand in two-metre rows, dense at the edge and thinning to
eight metres out, standing on the same height the terrain grid uses, in
batches a hundred metres long that stop drawing at sixty. The blades are
a generated atlas — `torcs-matgen`'s `grass-cards`, four clumps of
tapered blades with coverage in alpha — so nothing new needs a licence.
They sway with the trees' wind at a fraction of the amplitude, which the
geometry now carries per vertex rather than the shader assuming a tree.

### Two things the first render taught

**Cards as black blocks.** The atlas's alpha never reached the alpha
test: `torcs-matgen` wrote its PNGs with `noneSkipLast`, discarding the
fourth channel. It keeps straight alpha now. Every material's albedo was
written that way; only the cutout ever needed the channel.

**Aalborg has no verges.** The clumps appeared behind the barrier walls,
because the barrier stands at exactly the edge the grass scatters from,
and Aalborg is walled at 0.6 m for the whole lap — taller than any clump.
Grass behind a wall taller than itself is invisible from the road and
pure cost, so a side whose barrier is at least clump height gets none.
On Aalborg that is every side, and `testWalledVergesGetNoGrass` pins
zero clumps; the feature exists for open circuits, which the content
inventory says are most of them.

### Measured

Forced everywhere on Aalborg, road camera at a walled corner, 1280x832:
36,000 cards at the first density cost +5 ms even after the cards were
taken out of the depth prepass (an alpha-tested cutout pays for its
discard twice if it is in it; grass now depth-tests in the forward pass
instead, forgoing occlusion and reflection on itself). At the shipped
density — 17,600 cards, eight metres of reach, drawn to sixty — the
frame with grass measured 5.16 ms against 5.14 without.

## Brake lights and headlights

The first of the two features the classic path had that the new one did
not — the other is the mirror. The classic path drew the car's lights as
textured glow sprites at positions from the car's `Graphic Objects/Light`
section; the new path lights the lens geometry itself. `CarMaterials`
already knew the lenses by name; it now tells the rear ones (`WILIGHTREAR`)
from the front (`WIFRONTLIGHT`) and gives each an emitted radiance and a
channel — brake for the rear, headlight for the front. The channel's state
is per instance, since it changes every frame while the draw's material
does not: `InstanceUniforms` carries brake, headlight and rear-light bits
derived from the snapshot's commands the way `grUpdateCarlight` reads them,
and the vertex shader resolves the draw's channel against them into a
varying, so the fragment stage needs no new binding.

One detail: TORCS marks every `WI*` part as a window, so a lens is drawn
blended with its texture's alpha, and a glow blended at 0.3 is a dim glow.
The emission is divided by that alpha for lens channels, which puts it
through the blend at full strength. Bright enough to bloom in daylight,
which is what a brake light does.

The AC light sprites, their frusta and the fourteen-slot table stay with
the classic path; the lens geometry is the light now.

## The rear-view mirror

The last thing the classic path could do that the new one could not. The
classic mirror was a second camera at the bonnet looking backward, drawn
into a viewport of the same frame with `MirrorLayout`'s translated
rectangle. The new path keeps the camera and the layout — both are
presentation logic, and `MirrorLayout` is now public for it — and renders
the mirror through a **second `ForwardRenderer`** with a lighter preset: no
screen-space passes, no post, two cascades, no upscaling. It shares the
scene resources, which are device objects, but has its own targets and
per-pass caches, so neither renderer's cached state thrashes on the
other's size. Both views are encoded into one command buffer, the mirror
first; a composite pass then draws the mirror's tonemapped display target
into the layout's rectangle of the drawable, with a thin dark frame.

The image is flipped left to right in the composite. A camera looking
backward puts the car's left on the image's right; a mirror puts it back
on the left. The classic path did not flip, which a driver would have
noticed the first time something overtook.

From a cockpit view the body stays in the mirror — the cage and the rear
window are what a mirror there sees; from an external view the whole car
is hidden, so the mirror shows the road behind rather than the cabin the
first composite showed. The offscreen `render` takes the same request, so
`testMirrorCompositesFlippedIntoItsRectangleOnly` can check that the
composite changes nothing outside its rectangle and that the rectangle,
read right to left, is the mirror view read left to right.

With this the classic path has no feature the new one lacks. Retiring it
is the next step of Phase 2, and it is now a deletion rather than a loss.

## Retiring the classic path

Phase 2's last step, done once the new path had every feature the old one
had. It is a deletion, and the decision record is what it deleted.

`TORCSMetal` is gone: `SceneRenderer`, `Scene.metal`, the fixed-function
emulation, blob and baked shadows, car reflections, billboard lights, the
scene-height traversal and its draw-order and alpha-state bookkeeping. What
was not rendering moved to a new `TORCSPresentation` package with no Metal
dependency: the 31 camera presets, zoom, the fly camera and TV director, the
mirror camera and layout, and `VehiclePresentation`. `SceneCamera` came out of
the old scene geometry as its own type, and the fly camera now takes a height
closure so it runs over the generated road rather than a scene graph.

The app is modern-only. `--modern-driving-test` is the one diagnostic; the
fourteen classic smoke modes and the bench renderer went with the path they
exercised, and the scene inspector's orbit view was rewritten on
`ForwardRenderer`. `DrivingSession` keeps a single toggle, the mirror.

Eighteen test files went with it, all of them comparisons of the classic
raster against upstream: car lights, reflections, track shadows, draw order,
alpha state, scene height, edge smoothing, repeat rasters, vegetation fog.
Five more lost their renderer-dependent cases and kept their camera and
geometry assertions. Of the ~1,100 lines of graphics oracle, ~300 remain:
every `ref_*` symbol was grepped for a surviving Swift caller before its body
was removed, and the header lost exactly the prototypes whose bodies went.
The pinned upstream sources under `Upstream/Reference/graphics/` and the
provenance manifest are untouched; `verify-provenance.py` still checks the
excerpts, including the ones nothing calls any more, because they are the
record of what the port was compared against.

The suite fell from 420 tests to 354, all passing; the app builds and the
modern smoke still produces its 29 cameras and the mirror. Nothing that
survives asserts anything about rasterization, which is the narrowing the top
of this document announced.

## Rubber on the racing line

The rubber band had been centred on the road, which is where no car ever
runs. `RacingLine` in `TORCSTrackMesh` now derives a line from the segment
model — the same parity-verified segments the cars drive on — and the road
generator writes its lateral position per row into the fourth attribute
channel, alongside the lateral coordinate, width and role the markings
already used. The shader lays the rubber around that line instead of the
centre.

The line is geometric, not optimal, and makes no claim to be fast. Every
driver's line has the same shape — outside on the approach, inside at the
apex, outside on the exit — and that shape falls out of curvature alone. Each
metre of the lap gets a target pull toward the inside of its corner,
proportional to `70 m / radius` and saturating at one; a wide blur of that
target says where the corners are, and the line sits opposite to it on the
approaches (`1.6·target − 1.4·blur`, clamped), then a short blur removes the
kinks at segment joins. The line never comes within 12 % of the width of an
edge.

The filter widths matter more than the formula. The first version blurred
over 140 m and smoothed over 25 m, tuned by intuition for a circuit with long
corners. Aalborg's corners are 17–50 m long and 50–100 m apart, and at those
widths the smoothing flattened a corner's inside plateau to almost nothing
while the blur folded neighbouring corners of opposite hand into each
other: the apex of the tightest right-hander came out at 0.58 of the width,
barely off centre. At 60 m and 8 m the same corner reads 0.25, with the
approach and exit at 0.45–0.49. The test that caught it,
`testLineGoesInsideAtTheApexAndOutsideOnTheApproach`, also caught the sign:
lateral 0 is the right edge, so a right-hander's inside is *negative*, and
the first pass had the line hugging the outside wall of every corner.

TORCS splits a corner into many short arcs, so the test finds the apex as the
middle of the run of same-hand arcs around the tightest one, not the middle
of the tightest arc. `testLineStaysOnTheRoadAndIsContinuous` bounds the line
to the road, caps its per-metre change at a twentieth of the width (crossing
the road in under ten metres is a swerve, not a line), checks that it closes
on itself at the start line and that it is not the centre line.
`testRoadRowsCarryTheLine` checks the attribute is constant across a row
and varies along the lap.

In the shader the rubber is a metre-wide core where the tyres actually run
in a wider halo of lighter deposits, laid in longitudinal streaks rather than
as a wash. The first render darkened by 35 % and was invisible: the generated
asphalt is already dark, and a fifth less of dark is nothing. Rubbered tarmac
is near-black and glossy against the grey of the exposed aggregate around it,
so the core now takes the albedo to 28 % and the roughness to 60 %. The
first streak pattern wobbled along the road and read as ripples on water;
the wobble is now slow enough to be invisible. The cost is a dozen ALU per
road pixel, no draws and no textures. `--road-aerial H` on the render tool
raises the road camera to look down on the line; from 45 m the band visibly
crosses to the inside of the hairpin and back.

## Tyre smoke and dust

Phase 7 opens with particles. `ParticleSystem` in `TORCSRender` steps a few
hundred puffs on the CPU once per frame and `ParticleRenderer` draws them as
camera-facing quads in one instanced call. Emission is described by sources
— a contact patch, a velocity, a kind and an intensity — supplied by whoever
knows the simulation. The app builds them from the wheel skid factor the
simulation already computed and now publishes (`WheelVisualSnapshot.skid`,
the original per-wheel `skid` from `SimWheelUpdateForce`), and from the
surface under each hub: smoke where a tyre skids on anything, dust where it
runs on grass, gravel, sand or dirt, or off every strip onto the terrain.
The physics contact segment is not published, so the surface comes from the
track query at the hub, which is what the physics would have used.

The draw is depth-tested by hand. The pass has no depth attachment; the
fragment samples the stored opaque depth, discards behind it, and fades over
the last 0.6 m in front of it so a puff meets the ground and the car as a
volume rather than a cut. It writes neither depth nor velocity; motion blur
sees the background's motion through the cloud, which for a puff that is
drifting anyway is fine. Nothing in the pass depends on wall-clock time — the
churn is driven by each particle's age — and the emitter is a seeded
SplitMix64, so a diagnostic render repeats and `testDeterministicForASeed`
can compare two systems particle for particle.

### The first version cost three milliseconds

At 1280×832, 193 particles measured **+3.18 ms** in the interleaved
comparison. Not the fragment: the overdraw. A puff that has grown to two
metres across a few metres from the camera covers a large part of the screen,
and a cloud of them stacks that coverage. Three things brought it down:

| | Δ ms | |
|---|---|---|
| full resolution, 90/s, two-metre puffs | +3.18 | 193 particles |
| half resolution target + composite, 48/s, smaller puffs | +0.35 | 107 particles |
| tighter cloud, shorter life | **+0.31** | 107 particles |

The particles now render into a half-resolution `rgba16Float` target,
premultiplied and accumulating coverage in alpha, and a fullscreen composite
enlarges it bilinearly over the colour target. Smoke has no edge that half
resolution loses; where a puff meets a silhouette the bilinear enlargement
does soften the boundary by a pixel, and a depth-aware upsample is the
obvious refinement if it ever shows.

The look took two more rounds. The first cloud was a blown-out white fog
around the whole car: too many particles, too opaque, lit too bright, and
the noise that was meant to give a puff lumps was so gentle it read as a
gradient disc. Now the coverage is the noise at high contrast — a puff is
lumps with gaps — the smoke rises at half a metre a second rather than one,
lives under two seconds, and takes less sun and less ambient. Dust is
opaque and takes more sun than smoke.

`testPuffIsDrawnWhereVisibleAndHiddenBehindGeometry` renders the car
fixture with one puff above the roof (the image changes, and only near the
puff) and one on the view ray past the car's centre (the image does not
change at all: the manual depth test rejected every fragment).
`testSettingOffDrawsNothing` and `testRepeatable` cover the switch and the
determinism; `testCapacityIsRespected` the hard cap of 4096.

The mirror renderer draws the same system, so a burnout shows in the
mirror. The render tool's `--smoke N` steps N frames of emission at a
stationary car's rear wheels before rendering, and `--compare-particles`
measures the pass. The app smoke checks that a settled session at rest on
asphalt has nothing to emit.

Not done: spray and the exhaust. Skid marks, the same signal laid into a
ring of decals, follow in the next section.

## Skid marks

`SkidMarks` keeps a ring of 4,096 quads on the road. Each skidding tyre
extends its own strip by one quad whenever its contact patch has travelled a
quarter of a metre since the last, a tyre that stops skidding ends its
strip, and the oldest quads are overwritten when the ring is full, which is
how marks eventually vanish. The quad spans the tread width across the axle
direction taken from the wheel transform, and sits 1.5 cm above the contact
point so it wins the depth test against the road it lies on; the app lays
marks above a skid factor of 0.3, a little higher than the smoke's 0.2,
because a tyre chirps before it leaves rubber.

The draw is a multiplicative decal — destination × (1 − darkness) — with
the depth attachment loaded read-only, so a mark under the car body is
hidden by the body and a mark on the road only ever takes light away. The
darkness is the tread's grooves as bands across the mark, broken up along
its length at two scales. It runs before the reflection trace so a mark
shows in the paint of a car standing on it, and the mirror renderer draws
the same ring. The ring is copied whole into a triple-buffered vertex
buffer only on frames that laid a quad; 72 quads measured **+0.04 ms** at
1280×832, within the noise.

`testStripsGrowWithTravelAndBreakWhenSkiddingStops` pins the geometry: a
tyre creeping 5 cm a frame lays a quad every fifth frame, a frame without
the source ends the strip, the quad spans the width and carries metres
along it. `testPerTyreStripsAndRingWrap` checks two tyres are two strips
and that the ring overwrites its oldest quads.
`testMarkDarkensTheGroundAndHidesUnderTheBody` renders the car fixture from
above: a mark on the ground beside it lowers the image sum and brightens no
pixel; a mark under the body changes almost nothing. `--skid` on the render
tool lays an S through the origin and `--compare-skid` measures it.

The marks are geometry on the road, not paint in the road's texture: they
do not affect the road's roughness, so a fresh mark is not glossier than
the tarmac the way the racing line's rubber is. That would take a second
decal target the road shader reads, and can wait until the marks are
judged to need it.

## Wet weather

A scene condition rather than a quality setting: `ForwardRenderer.wetness`,
0 dry to 1 soaked, travels in the spare lane of the frame's camera position
and is shared with the mirror renderer. Batches flagged `receivesWeather`
— every generated road, side, barrier and terrain surface — respond to it
in the forward fragment, after the markings and rubber and before the
material is assembled:

- a film of water darkens the albedo by up to 45 % and pulls the roughness
  toward 0.5, a sheen rather than a mirror;
- puddles come from a two-octave value noise of the world position,
  thresholded by the wetness, and on the road biased toward the edges where
  the crown drains; a puddle darkens further, drops the roughness to 0.03,
  flattens the normal to the geometric one and clears the metallic, so it
  is a sheet of water the reflection trace and the sky probe both see;
- puddles only stand on near-horizontal ground, so a wet wall darkens and
  glosses but holds no water.

The road physics stays dry: the session's "Wet track" toggle changes the
picture, not the grip, and says so in its help. When the simulation has
weather the same value comes from it.

Spray is a third particle kind. On a wet road every tyre above 8 m/s flings
short-lived white mist that keeps more of the wheel's speed than smoke and
falls; the app emits it alongside smoke and dust, scaled by speed and
wetness.

### The lake

The first version pulled the film's roughness to 0.3. The road became a
lake — a continuous mirror of sky between the puddles — and the interleaved
comparison read **+0.79 ms** at 1280×832, because 0.3 is under the
reflection trace's roughness cutoff of 0.45 and every road pixel was being
traced where before none was. At 0.5 the film sits above the cutoff, only
the puddles trace, the road between them reads as wet tarmac rather than
water, and the cost is **+0.29 ms** at 1280×832 and **+0.89 ms** at native
2560×1664 — paid only while it rains.

`testWetGroundDarkensAndPuddlesWhereFlagged` renders a flat ground square:
soaked, its mean drops by more than a tenth and its pixel spread grows by
half, the puddles breaking up the flat shading; the same square without the
flag renders identically wet and dry. `testFrameUniformsCarryWetness` pins
the lane, and `testSprayIsShortLivedAndFalls` the new kind. The render
tool takes `--wet W` and `--compare-wet`.

Not done: rain itself — streaks in the air, drops on the glass — and a wet
sky. The sun still shines on the puddles, which reads as the hour after a
shower rather than the shower.

## Hardening: the shipped app, its shaders, and its memory

Three Phase 8 items, and a packaging fault found on the way.

**The app was not carrying its shaders.** `build-app.sh` still copied the
deleted TORCSMetal package's resource bundle — a stale copy lingered in the
build directory — and never copied the TORCSRender one. The app worked only
because SwiftPM's resource accessor falls back to the absolute build path
baked into the binary, which a copy on another machine does not have. The
script now copies every resource bundle of a package that still exists and
none of the test bundles, and fails if the render bundle is missing.

**Prebuilt shader library.** `Scripts/build-shaders.sh` compiles the sources
offline with the same invariance flag as the runtime compile, in the same
order — `testOfflineBuildScriptMirrorsTheSourceOrder` pins the script's list
to `ShaderLibrary.sourceOrder` — and the app build puts the result in the
render bundle. `ShaderLibrary` prefers it, looks for it in the package
bundle, in the application bundle's copy of it (SwiftPM's accessor does not
look in `Contents/Resources`), or at `TORCS_METALLIB`, and compiles from
source only when none is there, which is what `swift test` and the render
tool do. The app smoke now reports `shadersPrebuilt: true`.

What the measurement actually showed, on the render tool with a generated
circuit at 2560×1664:

| | shader library | renderer construction |
|---|---|---|
| source, driver cache warm | 7.5 ms | 45–55 ms |
| prebuilt, first use ever | 0.8 ms | **537 ms** |
| prebuilt, subsequent runs | 0.7 ms | 53–61 ms |

The library load is not where the time goes; pipeline construction is, and
the driver caches compiled pipelines on disk keyed by function, so every
route is fast after the first launch and every route pays about half a
second on it. That half second lands in `ForwardRenderer.init`, before any
race, which is what section 24 asks. An `MTLBinaryArchive` shipped with the
app would remove it from the first launch too; it is deferred until a first
launch is what is being tuned.

**No scaler built mid-race.** The spatial scaler was constructed on the
frame that first needed a render size — which, with dynamic resolution, is
the frame the controller steps on, exactly when the GPU is already behind.
The renderer now keeps scalers by render size and `prewarmSpatialScalers`
builds one for every step of the resolution ladder at the output size;
presentation calls it once per drawable size, before the first frame at
that size. Eight scalers take 4–8 ms to build.

**Memory budget.** `testGeneratedCircuitAtNativeOutputStaysUnderTheBudget`
loads Aalborg's generated road, terrain and grass with the car, renders
three native frames on the M2 Air preset and asserts the device's allocated
size under the preset's 1.5 GB cap: **212 MB** without material sets. The
render tool's `--memory` reports the same figure for a full session — road,
terrain, trees, grass and the generated materials — at **650 MB**. The
budget holds with room for a second car and a bigger circuit.

## Two artefacts of the trees

Both left over from the tree increment: a tree changed shape on one frame
as the car passed 70 m from it, and its shadow stood still while it swayed.

**Dithered detail switches.** `LevelOfDetail.fade` spreads a switch over a
12 m band. Inside it both builds draw, screen-door dithered with
complementary halves of a per-pixel interleaved gradient noise — the build
leaving keeps `noise < coverage`, the build arriving keeps
`noise ≥ 1 − coverage` — so every pixel shows exactly one of them and the
mix slides from one to the other across the band. The coverage and side
travel in a new `DrawUniforms.fade` lane (the struct grows to 224 bytes;
`ShaderLibraryTests` pins it), and the discard sits next to the alpha test
in both the forward and the depth-prepass fragments, so the prepass depth
matches what shades. Only alpha-tested pipelines dither, which is every
batch that has a detail range: trees and grass. Grass has no partner beyond
its 60 m and simply thins to nothing, which removes its pop as well.
`testPairIsComplementaryThroughTheBand` checks the two coverages sum to one
at every half metre through the band and that a three-level chain picks the
right end. In a still the tree in the band reads as a fine stipple; in
motion it is a two-second cross-dissolve.

**Wind in the shadow pass.** The shadow map's vertex shader had no sway, so
a tree's shadow was pinned to the ground while its crown moved. A second
depth-only pipeline, `shadowSwayVertex`, applies the forward shader's sway
formula in world space before the cascade projection and is chosen for any
batch that sways; the shadow pass now takes the animation time. The formula
is duplicated rather than shared because the two shaders take different
uniforms, and the comment on each says so. `testTreeShadowMovesWithTheWind`
puts a swaying card out of view with a low sun throwing its shadow across
the ground in view: the shadow region changes between two animation times,
and with the card not casting, nothing in view changes at all.

## Sustained, again, with everything on

The earlier sustained runs measured the default preset on the bare generated
road. This one is the whole session as the app now draws it — generated
road, terrain, trees with their detail pairs, grass, the generated
materials, rubber, occlusion, reflections, bloom, motion blur — on the M2
Air preset with dynamic resolution armed, orbiting for four minutes at
native 2560×1664:

| window | median | p95 | scale |
|---|---|---|---|
| 0–15 s | 8.73 ms | 14.6 ms | 1.00 |
| 60 s | 8.67 ms | 9.2 ms | 1.00 |
| 120 s | 8.69 ms | 13.2 ms | 1.00 |
| 180 s | 8.66 ms | 9.0 ms | 1.00 |
| 225–240 s | 8.64 ms | 9.0 ms | 1.00 |

First window to last, −1.0 %: no throttle in four minutes, the controller
never stepped, and the frame stayed inside the plan's 10.5 ms target with
the whole scene on. At 1280×832 the same session holds 3.47 ms flat for two
minutes. The earlier run that throttled at three and a half minutes was on
a warmer chip; this one was not, which is the reason the controller is
there rather than a tuning parameter, and why absolute figures in this
document are always paired with the window they came from.

The p95 spikes in the early windows are the material and atlas uploads and
the first pipeline uses; they are gone by the third minute.

## Sun glare

The sun is a disc in the sky pass and a bloom around it; what was missing
is what a lens does with a sun in frame. The resolve now adds a glare —
a halo, an anamorphic horizontal streak and six faint rays — around the
sun's screen position, in the sun's exposed colour, scaled by
`RenderSettings.sunGlareStrength` (0.35 on every preset). The renderer
projects the sun direction with the frame's unjittered view-projection and
keeps the result as `sunScreenPosition`; the resolve draws only when the
sun is in front of the camera and within half a frame of the view.

Occlusion comes from the depth buffer: twelve taps in a small disc around
the sun's position, counting the ones that see sky, which in a reversed
infinite depth is exactly zero because the sky writes none. A wall across
the sun gives zero visibility and no glare, which
`testGlareIsOccludedByGeometry` checks by rendering with and without the
setting and requiring identical images; `testGlareAppearsOnlyWithTheSunInFrame`
requires identical images with the sun behind the camera and a brighter,
never darker, image with it ahead. The mirror renderer has the glare off.

The first version took those twelve taps per fragment and cost **0.39 ms**
at 2560×1664. They now happen in the resolve's vertex shader — three
vertices, thirty-six taps — and reach the fragment as a flat varying; with
an early-out beyond the streak's reach the pass costs **+0.16–0.19 ms**
native with the sun in frame and nothing measurable with it out of frame.
The first shape drew a single hard ray that read as a drawn line; the rays
are now soft and faint and the streak carries the effect.

Not done: lens dirt, which the plan mentioned with bloom, and a glare for
headlights at night, which needs a night first.

## Where the plan stands

Against the plan's phases, after twenty-nine increments on the
`modern-renderer` branch (25 September 2026):

| Phase | Delivered | Deferred |
|---|---|---|
| 0 Foundations | TORCSRender, linear HDR, packed 32-byte vertex with tangents, generated mip chains, BC5/BC7 caches | — |
| 1 Light | Hillaire atmosphere, physical sun and exposure, AgX, four-cascade CSM + contact shadows, SH + prefiltered sky IBL, a drifting cloud layer and the overcast day | clustered punctual lights (no night to light) |
| 2 Upscaling | jitter, motion vectors, MetalFX temporal (measured a net loss) and spatial scalers, dynamic resolution, **classic path deleted** | reactive mask (spatial path needs none) |
| 3 Screen space | GTAO, SSR with a depth-aware filter and temporal reuse, motion blur, bloom | local probe |
| 4 Materials | 26 `torcs-matgen` sets incl. metals, car detail sets under the atlas, stochastic tiling, car paint/glass/lens | AI-sourced base maps, BC7-vs-ASTC comparison |
| 5 Track | generated road, curbs, barriers, terrain, markings, racing-line rubber, skid marks, pit garages, painted starting grid | road detail atlas beyond the markings |
| 6 Scatter | volumetric trees with dithered detail pairs, grass cards, wind (in the shadows too), tyre walls on the corners | impostors, crowds, GPU-driven culling (about 290 draws a frame: not needed) |
| 7 Effects | smoke, dust, spray, wet weather with puddles, rain and drops on the windscreen, sun glare, heat haze, a lens for the television view | — |
| 8 Hardening | prebuilt shaders, pre-warmed scalers, memory budget test, sustained runs, the seven signposts, app bundle fixed, hero car subdivided in place, per-pass GPU timer, near-field aerial perspective in closed form, detail-map anisotropy per preset, occlusion at a quarter on the Air, view-frustum batch culling (driver's-eye 15.2 → 9.2 ms, under budget at native, sustained 9.3 ms native for 90 s), a pipelined and a paced measurement loop (busy GPU: 6.8 ms/frame; paced 60 Hz: 85–96% of frames on time), the resolution controller made deadline-aware and self-checking (native held, 93–96% on time) | binary archive for the first launch |

The measured state of the default preset on the target machine is the
sustained table above: 8.7 ms at native with the whole session drawn, no
throttle in four minutes, the resolution controller idle. Everything in the
deferred column is polish or content; nothing in it is needed for the game
to look and run as the plan intended. The next steps with the most visible
return are the material list and a higher-polygon hero car, both content
rather than renderer work, and Speed Dreams' content remains waiting on the
user supplying it.

## The material list

Phase 4 had eight generated sets. `torcs-matgen` now authors twenty-six, in
the same discipline — each a description of the physical surface, with the
roughness and occlusion falling out of a height field rather than painted:

| For the circuit | For the trackside | For the car (detail sets) |
|---|---|---|
| asphalt, asphalt-worn, **asphalt-patched** (square repairs, tar snakes) | **armco** (W-profile, bolts, zinc spangle; metal) | **paint-flake** (sparse micro-facets; metal) |
| grass, **grass-dry**, grass-cards | **tyre-wall** (torus relief, alternate rows painted) | **rubber-tread** (grooves and sipes) |
| concrete, kerb | **chain-link** (alpha cutout; metal) | **carbon-weave** (2×2 twill) |
| gravel, dirt, **mud**, **sand** (wind ripples) | **brick** (stretcher bond, per-brick clay), **wood** (planks, rings), **painted-steel** | **brushed-metal**, **chrome** (metal), **plastic**, **fabric**, **glass** |

Two things changed in the pipeline to carry them. A set can be a **metal**:
the manifest records it, `MaterialLibrary.Binding.metallic` carries it, and
the surface's metalness is set to one so the ORM's blue channel scales it —
until now every generated set was a dielectric by construction, and the
recipe tests said so. And a car part can take a **detail set**: the car
keeps its painted atlas for colour and takes only the normal and ORM of a
set tiled under it, at a scale per part carried in a new lane of the draw
uniforms (`fade.z`) because the albedo must keep sampling at scale one.
Paint takes the flake, wheels the tread, the interior and the driver the
fabric; glass and lenses take nothing. `testCarBatchesBindDetailStructureAndMetalSetsAreFlagged`
writes four small sets to a temporary directory and checks the bindings.

The name rules grew with the list, and their order matters: a wooden fence
is wood before it is a fence. `testNamesMapToTheMaterialList` pins the
mapping for Aalborg's names and a set of generic ones, and checks that every
rule targets a set that exists. Aalborg's side strips and its second asphalt
now read as the older, patched tarmac; its walls stay concrete, because that
is what they are.

The tile test caught two seams on the first run: a brick and a plank
straddling the tile edge took two different per-item shades because their
ids were not wrapped. The first patched asphalt drew round patches — a
cellular threshold — and now cuts square ones from a jittered grid, which
is what a road crew does.

All twenty-six generate at 1024² in 13 s and weigh 312 MB uncompressed,
loaded lazily by name so a session pays only for the sets its surfaces use.
The shipped session uses six.

## The hero car, in place

The plan left a new high-polygon car out of scope and named it the obvious
follow-on. A new model needs a source with documentable terms, which is a
decision for the user; what can be done from project code is the plan's
own §7d, "upgrade the car in place", taken further than materials:
`MeshSubdivision` Loop-subdivides the original 155-DTM twice at load.

The rules are the standard ones with two additions that matter for a car.
Edges whose dihedral angle exceeds 35° are **creases** and subdivide as
curves of their own, so the panel lines the artist made sharp stay sharp
while the arches and the roof line round; a boundary vertex whose boundary
turns by more than 60° is a **corner** and stays put. Positions are
subdivided on the welded topology, texture coordinates are interpolated
per face corner, so the atlas seams AC files carry at every UV island
survive intact, and normals are recomputed from the finer surface,
averaged only across faces within the crease angle.

The first version subdivided each node on its own and opened gaps: a car's
panels are separate nodes sharing their outlines, and each outline rounded
by its own rule — a vertex with three crease edges on one panel and two on
its neighbour — so the bonnet drifted from the bumper by a centimetre and a
slit showed beside the headlight. `loop(group:)` now welds every node of
the car in scene space and subdivides them as one surface, then hands the
faces back to their nodes with the identity transform; a mirrored node has
its winding restored first. The join between two panels is then an
ordinary edge, a crease if they meet at an angle and smooth if they are
one surface, and the gaps closed.

| | triangles | GPU, native, car alone, 60 frames |
|---|---|---|
| as authored | 5,698 | 6.69 ms median |
| subdivided twice | 71,920 | 7.23 ms median |

Twelve times the triangles rather than sixteen: welding removes the
duplicate and degenerate faces the file carries. The half millisecond is
the car through four shadow cascades and the prepass as well as the
shading pass; in the session's chase view the frame carries 401k
triangles with the subdivided car and its wheels. The wheel arches are round,
the flake and the highlights run over a continuous surface, and the car no
longer reads as a set of facets — but its form is still a 1990s model's,
and the honest ceiling the plan named stands: the visible improvement is
shading and silhouette, not design. `testFixtureCarSubdividesInPlace` pins
the count and that the car's box moves by under five centimetres;
`testCreaseIsPreserved` folds a sheet and checks the ridge, the boundaries
and the two normal directions survive; the octahedron test checks the
smooth case rounds and welds.

## The seven signposts

Section 24 of the specification lists seven things to instrument; the app
had two batch-level intervals. `PerformanceSignposts` in TORCSCore now
holds one signposter under `org.torcs.mac / Performance` and the list of
the seven names, and each has a call site: **Simulation tick** around each
fixed step and **Track queries** around the lap-timing update in the
driving runtime, **AI update** around the robot's decision in the solo
runtime, **Collision processing** around the contact phase of the
multi-vehicle step, **Asset loading** around a session's content load, and
in presentation **Draw preparation** from the frame's start to commit and
**GPU duration** from commit to the completion handler, which the
signposter allows to end on another thread. An interval on a signposter
with no instrument attached returns immediately, so the hot paths keep
them on. `testEveryListedNameHasACallSite` reads the sources and fails if a
name on the list has no `begin` of it, so the list cannot drift from the
code.

## Reflections that hold still

The reflection trace dithers its start offset by a per-pixel noise whose
phase rotates every frame, and the depth-aware blur that followed it was
the only thing between that dither and the screen: a fine crawl on the
road and the car's flanks whenever the camera moved, and a shimmer when it
did not. A temporal resolve now sits between the blur and the composite.
It reprojects the previous frame's resolved reflection — by the velocity
buffer when one is bound, by the unjittered camera matrices otherwise —
clamps it to the 3×3 neighbourhood of this frame's result so a stale
reflection cannot ghost across a surface, and blends the current frame in
at 15 %. Because the phase rotates, what the blend converges on is the
average over the phases: the reflection without the dither. Two history
textures alternate at the trace's resolution; a size change or a
verification render starts cold.

The cold start is the same discipline as the noise reset: an offscreen
`render` begins every frame from a fresh phase and no history, so two
calls with the same inputs produce the same bytes, and
`testTemporalReuseAccumulatesOverASequenceAndStaysColdOtherwise` checks
both halves — cold renders identical and reusing nothing, then with the
reset off a three-frame sequence whose consecutive frames differ less as
it goes. The render tool's `--compare-ssr-temporal` measures the pass with
the reset off so the reuse actually runs:

| | Δ |
|---|---|
| 1280×832, full-resolution trace | +0.03 ms |
| 2560×1664, full-resolution trace | +0.19 ms |

Not done: reusing the history to trace fewer steps, which is the other
half of the usual reason for the pass and would turn it from a cost into a
saving.

## Pit garages

Phase 5's last unbuilt item. `PitGeneration` builds one garage per stall
from the parity-verified pit model — the stall positions, the stall length
and the pit side — against the outer edge of the pit lane: a box one stall
long less a gap, seven metres deep, 4.2 m high, with a painted-steel roller
door on the lane side under a brick lintel, brick side and back walls and
a concrete roof, each face with metre UVs so the sets tile. The footprint
is built from the stall's centre, the track tangent there and the outward
direction across the strip, because building from the stall's two ends
clamped a stall that straddled a segment join to a fraction of its length;
every wall faces away from the box's own centre and the orient pass winds
it to match, so no wall faces inward on either side of a circuit.

The track model already knew about the building. TORCS marks the pit-side
barrier segments `pitBuilding`, and trackgen extrudes them into a block the
length of the complex under the pit wall's texture. Three things had to
give way for the garages to be seen:

- the road generator no longer extrudes a `pitBuilding` barrier
  (`Parameters.pitBuildings`, off);
- the trackgen strip also drops the pit wall surface's batches
  (`tarmac-wall`), which are trackgen output like the `tr-` ones;
- `strippingPitComplex` removes any baked batch whose bounds overlap a
  garage footprint — Aalborg's baked building is ten `concrete.rgb`
  batches, and the lane's lamp posts stand inside the footprints and go
  too, which is right, since they would pierce the roofs.

The last of those took an afternoon to find: the block stayed after each
of the first two, dark and smooth, and every probe of the garages
themselves — normals, packing, the roof quad rendered alone — came back
clean, until a render of the baked scene with no generation at all showed
the same block. Along the way a second fault surfaced and was fixed:
painted content from an original texture was composited over the generated
set for *every* substituted batch, and for a plain grey wall texture the
extraction read the grey as paint and darkened the wall. Compositing now
happens only for a road that paints markings, which is what it was for.

`testOneGaragePerStallAgainstTheLaneEdge` pins the count, the dimensions,
the level floor and the distance from each stall;
`testPitBuildingBarriersAreLeftToTheGarages` that the road's own geometry
stops standing where the garages do (counted, then asserted once: an
assertion per vertex per garage took twenty minutes);
`testBakedPitComplexIsStrippedAndLampPostsStay` that the baked building
goes and the trees and road stay. The batches are named `pit-…` so no
original artwork file can match them.

## Tyre walls on the corners

The first of the Phase 6 furniture. `FurnitureGeneration` finds the corners
from the segment model — runs of same-hand arcs tighter than 120 m and
longer than 12 m, so a kink between two straights gets nothing — and lays a
tyre wall along the outside of each: a strip against the outer edge, in
front of whatever barrier the track has there, two tyres high and one deep,
stepped every two metres along the corner with the rows shared at segment
joins. It is dressing: the physics keeps the original barrier. The strip
takes the `tyre-wall` set with metre UVs along it, so the stacked tyres
repeat at their real size and the painted rows read from the road.

Two lessons from a short increment. The outward direction was first taken
across the outer strip, and Aalborg's outer strips can be narrower than
the half metre the probe used, which gave a zero direction and a strip of
zero depth; it now comes from the main road's own lateral axis. And the
first winding test judged each face against its *first* vertex's normal,
which for a strip whose rows share vertices between the front, the top
and the back is often perpendicular to the face; the orient pass judges
against the sum of the three, and so does the test now.

Also in this increment, by way of a fault it exposed: the render tool's
generated-track path had lost the pit garages and the pit-complex strip
between two commits (see the note on the shared checkout in the recap of
the session), and has them back.

## The starting grid, painted

The other session's G2 increment brought a native `StartingGrid` — the
original placement, parity-verified for sixteen cars. Its slots are now
painted on the road: `RoadPaint` holds one static quad per box in the skid
marks' vertex layout, and the skid-mark renderer gained a paint pipeline
that blends a white outline over the tarmac, depth-tested read-only like
the marks. Each box is a car's footprint, 4.7 × 2.2 m, its length and
width carried per draw so the outline is 12 cm wide whatever the box; a
hash wears the paint a little. Twenty boxes are painted whatever the entry
— a circuit's grid is painted for its capacity — from the track's own
`Starting Grid` section over the original defaults, resolved in
`DrivingContent.load`, and the render tool paints them for a generated
track. The mirror renderer draws the same set.

`testGridBoxesFromTheNativeStartingGrid` puts all twenty of Aalborg's
slots on the road; `testBoxesBecomeQuadsInMetres` pins the quad, the lift
and the metre coordinates; `testPaintBrightensOnlyUnderTheBox` renders a
box beside the car and requires more light, none taken away, and an
untouched frame with the decals off. The first look for the boxes was from
the start line facing forward, which is the wrong way: the grid is behind
the line, in the last fifty metres of the lap.

## Heat haze

The far road shimmers under a high sun. In the resolve, before the scene
is sampled, a rising two-octave value noise displaces the sample by up to
two and a half pixels where the opaque depth is between about a hundred
metres and the horizon — from 60 to 220 m in, fading out from 500 to
1,400 m — and only when the displaced sample is itself more than 45 m
away, so a car or a post ahead is never smeared into the road behind it.
The strength follows the sun's height: nothing below 17° of elevation,
full above 53°, scaled by `RenderSettings.heatHazeStrength`; the mirror
has it off. It costs **+0.15 ms** at native with the whole frame's road
in view.

`testFarGroundShimmersNearGroundHolds` looks down a 480 m checkered
strip: between two animation times the far band differs, the near band is
identical to the byte, and with the haze off or the sun at 10° nothing
differs at all. In a still the effect is a faint waviness in the far
markings; in motion it is the summer afternoon the lighting already
implies.

## Sustained, a third time: what the scale valve is worth

Everything since the previous sustained run — pit garages, tyre walls, the
painted grid, sun glare, heat haze, dithered detail switches, temporal
reflections, the subdivided car — measured together on the M2 Air preset,
orbiting at native 2560×1664 with a 55° sun so the glare and haze are in
play:

| | native, fixed scale | dynamic resolution |
|---|---|---|
| first window | 7.74 ms | 8.73 ms at scale 0.67 (p95 18.9 ms) |
| steady | 7.58–7.69 ms | 6.5–7.5 ms at scale 0.60–0.75 |
| 1280×832 | 3.21 → 3.19 ms over 90 s | — |

Native holds under eight milliseconds with everything on, at the track's
own sun and at the high one alike: the additions since R28 cost nothing
the earlier margin could not absorb. Two other things are in that table,
and they matter more than the headline.

The controller dropped two steps in the first fifteen seconds and never
came back to native. The first window's p95 is the material and atlas
uploads and the first pipeline uses — the same spikes every earlier run
showed and shrugged off at fixed scale — but the controller's thirty-frame
average crossed its 11 ms threshold during them, stepped down, and then
sat where its increase threshold (7.7 ms, 0.70 of the target) is exactly
the cost of the frame, oscillating 0.60–0.75 for four minutes. A warm-up
grace before the controller may act is the obvious fix and is queued with
the next change to it.

More telling: at 0.60–0.75 of the render resolution the frame cost 6.5 to
7.5 ms against 7.7 ms at native. Cutting the shaded pixels by half saved a
tenth. For the orbiting camera the frame is not bound by shading: it is the four
shadow cascades re-rendering the whole static circuit every frame, the
geometry passes, and the fixed-cost passes at output resolution. The plan
saw this coming — section 3 asked for a static/dynamic split of the
cascades with the static circuit rendered once and only the cars
refreshed — and `staticShadowRefreshInterval` has sat in the settings
unused since Phase 1.

**Correction, measured the same hour.** The orbit camera is the wrong
view to draw that conclusion from. The driver's-eye view — the road
camera at 250 m, the road filling the frame, sixty frames each at native
with a 40° sun:

| | GPU median |
|---|---|
| no trees | 11.8 ms |
| trees, detail pairs | **14.6 ms** |
| trees, middle build only | 13.3 ms |
| trees, two cascades instead of four | 14.7 ms |
| trees, 1280×832 | **6.6 ms** |

That view is shading-bound through and through: half the pixels is less
than half the time, and the cascades do not matter. In the view the
player actually drives, the controller's ladder is worth what the plan
said it was, and it will settle near 0.75 for a frame under the target.
What the two views agree on is that the per-pixel road — four cascades
sampled with a rotated kernel, the half-resolution trace and occlusion,
the markings, rubber and weather — is where the milliseconds are, and
that the sustained orbit runs in this document understate a lap. The
next sustained run should orbit at the driver's height.

## Rain

Phase 7's last item but the photo mode. A fourth particle kind: drops
spawned in a box above the source — the camera, wherever it is — falling
at 9 m/s with a little drift, carried along by the source's velocity, for
just over a second, at 1,800 a second. The vertex shader stands a rain
streak along its fall, three centimetres wide and seventy tall, rather
than facing it to the camera as the puffs are, and the fragment draws it
as a soft line lit by the skylight. Rain implies the wet road, so the
session's "Rain" toggle turns on the wetness too, and the sun goes to
thirty percent with the skylight kept and the exposure opened by a stop
and a fifth: the first version dimmed the ambient as well and left the
exposure alone, and the afternoon read as night, because there is no
auto-exposure to open up for an overcast sky and the skylight the
renderer uses comes from the atmosphere, not from the ambient value.

Some two thousand drops in the air cost **+1.0 ms** at native — about
what the tyre smoke costs per hundred puffs, since a streak is small and
the particle pass draws at half resolution. `testRainSpawnsAboveAndFalls`
pins the spawn box, the fall, and that the count settles at rate × life;
`testRainDrawsStreaksAndDimsTheSun` that the frame changes and the
dimming rule holds.

Not done: drops on the glass, the sky itself (still clear blue behind the
rain), and the physics, which stays dry.

## Where the milliseconds are

The previous section guessed at the shadow cascades and the correction
under it guessed at the road's pixels. This section measured instead, and
both guesses were mostly wrong.

**The cascade cadence is a null result.** `ShadowRenderer.encode` now
takes the refresh interval the settings have carried since Phase 1: the
near cascade every frame, the second every other, the far two every
`interval` frames staggered, each stale slice sampled with the matrix it
was rendered with, a history reset refreshing all. It is tested and it
works — and at interval 3 the orbit view measured 7.76 ms against 7.71,
the driver's-eye view 15.6 against 14.8. The shadow pass is not where the
time goes: with the cascades off entirely the orbit frame drops by 0.15
ms. The mechanism stays, off in every preset, until a circuit needs it.

**The controller now waits.** Its startup step-down came from the first
seconds' spikes; it ignores the first 180 frames after a reset
(`testControllerIgnoresTheWarmup`).

**What the orbit frame is made of**, native 2560×1664, 55° sun, everything
on unless stated, interleaved where the setting can be toggled per frame
and back-to-back sixty-frame runs where toggling it re-allocates targets
(reflections, motion blur — the interleaved comparison of those two
reported 16–22 ms medians, the cost of re-creating the frame targets
every other frame, not of the pass):

| | Δ at native |
|---|---|
| screen-space reflections, half resolution | **+2.5 ms** |
| motion blur at output resolution | **+1.4 ms** |
| trees (middle build, whole forest in view) | +1.2 ms |
| bloom | +0.18 ms |
| heat haze | +0.17 ms |
| sun glare (in frame) | +0.19 ms |
| grass, skid marks, depth prepass alone | ≈ 0 |
| four cascades | +0.15 ms |
| occlusion (with its standalone prepass) | **−1.0 ms** |

Occlusion is *cheaper on*: it forces the standalone depth prepass, and the
equal-depth shading pass that follows shades each visible pixel once,
which on a road that fills the frame is worth more than the occlusion
costs. The prepass setting on its own measured nothing because occlusion
had already turned it on.

And the frame is resolution-bound after all: the same orbit view at a
fixed spatial scale of 0.6 costs 6.4 ms against 7.5 native, and the
driver's-eye view 12.3 ms at 0.75 against 14.7. The earlier dynamic run
that seemed to say otherwise compared windows from different thermal
states, which this document warns against on its first page.

Where that leaves the budget: the two passes worth a millisecond or more
each at native are the reflections and the motion blur, both at the
full-resolution end of the pipeline. Tracing at a quarter resolution
instead of half, and blurring at the render resolution before the scaler
(the spatial path already does), are the next two increments with a
number attached.

## A quarter-resolution trace, and what it did not save

`RenderSettings.Quality` gains `quarter`, with a `divisor` the occlusion
and reflection passes take instead of comparing cases, and the render tool
accepts it. Measured on both views at native, sixty frames each,
back to back:

| reflections | orbit | driver's-eye |
|---|---|---|
| off | 6.74 ms | 14.40 ms |
| quarter | 7.45 ms | 14.75 ms |
| half | 7.48 ms | 14.75 ms |

Two corrections fall out. The reflections cost 0.35–0.7 ms at native, not
the 2.5 ms the previous section reported: that figure came from two runs
minutes apart on a chip whose clocks had moved between them, the very
comparison this document says not to make, and the interleaved comparison
that would have caught it is contaminated for this setting because
toggling it re-allocates the frame targets. And the trace's resolution is
not where its cost is: a quarter of the pixels costs the same as half, so
the milliseconds are in the composite at full resolution and the fixed
per-frame work, not the march. The option stays — it is free and looks the
same on the car — and the presets keep half.

Three null results in a row say the same thing: the tool's back-to-back
runs are too coarse for sub-millisecond attribution on a fanless chip, and
the plan's per-pass GPU timing from `MTLCounterSampleBuffer` (section 9.3,
never built) is the instrument this work now needs. It is the next
increment.

## Per-pass timing, at last

`PassTimer` is the instrument section 9.3 of the plan asked for and three
null results in a row said was overdue. Every pass attaches a stage pair
to its descriptor — vertex start and end, fragment start and end, or an
encoder's start and end for compute and blit — in one timestamp sample
buffer, and after the command buffer completes the pairs resolve to
durations. All of a frame's passes are then measured in the same frame on
the same clocks. `ForwardRenderer.passTimer` enables it; the render tool's
`--passes` prints the per-pass medians over its frames.

The first version bracketed each pass from its first vertex to its last
fragment and reported every pass as the time since the frame began: this
is a tile-based GPU, and it runs the vertex stages of several passes
before their fragment stages, so one pass's "vertex start to fragment end"
spans the others. A depth-only pass has no fragment stage to end at and
came back as the error sentinel. Each stage is now bracketed by its own
pair, and the sum of the working stages lands within a tenth of the
frame.

What the two views are made of, native 2560×1664, sixty frames, M2 Air
preset, medians of the stage that did the work:

| pass | orbit | driver's-eye |
|---|---|---|
| shadow cascades 0–3 | 0.12 ms | 0.65 ms |
| depth prepass (vertex + fragment) | 0.54 ms | 1.36 ms |
| occlusion + blur | 1.01 ms | 2.29 ms |
| **sky and forward opaque** (vertex + fragment) | **1.30 + 3.61 ms** | **2.01 + 7.99 ms** |
| reflections, four passes | 0.52 ms | 0.97 ms |
| motion blur | 0.39 ms | 0.65 ms |
| bloom, eleven passes | 0.18 ms | 0.27 ms |
| tonemap resolve (glare, haze) | 0.66 ms | 0.66 ms |
| sum of medians / frame | 6.76 / 7.30 ms | 14.31 / 15.18 ms |

So the forward pass is two thirds of the driver's-eye frame, its fragment
stage alone more than half; the occlusion is the next two milliseconds;
everything the earlier sections argued about — cascades, the trace's
resolution, the cadence — is in the tenths. The forward fragment is the
road: four cascades sampled with a rotated kernel, the aerial perspective
marched per pixel, the sky probe, the markings, rubber and weather. That
is where the next increment goes, and for the first time it will be able
to see what it did.

Two smaller corrections from the same instrument: the earlier
"occlusion is cheaper on" was the prepass it forces, not the occlusion,
which costs 1–2.3 ms itself; and the tool's summary had printed the
quality levels by a stale table since the quarter level shifted the raw
values, so "ao full" meant half. It prints the names now.

## The forward fragment, first cut

The per-pass numbers said the forward fragment stage was eight of the
driver's-eye view's fifteen milliseconds, and listed what it does per
pixel. The first thing on that list that could be cheaper without being
different was the aerial perspective: `aerialPerspective` marched every
pixel's view ray in eight steps, the count the sky LUT needs to cross a
hundred kilometres of atmosphere, and the road in front of the car is two
hundred metres of it. Over a ray that short the medium is uniform to
within the LUT's own resolution, and the step integration is analytic per
step, so two steps integrate it as exactly as eight. The count is now a
schedule on the ray's length: two steps under 300 m, four under a
kilometre, eight beyond. Nothing else in the pass changed.

Same binary, the two shader versions built to `.metallib` files and
swapped through `TORCS_METALLIB` on alternate runs, so neither version
was measured on a warmer chip than the other — the earlier sections'
lesson. Native 2560×1664, sixty frames, M2 Air preset:

| view | forward fragment, before | after | frame, before | after |
|---|---|---|---|---|
| driver's-eye, three pairs | 8.75 / 8.02 / 7.79 ms | 5.54 / 5.49 / 5.80 ms | 16.4 / 15.4 / 14.8 ms | 12.6 / 12.5 / 13.0 ms |
| orbit, three pairs | 3.61 / 3.61 / 3.61 ms | 2.94 / 2.94 / 2.93 ms | 7.40 / 7.30 / 7.46 ms | 6.60 / 6.69 / 6.64 ms |

A third of the forward fragment on the road-filled view, nearly a fifth
on the orbit, and two to three milliseconds off the driver's-eye frame —
more than the cascade cadence, the quarter trace and the quality preset
put together. One orbit "after" run came back at 10.1 ms with its vertex
stage doubled as well and is excluded: that is the chip throttling
mid-run, not the shader, and the alternation is what makes it obvious.

The images are the same. Both views rendered at 1280×832 before and after
differ by at most one 8-bit step in any channel, with no channel differing
by more than two; a test (`AerialPerspectiveTests`) probes the shortcut
against the eight-step reference on the same tables along a driver's ray
from two metres to five kilometres, at both sides of each edge of the
schedule, and holds it to a thousandth of the brightest channel.

That the shortcut is invisible says something about where the pass's
cost actually is: the eight-step march was three milliseconds of a
fifteen-millisecond frame for an integral whose value a two-step march
reproduces to four decimals. The remaining five and a half milliseconds
of forward fragment are the cascade kernel, the material and the probe;
the pass timer now shows whether the next cut moves them.

## The forward fragment, second cut

With the pass timer in place the forward fragment could be taken apart
without guessing. Each candidate was removed from a copy of the shader
sources, built to its own `.metallib`, and alternated with the current
one through `TORCS_METALLIB` in the same binary — driver's-eye view,
native, sixty frames, medians of the fragment stage. Base was 5.5 ms;
what each removal saved:

| removed | saving | note |
|---|---|---|
| everything after the albedo sample | 4.4 ms | the floor is 1.05 ms: albedo, outputs, rasterisation |
| normal and roughness maps | 1.4 ms | two samples at anisotropy 8 |
| aerial perspective (already two steps) | 1.2 ms | the tables and the exponentials, not the loop |
| shadow lookup entire | 0.9 ms | projection, selection and the compare |
| shadow kernel 8 taps → 1 | 0.2 ms | the kernel is not the cost of the shadow |
| road markings | 0.2 ms | |
| sky probe | 0.0 ms | |
| trees and grass, whole scene | 1.8 ms of vertex; fragment within noise | |

Two of those could be made cheaper without being made different.

**Aerial perspective in closed form.** The previous section cut the
march to two steps under 300 m; what remained was each step's samples of
the two tables and its exponentials. Over a ray that short the medium's
density changes by under a part in a thousand — its scale heights are
kilometres — so it is uniform, and the integral of a uniform medium has
an exact solution: one sample of the medium and of the tables at the
midpoint, and the per-step expression the marcher uses, applied once
over the whole ray. `nearFieldScattering` does that for rays under
`kNearFieldKilometres`; the planet-intersection tests are skipped too,
being below single precision at the planet's radius over a few hundred
metres. The probe test from the previous section holds it to the
eight-step reference at a thousandth of the brightest channel.

**Anisotropy on the detail maps.** The surface sampler filters at
anisotropy 8 because the road is seen at grazing angles and would
otherwise blur a few car lengths ahead. That is true of the albedo. The
normal and roughness maps carry less that anisotropy preserves, and
their two samples at 8 were a millimetre-scale detail the frame was
paying 1.4 ms for. They now take a second sampler at
`RenderSettings.detailAnisotropy`: 2 on the M2 Air preset, 4 balanced,
8 high; the albedo keeps 8 everywhere. Crops of the road at 1280×832
with the detail maps at 8, 2 and 1 are indistinguishable at that size.

Together, same protocol (the R43 shaders as one library, these as the
other, both through the same binary; the anisotropy switched with the
tool's `--detail-anisotropy`):

| view | forward fragment | frame |
|---|---|---|
| driver's-eye, R43 | 5.5 ms | 12.6 ms |
| driver's-eye, closed-form aerial alone | 5.0 ms | 12.1 ms |
| driver's-eye, both | 4.1 ms | 11.2 ms |
| orbit, R43 → both | 2.94 → 2.93 ms | 7.0 → 6.8 ms |

The orbit view has little road at a grazing angle and few pixels within
the near field's terms, and shows it. The driver's-eye view — the one
the plan's budget is for — has come from 15.2 ms two increments ago to
11.2, with nothing on screen changed beyond one 8-bit step on the
orbit view and, on the driver's-eye view, the anisotropy's own
sub-texel differences on the far road.

Two things the measuring taught. The chip throttled through the later
runs — the same shader measuring 4.1 ms one run and 8.7 ms the next,
with the vertex stage doubling alongside — and only alternation makes
that visible; a run whose neighbours disagree with it by a factor is
discarded, not averaged. And a `TORCS_METALLIB` naming a file that is
not there used to fall back to compiling the sources without a word,
which measured one shader change against itself for a whole series.
It is an error now, and it takes precedence over a bundled library, so
a measurement means what it says.

## Occlusion at a quarter

After the forward pass the occlusion pass was the driver's-eye view's
next two milliseconds. Taken apart the same way — each candidate
removed into its own library and alternated with the current one — at
its half resolution of 1280×832:

| removed | saving |
|---|---|
| the ambient (GTAO) term | 1.4 ms |
| contact shadows | 0.45 ms |
| the bilateral blur | 0.32 ms (measured directly) |
| horizon steps 4 → 2 | 0.5 ms |
| slices 3 → 2 | 0.45 ms |
| contact steps 8 → 4 | 0.15 ms |
| the 96-pixel radius clamp → 48 | nothing |

So the cost is the sample count times the pixel count, and there is no
one sample doing nothing. Fewer samples make the term noisier under the
same blur; fewer pixels do not, because the term is low-frequency by
construction — a horizon integral over a metre of world, blurred 4×4 and
then sampled bilinearly by the forward pass. `RenderSettings.Quality`
already had a `quarter` level from the reflection trace's null result,
and the occlusion renderer already keyed its target size on it.

The M2 Air preset's `ambientOcclusion` is now `.quarter`; balanced stays
at half and high at full. Same binary, the two levels alternated with
`--ao` (the pass's own stage medians, then the frame):

| view | half | quarter |
|---|---|---|
| driver's-eye, occlusion + blur | 1.94 + 0.32 ms | 0.68 + 0.17 ms |
| driver's-eye frame | 11.1 ms | 10.0 ms |
| circuit overview, occlusion + blur | 0.84 + 0.18 ms | 0.33 + 0.09 ms |
| circuit overview frame | 6.9 ms | 6.5 ms |

What it does to the picture, at 1280×832 output (so the occlusion is
computed at 320×208): the driver's-eye frame differs from the
half-resolution one by more than 8 of 255 in 0.1% of its channels
(against 5.1% for switching occlusion off altogether); a car at
three-quarter view with the sun at 40° differs in 0.1% of channels
(3.7% for off). The raw ambient buffer is visibly blockier at a quarter
— a wheel arch's shading resolves in 4-pixel steps — and none of that
survives the blur, the bilinear sample and the multiplication into a
sky term that is itself a small part of a sunlit pixel. The contact
term, which is the sharper of the two, comes out of the quarter target
nearly identical to the half one, because its edges are where the depth
buffer's are and the bilateral blur keeps them there.

Two increments ago the driver's-eye frame was 15.2 ms at native; it is
now 10.0, under the plan's 10.5 ms budget for the first time at full
resolution, with the resolution controller still holding native. The
occlusion at a quarter costs what the plan budgeted for it at half
(0.7 ms), and the forward pass is a millimetre from its own line
(4.1 + 2.0 ms against 3.2 — the vertex stage of the trees is what
remains above it).

## What was behind the camera

The forward-fragment attribution had one number that was not a fragment
cost: the trees and grass were 1.8 ms of the driver's-eye view's
*vertex* stage. A tree here is a trunk, branches and a crown of leaf
cards — the better part of a thousand triangles at the near build — and
the circuit places 169 of them. The forward pass decided what to submit
by distance alone, through the detail fade, so from a driver's seat the
trees behind the car were transformed, swayed and clipped every frame,
in the prepass and again in the forward pass. The shadow cascades had
their own sphere test since Phase 1; the camera never got one.

`ViewFrustum` is that test: the five clip planes of the unjittered
view-projection (the reversed infinite projection has no far plane, and
the helper simply has no plane for it), against each batch's bounding
sphere under its instance transform. Both draw loops skip what it
rejects; `ForwardRenderer.frustumCulling` turns it off, and the render
tool's `--no-frustum` with it, so the saving can be measured rather than
assumed. Driver's-eye view, native, alternated:

| | without | with |
|---|---|---|
| batches submitted | 247 | 125 (244 rejected across both passes) |
| triangles | 515 k | 316 k |
| depth prepass vertex stage | 0.55 ms | 0.37 ms |
| forward vertex stage | 1.61 ms | 1.14 ms |
| frame | 9.7 ms | 9.2–9.45 ms |

The circuit overview looks down on all of it and rejects nothing, and
its frame is unchanged. The driver's-eye image is byte-identical with
and without the cull, as a test now pins on the fixture, and the cull's
own tests check the planes against clip space directly on two thousand
random points.

The saving is the smallest of this run of increments, and the cheapest:
forty lines and no shader. It leaves the driver's-eye frame at 9.2 ms
at native. The vertex stage that remains is the trees in view, which is
where the plan's impostors would go if they were ever needed; at these
numbers they are not.

## Sustained, a fourth time: under budget at native

Four increments took the driver's-eye frame from 15.2 ms to 9.2 at
native; the sustained protocol says whether that survives the chip's
steady state. Same protocol as the third run — the default preset, the
whole generated session, orbiting at 2560×1664 with dynamic resolution
for four minutes — on a machine with nothing else of mine running,
after a first attempt was thrown away because a build ran beside it and
halved the frame rate.

| window | median | p95 | scale |
|---|---|---|---|
| 0–15 s | 9.34 ms | 11.1 ms | 1.00 |
| 30–75 s | 9.20–9.36 ms | 10.4–10.8 ms | 1.00 |
| 90 s | 9.91 ms | 14.1 ms | 0.75 |
| 105–195 s | 9.57–9.82 ms | 10.5–12.8 ms | 0.75 |
| 210–225 s | 8.54–8.79 ms | 10.6–12.5 ms | 0.67 |

Native for the first ninety seconds at 9.3 ms, under the plan's 10.5;
then the controller stepped to 0.75 as the chip warmed and the median
held under 10 through the rest, stepping once more at the end. The
third run, before the four cuts, had opened at 8.7 ms already at
scale 0.67 and settled around 7 ms at 0.60–0.75. The frame is now
cheaper at native than it was then at two thirds of it.

Two caveats the run itself exposed. The harness renders a frame and
waits for it, so the GPU idles between frames — 600 frames a window
here against 850 in the third run, the CPU side having grown with the
scene — and an idle GPU lowers its clock: the 1280×832 control run,
which sat flat at 3.2 ms in the third run, drifted from 3.4 to 7.5 ms
over ninety seconds with the GPU busy a third of the time, and a photo
frame measured *faster* with the lens than without because the heavier
frame kept the clock up (every other pass in it ran at half the time).
Per-pass medians within one frame stay comparable; frame medians
across runs with different loads are not, and a run's frame count is
the tell. The app's presentation pipelines frames and does not have
this problem; the harness should, and that is the next measurement
increment. The fixed driver's-eye run, 8.6 ms opening, wandered to 11.4
and back to 9.8 over two minutes with a window server taking a third
of a core throughout: reported, not relied on.

## A lens for the television view

The one Phase 7 item still deferred was depth of field, and the plan was
specific about where it belongs: replay and photo views, never the race.
A driver's eyes focus where they look; a blurred mirror or dashboard is a
fault. A broadcast camera has a lens, and its background is soft because
the lens is long and open.

`DepthOfField` is that lens, in the units a camera operator would use —
focus distance, f-number, focal length — and the renderer converts it
to a circle of confusion in pixels for the image it has, by the thin
lens: `f² / (N (F − f))` on a 36 mm sensor for a subject at infinity,
scaled by `(d − F) / d` for one at distance d. Signed, so the shader can
tell a subject in front of the focus from one behind it. Three passes:

- **Prefilter**, half resolution: the scene colour with the circle in
  its alpha, from the nearest of the four depth texels under each
  pixel so a thin near edge keeps its blur.
- **Gather**, half resolution: forty-nine taps on three rings of a disc
  as wide as the largest circle, each weighted by whether its own circle
  reaches the pixel (scatter as gather) — a tap behind the pixel reaches
  no further than the pixel's own circle, so a sharp subject keeps its
  edge against a blurred background while a blurred foreground still
  spreads over a sharp one. Rotated per pixel so the rings' residual is
  noise. A pixel whose neighbourhood carries no circle — most of a
  photograph — returns after seventeen looks around the rim instead of
  the disc.
- **Composite**, in the resolve: the blurred image where the pixel's own
  circle is wider than half a texel of it, the sharp one where it is not.

`RenderSettings.depthOfField` allows it (on in every preset); the view
supplies the lens through `ForwardRenderer.depthOfField`, and the app
sets an 85 mm at f/2.8 focused on the followed car for the television
preset and nil for every other. The mirror never composites it. The
render tool takes `--dof <metres>`, `--fstop`, `--focal` and `--dof-max`.

What it costs, native 2560×1664 (the passes run at 1280×832),
alternated:

| view | prefilter | gather | frame without → with |
|---|---|---|---|
| driver's-eye, focus 25 m | 0.3 ms | 1.9–2.3 ms | 9.3 → 11.3–13.0 ms |
| car photo, focus on the car | 0.12 ms | 1.8–2.6 ms | 6.1 → 6.3 ms (the GPU clock rose with the load; every other pass halved) |

Two to two and a half milliseconds for a fully blurred background is
the honest price of a 49-tap gather over a million pixels, and the
television view is the one view that has the room: it is not the
driver's, and its own cost is the circuit overview's 6.5 ms. The
early-out is what keeps a photograph cheap where it is sharp.

Tests: the thin-lens arithmetic (zero at the focus, signed either side,
capped, a faster lens shallower, a shorter one deeper); a render focused
on the fixture keeps more than 80% of the sharp frame's edge energy
while one focused far in front of it loses more than a quarter, and
removing the lens returns the sharp bytes exactly; the targets are half
the source and follow it; the two entry points are pinned in the
library.

## Three loops, three answers: what a frame costs depends on who asks

The previous section's caveat — the harness renders a frame and waits
for it, the GPU idles and lowers its clock — turned out to be the
largest error in this document's numbers, and fixing it did not produce
one true figure but three regimes, each answering a different question.

`ForwardRenderer.submit` is the offscreen path without the wait: it
encodes, commits with a completion handler that reports the frame's GPU
time (and records it for the resolution controller, as presentation
does), and returns. The per-frame buffers — particles, skid marks — were
already rings of three, so up to three frames may be in flight, as in
the app. The render tool's timing and sustained loops take
`--in-flight N`, and the sustained loop also `--pace HZ`: one frame per
display interval with at most two in flight, reporting the
submit-to-completion latency and the share of frames that finished
inside the interval. A test submits a dozen frames, sees each complete
with a time, and checks the synchronous path still renders the cold
frame afterwards.

The same circuit orbit at native, the three ways, alone on the machine:

| loop | per-buffer GPU median | wall per frame | GPU busy | what it measures |
|---|---|---|---|---|
| render and wait | 9.5 ms | 25.7 ms | 37% | a GPU at the clock it drops to when a third busy |
| three in flight | 7.6 ms | 6.8 ms | 100% | throughput of a GPU kept busy — the true cost of the work |
| paced at 60 Hz, dynamic | 9.2–10.5 ms | 16.67 ms | ~60% | what presentation sees |

Kept busy, the frame the synchronous loop had put at 9.3–9.5 ms is
6.8 ms of throughput, 28% less — and every "frame" in the earlier
sections was the synchronous figure, pessimistic by roughly that. Per-
pass medians within one frame, which is what the cuts were decided on,
compare correctly in any regime; frame totals across regimes do not.
With buffers overlapping, one buffer's start-to-end span includes its
neighbours' work (5.6 ms per buffer at 1280×832 against 5.0 ms of
throughput), so the busy loop reports wall-clock per frame as the cost.

The paced loop is the one that answers the plan's question, and its
answer is not the one the throughput suggests. At 60 Hz the GPU is busy
a little over half the time, runs at a clock to match, and the
per-buffer span sits at 9–11 ms; add the CPU's encoding ahead of the
commit and the median submit-to-completion latency is 12–14 ms against
a 16.7 ms interval, with 85–96% of frames on time:

| view, paced 60 Hz | scale | latency median | on time |
|---|---|---|---|
| circuit orbit, dynamic | 0.75 → 0.60 | 10.7–12.6 ms | 88–96% |
| driver's-eye, fixed native | 1.00 | 13.0–13.9 ms | 85–89% |
| driver's-eye, dynamic | 0.60 → 0.55 | 12.5–13.6 ms | 80–82% |

The last row is the finding. The resolution controller is fed GPU spans;
under pacing those spans are inflated by the lowered clock, so it reads
a frame that was on time as over budget, steps down, and a lighter frame
lowers the utilisation and the clock further — the driver's-eye view on
time 87% of the time at native became 81% at 0.6. Rendering fewer pixels
did not make more frames on time, because pixels were not what the late
frames were waiting for. And the busy loop's dynamic run had collapsed
to the 0.40 floor on its first window for the same reason, overlapped
spans this time, while its throughput at 0.40 was worse than native's
(9.3 against 6.8 ms/frame: the scaler path costs more than it saves when
the GPU is already busy).

The paced loop can also say what the late frames were waiting for: a
late frame whose own GPU span fit inside the interval was not late for
its pixels. Driver's-eye, native, paced, two windows:

| window | on time | late, GPU-bound | late, waiting |
|---|---|---|---|
| 0–15 s | 90.9% | 11 | 71 |
| 15–30 s | 92.9% | 4 | 60 |

Nine in ten late frames had a GPU span that fit. They were waiting on
the CPU's encoding ahead of the commit, or on the GPU being busy with
another process's work — a window server was taking a third of a core
through every run in this section — and no render scale reaches either.
So the valve the plan relies on is closed by the signal it is given, and
would not have opened anything had it stayed open: it should step down
only for frames the GPU itself made late, and step back if a step bought
nothing. That is the next increment. What this one delivers is the
instrument that can tell.

## The valve, opened

The resolution controller had two faults the paced loop exposed. Its
target was two thirds of the interval — 11 ms at 60 Hz — so a frame
whose GPU span was 10.5 ms, on time by two milliseconds, sat at the
edge of "over budget" and any settling of the GPU's clock pushed it
over. And it assumed that fewer pixels always meant less time, which a
GPU that lowers its clock with its load does not honour: it stepped
down, measured the same span at fewer pixels, and stepped down again.

Two changes to `DynamicResolutionController`, neither large:

- The target is most of the interval — `target(forInterval:)` gives
  nine tenths, 15 ms at 60 Hz — the remainder being the CPU's share
  ahead of the commit. A span inside it is a frame on time.
- A step down is an experiment. The average before it is kept; after
  `judgementFrames` at the new level, a step that did not cut the
  average by `usefulStepFraction` is undone, and no further step is
  attempted for `holdFrames` (fifteen seconds at 60 Hz): the cost was
  not in the pixels, and measuring again sooner would only repeat the
  experiment. A step that did cut it is kept, as before.

The controller's older tests modelled the cost as a constant, which is
now precisely the case that gets reverted; they model it as
proportional to the scale where they mean "the pixels are the cost",
and three new tests pin the target, the reversion, and the keeping.

Paced at 60 Hz with dynamic resolution, alone on the machine:

| view | before: scale, on time | after: scale, on time |
|---|---|---|
| driver's-eye | 0.60 → 0.55, 80–82% | 1.00 held, 93–96% |
| circuit orbit | 0.75 → 0.60, 88–96% | 1.00 held, 92–95% |

Native throughout, and more frames on time than the fixed-native run of
the previous section (85–89%), the remaining late frames being nine in
ten "waiting" ones as before. The synchronous protocol, run for
continuity, held 6.6 ms at native for its two minutes with the
controller idle — where the morning's run of the same loop had read
9.3 ms and stepped to 0.75. The difference is the machine, not the
renderer: a browser that had held a third of a core through the
morning's runs was gone by evening (the window server's share was not
smaller — 47% of a core against 38%), and the late-but-fitting frames
had fallen with it. The document's earlier
frame totals were taken in the busier state, which is one more reason
to read them against each other and not as absolutes.

The valve still closes for the case it was built for. Under real
throttling the span grows with the pixels, the step cuts it, and the
step is kept; the thermal-ramp test is unchanged. What it no longer does
is give up sharpness to a clock.

## Clouds, and an overcast day

Section 5 of the plan put "a single scrolling cloud layer with parallax"
over the atmosphere, and the weather work since had a wet track and
rain under a sky that stayed clear. The layer is here now, and with it
the overcast day the memory of remaining items had been carrying.

One layer at 1,500 m, a four-octave value noise in a 2.2 km cell
drifting at 12 m/s, drawn in the sky pass where the view ray meets the
layer: the noise thresholded by a coverage — 0 clear, 1 covered — is
the cloud's density there, thinning toward the horizon where the layer
is seen edge-on. The coverage rides in the frame uniforms' spare lane
of the sun direction, so the sun disc is hidden by the cloud's density
along the sun's own direction — a gap shows it, a bank does not — and
the glare goes with it.

What the clouds are made of took two tries. The first lit their
undersides with the clear sky's zenith, which is dim and blue, and
every cloud came out near black: a storm, not an overcast. A cloud is
bright; most of the sunlight that falls on it comes out again,
diffused, and an overcast sky is a large grey lamp. The layer's light
seen from below is the sun's, scattered through it — two thirds of it
through a thin cloud, a quarter through a thick one — plus the
skylight; toward the sun the thin edges glow with forward scattering.

The scene under it changes in two places. `SunLighting.overcast(_:)`
gives the lighting of a covered sky — the sun to a fifth, so shadows
all but go, and the exposure opened by a stop and a third, as an eye
would — and the app and the render tool both apply it, so the sky pass
and the scene agree on how much sun there is. And the forward fragment
raises and greys the skylight the scene receives from the same coverage
lane, because the scene's ambient is the sky tables' spherical-harmonic
irradiance, not the lighting struct's flat term, and the tables describe
a clear sky: under cloud the diffuse light is the sun's, scattered,
and the larger part of what lights the road.

A session toggle, "Overcast", beside "Wet track" and "Rain"; rain covers
the sky as well now. The tool takes `--overcast C`. Tests: the coverage
lane and its clamp; the lighting helper's numbers; and a render whose
top third loses more than half its blue-over-red under full cover, with
half cover between — under identical lighting, since the opened
exposure would brighten the blue that remains and mask what the clouds
do — and repeats exactly.

Cost, native, alternated: the sky pass is part of "sky and forward
opaque", which rose by 0.0–0.4 ms with the layer drawn over a full sky;
the frame by 0.1–0.5 ms. The layer costs per sky pixel only.

## Rain on the glass

The last of the weather: from the driver's seat, in the rain, the
windscreen has drops on it. Only there — a chase camera has no glass,
and the app sets `ForwardRenderer.windscreenRain` for the driver preset
when it rains and for nothing else.

It is a screen-space effect at the resolve, ahead of the tonemap: three
layers of drops on grids down the frame — twelve, twenty-four and
fifty-six cells to the height — each cell holding a drop with a fifth
of a chance, placed anywhere in its cell by its hash, the two coarser
layers sliding down at their own pace with their cells sliding with
them so a drop keeps its shape as it falls. A drop is a lens: the
normal of a sphere cap bends the scene sample toward the drop's centre
by up to the drop's own radius, which turns the picture inside it
upside down as a real drop does, and the glass under it is lifted a
little where the drop scatters the light behind it. Units inside are
fractions of the frame's height, so a drop is round at any aspect.

The first version had every cell hold a drop and the centres on rows,
and refracted by a large fraction of the screen: a lattice of blobs
over a smeared picture. Sparseness, placement anywhere in the cell and
an offset bounded by the radius made it rain on glass.

Cost, driver's-eye at native: the resolve from 0.71 to 1.23 ms, the
frame by half a millisecond — three hashes and a square root per pixel,
paid only in the one view that asks. The tool takes `--windscreen R` to
put it in any view. The test: with the drops the frame differs, the
difference is confined to bent edges (the fixture's flat sky refracts
into itself), the mean brightness moves under 5% — refraction moves
light, it does not add it — the frame repeats exactly, and it is gone
when the amount is zero.

## Licensing

No third-party artwork is imported by this work. New render source is
GPL-2.0-only, consistent with the rest of the application. Generated material
sets authored by project code follow the project's CC BY-SA 4.0 default for new
non-code assets; see `ASSET_LICENSES.md`.
