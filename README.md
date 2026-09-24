# TORCS Mac

A native macOS Swift 6 / Metal port of **TORCS 1.3.9**, developed incrementally
against executable upstream reference tests. **Early keyboard driving now works
for a prepared 155-DTM/Aalborg session; full racing remains unfinished.**

The native Metal driving window uses fixed-step vehicle physics, four animated
wheels, original cameras, configurable practice/solo qualifying, countdown,
restart, lap results and per-tick telemetry recording. Component and model inspectors remain
available. Selected physics and camera behavior are compared with original C++
code; the app itself contains no original executable or C++ physics runtime.

A native BT single-car AI runtime is also available as a headless gameplay
diagnostic. It completes ten laps repeatably and a forced-pit run with native
physics; opponent racing
and the driving-window integration remain pending. See [native BT](Documentation/NATIVE_BT.md).

## Build and run

Requires macOS 14+, Apple Silicon, and full Xcode with Swift 6. Validated with
Swift 6.3.3 / Xcode 26.6. No third-party packages or local upstream checkout are
needed to build or run tests. Preparing the driving session additionally uses
explicit local texture inputs, as described below.

```sh
swift build
swift test
Scripts/build-app.sh
open build/TORCSMac.app
```

Open `Package.swift` in Xcode to develop the app. The packaging script creates an
ad-hoc signed app under `build/`; see [distribution](Documentation/DISTRIBUTION.md)
for Developer ID and notarization support. Those distribution paths are unverified.

The app opens the driving window. Open a prepared session, choose **New Session…**
for practice or solo qualifying and a lap count, then press **Start**. Click the
Metal view for keyboard focus: arrows or WASD drive, E/Q shift, and P pauses.
Controls… edits bindings. Results… reviews and exports lap times; Drive Again
resets the car. Settings selects 60 or 120 Hz presentation; physics stays at
500 Hz. The component inspector is available under Simulation → Open Component
Lab. AI races are still pending; see [gameplay](Documentation/GAMEPLAY.md).

## Reference comparison

```sh
mkdir -p Artifacts
swift run torcs-reference --ticks 10000 --telemetry Artifacts/reference.jsonl
swift run torcs-sim --ticks 10000 --telemetry Artifacts/native.jsonl
swift run torcs-diff Artifacts/reference.jsonl Artifacts/native.jsonl --report Artifacts/parity.json
```

These commands run a **component sweep**, not a race. All ten fields matched
exactly over 10,000 ticks in debug and release on the tested machine. `torcs-diff`
reports absolute/relative maxima, RMS, divergence over time and threshold failures.
It rejects schema, field and tick mismatches. Exit codes: 0 pass, 1 divergence,
2 invalid input. Comparisons and complete schema-2 reports stream without a total
capture-size limit; see [telemetry comparison](Documentation/TELEMETRY_COMPARISON.md).
Full race telemetry is not implemented.

Native field placement now reproduces the original starting grid exactly, and the
multi-car simulation accepts one car definition per car; see
[starting grid](Documentation/STARTING_GRID.md).

The reference CLI also runs a **multi-car original race**: 1-10 original BT
drivers placed by the verbatim original starting grid and stepped through
`ReOneStep`, `ReManage`, `ReRaceRules` and `ReSortCars`, with per-car callback,
rule, penalty and classification capture. A three-car, three-lap Aalborg race
completes and repeats exactly. This is the executable baseline for the remaining
gameplay work; see [race oracle](Documentation/RACE_ORACLE.md).

```sh
.build/release/torcs-reference --robot bt --fixtures Tests/UnitTests/Fixtures \
  --cars 3 --grid quickrace --laps 3 --max-ticks 600000 \
  --summary Artifacts/race-oracle-3car.json
```

The reference CLI also runs original whole-car physics on pinned Aalborg/155-DTM
configuration, including tires, drivetrain and collisions. This code is confined
to tools/tests. The native CLI runs five single-car scenarios and the two-car
collision scenario independently.

