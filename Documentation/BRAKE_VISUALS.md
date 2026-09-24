# Generated brakes and temperature color

The native driving scene now includes TORCS 1.3.9's generated hubs, brake discs
and calipers behind the detailed wheel meshes. Original `initWheel` always adds
these parts, including when detailed wheels are enabled. Previously the native
scene loaded only those detailed meshes, leaving out the generated brake parts.

`BrakeGeometry` preserves the original fan/strip vertices, normals, colors,
unlit/untextured material state, disabled culling and child order. Each wheel
adds 49 vertices and 43 triangles; four wheels add 196 vertices, 172 triangles
and 12 draws in the existing opaque pass. Geometry uploads at content setup.
There are no new textures, shader changes or render passes.

The brake transform includes body motion, suspension position, steering and
camber. It precedes the separate wheel-spin, side-flip and size transforms,
matching the original scene graph. The hub and caliper keep their fixed colors.
Only the disc receives the original temperature color from the immutable
physics snapshot: `(0.1 + 1.5t, 0.1 + 0.3t, 0.1 - 0.3t)`. The existing unlit
shader clamps that color. No simulation temperature is changed for rendering.

`DrivingContent.scenes` retains the six original body/wheel/track resources and
their loader bounds. `renderScenes` appends twelve generated parts. Legacy
five-instance vehicle diagnostics remain available; the driving window, Fly,
TV and traffic diagnostics now use seventeen instances per car. Mirror
exclusions include all current-car parts. The Fly height graph attaches the
same generated geometry before wheel rotation and retains previous-draw timing.

## Reference and GPU checks

The test adapter compiles a notice-retaining, byte-exact prefix of original
`initWheel` from the already pinned `grcar.cpp`, stopping before wheel loading.
Small test-only storage classes capture its arrays and material choices. The
provenance script verifies the excerpt against that original source. No original
source files or artwork are newly imported.

- 960 wheel/radius/width cases: 2,880 parts and 141,120 vertex values match
  exactly, as do normals, colors, primitive type and culling.
- Original wheel-position matrices are now compared alongside existing wheel
  matrices and heat colors: 300 authored cases and 2,002 native publications.
  Maximum matrix differences remain within the existing native transform
  tolerance: 0.0000009536743 and 0.000030517578 respectively.
- 20,736 original PLIB height queries over 32 rolled/steered poses include
  8,630 brake hits. Heights, retained hit counts and submitted triangle counts
  match exactly, including hidden-car cases. The oracle uses original-generated
  vertices and an original car-branch/selector topology.
- GPU fixtures check four temperatures, color clamping, fixed-part isolation,
  exact repeated pixels and atomic rejection of nonfinite instance colors.

The complete debug suite passes 246 tests. The 33 selected brake, vehicle,
camera, mirror, reflection, shadow and raster tests also pass in release and
under Address Sanitizer. These are bounded reference and renderer checks;
they do not establish whole-scene OpenGL pixel parity or long-race performance.

## Packaged captures

The ad-hoc-signed local preview is `build/TORCSBrakePreview.app`. Open the prepared
`Artifacts/driving-track-shadow-session` through **File → Open Driving Session…**.
It retains all 31 camera presets and the existing quality controls.

```sh
build/TORCSBrakePreview.app/Contents/MacOS/TORCSMac --brake-visual-test \
  Artifacts/driving-track-shadow-session Artifacts/new-brake-capture
```

The diagnostic advances native physics for 4,500 ticks: acceleration followed by
braking. It captures the initial settled snapshot and the hottest published
snapshot, with original side cameras and an explicitly labeled wheel-inspection
camera. Omitted geometry and fixed cold-disc color are presentation controls;
physics is identical for all comparisons. The initial settled snapshot can
already contain residual brake heat.

`--brake-visual-benchmark` additionally compares brake-off/on rendering in classic
and 4× MSAA/filtering modes at 960×640. It takes 60 interleaved samples per mode
after 10 warmups. This stationary side-view measurement excludes physics,
resource loading and file IO; GPU command time and offscreen wall time are
reported separately. Run without active builds or other known graphics work.

Five processes (one debug, four packaged release, including Metal validation and
the separate benchmark) produce identical 24-image hashes and non-timing records.
Each has 24 exact immediate repeat pairs. The hottest published temperature is
0.21326917 at tick 3,087. Across the controlled captures, geometry changes 207,240
channels and published heat changes 65,758. The wheel-inspection image visibly
shows the heated disc behind the spokes. These counts include enlarged inspection
views and are not a measure of typical gameplay visibility.

The current Fly diagnostic retains all 24 previous image hashes and camera
records. TV camera records are unchanged; 10 of 24 images change with the added
parts. The three-car diagnostic retains its camera/physics metadata, twelve
automatic switches across two runs, and 80 exact immediate repeat pairs; 24 of
80 images change. It runs with Metal API/GPU validation, with no reported fault.
The previous mirror-fixture limitation still applies: the actual initial traffic
mirror's ground shadows are cropped/occluded, while independent GPU fixtures
verify other-car shadow visibility.

On the Apple M2 (8 GiB, macOS 26.2), the stationary 960×640 sample records:

| Mode | GPU median, omitted → included | Offscreen wall median, omitted → included |
|---|---|---|
| Classic | 0.54075 → 0.54363 ms | 4.35971 → 4.42529 ms |
| 4× MSAA/filtering | 0.60721 → 0.60908 ms | 4.35825 → 4.41204 ms |

Median GPU cost increases by less than 0.003 ms, smaller than observed sample
variation; wall medians increase by about 0.05–0.07 ms. This is a small measured
cost in this scene, not a race-FPS guarantee. The existing shader, prior
MultiShadow/TV/Fly preview binaries and camera preference file retain their hashes.

Recorded capture, timing, source-hash and packaging evidence is in
`brake-visuals-report.json`. Other LODs, brake lights, skidmarks, smoke, body
deformation, full scene effects and multi-car gameplay remain open. This change
restores an original visual detail; broader enhanced rendering still needs
separate quality and performance measurements.
