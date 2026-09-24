# Asset pipeline

TORCSAssets now parses uncompressed AC/ACC scenes and compiles a versioned binary
mesh cache. The native `torcs-assetc` executable and cache reader require no C++,
PLIB, OpenGL or upstream installation. SGI/PNG image decoding, mip caches and Metal texture upload are available. A
transactional content importer and complete race-scene rendering remain unfinished.
Single-model Metal inspection now loads compiled packages; see SCENE_RENDERING.md.

## Measured parser compatibility

The unchanged TORCS 1.3.9 `grloadac.cpp` executes in CReference using project-owned
scene-storage adapters. Tests capture its scene graph before SSG flatten/stripify,
texture decoding or any graphics call. Original PLIB vector/normal arithmetic
and case-insensitive token comparison remain in the reference. The adapters
retain constructor arrays, transforms, names, explicit render states and indices;
they do not substitute native parser output or invent rendered reference images.

The selected original 155-DTM and Aalborg ACC files compare exactly: 2,996 scene
nodes, 1,333 mesh batches and 313,728 floating-point fields, with integer indices,
names, hierarchy, culling and texture paths compared separately. Eighty authored
cases cover five primitive modes, explicit/generated normals, car/window states,
material changes, transforms, UV repeat/offset and one through four texture units.
Another case checks case-insensitive record tags, absent texture layers and the
original acceptance of EOF before all declared children. Aalborg requires that
last compatibility rule; native loading emits a warning for the short child list.
See `asset-loader-parity-report.json` for reproducible evidence and build scope.

Preserved details include AC-to-TORCS `(x, y, z) -> (x, -z, y)`, original matrix
ordering, `rot` clearing prior translation, group callback scopes, DRIVER/TKMN
name handling, multiple UV layers, last-reference UV values for indexed vertices,
16-bit legacy index narrowing and last-surface material/culling in strip batches.
Strip winding resets at each batch and degenerate triangles are retained. The
cache preserves line-loop/line-strip records; triangle conversion diagnoses them
because they need a separate rendering pipeline.

The selected meshes declare 4,032 / 13,577 vertices and 352 / 1,556 surfaces.
Their two compiled caches total 1,611,889 bytes and yield 18,003 triangles including
degenerates. This is parser and buffer evidence, not visual parity with the original
renderer. `selected-asset-inventory.json` records the earlier source inventory.

## Compilation and cache

```sh
swift build -c release
mkdir -p Artifacts
.build/release/torcs-assetc Tests/UnitTests/Fixtures/Artwork/155-DTM/155-DTM.acc Artifacts/155-DTM.torcsmesh --car
.build/release/torcs-assetc Tests/UnitTests/Fixtures/Artwork/aalborg/aalborg.acc Artifacts/aalborg.torcsmesh
python3 Scripts/verify-assets.py
```

`--texture-units 1…4` defaults to four. Car mode preserves the original car map
selection. Current mesh cache version 2 corresponds to compiler `torcs-ac-swift-2`
and retains raw loader XY bounds, including unreferenced vertices before transforms.
Version-1 meshes remain readable with absent bounds and their original cache identity;
recompilation enables track shadow projection onto cars. Changing compiler semantics
requires a version bump. Cache identity includes source SHA-256,
version and every compilation setting. The little-endian payload preserves Float
bit patterns, hierarchy, all four UV/state arrays, indices, strip lengths and
compatibility warnings. A SHA-256 over source/settings and payload detects
corruption; it is not a publisher signature. Runtime callers can require the
expected source hash and options. The decoder validates topology, buffer shapes,
finite fields, indices, path safety and counts before returning a scene.

The compiler reads at most 64 MiB, validates and round-trips its output before an
atomic write, and rejects overwriting its own source path. CLI checks compile
the body, track and four wheel fixtures twice in separate processes and verify that invalid or excessive
inputs leave an existing destination intact. This explicit destination compiler
is not yet a content installer with conflict resolution.

Parser limits include 100,000 nodes, 1,000 materials, two million declared
vertices, eight million references, depth 128 and 4,096 bytes per text line.
Cache decoding is capped at 256 MiB with bounded counts. Unsupported records,
nonfinite geometry, unsafe texture paths and undefined original mixed-normal or
unwritten indexed-UV storage produce diagnostics. Invalid/truncated-input tests
run against native code; arbitrary malformed content is never fed to legacy C++.
These checks do not establish exhaustive fuzz coverage or bounded total RSS.

