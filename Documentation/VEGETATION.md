# Volumetric vegetation

The user requested real volume for trees currently visible as two intersecting
planes. An optional implementation now recognizes the selected Aalborg trees and
renders shared 3D trunks, branches and foliage sprays. The driving view exposes
a **3D trees** toggle, initially off. Original rendering remains available.
This is an initial procedural treatment; close-range foliage appearance and
moving LOD transitions still need refinement and acceptance.

The latest preview is build/TORCSFoliageDepthPreview.app. It retains the foliage
described below and replaces its separate fog-depth varying with
`1 / fragment position.w`. SceneCamera's perspective projection makes clip w
equal to negative eye-space z. Metal supplies reciprocal clip w in the fragment
position ([MSL specification, page 146](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf)).
The original linear fog range, color and fragment-stage clamp are retained.
No original scene, shadow or light shader is changed.

The reduced chase reproducer no longer shows the large first-frame difference
with this representation. Two full normal runs each pass 56 camera checks;
55 immediate pairs are exact and one has three one-byte differences within the
existing tolerance. All 56 image hashes match between those processes, and all
28 original-mode images match the preceding Foliage preview. Original-mode
restoration is exact in those runs. The final packaged validation run still
fails in smoothed Chase (92 channels, max byte delta 10) and the smoothed
broadleaf front view (53 channels, max delta 2). The preview remains experimental.

Current tests pass 43 focused release cases and four tree/fog ASan cases.
The new fog test casts a vertical center-pixel ray and uses the CPU canopy
intersection as an independent depth oracle. Partial fog matches the expected
blend for all three tree families; full fog and exact fog-off restoration pass
in both quality modes. This checks that the change preserves visible fog rather
than merely disabling its shader work. The last complete 274-test suite predates
the foliage-spray revision; it is not claimed as a current full-suite result.

The current packaged chase benchmark measures the following GPU times, using
60 interleaved samples per mode after ten timing-only warmups at 960×640 on M2:

| Mode | Original median / p95 | 3D trees median / p95 |
|---|---|---|
| Classic | 0.649 / 2.262 ms | 0.914 / 3.458 ms |
| 4× smoothing/filtering | 0.795 / 2.550 ms | 1.005 / 3.350 ms |

The additional median GPU cost is 0.21–0.27 ms in this scene. Desktop activity
and variable tails limit the result; no full-race performance acceptance is
claimed. Draw and triangle counts remain ten and 145,824 for chase. The original
defaults, earlier preview binaries and camera preferences are preserved.
See foliage-depth-report.json for current hashes, tests, captures and timings.

The investigation uses a reduced 16-frame chase probe and retained diagnostic
package copies. Clipping all tree primitives or simplifying their shader to a
constant produces exact repeats. Texture-only shading and constant fog factors
stay within tolerance; removing tree texturing alone does not. Explicit texture
gradients, branch removal, bark-grain removal, back-face-lighting removal, fog
varying packing/interpolation changes, vertex fog-factor calculation, constant
rebinding and strict floating-point compilation do not resolve the large failure.
Only fragment-depth fog reconstruction is retained. These observations narrow
the failure; they do not establish a driver/compiler root cause. No frame is
discarded for image acceptance and no tolerance is relaxed.

The preceding build/TORCSFoliagePreview.app introduced crowns containing many
small, individually oriented blades distributed through a three-dimensional
volume. This removes the solid ellipsoid surface and gives finer silhouettes
and gaps between foliage. An intermediate version placed blades too horizontally
and was revised after inspecting side views. The final version varies blade
orientation through all axes while keeping branch spread and original tree
extents. Meshes are generated once with an integer-seeded generator; no leaf
geometry is generated per frame and no texture is added. Appearance remains
procedural, especially the tall tree's separated branch clusters.

For that preceding revision, 38 focused release tests and the three tree tests under
AddressSanitizer pass. Additional assertions cover generated position/normal/UV
determinism, finite normals and source bounds. All 28 original-mode images in the
normal packaged capture match the preceding Tree preview exactly. The chase
view submits 145,824 tree triangles, up from 131,696 (10.7%), in the same ten
instanced draws. Actual rendering cost is not established for this revision:
the benchmark correctly skips its timing loop when image acceptance fails.