```sh
swift run torcs-reference --scenario braking --fixtures Tests/UnitTests/Fixtures --ticks 3000 --telemetry Artifacts/braking.jsonl
swift build -c release
python3 Scripts/verify-reference-world.py
```

Six scripted scenarios have exact repeatability within the tested release build.
Each records 142 fields per car. Native stationary, acceleration, braking,
cornering and combined scenarios can be compared with the same schema:

```sh
swift run torcs-sim --scenario braking --fixtures Tests/UnitTests/Fixtures --ticks 3000 --telemetry Artifacts/braking-native.jsonl
swift run torcs-diff Artifacts/braking.jsonl Artifacts/braking-native.jsonl --report Artifacts/braking-parity.json
Scripts/verify-single-car.sh
swift run torcs-sim --scenario car-collision --fixtures Tests/UnitTests/Fixtures --ticks 3000 --cars 2 --telemetry Artifacts/car-collision-native.jsonl
Scripts/verify-car-collision.sh
```

The scripts build release tools and check repeatability and native/reference
parity for these six scenarios. Native code owns its random stream and
loads XML/geometry without C++ or Expat. Native convex queries and box/box car
collision dispatch are connected, including fixed wall/car and fixed-pair contacts.
Undefined upstream wall-as-car access produces a native diagnostic.
[Removal and towing](Documentation/REMOVAL_PORT.md) are connected to normal updates,
including coasting, pit-car collision participation and published towing poses.
[Pit service physics](Documentation/PIT_SERVICE.md) now applies fuel, repairs, tire
replacement and setup changes. Pit allocation/timing now integrates with physics (see
[RACE_PITS.md](Documentation/RACE_PITS.md)); complete race/robot execution remains pending.
The cornering script reaches
a barrier and does not establish steady-state cornering parity.

```sh
Scripts/verify.sh
build/TORCSMac.app/Contents/MacOS/TORCSMac --metal-smoke-test
```

`verify.sh` checks provenance, tests, release builds, repeatability, and parity.
It requires Python 3 for provenance checks. The Metal smoke test executes a real
offscreen GPU render and fails if it produces no geometry. It requires a graphical
macOS session; the component CLIs do not depend on Metal or launch the app.

## Mesh compilation

```sh
swift build -c release
mkdir -p Artifacts
.build/release/torcs-assetc Tests/UnitTests/Fixtures/Artwork/155-DTM/155-DTM.acc Artifacts/155-DTM.torcsmesh --car
.build/release/torcs-assetc Tests/UnitTests/Fixtures/Artwork/aalborg/aalborg.acc Artifacts/aalborg.torcsmesh
python3 Scripts/verify-assets.py
```

Both original meshes match the original ACC parser and round-trip through a
validated binary cache. Aalborg produces an expected short-child-list warning,
preserving original acceptance. SGI/PNG textures decode into faithful CPU mipmaps and upload to Metal. Four
detailed-wheel meshes also match original loading. The compiled scene inspector renders car body, wheel and track meshes with textures and depth testing.
Driving wheel attachment/animation is integrated; full scene fidelity remains pending. See
[scene rendering](Documentation/SCENE_RENDERING.md).

Compile an SGI or PNG texture and verify native GPU transfer:

```sh
.build/release/torcs-assetc --texture Tests/UnitTests/Fixtures/Artwork/155-DTM/155-DTM.rgb Artifacts/155-DTM.torcstex
python3 Scripts/verify-textures.py
Scripts/build-app.sh
build/TORCSMac.app/Contents/MacOS/TORCSMac --texture-smoke-test Artifacts/155-DTM.torcstex
```

## Current capabilities and next work

