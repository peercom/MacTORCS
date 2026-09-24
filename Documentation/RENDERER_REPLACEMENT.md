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

## Licensing

No third-party artwork is imported by this work. New render source is
GPL-2.0-only, consistent with the rest of the application. Generated material
sets authored by project code follow the project's CC BY-SA 4.0 default for new
non-code assets; see `ASSET_LICENSES.md`.
