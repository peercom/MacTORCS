# Original scene submission order

The renderer now follows TORCS's scene anchors and SSG's two-stage leaf
submission. The previous renderer sorted all translucent mesh centers by view
space depth, placing shadows and lights before the entire sorted list. That
could reorder track decals relative to shadows and lights, mix windows from
different cars, and change a car's internal scene order.

Original `grInitScene` adds land, pits, skid marks, shadows, car lights, cars,
smoke and sun anchors in that order. During traversal SSG draws opaque leaves
immediately and queues translucent leaves; it later plays that queue in
insertion order. It does not sort each translucent mesh by its center.

Before traversal, each original screen sorts whole cars by squared horizontal
(X/Y) distance from its display camera. `grDrawCar` removes and appends each car
transform in that order. A car's body and wheels therefore stay together. Shadow
and light anchors retain their own initialization order, independently of the
car sort. The car loader also wraps the first `DRIVER` subtree in a selector
appended after that subtree's former siblings. Native geometry now traverses
children explicitly and reproduces this driver relocation for car resources.

The original frame sets `GL_LEQUAL`. Ordinary translucent leaves still write
depth: translucency controls deferred submission, not the depth mask. SSG has no
`glDepthMask` calls; TORCS shadows, lights and smoke explicitly disable writes
for their own draws and restore them afterward. The native renderer now uses
Metal `lessEqual` and enables writes for ordinary meshes, including translucent
ones. Previously it used `less` and disabled writes for all translucent meshes.

## Native path

`SceneInstance.anchor` identifies the original scene group. Track instances use
`.land`; `VehiclePresentation.instances` assigns the same `SceneCarPlacement`
identifier and body position to every body, brake and wheel part of a car.
Traffic passes each car's distinct identifier. Standalone inspector instances
without car metadata retain their input order. Shadows and lights use their
existing typed setters; mesh instances cannot occupy those reserved anchors.
The other anchor names do not imply that native smoke, skid marks, pits or lens
flare generation is complete.

`SceneDrawOrder` retains a screen's car ordering across publications, computes
per-view order and preserves each car's internal instance sequence. Mirrors
prepare before the main view and sort the full supplied car set before excluding
hidden instance indices. Hidden indices refer to the original publication, so
sorting cannot hide another car by mistake. Prepared plans remain stable for
immediate repeated captures; publishing instances begins a new view update.
The displayed/interpolated positions supplied by native presentation are the
sort inputs; this is not a claim of identical original display scheduling.

The original comparator returns +1 for equal distances instead of zero. Passing
that comparator to Swift's sort would violate its ordering requirements. The
native Swift planner uses macOS libc `qsort_b`, checked against original code
calling this host's `qsort`, including ties and sequential camera updates. This
preserves the selected host behavior; tie ordering on other libc versions or
platforms is not promised. No original C++ or OpenGL code enters the native app.
Nonfinite placements, distance overflow, inconsistent positions for one car ID
and invalid/reserved anchors are rejected. Rejected publication preserves the
previous prepared scene.

The renderer emits opaque draws in traversal order, then deferred groups in
original anchor order. It reuses existing buffers, textures, render passes and
material pipelines. Optional command traces record actual main/mirror mesh,
shadow and light submissions only when diagnostic capture is enabled. These
traces exclude sky and the final mirror compositing draw.

## Reference boundary

Unchanged bundled PLIB `ssgDList.cxx` and `ssg.cxx`, plus TORCS `grmain.cpp`,
are newly pinned with their original notices. Leaf, branch/entity and vertex
sources reuse existing pins. Fourteen notice-retaining excerpts execute original
traversal, name search, deferred queue, scene-anchor initialization, driver
wrapping, distance calculation, car comparison, frame depth setup/dispatch and
ordinary mesh draw paths. The source inventory is 180 source/license plus 46
content entries, 226 total.