- Fixed-step clock, immutable presentation snapshots, native shell and Metal lab.
- Native version-4 roads, profiles, banking, curbs, barriers, static pits and track queries checked against original Aalborg.
- Reference-tested wheel ride/contact, tire forces, heat/wear/grip, wheel rotation, suspension, brakes and steering.
- Native wheel/axle configuration, chassis-to-wheel transforms and axle load sharing.
- Reference-tested engine torque/RPM/fuel/exhaust, all five differential modes, gearbox/clutch and RWD/FWD/AWD routing.
- Reference-tested body/wing aerodynamics, ground effect, damage response and drafting.
- Chassis integration, ground/barrier response and damage generation; coupled vehicle dynamics match 30,000 independent ticks against original routines.
- Original convex/complex queries and previous-pose contacts; native two/three-car collisions, fixed-wall geometry/strikes, fixed-pair pose freezing and mixed wall/car pileups checked against original code.
- Driver-command checks, atmosphere, settling/prestart/running phases, owned random state and standalone 142-field single-car telemetry.
- Four-wheel runtime checked over 10,000 undriven and 16,000 driven ticks against original code, plus mass/inertia and parameter-unit checks.
- Original full-physics harness; native configuration merges match all 292 selected car/category values.
- Original car, Aalborg track, race and robot XML fixture parsing with explicit
  local entity resolution; ranges, hexadecimal values and SI serialization.
- Pinned upstream source, GPL v2 license, retained attribution and content manifest.

- Native team pit assignment, admission, service timing, setup restrictions and
  shared-stall release connected to physics; see [race pit management](Documentation/RACE_PITS.md).

The full upstream race harness, penalties and complete race behavior,
content installation, complete race rendering, verified five-lap driving, robots, race logic, replay, physical controller validation and audio remain
unfinished. See the [status matrix](Documentation/PORT_STATUS.md),
[implementation checklist](Documentation/IMPLEMENTATION_CHECKLIST.md),
[architecture study](Documentation/ARCHITECTURE_UPSTREAM.md),
[physics parity evidence](Documentation/PHYSICS_PARITY.md), and
[track parity evidence](Documentation/TRACK_PARITY.md).

## License

New application source: **GPL-2.0-only** ([full license](LICENSE)). Original TORCS
files retain their GPL-2.0-or-later notices; reference-only SOLID and PLIB code retains
LGPL-2.0-or-later. Native SOLID-derived Swift portions use the LGPL v2 section 3
conversion to GPL v2. See [third-party notices](THIRD_PARTY_NOTICES.md) and
[asset licenses](Documentation/ASSET_LICENSES.md). Six original meshes, 27 SGI textures, two PNG textures and their notices retain
Free Art terms; they are not
bundled in the current app.

## Inspect compiled scenes

```sh
mkdir -p Artifacts/scenes
.build/release/torcs-assetc --scene Tests/UnitTests/Fixtures/Artwork/155-DTM/155-DTM.acc Artifacts/scenes/car --car
Scripts/build-app.sh
open build/TORCSMac.app
```

Use **File → Open Compiled Scene…** and choose `Artifacts/scenes/car`. Drag or
use arrow keys to orbit, scroll or press +/− to zoom, and press R to frame.
Compilation refuses existing output folders and unresolved texture dependencies.
For Aalborg’s explicit local shared-texture search and offscreen rendering checks,
see [scene rendering](Documentation/SCENE_RENDERING.md). This is model inspection;
the prepared driving session is described below, and complete renderer fidelity remains unfinished.

The assembled vehicle diagnostic now renders native physics snapshots with all
four wheels on the track. Run `Scripts/verify-vehicle-scene.py` with an explicit
TORCS source directory after building the release app. See
[vehicle presentation](Documentation/VEHICLE_PRESENTATION.md). Native keyboard driving and the original chase camera are now integrated;
five-lap timing and telemetry capture are described in [lap timing](Documentation/LAP_TIMING.md).

## Drive the selected car and track

