# Compiled scenes and Metal inspection

The native application can now display original ACC mesh geometry through Metal,
using compiled mesh and texture caches. **File → Open Compiled Scene…** opens a
folder containing `scene.json`; the inspector supports orbit, zoom and framing.
The existing component lab remains the default window. These inspection scenes
are not a playable race, and visual equivalence with the original renderer is not
claimed.

## Compile and open

```sh
swift build -c release
mkdir -p Artifacts/scenes
.build/release/torcs-assetc --scene Tests/UnitTests/Fixtures/Artwork/155-DTM/155-DTM.acc Artifacts/scenes/car --car
Scripts/build-app.sh
open build/TORCSMac.app
```

Choose `Artifacts/scenes/car` in the File menu. Drag or use arrow keys to orbit, scroll or use +/−
to zoom, and double-click or press R to frame the model. Loading reads binary
caches on a background task; geometry preparation, shader/pipeline creation and
texture upload happen before drawing. Draw callbacks do not read files or parse
AC/PNG/SGI. Inspector camera state is presentation-only and cannot alter physics.

Aalborg additionally references five shared concrete/pylon textures not imported
into this repository. To inspect the full mesh locally, supply an extracted
upstream directory explicitly:

```sh
.build/release/torcs-assetc --scene Tests/UnitTests/Fixtures/Artwork/aalborg/aalborg.acc Artifacts/scenes/track --texture-root /path/to/torcs-1.3.9/data/data/textures
build/TORCSMac.app/Contents/MacOS/TORCSMac --scene-smoke-test Artifacts/scenes/track Artifacts/track.png
python3 Scripts/verify-scenes.py /path/to/torcs-1.3.9
```

The smoke command renders real geometry twice, compares readback bytes, checks
non-background coverage and saves a PNG. The current comparison reports every
changed channel and permits a maximum one-byte-value difference in at most 0.01%
of channels; close vehicle/glass views exposed sparse rounding differences. Checksums describe the tested host;
they are not portable GPU golden images or original TORCS screenshots.

## Cache package contract

`scene.json` version 1 names one compiled model and maps every referenced texture
name to a compiled texture cache. `--texture-root` can be repeated; model-directory
lookup precedes the explicit additional roots. All dependencies must resolve.
Missing content is diagnosed; no substitute artwork is silently generated.
Intentional absent texture layers use white as the multiplication identity.

Compilation writes a new sibling staging directory, validates the complete result
and renames it into place. Existing output directories are rejected, including
repeated compilation to the same destination. Mesh/cache hashes and original
texture names survive loading. Relative references and symlinks remain contained
within their explicitly selected roots. The index is limited to 1 MiB / 4,096
textures; total texture cache data is limited to 512 MiB. Existing individual
mesh and texture cache limits still apply. This is an inspection package, not the
planned transactional user content installer, and is not a redistribution license.
Original artwork notices and source/provenance must accompany distributed derivatives.

## Rendering behavior and evidence

SceneGeometry composes the cached column-major hierarchy into world transforms,
retains normals/UVs/materials, and expands the original triangle, fan and separate
strip batches into index buffers. It rejects line primitives and singular or
non-affine transforms rather than assigning speculative rendering behavior.
Culling preserves mesh state. Normals use inverse-transpose transforms. GPU tests
check bottom-first source texture orientation, layer modulation, depth occlusion,
both culling modes, alpha discard, alpha blending and material emission.

The initial shader uses smooth vertex lighting, material color and emission,
separate specular, repeating trilinear sampling and up to three track MODULATE
layers. The sampled texture data and render target are unorm; no extra implicit
sRGB conversion is introduced. Base texture enable, blend, alpha-test/clamp and
translucency flags come from the reference-tested parser. Alpha setter metadata
preserves inheritance independently from explicit enable/disable; the binary ACC
cache reconstructs it without changing existing payloads. See ALPHA_STATE.md. Translucent batches render after opaque traversal, retaining original anchor
and per-car child order. Whole cars sort by horizontal camera distance, with
independent mirror ordering. Ordinary translucent meshes retain depth writes, as in SSG; the frame uses
LEQUAL. Shadows and car lights temporarily disable writes in their own paths. See DRAW_ORDER.md for the original queue checks and remaining scope.

Original source inspected: `grvtxtable.cpp` draw/array/multitexture paths,
`grmultitexstate.cpp`, `grscene.cpp` lighting, and PLIB `ssgSimpleState.cxx`.
The test oracle calls the already pinned original PLIB `sgMultMat4` and
`sgXformPnt3`; native world vertices are not fed into the oracle. Three selected
models and 16 authored nested-transform scenes compare 18,194 vertices. Maximum
observed absolute error in debug, release and AddressSanitizer tests is 0.00000190735 world units;
SIMD evaluation order need not be bit-identical to scalar PLIB.

## Remaining integration

The inspector loads one model package at a time. The renderer also supports
multiple resources and dynamic instances; an assembled diagnostic places the
car and four wheels on Aalborg using immutable physics snapshots. Wheel placement,
scaling and speed selection now have original graphics comparisons. See
VEHICLE_PRESENTATION.md. Native keyboard driving and the original very-near chase
camera are now integrated; see DRIVING_SESSION.md. Other camera modes remain open. Car environment reflections/projected shadows are
explicitly reported as missing. Track-specific light/fog settings, sky, shadows,
effects, HUD, mirrors, MSAA, exact material/raster parity and performance profiling
remain open. Normalless geometry uses an explicit `(0,0,1)` normal with a warning;
it does not reproduce inherited legacy GL normal state. No full renderer or
first-playable milestone is marked complete by this increment.

The initial scene-inspector increment passed all 149 debug/release tests and
24 selected AddressSanitizer tests. Three scene packages compile reproducibly in separate processes and
render repeatably on the tested Metal device. Native UI checks cover opening and
switching models, drag and keyboard orbit, bounded zoom and framing; the Metal
view exposes its role and keyboard help through accessibility. The existing
component-render checksum and 29-texture GPU transfer checks still pass.
See `scene-rendering-report.json` for source hashes, counts and limits.

Prepared driving sessions now supply original track lighting, background geometry
and linear fog through the same renderer. Inspector scenes continue to use
generic lighting. See [TRACK_ENVIRONMENT.md](TRACK_ENVIRONMENT.md); the additional
configuration, sky geometry, PNG and GPU checks do not establish whole-scene
raster parity.