## Imported content and remaining work

Six unchanged meshes, 27 SGI textures, two PNG textures and three directory notices are imported
as test fixtures. The per-file manifest and ASSET_LICENSES.md retain Free Art
terms, authors, hashes and original access. Derived caches retain those artwork
terms and must travel with the corresponding notices/provenance when distributed;
compilation does not relicense content. No cache is shipped in the current app.

Shared textures without precise per-file license evidence remain excluded. The
four `trb1-3` speed-dependent wheel meshes now match original car-mode loading
and compile into caches. The assembled diagnostic now attaches and animates
them from physics snapshots; see VEHICLE_PRESENTATION.md. Finish the remaining
dependency audit and finish the user-facing importer. Native keyboard driving
now loads prepared sessions; see DRIVING_SESSION.md. Gzip AC files, SSG
optimization, full lighting/state interpretation,
tangents, content installation and broad-format compatibility remain open.
Never silently replace missing dependencies and call that content compatible.


## Texture compilation and Metal transfer

`TextureImage` decodes original one-byte SGI components, raw planes or RLE rows,
one through four channels, both byte orders and original MultiGen header repairs.
Rows retain source bottom-first order. Luminance and luminance-alpha remain in
original channel layouts through mip generation, then expand to straight RGBA8
for Metal. No implicit gamma correction or premultiplication is applied to SGI.

`TexturePyramid` preserves TORCS's integer four-sample averaging and channel-3
maximum-alpha rule. Two-channel alpha is averaged, as in the original code.
Case-sensitive `_n` and `shadow` naming rules disable mipmaps. User size limits
select a precomputed lower level, even when mipmaps are disabled. The original
proxy loop can produce zero dimensions for extreme aspect ratios and small limits;
native code diagnoses that case. GPU compression and hardware proxy rejection are
outside this comparison; the reference adapters accept valid requested sizes.

The unchanged original PLIB decoder and TORCS custom mipmap implementation execute
with GL upload capture adapters. Twenty-seven original textures produce 118 levels
and 34,843,291 exactly matching bytes. Authored cases cover channels, raw/RLE,
endianness, header repair, one-pixel dimensions, size reduction and mipmap names.
Malformed input is exercised only in native code. The parser checks file/row/run
bounds and decoded size; one-byte pixels only, at most 16,777,216 pixels and a
16,384-pixel axis. SGI input is limited to 64 MiB; unsupported formats fail explicitly.

```sh
swift build -c release
.build/release/torcs-assetc --texture Tests/UnitTests/Fixtures/Artwork/155-DTM/155-DTM.rgb Artifacts/155-DTM.torcstex
python3 Scripts/verify-textures.py
Scripts/build-app.sh
build/TORCSMac.app/Contents/MacOS/TORCSMac --texture-smoke-test Artifacts/155-DTM.torcstex
```

Texture options: `--no-mipmaps` and `--max-texture-size 1…16384` (default 4096).
Cache version 2 maps to `torcs-texture-swift-2` (PNG support); version-1 caches
are invalidated and must be recompiled. The lossless little-endian cache
retains source hash, filename, options, dimensions, channel count and every mip
byte. Its identity includes all of those compilation inputs. A full-payload SHA-256
checks corruption; structural checks enforce a valid mip chain. The compiler
validates its output before atomic publication. All 27 fixtures round-trip exactly;
their caches total 34,848,375 bytes. Source artwork notices still apply to caches.

`ContentSearchPath` checks caller-supplied roots in order, retaining first-match
selection without an implicit current-directory or network fallback. Relative
references and resolved symlink targets must stay within their root. Missing
resources, traversal and oversized reads fail explicitly. This is a loader for
explicit trusted roots, not a race-resistant transactional installer.

`MetalTextureUpload` creates `.rgba8Unorm` resources with the original mip levels.
The texture smoke command blits each level through the GPU to a readback buffer
and compares every RGBA byte. All 27 caches pass across 118 levels / 34,930,672
RGBA bytes. It verifies texture transfer, not sampling,
rasterization, lighting, texture-coordinate orientation on geometry or visual parity.
The app's normal presentation remains the suspension lab.