The current local gameplay preview is `build/TORCSGameplayPreview.app`: configurable
practice/solo qualifying, countdown, restart and JSON results. All 282 release
tests and seven session AddressSanitizer tests pass. AI racing and packaged UI
acceptance remain open; see [gameplay status](Documentation/GAMEPLAY.md).

After building the release tools and app, run:

```sh
python3 Scripts/prepare-driving-session.py /path/to/torcs-1.3.9 Artifacts/driving-session
```

Choose **File → Open Driving Session…**, select that new folder, and click **Start**.
**New Session…** selects practice or solo qualifying and 1–100 laps.
Arrow keys/WASD drive, E/Q shift, C operates the clutch, and P pauses. Switching
away pauses automatically. See [driving sessions](Documentation/DRIVING_SESSION.md)
for preparation, licensing limits and controls. **Record Telemetry…** captures every
simulation tick; **Finish Recording** saves JSONL. The lap strip shows current/last/best
times and validity. **Results…** reviews the session and saves a JSON report;
**Drive Again** resets the car for another run. A full five-lap physical run,
physical controller driving, audio, replay and complete race modes remain unverified or unfinished.

**Controls…** configures keyboard bindings and GameController axes/buttons, inversion,
dead zones, sensitivity and linearity. Default gamepad controls are left-stick steering,
right/left triggers for accelerator/brake, shoulders for shifting, south button for
clutch and Menu for pause. See [native input](Documentation/INPUT.md) for defaults,
neutral activation and the original-axis reference boundary.

Driving visual increment: six chase/bonnet/road cameras, original projected car
shadows and optional sharper road texture filtering are described in
[DRIVING_VISUALS.md](Documentation/DRIVING_VISUALS.md). Gameplay now takes priority
over further visual/foliage work and physical GameController validation. The original BT reference-only milestone
and its build-mode limitation are recorded in [ROBOT_API.md](Documentation/ROBOT_API.md).

Prepared driving sessions now render the original track sky, sun lighting and
linear fog. See [TRACK_ENVIRONMENT.md](Documentation/TRACK_ENVIRONMENT.md) for
reference checks and preparation instructions; subsequent raster stabilization is documented below.

Additional original exterior camera families: [EXTERIOR_CAMERAS.md](Documentation/EXTERIOR_CAMERAS.md).

Material-specific shader specialization and repeated-frame validation: [RASTER_STABILITY.md](Documentation/RASTER_STABILITY.md).

Original car reflection and environment-shading maps, with measured GPU cost:
[CAR_REFLECTIONS.md](Documentation/CAR_REFLECTIONS.md).

Projected track shadows on car bodies, compatible mesh-cache bounds and texture
sharing: [CAR_TRACK_SHADOWS.md](Documentation/CAR_TRACK_SHADOWS.md).

The driver/circuit increment brought the camera picker to 27 views, including the original driver view,
circuit-center view and five panoramas:
[DRIVER_SURVEY_CAMERAS.md](Documentation/DRIVER_SURVEY_CAMERAS.md).
The separate local preview is `build/TORCSSurveyPreview.app`.

Driver, Bonnet and Road now support the original rear-view mirror, with shared
scene resources and reusable crop-sized render targets:
[REAR_VIEW_MIRROR.md](Documentation/REAR_VIEW_MIRROR.md).
That increment’s local preview is `build/TORCSMirrorPreview.app`.

Optional 4× geometry edge smoothing, including the rear-view mirror:
[EDGE_SMOOTHING.md](Documentation/EDGE_SMOOTHING.md).
Classic rendering remains the default. That increment’s local preview is
`build/TORCSSmoothingPreview.app`.

The earlier trackside increment brought the picker to 29 views, including original fixed and zoomed trackside
cameras selected from the track XML: [TRACKSIDE_CAMERAS.md](Documentation/TRACKSIDE_CAMERAS.md).
That increment’s local preview is `build/TORCSTracksidePreview.app`. Open the prepared
`Artifacts/driving-track-shadow-session` through **File → Open Driving Session…**.

