# Track shadows on cars

The native renderer now applies TORCS's baked track-shadow map to indexed car
meshes, completing the selected four-texture car path: body texture, scrolling
reflection, yaw-dependent environment shading and projected track shadow.
This restores car shading under the original track's trees and structures.
It is distinct from the existing shadow cast by the car onto the road.

`shadow2.rgb` uses the original fourth ACC UV set and texture matrix `T × R × S`.
Translation comes from car world XY relative to raw track-model bounds. Rotation
uses car yaw; scale uses the car loader's extent ratios. Only indexed meshes with
map level ≤ −3 receive this optional layer. RGBA modulation happens before the
existing separate-specular addition, alpha rejection, blending and fog.
There is no extra draw call, render pass or dynamic shadow-map generation.

## Original initialization behavior

The loader bounds include every declared vertex before node transformations or
surface selection. They are not the rendered scene's world-space bounds. The
native parser now preserves these values in mesh cache version 2. Version-1
caches remain readable, retain their old cache identity and expose absent bounds.
Older prepared sessions keep their previous appearance; recompilation supplies
the additional projection metadata.

TORCS records `grCarInfo.sx/sy` after initializing all four wheels. With detailed
wheel models enabled, each wheel loads speed meshes 0–3, and the final successful
wheel load replaces the global loader ratio. The selected prepared session uses
all four detailed speed meshes, so it deliberately uses `wheel3` bounds:

| Selected scale | X | Y |
|---|---:|---:|
| Original detailed-wheel result | 0.0011722443 | 0.0012535454 |
| Body-only ratio, used with simple wheels | 0.0056255655 | 0.0024068072 |

Changing to the body ratio would alter original behavior. The reference adapter
executes the byte-verified original nested wheel-load loops and subsequent scale
assignment: detailed mode performs 16 loads; simple mode performs none. Distinct
synthetic speed-model ratios also verify that the final load wins. Scene
loading itself is captured with supplied ratios. Missing-model fallback and a
full original graphics initialization are outside this adapter's scope.

## Evidence

- Original parser bounds match for the body, track, all four wheel models and an
  authored case containing an extreme unreferenced vertex. Existing 160 authored
  parser cases also compare raw bounds against the original.
- 2,000 projected texture matrices / 16,000 coefficients match the original
  exactly. The original texture-matrix block executes through headless capture
  adapters and original PLIB mathematics.
- GPU fixtures exercise indexed/nonindexed and map-level gates, both translation
  axes, nonuniform scale with rotation, missing textures, disabling and alpha
  cutoff. Invalid bounds and nonfinite positions are rejected.
- Cache checks preserve v1 readability, distinguish cache identities, round-trip
  new bounds and reject corrupt or structurally invalid bounds.
- The pinned-car repeat test covers four views × 30 repeats × three modes:
  maps off, two environment maps and all three environment maps. All 360 repeats
  have zero changed channels in debug, release and Address Sanitizer builds.
- 33 relevant asset/graphics/presentation tests pass in debug, release and under
  Address Sanitizer. The current inventory is 193; this increment did not rerun
  the complete suite. Evidence is recorded in `car-track-shadows-report.json`.
- Two fresh packaged runs produce identical hashes for all 28 saved frames.
  All 20 camera pairs and the additional shaded-road repeat pass with zero
  changed channels. Metal API and GPU shader validation also pass without a
  reported fault; instrumented timings are excluded from performance claims.

The usual starting position is sunlit, so projection on/off correctly produces
identical output there. A separate diagnostic samples 1,492 road positions,
settles native vehicle physics at distance 408.69998 m, and renders projection
off/on. It changes 247,172 channels in the shaded-road view. This is a settled
rendering witness, not evidence of a completed driving lap.

Original GL screenshot equality, other car/track combinations, missing detailed
models, scene-wide dynamic shadows and other Apple GPU families remain unverified.

## Cost and resource reuse

The 960 × 640 stationary single-car diagnostic interleaves 60 samples per mode
after ten warmups. GPU medians for the additional track projection are:

| Fresh run | Projection off | Projection on | Difference |
|---|---:|---:|---:|
| First | 0.6357 ms | 0.6449 ms | +0.0092 ms |
| Second | 0.6408 ms | 0.6456 ms | +0.0048 ms |

The scene is sunlit during these timings; the extra texture lookup and coordinate
transform still execute. Optional 4× filtering with all maps measured
0.6806–0.6931 ms. GPU p95 values remain noisy, around 1.84–1.91 ms for classic
projection. These are offscreen command measurements, not gameplay FPS or a
multi-car performance guarantee.

The renderer now shares scene textures by actual mip layout and byte contents.
It does not trust supplied cache identity strings. The selected content has 35
texture references and 32 distinct GPU textures: sharing removes 8,388,612 bytes
of duplicate RGBA mip payload, mainly wheel artwork. Reusing the already-loaded
track shadow instead of uploading it again avoids another 4,194,304 bytes.
Together this avoids about 12 MiB of duplicate pixel payload. These are calculated
payload sizes, not measured driver allocation sizes or process RSS. External
replacement environment textures are not retained in the scene cache indefinitely.
The original sunlit image hashes remain unchanged after this resource sharing.

## Local preview

Use `build/TORCSTrackShadowPreview.app`, then **File → Open Driving Session…**
and select `Artifacts/driving-track-shadow-session`. The bundle is ad-hoc signed
and checked offscreen; a new interactive driving acceptance run was not performed.
The **Car shadow** toggle continues to control the shadow beneath the car; track
projection follows the original baked track artwork.

Prepared content reuses the existing licensed Aalborg `shadow2.rgb` cache.
No additional original artwork or source file was imported. The seven shared
track/environment images identified earlier remain local-only pending attribution;
the app and repository still exclude those images and prepared content.

The overall port remains incomplete. Next visual work includes rear-view mirrors,
remaining camera families and other original effects, plus measured optional
edge smoothing. Full race modes, native robots, audio, replay, content coverage,
performance acceptance and distribution remain open. Physical controller
validation stays behind the user's camera and visual priorities.