See `texture-parity-report.json` for build evidence and
`texture-dependency-inventory.json` for import decisions. The inventory covers
body/track mesh references, shadow/legacy-wheel/instrument names and the detailed
wheel meshes/texture; environment overlays and robot texture overrides need work.


## PNG compatibility

Native `TextureImage.decodePNG` uses Apple ImageIO for decompression, filters and
Adam7 reconstruction, with explicit compatibility transforms from original
`GfImgReadPng`. The unchanged original read function is byte-verified against
pinned img.cpp and runs with the release's bundled libpng 1.6.50, generic CPU
paths (`PNG_ARM_NEON_OPT=0`) and system zlib in reference tests only. No vendored
libpng code is linked into the native app or asset compiler.

The production decoder validates chunks/CRCs and dimensions, then gives ImageIO a
copy containing only image-defining chunks. Color-profile metadata and tRNS are
handled outside ImageIO to avoid implicit color conversion or lost alpha. A
surrogate palette carries each source index through either indexed or expanded
ImageIO storage; this preserves duplicate palette colors with distinct alpha.
The original palette is applied after decoding. Source files are never modified.

Preserved behavior: bottom-first output rows, straight RGBA, explicit tRNS,
16-bit-to-8-bit reduction, fixed-point gamma rounding/thresholds, the quantized
16-bit gamma tables and sBIT precision. The default screen gamma is 2.0. Only an
actual gAMA chunk selects file gamma; otherwise it is 0.50, including sRGB-only
files in pinned libpng 1.6.50. An older libpng version can behave differently;
no cross-version pixel equivalence is claimed. The original 1-bit inversion
request occurs after conversion to RGB and does not invert accepted output here.

The native decoder preserves the original four-byte-row rejection gate: opaque
gray, opaque palette and opaque 16-bit RGB layouts are rejected. Authored tests
cover all standard color types/depths, five filters, interlacing, gamma boundaries,
transparency, significant bits and duplicate palette colors. Of 1,092 layout/gamma
cases, 672 yield matching pixels and 420 are rejected by both implementations.
Thirty-two additional metadata cases also match. Native malformed-input checks
cover truncation, CRCs, compressed-data errors, palette bounds and invalid gamma;
arbitrary malformed input is never passed to the legacy function. This is not
exhaustive fuzzing, an RSS benchmark or a leak-freedom claim for legacy failure paths.

Aalborg raceline.png and trb1-3 wheel3d.png compare exactly over 2,228,224 base
pixel bytes. Their 20 original mip levels total 2,970,968 bytes and round-trip
through deterministic caches. The four wheel meshes add 48 nodes, 20 mesh batches
and 26,960 exact scalar comparisons. Wheel attachment/scaling, handedness and
rotation-speed selection now compare against original graphics code; assembled
rendering consumes interpolated physics snapshots. Native keyboard driving now
loads prepared sessions; general content installation remains open.

`torcs-assetc --texture` now detects SGI/PNG by content. Screen gamma 2.0 is fixed
for compiled PNGs; the lower-level decoder exposes gamma for reference tests.
PNG sources retain the same 64 MiB / 16,777,216-pixel limits. Unknown critical
chunks, invalid ordering/layouts and unexpected ImageIO sample representation
produce diagnostics. The compiled cache format stays lossless; compiler version
is bumped because supported decoding behavior changed.

```sh
.build/release/torcs-assetc --texture Tests/UnitTests/Fixtures/Artwork/aalborg/raceline.png Artifacts/raceline.torcstex
python3 Scripts/verify-assets.py
python3 Scripts/verify-textures.py
build/TORCSMac.app/Contents/MacOS/TORCSMac --texture-smoke-test Artifacts/textures/*.torcstex
```

The current 29 texture caches total 37,819,886 bytes. Metal upload/readback
checks all 138 levels and 37,901,640 expanded RGBA bytes with no differences.

Current evidence: `png-parity-report.json`. Historical mesh/SGI reports remain
unchanged to preserve their original source hashes and tested scope.
