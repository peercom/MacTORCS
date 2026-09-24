# Fly camera and original scene-height traversal

The driving picker now includes **Fly**, the 30th camera, with original F10
motion and independent saved zoom (`fovy-8-0`). Its height query includes the
selected native scene: track, car body/driver, four modeled wheels, generated
hubs/discs/calipers and projected car shadow. This is not yet the complete
original scene; additional LODs, pits, skidmarks, smoke and lights remain outside
this slice.
A physical road-height lookup is not equivalent to this scenery query.

## Height semantics

`SceneHeightQuery` follows TORCS `grGetHOT` and the pinned PLIB HOT traversal. It
retains the AC hierarchy and child order, builds original bounding spheres, applies
the query-relative translation before descending through local transforms, and
performs original triangle tests. Sphere transforms deliberately leave the radius
unchanged, as original `sgSphere::orthoXform` does, including scaled transforms.

The query starts at Z = 100000. It honors mesh face culling, triangle bounding
boxes, normalized planes, the original 1% projected-area allowance and vertical
extent checks. Materials, texture alpha and rendering transparency do not affect
these tests. It returns the highest retained plane height, initialized to the
original -1000000 sentinel. The original 100-slot array accepts only 99 hits;
traversal order therefore matters. Degenerate triangles can consume hit slots
without contributing a finite height, and that behavior is retained.

`grVtxTable` inherits sequential PLIB triangle enumeration even for indexed strip
meshes. Its header explicitly notes the array limitation. The native query keeps
that behavior separately from Metal's correct indexed rendering. Substituting
render indices, skipping degenerate hits or sorting intersections by height would
change the reference result.

Scene validation rejects nonfinite coordinates, non-affine transforms, overflowing
bounds, hierarchies deeper than 128 and meshes above the original signed-short
vertex range. The query is an immutable value with caller-local result state;
there is no global hit buffer or filesystem access in native queries. Construction
happens separately from queries. No race-performance claim is made.

## Fly motion

`FlyCamera` preserves the original clock rules, timer renewal, target-car switch
reset, randomized offsets, height-dependent spring gain, damping, Euler position
update, overflow-time reset and one-meter scene clearance. `select()` resets only
the original timer and car identifier. Equal timestamps do not advance motion or
randomness. The first nonzero timestamp initializes the clock and returns, as in
upstream; the initial zero eye/target is kept in state.

The presentation accessor returns no view while eye and target cannot define a
valid Z-up camera. Integration must keep the preceding valid view until an actual
fly update is available. This prevents passing upstream's degenerate initial pose
into a Metal matrix without inventing alternate fly motion. The F10 factory uses
67.5 degrees, near/far 1/1000 and fog 500/1000 at the current unit FOV factor.

Each camera owns a separate Darwin-compatible random stream. Fly scaling is
`rand() / (RAND_MAX + 1.0)` in Double, unlike the simulation's Float scaling. The
original application shares libc randomness between subsystems; native rendering
must never consume the authoritative physics stream. Given the same seed and
inputs, the kernel is compared against the original class using libc `rand` on
the reference host. Cross-platform libc equivalence is not claimed. Invalid input
or a failed/nonfinite height query rolls back all motion and camera RNG changes.

## Reference boundary and next integration

The reference adapter compiles byte-verified original class/method excerpts from
TORCS 1.3.9 and its bundled PLIB r2173 source. The scene adapter supplies storage
for AC transform/branch/leaf nodes and calls original sphere building, traversal,
triangle enumeration, intersection, hit insertion and `grGetHOT`. Original SG
math is linked. It does not emulate graphics or traversal callbacks. Original selector and
range-selector traversal now execute in the adapter as well. The fly oracle executes the
original F10 class and factory with original scene-height queries and libc RNG.
It runs only in tests and is not linked by the native app. Capture does not read
original uninitialized gain/damping/offset-height fields before the first active
update; comparisons of those fields begin once a car is active.

The current mesh tests cover raw parsed graphs. All surfaces in the three selected
fixtures use type 4, which sets original `usestrip`; both loader wrappers therefore
skip their optional SSG flatten/stripify path for these files. The inspected file
hashes and surface counts are retained in `Artifacts/height-selected-loader-flags.json`.
Matching those transformations where other content enables them remains required
before claiming whole-content height parity. The original kernel evidence remains
in `fly-camera-kernel-report.json`; integration evidence is recorded separately in
`fly-camera-integration-report.json`.

### Integration ordering found in original sources

`cGrScreen::camDraw` calls `dispCam->update` before the `grDrawCar` loop. Therefore
fly height queries see the scene state left by the preceding draw pass, while the
spring targets the current car position. `grDrawCar` subsequently updates car,
wheel and shadow transforms, selector choices and car-anchor ordering. Simply
querying the newly interpolated instances would change that sequence.

`cGrScreen::selectCamera` changes the camera list and loads defaults without
calling `onSelect`. The call in `cGrScreen::update` occurs in the `carChanged`
branch. `FlyCamera.select()` ports that hook; integration must not reset the
kernel on every picker change merely because of its name. Returning to F10 must
retain its clock and state and let the original elapsed-time rule decide a reset.

Ordinary `ssgSelector::hot` traverses selected children in stored order, while its
bounding sphere is inherited from the full branch. Non-additive
`ssgRangeSelector::hot` always queries the first child rather than the currently
drawn range. The mutable `SceneHeightAssembly` now preserves and reference-tests these rules.
Static resources are shared across instances; transform updates recompute ancestor
bounds. Invalid updates leave the previous graph intact. Replacing a small shadow
resource recomputes the assembly bounds without rebuilding static meshes.