That preceding normal packaged capture records failures in
classic Chase, smoothed Driver/mirror and smoothed TV. A separate validation run
also exposes an original-tree frame and restoration failure. A diagnostic copy
of the package using fixed mip level zero for foliage still fails; that probe is
retained under Artifacts and is not incorporated into application source.
Most changed pixels in the large Chase failure do not consistently differ from
the original-mode image, so investigation must include shared/original scene
rendering, not only foliage sampling. No root cause is asserted.

The capture tool now records failed repeats and original-mode restorations,
retains the corresponding images, completes the remaining views, writes its
report, and exits with failure when any acceptance check failed. Timing is
disabled for failed runs. Submission mismatches still stop the run immediately.
See foliage-report.json for that revision's evidence; the sections below retain
earlier tree-order experiments and timings, which do not measure the latest foliage.

Local inspection confirms that Aalborg's `tree-aa1.ac` contains two intersecting
rectangular foliage planes with the `allborg-trees_n.rgb` atlas. The compiled
`aalborg.acc` splits atlas geometry across 681 mesh objects: 676 have three
vertices, two have four, and the remaining three have 18, 60 and 66. This is an
object count, not a tree count. Placement recovery must reconcile split faces
and combined geometry; arbitrary OBJ names are not stable tree identifiers.
The read-only inventory is in Artifacts/vegetation-source-inspection.json.

The enhanced mode uses actual trunk/branch/foliage volume nearby,
simpler 3D trees at medium distance and the original atlas billboards far away.
Reuse several deterministic tree variants with varied orientation and scale,
preserving recovered original positions, extents and broad species silhouettes.
Avoid replacing the trees with smooth identical cones. Camera orbit and Fly views
must retain plausible silhouettes from above and between the original plane axes.

Group repeated meshes for instanced submission and select detail per view;
mirrors need their own visibility/detail decisions. Metal supports geometry LOD
and instancing; no mesh-shader dependency is necessary for a small static forest.
See Apple's [LOD sample](https://developer.apple.com/documentation/metal/adjusting-the-level-of-detail-using-metal-mesh-shaders)
for the general distance/detail approach; that sample's particular mesh-shader
implementation is not a commitment for this renderer.

Implementation gates:

- Recover tree placements from the original data with deterministic geometry
  checks, retaining unrecognized atlas geometry unchanged.
- Provide a reviewable original/enhanced toggle and matched captures from chase,
  trackside, TV, Fly and mirror views; preserve physics and camera records.
- Measure CPU submissions, triangles, GPU time and repeated-frame stability with
  enhancement off/on before choosing default quality and distance thresholds.
- Add nearby tree shadows only after the shadow path is measured; no unmeasured
  forest-wide dynamic-shadow cost should be hidden in the default setting.

The renderer uses 18 shared meshes: three source families, three deterministic
variants and two geometry detail levels. All 169 placements keep their recovered
position, tilt and extents. Per-view projected height selects detailed geometry
at 160 pixels or above, simpler geometry at 35–160 pixels, and original planes
below 35 pixels. These provisional thresholds need moving-view acceptance.
Draws are instanced in at most 18 groups per track instance/view, with bounded
512-instance uploads. The existing atlas is reused; no new texture is uploaded.
The Fly camera includes the detailed canopy surface in its presentation-only
height query when enabled. Physics and collision geometry are unchanged.

Foliage blades sample a dense patch within each source tree’s atlas region.
This currently looks more stylized than the original
photographs; it is not a claim of completed visual fidelity. A first lathed-shell
experiment produced horizontal bands and was replaced. Earlier cluster variants
failed full-resolution repeat checks, including with cutout discard removed.
The cause was not established; Metal validation reported no resource fault. The
revised branch proportions subsequently passed 52 full-scene immediate repeats
with identical pixels. All failed captures/logs remain under Artifacts.

The preceding tree-order source passes the complete 274-test release suite and 38 affected
release/AddressSanitizer tests. The new build/TORCSTreePreview.app submits the
optional opaque tree block before the original draw stream. This clears the
previous large first-frame failure in the tested views. The old preserved
Vegetation preview still reproduces that failure (3,787 channels, max byte delta
52) as a negative control. An earlier experiment giving trees separate buffer,
texture and sampler bindings did not fix it and was reverted. This establishes
an effective ordering change for that case, not a driver or application root cause.

Two fresh normal packaged processes each complete 56 matched views with unchanged
immediate-repeat tolerance and exact original-mode restoration. Coverage includes
Chase, trackside, Driver/mirror, TV, Fly and three directions for each tree family,
in both quality modes. Of 112 immediate pairs, 111 are exact; one has three
one-byte differences. Across processes, 55 of 56 image hashes match exactly; the
smoothed TV image differs in three channels by one byte at two left-edge pixels.
Camera, physics, draw and triangle records match between processes.