Test-only adapters provide object storage, explicit visibility and no-op GL
matrix calls. They capture actual original leaf draw order. They do not run an
OpenGL driver, arbitrary traversal callbacks, geometry optimization, LOD selection
or the original deferred-queue overflow behavior. Native transforms and camera
kernels retain their separate reference checks. This is draw-order evidence, not
whole-scene OpenGL pixel parity. The separate depth adapter executes original
frame and ordinary vertex/car draw excerpts with no-op state application,
geometry, matrix and light adapters; it captures the comparison and inherited
write mask through eight draw branches, starting with either mask value. It
does not execute arbitrary callbacks or prove their effects on depth state.
The absence of depth-mask changes in SSG state application is a source audit.

Authored tests cover nested/breadth-first storage, mixed opaque/translucent
leaves, multiple named driver subtrees, driver hiding, sequential per-view car
sorts, horizontal-distance ties and invalid-publication rollback. All six
selected original meshes are also checked against the queue with their actual
hierarchy and translucency flags. GPU fixtures verify the land/shadow/light/car
sequence, analytical alpha blending, whole-car grouping despite conflicting mesh
depths, mirror ordering and stable repeats in classic and 4× MSAA modes.
A dedicated overlapping-mesh fixture checks that farther translucent geometry
fails after a nearer translucent draw writes depth, while equal-depth geometry
passes and blends. These pixels distinguish both corrected native states.

## Remaining fidelity work

Alpha-test enable/threshold inheritance is now implemented separately in
ALPHA_STATE.md. Inherited normals and other legacy state still need broader
integration. Actual mesh frustum/LOD and
callback behavior, additional original effects, multi-car Fly height, complete
race presentation and all-content coverage remain open. Fixing submission order
does not complete those systems. Current capture, build and performance evidence
belongs in `draw-order-report.json`; earlier reports remain historical records.

## Validation and local preview

The full debug suite passes 263 tests. The selected 34 graphics/reference tests
also pass in debug, release and AddressSanitizer. Six new tests cover 256 nested
traversal cases, 840 sequential car-view updates, six selected original models
(3,044 nodes and 1,353 drawable leaves), and original depth dispatch. GPU fixtures
check submission traces, overlap/depth, mirrors and 18 repeated frame pairs
across classic and quality modes.

`build/TORCSOrderPreview.app` is a separate ad-hoc-signed local preview; earlier
Light and Brake previews are preserved. Open `Artifacts/driving-light-prepared`
through File → Open Driving Session. The app does not bundle original artwork.
A selected capture can be reproduced into a fresh directory with:

```sh
build/TORCSOrderPreview.app/Contents/MacOS/TORCSMac \
  --car-light-visual-test Artifacts/driving-light-prepared Artifacts/order-local-capture
```

In an isolated pair of stationary 960×640 chase measurements, old/new median GPU
times were 0.6442/0.6373 ms with lights in classic mode and 0.7867/0.7783 ms in
quality mode. Without lights they were 0.6375/0.6385 and 0.7770/0.7780 ms. Tail
variation was much larger than these differences; this is not evidence of a
reliable speedup or full-race performance. No passes or textures were added.
These stationary measurements reuse scene publication, so a separate probe calls
the compiled release planner with fresh publication and both view sorts every
iteration. Its median costs for 1/3/16/32 cars were 2.92/7.08/32.00/66.79 μs
(17 instances per car plus land, 1,000 samples after 200 warmups). The probe does
not include rendering, physics or content loading. See the machine report for
raw medians, tails, source hashes and evidence paths.

Four release light-capture processes, including Metal API/GPU validation, agree
on all 24 images and non-timing records; each also passes 24 immediate repeats.
The revised Fly/TV/three-car traffic diagnostics pass 24/24/80 repeated captures.
Their camera/zoom/TV-selection records match the preceding Light preview. Image
hashes change in 24/24 light, 24/24 Fly, 22/24 TV and 80/80 traffic captures; the
old pictures are retained as historical comparisons. This is within-build native
repeatability and reference-tested scheduling, not original OpenGL pixel parity.
The packaged Metal smoke test passes, and signature/library checks find no direct
C++ or Expat runtime dependency.
