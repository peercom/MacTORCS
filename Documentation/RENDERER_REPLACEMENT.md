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

## Licensing

No third-party artwork is imported by this work. New render source is
GPL-2.0-only, consistent with the rest of the application. Generated material
sets authored by project code follow the project's CC BY-SA 4.0 default for new
non-code assets; see `ASSET_LICENSES.md`.
