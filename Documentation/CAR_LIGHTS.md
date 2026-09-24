# Original car lights and Metal rendering

The port now loads original car-light definitions, publishes brake/headlight
commands in immutable visual snapshots, and implements the original light
switching, world positions, billboard geometry and draw-time texture rotation.
Metal now submits these lights in the driving window and rear-view mirrors.
The Light preview adds visible, simulation-command-driven brake lights to the
selected 155-DTM. The earlier kernel report remains historical evidence; current
integration evidence belongs in `car-light-rendering-report.json`.

## Source behavior retained

TORCS `grInitCar` counts children in `Graphic Objects/Light` but reads numbered
paths `1...count`. Missing numbered paths receive defaults, even if differently
named children exist. Positions default to zero and size to 0.2. Head1/head2,
rear, brake and brake2 are mapped; unrecognized strings become unspecified.
Although the header contains reverse/rear2 constants, the original loader does
not map those names. The native loader preserves that distinction. More than
fourteen lights is rejected instead of overflowing the original fixed arrays.
Nonfinite configuration is rejected; finite zero and negative sizes are retained.

The original update clones each defined light, transforms its single stored
position by the published car matrix, and sets its on/off flag. Brake and brake2
use `brakeCmd > 0`; they do not depend on brake torque, wheel temperature or gear.
Head1/head2 use bits 1/2 of `lightCmd`; rear uses either bit. The default switch
branch retains the initially enabled flag. Hidden-current-car views remove the
light children entirely. Visible but switched-off lights remain one-point leaves
in the original scene graph. Their billboard quad is generated only when drawn.

`CarLightInstance` implements these state/transform rules. `DriverCommand` now
carries the original light bitmask, and `VehicleVisualSnapshot` publishes both
brake and light commands from the scheduled vehicle state. This is the current
command, including normal simulation control checking where that stage executes;
it is not an inferred pedal value. `DrivingContent.lights` parses the selected
car's definitions. Headlight input bindings are not yet exposed.

The draw function extracts camera right/up from the model-view matrix and
constructs four corners in original A/B/D/C triangle-strip order. Its color is
(0.8, 0.8, 0.8, 0.75), with no lighting, no culling, no depth writes and original
polygon offset slope −15 / units −20. Texture coordinates are (0,0), (0,1), (1,0),
(1,1). The texture matrix rotates about (0.5,0.5) by
`Float(rand()) / Float(RAND_MAX) * 45` degrees. This differs from the random
normalization used by physics and by the Fly camera.

`CarLightGeometry` preserves the arithmetic, including Double factor/Float size
in vertex construction and Float trigonometry in the original PLIB rotation.
`CarLightDrawing` owns a presentation-only Darwin-compatible stream. An enabled
draw consumes one random value; switched-off lights consume none. The caller must
invoke it after visibility and culling. Failed native validation rolls back the
stream, and no simulation RNG is accessed. This deliberately isolates rendering
randomness from physics; it does not reproduce global libc RNG coupling between
original graphics and simulation or promise other-platform libc sequences.

## Reference adapter and checks

Unmodified grcarlight.cpp and grcarlight.h are pinned to the existing TORCS 1.3.9
archive with their original Christophe Guionneau notices. The provenance verifier
checks byte-exact configuration, constants, update and full draw-function excerpts.
Test-only storage adapters execute original update logic and capture the original
GL calls. Texture-matrix calls are composed using original PLIB matrix routines;
this is not an original OpenGL driver or a pixel oracle. The wrapper supplies
explicit random integers to the draw function, separately checking the native
stream against this host's libc `rand`.

- 15 XML fixtures, including the selected 155-DTM and numbered/default edge cases:
  29 light definitions match original configuration values exactly.
- 1,008 type/command/visibility cases: original child count, enablement and
  transformed world positions match exactly, including NaN brake comparison.
- 2,400 billboard cases: all 28,800 vertex scalars, texture matrices, UVs and
  colors match exactly. Captured calls verify depth-write disable/restore,
  polygon offset/reset, one random draw and texture-matrix reset.
- 8,000 native random draws across four seeds match original angle values exactly.
  Disabled lights and rejected draw inputs do not advance the native stream.
- 2,000 native physics ticks publish the current commands. Evaluating visible
  lights for 800 draws leaves compared body positions/velocities, engine speed,
  physics RNG state and draw counts unchanged against a parallel native run.
  This isolation check is not a new whole-physics reference-parity claim.

At the kernel milestone, the full debug suite passed 252 tests. All 29 selected light, vehicle, control,
input, runtime and brake tests pass in release and under Address Sanitizer. The
release native binary has no direct C++ runtime or Expat dependency. Rerunning
the native brake diagnostic produces the same 24 image hashes and all records
as the prior packaged preview, with 24 exact immediate repeat pairs. Renderer,
shader, Brake preview binary and camera preferences retain their recorded hashes.

Machine-readable test/build/provenance evidence is recorded in
`car-light-kernel-report.json`. No new light artwork is imported or redistributed.

## Metal integration

The selected session prepares the original `breaklight2.rgb` as a single-level
texture. All five original texture names are supported by the renderer. Textures
with identical pixel data share one GPU allocation. Existing version-1 sessions
without a `lightTextures` dictionary remain readable and display no light quads.
The preparation script now records the shared light texture's source and hash in
`local-light-sources.json`. Its per-file artwork terms remain unresolved: the
texture and compiled cache stay local and are not bundled in the application.

