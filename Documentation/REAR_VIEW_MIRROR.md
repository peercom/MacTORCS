# Rear-view mirror

The driver, bonnet and road views now offer TORCS's rear-view mirror, enabled by
default and controlled by the native **Rear-view mirror** toggle. Other camera
families disable the toggle, preserving the original mirror-allowed flags.

The rear camera starts at the configured bonnet position and looks 30 m backward
in car coordinates. Its up direction follows body roll. The default field of
view is 90° divided by the full-screen aspect ratio, with near/far planes of
0.3/300 m and fog from 200 to 300 m. These distances use the default FOV factor of
one, as do the existing native camera presets; graphics preference and track
FOV-factor overrides remain pending.

The mirror is a horizontally reversed center crop of that full-screen camera,
not a camera stretched to the mirror's aspect ratio. Original integer pixel
rounding determines the half-width, one-sixth-height crop and its placement near
the top of the screen. The current car, its wheels and its ground shadow are
excluded from the rear view. Other supplied scene instances remain visible.

## Native rendering

One additional scene pass renders directly into a crop-sized private color and
depth target using a translated full-screen viewport. A four-vertex overlay in
the main pass reverses the image horizontally and copies RGB with opaque alpha,
without relighting or applying fog a second time. Scene buffers, textures and
material pipelines are shared. Targets are reused until their pixel dimensions
change. This avoids the original framebuffer-copy operation and its power-of-two
texture padding while preserving the sampled crop and orientation.

At 960 × 640, the two 480 × 106 targets contain 407,040 bytes of pixel payload
combined (RGBA8 plus depth32). This excludes driver allocation overhead and is
not measured process memory. Mirroring adds geometry submission for the rear
view; it is not a free overlay. It does not alter simulation state or timing.

## Reference boundary and tests

Four verbatim excerpts from already-pinned grcam.h, grcam.cpp and grscreen.cpp
execute the original mirror class, methods, factory and layout through headless
GL-call capture. The provenance script verifies their bytes. The adapter records
viewport/scissor, copy source, display vertices and texture coordinates. GL
allocation is stubbed, and a floor-power helper supplies the texture sizing
input; legacy power-of-two allocation behavior is not claimed as tested. No
additional source file or artwork was imported.

- 1,200 poses and window sizes compare the original eye/target/up, projection,
  fog, flags, crop, placement and horizontal reversal. The selected pose and
  rectangle comparisons have zero observed error in all tested builds.
- GPU fixtures compare the native mirror to the horizontally reversed crop of
  an independently rendered full-size rear camera at three sizes, including odd
  dimensions and doubled dimensions. They also check that pixels outside the
  overlay stay unchanged, current-car instances are excluded, and disabling the
  mirror restores the main image.
- Fifteen repeated fixture frames remain identical. Targets are reused across
  repeats and adjacent odd/even sizes with equal crop dimensions.
- A separate fixture verifies that the player's shadow remains visible in the
  main camera and is absent from the mirror.
- Thirty-three selected graphics/presentation tests pass in debug, release and
  Address Sanitizer. The inventory is 200; this increment does not claim a new
  complete-suite run.
- Fresh packaged runs match all 42 saved image hashes, including mirror on/off
  for all three supported views and an odd-sized driver view. All 35 images from
  the previous survey-camera preview are unchanged. Sixteen mirror repeat pairs
  pass and resizing back restores the original image exactly.
- Metal API and GPU shader validation report no faults; all 42 instrumented
  image hashes match the normal runs. The packaged Metal smoke checksum is
  1103027.

The native-window check found and fixed a paused redraw problem: changing the
camera updated its picker without refreshing the Metal image. Camera, shadow,
mirror and filtering values now invalidate the representable explicitly, and a
paused update requests a draw. The rebuilt release app was checked through the
native controls: Driver selection, mirror off/on and window enlargement/restoration
all redraw correctly while simulation time remains 0.00 s. Three mirror tests
were rerun in release after this UI-only fix. This is paused UI integration
evidence, not a completed driving-lap or frame-pacing acceptance run.

Packaged scene results, measured costs and build configurations are recorded in
`rear-view-mirror-report.json`. Numerical/capture parity does not establish pixel
equality with TORCS's original OpenGL output. Multicar driving, other content,
other GPUs and long-running resize/memory behavior still need acceptance work.
Extremely narrow views with aspect ratio at or below 1:2 are rejected because
the original formula reaches or exceeds a 180° perspective field of view; the
native driving window's minimum size stays outside that range.

## Measured cost

The diagnostic interleaves 60 measured mirror-off/on samples per view after ten
warmups, on an Apple M2 at 960 × 640. A clean follow-up process measured:

| View | Mirror off | Mirror on | Added GPU time |
|---|---:|---:|---:|
| Bonnet | 0.6162 ms | 1.0255 ms | 0.4093 ms |
| Road | 0.5501 ms | 0.9399 ms | 0.3897 ms |
| Driver | 0.6697 ms | 1.0651 ms | 0.3954 ms |

These are GPU command medians, not gameplay FPS. The first run was noisier:
mirror-on medians were 1.8843/0.9451/1.1470 ms for Bonnet/Road/Driver, including
a 3.5513 ms bonnet p95. The clean follow-up p95 values were 2.3187/1.1761/1.8514 ms.
The report retains all samples' summaries rather than claiming a guaranteed
0.4 ms cost. A second process confirms image stability, but its timings are
excluded from this table because the short Metal smoke check ran concurrently.
Metal validation timings are also excluded. Multicar races and interactive frame
pacing remain to be profiled.

## Local preview

Use `build/TORCSMirrorPreview.app`, open `Artifacts/driving-track-shadow-session`
through **File → Open Driving Session…**, then choose Driver, Bonnet or Road.
The app bundle excludes prepared local-only content. Shared artwork attribution
and full distribution acceptance remain open.

The next visual work is the remaining camera families, measured optional edge
smoothing and original effects/shadow coverage. Physical controller validation
remains behind the user's visual priorities. Complete race modes, native robots,
audio, replay and broader content support are still required by the full goal.
