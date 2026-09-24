# Per-car projected shadows and native traffic rendering

`SceneRenderer` now accepts ordered `SceneShadow` records for multiple cars.
Each record has a stable car ID, a texture resource slot, six projected vertices
and its own transformed normal. The existing single-car setters remain available.
The renderer loads textures separately from changing geometry and shares identical
mip content across slots. Nil slots support cars without a shadow texture.

## Original behavior

TORCS 1.3.9 initializes one child of `ShadowAnchor` for each car, before loading
cars. `grDrawShadow` replaces only the leaf under that child's anchor, retaining
anchor order. The six vertices use the existing original footprint and track
height projection. Normals follow the car body transform. Each car loads its own
configured shadow texture. `grDrawCar` hides a shadow only when that car is the
current car and the camera's draw-current flag is not one. Thus the rear-view
mirror hides its current car's shadow while retaining shadows for other cars.

Sources: pinned `graphics/grcar.cpp`, `graphics/grshadow.cpp`, `graphics/grscene.cpp`
and `graphics/grscreen.cpp`; initialization order is also inspected in the local
original `src/modules/graphic/ssggraph/grmain.cpp`. A notice-retaining, byte-exact
`shadow-visibility.inc` is checked against pinned grcar.cpp and compiled by the
reference adapter. The visibility sweep has 2,696 cases over 1/2/3/16/32 cars,
including absent current cars. The existing 6,000-vertex original geometry
comparison continues to run.

The supplied shadow array follows initialization order, independently of standings
or TV camera selection. Each view filters that array using `ShadowView`.
`RearViewMirror.currentCar` identifies the car to hide; its existing instance
exclusions continue to hide the body and wheels. Main-view filtering is independent
so Road view can suppress its own car while other cars remain visible.

## GPU submission

Textures are uploaded at setup. Geometry updates validate the entire batch before
replacing it. Duplicate/out-of-range car IDs, missing resource slots, malformed
strips and nonfinite or degenerate normals are rejected atomically. Removing a
texture slot still referenced by geometry also fails without changing resources.
There are at most 128 texture slots and 1,024 distinct car shadow records.

The existing render pass draws each visible six-vertex strip with its texture and
normal. It retains blending, backface culling, no depth writes and the original
polygon-offset numbers. Pipeline/depth state is set once for the shadow group;
there is no added render pass or shader change. A three-car TV view submits three
shadow draws; a three-car Driver view with its mirror submits three plus two.

The existing renderer places this group after opaque geometry and before
transparent geometry. This is not a complete original scene-graph/OpenGL raster
oracle; full scene traversal, transparency behavior across all original effects,
Metal versus GL depth units and other GPUs remain broader fidelity work.

## Tests and diagnostic

GPU tests use differently colored overlapping shadows to make blend order and
resource selection observable, verify distinct per-car normal lighting, check
atomic failure behavior and compare mirror crops against independent full-size
rear views. Tests cover classic and 4× MSAA/filtering, repeated submissions and
legacy single-shadow setter identity. Existing single-car shadow occlusion,
backface culling, transparent foreground and mirror tests also run.

`TrafficVisualSmoke` advances three real native 155-DTM cars, supplies immutable
collision histories to the original TV director and renders target changes.
It shares one car mesh resource set and one shadow GPU texture across all cars.
Each run includes shadow-on/off captures in classic and quality modes, a Driver
mirror capture and immediate exact raster repeats. Two native runs are compared
within each process. Cars use scripted commands and fixed launch order; this is
not native AI, race sorting or a multi-car GUI session. Shadows are projected
from current published body transforms and native track heights.

```sh
build/TORCSMultiShadowPreview.app/Contents/MacOS/TORCSMac --traffic-visual-test \
  Artifacts/driving-track-shadow-session Artifacts/new-traffic-capture
```

`--traffic-shadow-benchmark` additionally measures a stationary 960×640 three-car
TV scene: 60 interleaved samples per classic/quality and shadow-off/on combination,
after 10 warmups. Physics, resource loading and screenshot writes occur outside
that measured loop. GPU command time and offscreen wall time are separate; these
are not gameplay FPS, a whole-race performance guarantee or validation timings.
Run only without active builds or other known graphics work.

Interactive multi-car racing, full standings, other car/track artwork, multi-car
Fly height assembly, scene-wide shadows and native AI remain pending.

## Recorded validation

All 28 selected tests pass in debug, release and Address Sanitizer; the inventory
is 242. The previous full debug suite passed 238 tests before this increment;
there is no new full-suite claim. Provenance verifies 221 pinned entries and the
new derived visibility excerpt. The preview has a verified ad-hoc signature and
no direct C++ runtime or Expat dependency.

Four fresh processes (including Metal API/GPU validation and the separate timing
run) produce the same 80 image hashes and view records. Each process runs native
traffic twice, with 80 immediate exact repeat pairs and six automatic TV target
switches per 901-frame run. Four switch moments are captured per run. Shadow-on/off
comparisons change 551,744 channels across those images. Validation reports no
faults. The initial Driver mirror capture submits two other-car shadow draws, but
the ground shadows are cropped/occluded in those pixels: its shadow difference is
zero. The independent colored GPU mirror fixtures establish that other-car
shadows appear inside the crop and the current car's shadow is excluded.

The preceding single-car TV and Fly diagnostics were rerendered with the new
renderer. All 48 images and their view metadata remain identical. Previous TV/Fly
preview binaries and user camera preferences are preserved. Detailed source and
evidence hashes are in `multi-car-shadows-report.json`.

On the M2 host, the stationary TV scene at frame 30 measured:

| Mode | GPU median, ms | GPU p95, ms | Offscreen wall median, ms |
|---|---:|---:|---:|
| Classic, shadows off | 0.645 | 1.525 | 4.668 |
| Classic, three shadows | 0.645 | 1.541 | 4.700 |
| Existing quality mode, shadows off | 0.778 | 1.746 | 4.782 |
| Existing quality mode, three shadows | 0.775 | 1.641 | 4.721 |

The shadow-on/off median differences are below 0.003 ms and smaller than observed
variation; the lower quality-mode number is not evidence of a speedup. This covers
one scene, car model, camera and GPU, with physics and CPU projection outside the
measured loop. It establishes neither gameplay FPS nor a general performance bound.