Each visible light is culled using its world-space point and the original PLIB
perspective frustum. Lights retain car/light initialization order. Mirrors prepare
first and exclude their current car, while retaining other cars' lights. Each
prepared view retains its random angle for immediate repeated captures. Publishing
a new frame clears the prepared views; resetting the explicit presentation stream
is reserved for independent diagnostic runs. Physics randomness remains separate.

Quads draw in the existing scene render pass with source-alpha blending, depth
reads, no depth writes, no face culling and the original polygon offset. The
shader applies original color modulation and the existing track fog. Clamping UVs
to [0,1] before a linear transparent-border sample reproduces GL_CLAMP's edge blend;
clamp-to-edge alone would incorrectly smear the rim. No mipmaps, extra render
pass, framebuffer bloom or per-frame texture upload is added. Both classic and
optional 4× MSAA rendering use this path.

The light group follows track translucency and the shadow group, and precedes
car translucency. The subsequent draw-order increment replaces the former global
mesh sort with original anchor and whole-car traversal order; see DRAW_ORDER.md.
Original light state leaves alpha testing inherited. ALPHA_STATE.md now covers
that integration: the shader compares texture alpha multiplied by 0.75 against
the state left by preceding visible draws. Full original frustum/LOD selection
and other inherited state still need broader content validation. These checks
are not original OpenGL pixel parity.

Fly scene-height assembly includes visible lights as one-point leaves, including
lights switched off. Their bounds participate in ancestor growth. They intersect
no triangles, but the original PLIB diagnostic adds `vertexCount - 2`, or -1, for
a surviving one-point strip; the native diagnostic preserves this quirk. The
public physical triangle count remains zero. Hidden-current-car views remove the
light leaves. Other generated geometry and full scene/LOD coverage remain open.

## Capture and checks

Prepare a new local session with `Scripts/prepare-driving-session.py`, open it via
**File → Open Driving Session…**, then choose a rear-facing chase view and brake.
The new local preview is `build/TORCSLightPreview.app`. Headlight bindings and
additional cars' light artwork still need integration; the selected 155-DTM
configuration contains two brake2 lights.

```sh
build/TORCSLightPreview.app/Contents/MacOS/TORCSMac --car-light-visual-test Artifacts/driving-light-prepared Artifacts/new-light-capture
build/TORCSLightPreview.app/Contents/MacOS/TORCSMac --car-light-benchmark Artifacts/driving-light-prepared Artifacts/new-light-benchmark
```

The capture advances actual native physics for 1,800 throttle ticks and then 100
braking ticks. It compares enabled/omitted lights in chase, rear inspection and
Driver/mirror views at both quality settings: 24 images and 24 exact immediate
repeat pairs. Released commands change no pixels; braking visibly changes the
rear lights. The inspection view is diagnostic, not an additional camera preset.

Five additional tests compare 10,290 point-frustum boundary cases and 165 light
height queries against original PLIB. GPU checks cover ordered alpha blending,
body occlusion, no depth writes, border sampling and original modulation, current
car exclusions and visible other-car mirror lights. Repeated submissions preserve
pixel bytes, command digests and random draw counts. Original geometry/configuration
and physics-publication checks remain covered by the earlier six light tests.

The full debug suite passes 257 tests; all 31 selected light, Fly-height, brake,
shadow, mirror and raster tests pass in release and under Address Sanitizer.
Four release capture processes (including Metal API/GPU validation and the
benchmark) agree on all 24 images and metadata, each with 24 exact immediate
repeat pairs. Two debug processes agree separately. Release braking changes
50,903 channels across the enabled/omitted comparisons; released lights change
zero. The earlier 24 brake images and all their records remain unchanged.

The new Fly and TV diagnostics each retain all 24 earlier image hashes and
camera/physics records. In two scripted three-car runs, all 80 images repeat,
12 target-switch records remain unchanged, and eight TV images change from the
newly visible lights. Six lights share one texture; mirror draw counts retain
other-car lights, with dedicated GPU fixtures verifying their visible pixels.

The selected light scenario is not pixel-identical between debug and release,
including omitted-light controls. A separate probe using the same compiled
modules and inputs finds maximum body-position differences of 0.00006103515625 m
at ticks 1,800 and 1,900, plus camera-matrix and wheel-spin differences. This does
not identify the first divergent arithmetic operation or establish a new physics
regression. Pixel and state differences are recorded without claiming cross-build
identity or assigning all differences to one cause.

On the M2 host, stationary 960×640 chase-view medians were:

| Mode | GPU lights omitted | GPU lights enabled | Added GPU time | Offscreen wall omitted / enabled |
|---|---:|---:|---:|---:|
| Classic | 0.6394 ms | 0.6439 ms | 0.0045 ms | 4.4779 / 4.5216 ms |
| 4× MSAA/filtering | 0.7780 ms | 0.7885 ms | 0.0105 ms | 4.5798 / 4.5937 ms |

Each mode uses 60 interleaved samples after ten warmups. The two visible lights
add two draws and four triangles in the existing pass. Measurements exclude
simulation and file IO; they are a bounded rendering-cost check, not a whole-race
FPS claim. Full timings, source hashes and evidence are retained in
`car-light-rendering-report.json`.

The full port goal remains open, including native AI, complete race modes,
audio, replay, broader content, profiling and distribution.
