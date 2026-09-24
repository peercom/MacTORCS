# Optional edge smoothing

**Smooth edges** enables 4× multisample antialiasing for the main scene and
rear-view mirror. It improves geometric edges on cars and track objects. Classic
single-sample rendering remains the default, and switching it back on restores
the original native output. This is an optional visual enhancement, not a change
to TORCS simulation or a claim of matching the original OpenGL rasterizer.

TORCS 1.3.9 already requests a multisample visual in its optional "best" GLUT
video-initialization path, with fallbacks when unavailable. This native feature
restores an explicit antialiasing choice; it does not claim that upstream TORCS
could never antialias. The original screen.cpp was inspected against the pinned
release archive without importing another source file. Its selected visual,
sample pattern and GL resolve are not reproduced as a pixel-parity oracle.

Both sample-count variants of all seven pipelines are prepared when the renderer
loads: the four material blend/alpha-test combinations, sky, ground shadow and
mirror composition. Toggling the option does not compile shaders or upload scene
geometry/textures again. Color and depth targets are reused at each drawable size
and are separate for the main view and the mirror. There are no added scene draw
calls or render passes; Metal resolves the samples when each existing pass ends.

On supported Apple GPUs, transient multisample color/depth attachments use
memoryless storage and discard their samples after the color resolve. Other
supported GPUs use private storage. A device without 4× sample support disables
the UI option and retains classic rendering. This follows Apple's documented
[MSAA and memoryless-target approach](https://developer.apple.com/documentation/metal/improving-edge-rendering-quality-with-multisample-antialiasing-msaa)
and [resolve store action](https://developer.apple.com/documentation/metal/mtlstoreaction/multisampleresolve).
No custom compute resolve or additional image-filter shader is introduced.

## Quality scope

A GPU triangle fixture is compared against an independent analytic reference
that clips the triangle to every pixel and calculates its exact area. At 64 × 64,
summed squared coverage error falls from 12.23446 to 1.70198 (86.1% lower), with
115 partially covered pixels. Fully covered/uncovered pixel values are unchanged.
This quantifies one authored geometric edge case, not a perceptual quality score
for all content.

The existing alpha-test thresholds, blending, depth rules, lighting, fog and
textures are preserved. No alpha-to-coverage is enabled: geometry MSAA does not
solve aliasing inside cutout foliage textures or replace anisotropic road-texture
filtering. Those are separate quality questions.

Tests also cover all four material variants, twelve cutoff/blend cases, mirror
composition, odd-size resizing, target reuse and classic-output restoration.
The pinned car regression now repeats four views with three map combinations
under both sample counts, totaling 720 repeated renders per tested build.
Packaged full-scene comparisons, measured GPU costs and exact validation scope
are recorded in `edge-smoothing-report.json`.

Thirty-six selected graphics/presentation tests pass in debug, release and
Address Sanitizer. All 720 car repeats have zero changed channels. The current
test inventory is 203; this increment did not rerun the complete suite.

Two fresh packaged processes match all 76 saved image hashes. The 54 camera
repeat pairs (27 cameras × two sample counts) have zero changed channels. All
42 frames from the preceding mirror preview are unchanged with smoothing off.
The smoothing diagnostic also checks 16 repeats, including Driver with its
mirror, an odd-sized window and exact restoration after resizing.

Metal API and GPU shader validation report no faults. All 76 instrumented image
hashes match the two normal runs. The packaged Metal smoke checksum is 1103027.
Native UI checks verify paused off/on redraw in Chase and Driver, the mirror,
combined anisotropic filtering, and window enlargement/restoration. The controls
fit the normal minimum window size. Classic controls and window size were
restored before quitting the test app; simulation time remained 0.00 s.
This is paused UI integration evidence, not driving or frame-pacing acceptance.

## Measured cost

At 960 × 640 on the tested Apple M2, each process interleaves 60 measured off/on
samples after ten warmups per mode. Median GPU command durations across the two
fresh runs are:

| View | Classic | Smooth edges | Added GPU time |
|---|---:|---:|---:|
| Chase | 0.6425–0.6447 ms | 0.7490–0.7526 ms | 0.1043–0.1101 ms |
| Side 3 | 0.5977–0.5995 ms | 0.6990–0.7001 ms | 0.1006–0.1012 ms |
| Driver with mirror | 1.0660–1.0738 ms | 1.1617–1.1647 ms | 0.0909–0.0957 ms |

This bounded cost supports retaining the feature as an optional quality setting.
It is not a gameplay FPS guarantee. GPU p95 measurements are noisier (roughly
2.0–3.2 ms across these runs/modes); the machine-readable report retains them.
Metal validation timings are excluded. The multisample attachments use
memoryless storage on this host; this is not a measurement of total renderer RSS.

## Local preview and remaining work

Use `build/TORCSSmoothingPreview.app`, open the prepared
`Artifacts/driving-track-shadow-session`, then enable **Smooth edges**. It is
independent of **Sharper road textures**, the existing optional 4× anisotropic
filtering control. Prepared content is not bundled with the preview.

Performance evidence is limited to selected stationary offscreen views on the
tested Apple M2. Gameplay frame pacing, traffic, other content/GPU families,
long-running memory behavior and complete scene-wide shadow/effect coverage
remain open. The full port still requires complete races, native robots, audio,
replay and distribution acceptance. Physical controller validation remains behind
the user's visual priorities.