Metal API/GPU validation still exposes a smoothed trackside repeat failure:
32 channels at 19 pixels differ by up to six byte levels, in a small tree region
at x=446–453, y=269–292. The first image and two later images match the normal
capture exactly; the immediate second image differs. Recorded submission hashes
match and validation reports no resource fault. No acceptance frames are skipped
and no tolerances are relaxed. The preview remains experimental, with the Order
preview retained as the validated baseline. The separate inherited-alpha wheel
regression is also still open. Current evidence is in vegetation-order-report.json;
vegetation-report.json retains the preceding failed prototype's evidence.

The preceding tree-order benchmark uses its packaged release on Apple M2/8 GiB, macOS 26.2,
at 960×640 in a stationary chase view. It interleaves 60 measured samples per mode
after ten warmups used only for timing. Desktop activity is recorded; no build,
test or other capture ran concurrently. Results are scoped to this offscreen view:

| Mode | Original GPU median / p95 | Volume GPU median / p95 |
|---|---|---|
| Classic | 0.647 / 1.564 ms | 0.645 / 2.336 ms |
| 4× smoothing/filtering | 0.794 / 2.343 ms | 0.730 / 1.112 ms |

The volume path submits ten instanced draws and 131,696 tree triangles in that
view. Across all captured views, the additional geometry uses 6–16 draws,
including mirrors. GPU medians show no material increase in this particular
scene, but the variable tails prevent a general speedup or full-race FPS claim.
Loading, simulation and moving detail transitions are excluded.

A separate release CPU probe measures the additional detailed-canopy height
query at all 169 tree centers: 92.6 µs median, 167.8 µs p95, 220.3 µs maximum
over 1,014 queries. Outside-forest queries measure 0.25 µs median over 192 samples.
This excludes the original height graph and the rest of the Fly update. Loading
and one warmup sweep are outside timing. See Artifacts/vegetation-height-timing.json.

The original mode applies the original draw states in their original order.
When replacing a recognized tree, the renderer still applies its state metadata
at its original position so later inherited state is preserved. The enhanced
meshes have already been submitted through a separate opaque pipeline before
that original stream. Unrecognized atlas geometry is retained. Tree
shadows are not yet implemented.

Further geometric inspection recovered 338 quadrilateral planes from 676 split
triangles, then paired all of them into 169 candidate tree placements. Pair
centers agree within 0.00056 m and their upright edge vectors within 0.01 m.
Comparing world-axis height extents was insufficient because the trees are tilted;
matching actual upright edge vectors resolves those cases. Remaining atlas meshes
include hedge-like strips and must not be replaced solely by texture name.
Artifacts/vegetation-placement-inspection.json retains the candidates and matching
criteria. The production recognizer now checks these candidates against the decoded,
transformed scene geometry; damaged or ambiguous pairs are left unchanged.

The paired candidates divide into the atlas's three source-tree regions: 81 of
the first tree (about 14.235 m high), 79 of the second (18.65 m) and nine of the
third (17.412 m). These sizes match the separate source tree models. This supports
three shared mesh families rather than creating a unique mesh for every tree.

Recognition validates each candidate's rectangular faces, near-perpendicular
horizontal edges, common upright direction and matching atlas region. The
enhanced Fly query includes detailed canopy triangles, while the original mode
retains its original height graph and parity tests. Ordinary race physics and
collision geometry are unchanged. Actual Fly captures and canopy-query timing
are now recorded; moving transitions and native GUI acceptance remain open.

The additional offline diagnostic in Artifacts/validate-tree-candidates.py now
checks all 338 rectangles and matches all 169 pairs to the three source models.
Opposite-edge lengths differ by at most 1.414 mm; recovered widths differ from
the source by at most 1.093 mm. The source planes have different UV ranges and
are not exactly perpendicular, so recognition must compare each pair with its
source family rather than requiring equal UV bounds or exactly 90 degrees.
The maximum direction-cosine difference from the original model is 0.000170,
within a 0.001 bound accounting for millimeter-rounded ACC coordinates.
See Artifacts/vegetation-candidate-validation.json. Production tests now recover the same family counts, preserve all five other
atlas batches, and reject a damaged tree and unrelated texture names. GPU tests
check three directions for each family in both quality modes, exact original-mode
restoration, instanced draw limits, texture reuse and independent mirror choices.