## Original kernel validation (previous increment)

The full debug suite passes 218 tests. The 63 selected asset/camera/rendering
tests pass in release and under Address Sanitizer. Seven new cases cover 28,313
height queries and 48,000 fly updates; all compared heights, retained-hit counts,
submitted-triangle counts, node spheres, defined fly-state values, clock values
and random-draw counts match exactly. Fly comparisons make 47,080 scene-height
calls and consume 2,412 random draws across four seeds and two terrain heights.

The 218 imported source/content/license entries pass provenance and pinned-archive
verification. Native app targets build; the release binary has no C++ runtime or
direct Expat dependency. Renderer, shaders, driving UI and the packaged Zoom
preview binary match their previous recorded hashes. No new fly image, native UI
integration or gameplay-performance result is claimed.

## Driving integration

`DrivingSceneHeight` retains the original eight anchor positions and separate
body, wheel-position, wheel-rotation, right-wheel-flip and wheel-scale stages.
Only the supported native resources populate those anchors. All four wheel-speed
children contribute selector bounds; only the selected child supplies hits.
Hidden shadows remove their bounds as original `grDrawShadow` does, rather than
retaining them in an inactive selector. Driver selection moves the original DRIVER subtree to the last sibling, matching
original wrapper insertion. Hidden drivers remain part of the bounding spheres.

`DrivingFlyCamera.draw` first advances the selected camera against the preceding
height graph, then publishes current body/wheel/shadow geometry for the next draw.
This runs even while another camera is selected. It targets the current published
physical car position; Metal retains its existing interpolation for visible
geometry. The initial degenerate F10 pose retains the renderer's preceding valid
view. Picker changes do not call the original car-change hook. Paused zoom changes
projection without changing eye, clock or random draws. A failed scene publication
also rolls back motion and randomness.

The native scene currently uses its available full-detail car resource throughout.
It does not reproduce other original LOD resources, remaining generated effects, callbacks,
body damage deformation, multiple cars or their anchor sorting. Native body/wheel transform construction
has the separately measured tolerance documented in VEHICLE_PRESENTATION.md;
exact query comparisons use identical supplied transform matrices. Do not infer
whole-original-scene or original-OpenGL pixel parity from those comparisons.

The additional tests cover 12,960 moving graph queries with exact heights, hit
counts, triangle counts and spheres, shared-resource hit saturation, driver
visibility/order, projected-shadow replacement and transactional failure. Driving
integration checks a 201-meter clearance witness against previous-draw geometry,
paused zoom, deselection/reselection and rejected publication. A separate
1,218-update original F10 zoom sweep checks limits, saved values and keys.

`TORCSMac --fly-visual-test <prepared-session> <new-output-directory>` runs two
identical native physics sequences, each with 901 draw frames and a temporary
camera deselection. It captures moving Fly views, paused zoom variants and classic
versus optional 4× MSAA/filtering modes. It verifies immediate raster repeats and
same-seed replayed native simulation images. It does not benchmark gameplay.

The new separate preview is `build/TORCSFlyPreview.app`. The existing Zoom preview
and the user's camera preference file are preserved. Native interactive Fly
selection, zoom/reset and relaunch acceptance remain to be checked when the
running driving session is available for automation. Automatic TV selection and
broader graphics/shadows remain next presentation work.

## Completed integration validation

The initial full debug run passes 225 tests, and the initial selected sanitizer
run passes 70. Source review then identified the hidden-shadow bounds correction;
all 70 selected camera/rendering/geometry cases pass on final source in debug and
release, and the seven affected cases pass again under Address Sanitizer. The
final test inventory is 225. All 220 pinned source/content/license entries pass
manifest and release-archive verification.

Three fresh runs of the packaged app produce the same 24 images and camera states.
Each includes two identical 901-frame native physics sequences and 24 exact
immediate raster-repeat pairs. The third run enables Metal API and GPU validation
with no reported fault. Two captures were visually inspected. The scripted drive
reaches the track edge by 15 seconds; this is neither an AI lap nor a five-lap
acceptance result. The packaged Metal smoke checksum remains 1103027, strict
ad-hoc signature verification passes, and the native binary has no direct C++
runtime or Expat dependency. No new gameplay-performance claim is made.

The renderer, shader, existing Zoom preview binary, user's camera file and 120
prior PNG files retain their recorded hashes. Those older views were not newly
rerendered in this increment. See `fly-camera-integration-report.json` for source,
artifact and log hashes and the precise validation boundary.

## Generated brake extension

The current driving assembly includes all twelve original generated brake parts
under each wheel-position transform, before rotation/flip/scale. Brake radius is
part of the immutable wheel configuration; changes require rebuilding the height
scene. Original-generated vertices in a PLIB graph match 20,736 native queries,
including hidden-car cases and 8,630 brake hits, with exact heights and traversal
counts. Existing earlier image reports describe their historical mesh-only scene.
See BRAKE_VISUALS.md and brake-visuals-report.json for current captures and scope.

The car-light rendering increment adds original one-point light leaves to the
selected driving graph before the car anchor. Switched-off lights retain bounds;
hidden-car lights are absent. They contain zero physical triangles. A surviving
one-point strip nevertheless contributes -1 to PLIB's legacy HOT diagnostic count
(`getNumVertices() - 2`); native query results preserve that counter as well as
heights, hit counts and bounds. See CAR_LIGHTS.md and its rendering report.