Those 29 views support original zoom commands and independent saved zoom values:
[CAMERA_ZOOM.md](Documentation/CAMERA_ZOOM.md). Native camera selection also persists.
That increment’s local preview is `build/TORCSZoomPreview.app`; use the camera row's zoom
buttons and **Zoom options** menu. Original `graph.xml` preference import and
multiple-screen/per-driver preferences remain pending.

The preceding local preview is `build/TORCSFlyPreview.app`, adding **Fly** as the 30th
camera with independent saved zoom. Its reference-tested F10 motion queries the
preceding draw’s track, car, wheels and shadow. Other original scene effects and
LODs remain outside this selected scene.
See [FLY_CAMERA.md](Documentation/FLY_CAMERA.md) for the original behavior and limits.

The TV-camera preview is `build/TORCSTVPreview.app`, adding **TV director** as
camera 31 with original F11 zoom and independent saved preferences. Immutable
per-step collision history and shared screen acknowledgements preserve events
without changing physics. The prepared GUI session still has one car; actual
native three-car selection is compared separately against original code.
See [TV_DIRECTOR.md](Documentation/TV_DIRECTOR.md) for tested behavior and limits.

The multi-car-shadow preview is `build/TORCSMultiShadowPreview.app`. It adds per-car
projected shadows and correct other-car shadow visibility in mirrors. Its native
traffic diagnostic renders three cars and automatic TV target changes; the
interactive driving session still contains one car. See
[MULTI_CAR_SHADOWS.md](Documentation/MULTI_CAR_SHADOWS.md) for the capture command,
reference coverage and performance scope.

The preceding brake preview is `build/TORCSBrakePreview.app`. It restores the original
hubs, discs and calipers behind the wheels, including simulation-driven disc heat
color. The Fly height graph and mirror visibility include these parts. See
[BRAKE_VISUALS.md](Documentation/BRAKE_VISUALS.md) for original-reference checks,
capture commands and measured rendering cost.

The preceding Light preview is `build/TORCSLightPreview.app`. Original brake-light
textures now render from simulation commands, with point culling, body occlusion
and per-car mirror visibility. Open `Artifacts/driving-light-prepared` through
**File → Open Driving Session…**. Older prepared sessions need to be prepared
again to include the light texture. See [CAR_LIGHTS.md](Documentation/CAR_LIGHTS.md)
for reference coverage, capture commands and remaining transparency/content limits.

The validated baseline preview is `build/TORCSOrderPreview.app`. It restores original
scene-anchor and whole-car submission order, the driver's position in the scene
hierarchy, and TORCS's depth comparison/write behavior for overlapping meshes.
Open `Artifacts/driving-light-prepared` through **File → Open Driving Session…**.
See [DRAW_ORDER.md](Documentation/DRAW_ORDER.md) for reference checks, depth
fixtures, performance scope and remaining rendering work. Earlier previews remain
available for comparison.

`build/TORCSFoliageDepthPreview.app` adds an experimental **3D trees** option for
the same prepared session. It uses actual trunk/branch/foliage geometry for 169
Aalborg trees, shared meshes and per-view distance detail; original trees remain
selectable. The option starts off. The latest foliage uses individually oriented
sprays throughout the crown instead of solid ellipsoids. Its fog now recovers eye
depth from fragment position, removing the large classic first-frame difference
in the tested views while preserving the fog formula. It passes 43 focused
release tests and four tree/fog tests under AddressSanitizer. Two normal runs
pass all 56 camera checks and produce identical images between processes;
smoothed views still fail under Metal validation, so the baseline is unchanged.
The stationary 960×640 chase benchmark measures about 0.21–0.27 ms additional
median GPU time for tree mode; full-race performance remains unverified. Close
foliage still looks procedural, and tree shadows remain open. See
[VEGETATION.md](Documentation/VEGETATION.md) for the current boundary and evidence.
