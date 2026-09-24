# Compatibility boundaries

Reference: TORCS 1.3.9, simuv2. See UPSTREAM.md.

## Parameters

Implemented: UTF-8 XML; ordered nested sections; attnum/attstr; Float SI values;
min/max normalization; allowed-string metadata; hexadecimal `0x` values;
semantic serialization (writes exact Float SI values, omits original unit labels).
Unknown unit tokens have factor one, matching upstream. Missing requested
values return the caller's default without unit conversion. Unit tests compare
both conversion directions directly with the original C++ functions.

External entities require explicit in-memory data keyed by entity name. The
parser never follows file or HTTP system identifiers. Text declarations at the
start of external parsed entities are removed before inclusion. Entity recursion,
unsupported internal declarations and missing definitions fail explicitly.

`data/data/tracks/objects.xml` in the pinned release has a Latin-1 byte in a
copyright comment despite declaring UTF-8. Callers must explicitly enable
`allowLegacyLatin1` for this known legacy content; strict parsing rejects it.
Original fixture bytes and notices remain unchanged.

Malformed numbers, nonfinite values, duplicate sections/attributes, excessive
XML size/depth and unsupported elements are rejected with diagnostics. This is
stricter than legacy undefined/error behavior. The immutable merger implements reference-only, target-only, both and neither
modes. Numeric ranges intersect and values clamp in upstream order; string
choices intersect and invalid overrides retain the reference default. Upstream
BOTH-mode duplicate choice behavior is deliberately retained. Native sections
match original serialized merges for focused fixtures; all 292 numeric/string
values in the 155-DTM/category merge match the live original parser exactly.
Type mismatches and root parameters are rejected by the merger. Original file
formatting/comments round-trip, all setup workflows and complete parser
compatibility remain pending.

## Tracks

The native version-4 road builder reads the same immutable parameter model. It
constructs straight/curved segments, changing radii, Hermite/linear profiles,
banking, inherited surfaces, borders/curbs, tapering sides, barriers and static
pit positions/flags. Indexed topology
replaces legacy pointers. Original contact-height, surface-normal, local/global
and side-selection semantics are ported, including metre/radian toStart units.
Aalborg and a targeted synthetic fixture match the original loader and queries
in the tested debug/release builds; see TRACK_PARITY.md for complete scope.

Version-4 camera metadata and F8/F9 trackside views now match the tested original
loader/camera cases; see TRACKSIDE_CAMERAS.md. Selected pit admission/allocation/
timing is implemented as documented below. Complete race behavior, scene coverage,
versions 0–3 and broad upstream-content compatibility remain pending. The static track builder
does not declare a track ready for racing. Invalid subdivision counts and broken
topology fail before simulation; the current limit is 100,000 main subdivisions.

## Physics

Float state; fixed 0.002 s step. Suspension, brakes and steering have isolated
component parity. Later sections cover live configuration, pit service and
integrated vehicle updates. No whole-vehicle parity
or content compatibility is claimed from XML parsing alone. Native mass, CG,
inverse inertia, static wheel loads, axle geometry and fuel parameters match
original SimConfig for the selected car/category; broader configuration coverage
remains pending. Runtime fuel/mass effects are covered by the later vehicle
comparisons. The native wheel ride/contact
stage now combines native track queries, suspension check-in and brake updates
with reference parity across contact limits and a 5,000-tick sequence. Native wheel
forces, tire thermal/wear/grip and free-wheel/rotation stages now match selected
original cases, including a coupled 6,000-tick wheel sequence. Fresh-car wheel/axle configuration and chassis-to-wheel transforms are now
checked against original code. Later sections document collision and pit
reconfiguration integration; full race behavior remains pending.

Preserved force behaviors include clearing ride's airborne flag at force entry,
unclamped neighbouring-surface contributions, raw previous-force storage for
RELAXATION2 and its double 0.01 literal. Exactly sideways motion with zero tangent
velocity retains the original NaN/infinite longitudinal slip; these cases are
classified separately from finite parity results. No epsilon has been invented.
Fresh configuration preserves the original zero-initialized brake inertia and
suspension-rest ordering, parameter clamps and negative tire-base-mass fallback
of 3 kg. Singular derived tire parameters are rejected before dynamic state.
Chassis-to-wheel transforms retain PLIB's radians-to-degrees-to-radians rounding,
rotation ordering and yaw-rate contribution to wheel body velocity. Axle loads
preserve the third spring's strict travel gate without another suspension check-in.
A native four-wheel sequence matches 10,000 original forced-chassis ticks, with
both axles explicitly undriven. Separate driven sequences now cover the original
155-DTM AWD setup and authored RWD/FWD/AWD setups over 16,000 more ticks.

Wear remains Double inside otherwise Float tire state. Thermal updates only run
for skill level 3 with a positive tire rule factor, after forces and before wheel
rotation, so new grip affects the following force tick. Wheel rotation accepts
finite bounded inputs; invalid/nonfinite state is not a supported driving state.

## Reference tools

The original physics harness loads Aalborg and 155-DTM with real collisions and
142 finite numeric telemetry fields per car. Six scripted scenarios are available.
These validate the reference and prepare future native comparison; they are not
native gameplay. Braking checkpoints are sampled every 50 ticks from a complete
release capture. Full captures retain every tick. Telemetry writing uses bounded
memory; `torcs-diff` now streams both inputs and all divergence records without a
total input-size limit. Small-array APIs retain their previous bounds/layout. New
CLI reports use schema 2 with divergence grouped by record; see TELEMETRY_COMPARISON.md.

## Engine and differential kernels

Fresh engine configuration, original torque interpolation, limiter behavior,
engine braking, fuel consumption and broken/eliminated flags are ported. The
original duplicated final curve endpoint retains NaN coefficients; strict lookup
never selects that redundant segment. No interval match retains the prior torque.
Free-rev RPM is not clamped; idle/maximum enforcement occurs only during engaged
clutch coupling. Engine reaction preserves reverse-ratio behavior.

Exhaust pressure and smoke update in original order. The native caller supplies
randomness through a callback, consumed exactly once per fueled RPM update.
Current tests use a common original-platform random value for each test seed;
this is not yet a portable simulation PRNG or global-random-stream parity claim.

Differentials preserve NONE, SPOOL, FREE, LIMITED SLIP and VISCOUS COUPLER,
unknown-type fallback, torque-bias clamps, asymmetric viscosity behavior,
acceleration/braking lock thresholds, wheel brake integration and engine reaction.
NONE still splits input torque when both wheels are stationary, as upstream does.
Malformed/singular configuration is rejected. Pit reconfiguration and selected
vehicle traces are covered below; full content/race parity remains unclaimed.

## Gearbox and drivetrain routing

Fresh setup, reverse/neutral/forward gears, clutch release and all three drive
layouts are ported. Gear holes retain zero ratio/inertia and unit efficiency.
The release branch consumes a whole tick even when its timer expires; automatic
clutch disengagement uses the strict transfer > 0.99 threshold and caps throttle
at 0.1. Cached axis inertias change on gear shifts, even though current inertia
is recalculated on every gearbox update. AWD divides axle feedback torque and
braking by the central ratio, updates the central differential with engine RPM
coupling, then runs both axle differentials using its resulting output torque.
RWD/FWD update the undriven axle before wheel rotation.

Tests preserve independent engine, fuel, transmission and wheel state while
supplying common chassis motion, wheel controls and exhaust random inputs.
This establishes driven component integration, not autonomous vehicle motion.
Unknown drive layouts, singular nonzero-gear efficiency and zero central ratio
are rejected; unsupported invalid configurations are not claimed compatible.

## Body/wing aerodynamics

Fresh aerodynamic setup and original drag, ground effect, wing forces and
multi-car drafting are ported. Body drag uses longitudinal velocity squared;
the ground-effect direction factor uses the caller's 3D speed and is clamped
only below zero. Damage multiplies body and wing drag, not wing lift. Wings
produce zero forces for nonpositive longitudinal speed. Only the rear wing
contributes to the coefficient used for drafting.

Drafting preserves strict speed, relative-direction and yaw thresholds, original
Float-step angle wrapping, and the minimum candidate drag factor. Its front and
rear effects use different coefficients and distance exponents. A NaN candidate
from coincident zero-coefficient vehicles remains ignored by the original strict
comparison; finite result checks cover that behavior. Previous-tick ride heights
and sequential car-update traffic must be supplied in upstream order when these
kernels are connected to the native car loop. Wing pit adjustment checks follow
below; race-level traffic scheduling remains pending.

## Chassis force and motion

Chassis force accumulation includes transformed weight, wheel forces/moments,
body/wing aero, rolling resistance, fuel mass and inverse inertia. It preserves
the legacy wheel roll-center expression, rolling-resistance speed cache and caps,
yaw-rate limit of 9 rad/s, roll/pitch clamp at ±1.04 rad and Float yaw wrapping.
Corners use new velocities but the old pose, preceding position advancement.
The original simuv2 corner-velocity code reads yaw cosine/sine caches that are
never assigned by this module; fresh cars therefore retain zero values. The port
preserves those caches rather than replacing them with current yaw trigonometry.

The coupled mechanical runtime now owns its chassis motion as well as engine,
fuel, drivetrain and wheel state. Three 6,000-tick comparisons match the original
with identical initial state and controls. Ground, barriers and car-to-car
collision are explicitly absent from both paths: the oracle calls unchanged
SimCarUpdate directly while its existing NO_SIMU bit makes the two environment
functions return. It does not call the full SimUpdate scheduler under that flag.
This isolates genuine mechanical integration without claiming full vehicle/race
compatibility. A separate integrated path now adds ground/barrier response below.
Subsequent sections cover driver controls, atmosphere scheduling, car collisions,
pit setup changes and random-stream ownership. Race management remains pending.

## Ground and barrier response

Native environment response preserves SimCarCollideZ then SimCarCollideXYScene,
including per-corner ordering, NO_SIMU early returns, FINISH damage suppression,
skill/rule scaling and truncation to integer damage for each impact. Ground
contacts rotate penetrating corners, remove inward world normal velocity and mark
a crash below the strict -5 m/s normal-speed threshold. They do not snap the
center vertically onto the road. Barrier response uses the corner's existing
velocity, corrects center position before computing the lever arm, applies
friction, caps world yaw velocity at ±6 rad/s, adds damage and then rebounds.

Only world dynamics change. Body dynamics, corner samples and cached track
location retain their previous values; normal/impact-position metadata persists
across ticks and its Z fields remain untouched by barrier updates. Damage is now
generated by the native path and influences following-tick aerodynamic drag.
Five coupled 6,000-tick comparisons exercise stationary, acceleration/braking,
steering, a drop and a barrier strike. They call real original environment
routines, without the collision-skip flag used by the isolated chassis test.
Original corner-based barrier detection's convex-edge limitation is retained.
Integer-overflow/nonfinite damage is rejected; upstream's undefined integer
conversion behavior is not claimed compatible. Car-to-car detection/response and
full vehicle/race scheduling remain pending.


## Active-car commands and owned random state

Driver commands now use original ctrlCheck ordering, including nonfinite cleanup,
broken/finish overrides, clamps and clutch complement. Configuration drives
steering and brake pressure. The atmosphere remains the original constant
293.15 K / 101300 Pa. Settling, prestart and running follow the original active-car
stage gates; fresh and post-settling prestart preserve frozen mechanical state.
`stepActiveVehicle` rejects removal/towing/pit lifecycle inputs explicitly.

The native single-car harness independently loads pinned Aalborg/155-DTM XML,
places and settles the car, advances at 500 Hz and exports the reference's 142
fields. Its owned Swift Park–Miller state reproduces the tested Darwin rand/urandom
sequence, including zero and large seeds, without process-global RNG state.
No same-seed equivalence to other systems' libc generators is assumed. Five
scripted scenarios now have full SimUpdate comparisons and continuous-stream
telemetry comparisons. The multi-car extension below adds box/box collisions;
later sections add fixed-object detection and lifecycle/removal. Pit-time
reconfiguration is described below; race/robot execution remains open. Prior sections describe
historical component-test boundaries; these new paths add the control scheduling
and random ownership that those tests intentionally omitted.


## Car/car and fixed-wall response kernels

Native response now preserves original car-index ordering, PIT participation,
planar normal narrowing, blocked separation, accumulated VelColl, per-impact
integer damage, ±3 rad/s yaw limiting and callback matrix refresh. The response
uses stale public orientation/transform separately from current world dynamics.
Car/car and fixed-wall formulas remain distinct where the original differs.
Direct callback sweeps and three-body contact sequences match the original.
These response tests supply contacts explicitly. See COLLISION_PORT.md for
their exact boundaries and the subsequent detection work.

## Convex queries and active multi-car loop

Native Double support maps, determinant GJK, relative/world queries and SMART
contacts now preserve the original previous/current-transform distinction,
tolerances, polygon cursor and degenerate-result classifications. The native
multi-car loop advances previous poses only after a dispatch with zero detected
pairs. Each callback can update cached transforms for subsequent pairs, and
accumulated velocity commits after all contacts. Body state and public pose lag
are preserved. Drafting reads sequentially updated traffic; random draws share
one owned stream across cars.

Two-car and three-car runs independently load and evolve native/reference state,
then compare 142 fields per car for 3,000 and 2,000 ticks respectively. Native
dispatch uses stable car indices; these runs verify the selected original object
ordering, not all allocation-dependent orderings or platforms. The query tests
separately cover boxes, simplexes and convex polygons. The fixed-wall extension
below adds complex/convex dispatch, followed by the removal/towing integration.
Pit service physics follows below; race scheduling remains open.

## Fixed wall/car collision

Native wall geometry retains original cap vertices, x-only continuity checks,
Float height arithmetic and left/right object ordering. The polygon hierarchy
preserves partition swaps, tie handling and first-hit traversal. Affine inverse
and composition retain original transform type flags: an imported rotation matrix
still takes the full inverse branch. Current-pose primitive selection and
previous-pose closest points remain separate operations.

Single- and multi-car APIs now share the same dispatcher. Each car visits fixed
walls before its earlier-index car partners on the tested reference host. Wall
hits also prevent global previous-pose advancement. Integrated left/right
strikes compare 6,000 ticks against original SimUpdate after independent setup
and settling. Original geometry is observed during actual buildWalls calls;
native geometry comes from native XML/track construction.

The fixed-pair extension below adds complex/complex dispatch. Deforming polygon
bases remain outside the static-wall scope. Unfinished closed wall rings and more than 100 fixed objects
produce native diagnostics rather than relying on upstream's broken/truncated
construction. See COLLISION_PORT.md and wall-collision-parity-report.json.

## Fixed-pair counting and mixed collision dispatch

The dispatcher now tests fixed-object pairs before car contacts. Complex/complex
queries retain original six-axis bounding rejection and hierarchy split/traversal
order. Contacts that trigger the wall callback's NaN-normal early return still
count, preventing previous-transform advancement exactly as dtTest does.
Original wall callbacks assume their partner is a car. When a fixed-pair normal
would pass that early-return gate, native code rejects the invalid track rather
than dereferencing a wall as a car or inventing a response.

Original-object diagnostics identify eleven invalid cases among twelve crossing
fixtures; those unsafe callbacks are not invoked. Separate full SimUpdate tests
verify a 3,000-tick fixed-contact run and 7,000 ticks of three-car left/right wall
pileups, including simultaneous wall/car and car/car contacts. All state evolves
independently. Allocation-order equivalence beyond the tested host/cases remains
unclaimed. Current evidence is in fixed-mixed-collision-parity-report.json.

## Removal and towing kernel

A separate native VehicleRemovalState now matches the original RemoveCar kernel
for damage/pit/coasting gates, collision unregistration and all three towing
phases. Published dynamics and display matrices remain distinct from mechanical
state, including the stale initial matrix and original strict phase thresholds.
Six complete independently evolving towing trajectories and boundary sweeps
compare 10,309,416 finite values exactly; six NaN outputs are classified separately.
A missing pit on a broken pit car raises an explicit diagnostic instead of the
original null dereference. See REMOVAL_PORT.md and removal-parity-report.json.

The normal single/multi-car update now owns and schedules this state. It preserves
coasting before towing, collision unregistration, inactive pit-object participation,
separate published/body/world motion and default flag persistence. The isolated
stepActiveVehicle kernel still requires active inputs; managed simulation handles
lifecycle decisions before entering its internal active stage.

Eight full-update scenarios compare mechanical and published state against actual
original SimUpdate, including moving damage/elimination, fuel exhaustion, pit release,
pit contact, surviving-car collisions and prestart states. Collision detection uses
a retained pit-object transform while response uses the published matrix; their
one-tick difference is preserved. Each scenario also checks the final RNG stream.
See lifecycle-parity-report.json. Pit service physics and race pit management
follow below; the full race/gameplay layer remains unfinished.

## Pit setup and reconfiguration

Native PitSetup loads all 89 value/minimum/maximum triples and three differential
identifiers using original missing-field and bounds-only semantics. The complete
SimReConfig operation now applies fuel, repairs, steering/brakes, wing and axle
settings, wheel alignment/suspension, tire replacement and driven differential/
gear settings. Original fixed-parameter gates, ignored differential type requests,
reverse-ratio sourcing and retained gearbox caches are preserved.

Mechanical tire wear remains Double; published wear narrows to Float. Service
changes mechanical tire state immediately while PIT cars retain published tire
values until active copy-back. Forty configuration operations and nine services
followed by 13,500 ticks across AWD/RWD/FWD compare exactly against unchanged
original code. See PIT_SERVICE.md and pit-service-parity-report.json.

These are physics-boundary service calls. Race pit integration now adds admission,
shared assignment, duration and release; see RACE_PITS.md. It retains immediate
service, strict deadline release, session setup restrictions and the first
teammate’s stall bounds. Original pit functions are reference-tested directly.
Penalty enforcement, complete race execution and gameplay remain open.


## Legacy AC/ACC scenes and compiled meshes

The native parser now preserves selected original scene construction, coordinates,
UV layers, materials, strip grouping and indices. Both pinned meshes and authored
edge cases compare against unchanged original grloadac.cpp before graphics or
SSG optimization. A validated binary cache retains source/options identity and
round-trips exact Float storage. Malformed input is diagnosed with bounded reads
and structural checks. See ASSET_PIPELINE.md for compatibility quirks, limits and
reproduction commands. SGI/PNG textures now have original pixel/mipmap comparisons and validated native
caches; Metal upload uses unorm bytes. PNG behavior is pinned to original
GfImgReadPng with bundled libpng 1.6.50; the native app uses ImageIO decompression
and explicit compatibility transforms. Four speed-dependent wheel meshes also
match original loading. Compressed AC files, complete race rendering and content
installation remain unfinished.
See ASSET_PIPELINE.md for channel/alpha/downsize behavior and strict input limits.

Compiled model inspection now renders the selected body/track/wheel geometry in
Metal with tested UV orientation, depth, culling and material states. Hierarchy
transforms compare against original PLIB. Inspection lighting, transparency sort
order and absent reflections/effects prevent a full visual-parity claim.
See SCENE_RENDERING.md; the first playable slice is still open.

The assembled vehicle diagnostic renders body, track and four speed-selected
wheels from immutable physics snapshots. Published wheel values match the original
simulation exactly in 2,002 samples; graphics transforms have bounded Float
differences from PLIB. See VEHICLE_PRESENTATION.md for measured errors and limits.

Native keyboard driving now connects the selected simulation to the renderer in
a live window. Original F2 very-near chase-camera arithmetic compares exactly in
1,000 updates, including per-graphics-update relaxation and yaw-wrap behavior.
This is not legacy human-robot input parity or completed practice/race behavior;
see DRIVING_SESSION.md.

The live session now integrates a selected human lap-timing kernel compared with
original ReManage/ReRaceRules: crossing/reversal, best-lap validity, speed/distance
and finish boundaries. This includes original Float start-time narrowing. Native
telemetry records each physics tick and its resulting timing state. The physical
oracle scenario crosses the start line once; authored five-lap boundary tests do
not establish physically completed laps. See LAP_TIMING.md.

## Native input

GameController extended profiles and configurable keyboard/controller bindings now
feed the native driving session. Selected original human joystick branches match
exactly in 13,032 cases. Keyboard ramps, assists, original robot scheduling and
physical gamepad driving are not verified. See INPUT.md for the precise boundary.


## Camera zoom preferences

All 31 native camera presets support original grcam zoom/default arithmetic and
factory limits, including distance-scaled circuit/trackside views. Native selection
and zoom persistence uses one viewport's `cameras.json` with original `fovy-head-id`
keys. Original `graph.xml` import/export, multiple-screen/per-driver preference
selection and keyboard zoom bindings remain pending. See CAMERA_ZOOM.md for exact
reference-test coverage, file validation and native rendering evidence.

## Fly-camera kernel and scene height

The F10 motion kernel matches 48,000 original updates over four seeds, including
clock holds, reselection, time jumps, target changes and scenery clamps. Native
camera RNG ownership is separate from physics. The static raw-AC height query
matches original PLIB traversal for selected meshes and authored edge/hierarchy
cases, including the 99-hit cap and original indexed-array limitation.

The Fly camera is now in the driving picker. Selector traversal and moving
assembly bounds are reference-tested; the selected native scene preserves
anchor order and previous-draw query timing. Complete original-scene parity still
requires other LODs, generated effects/geometry, callbacks, multiple-car sorting
and optional loader optimization for content that enables it. Existing native
transform tolerances also apply; exact query tests use identical input matrices.
See FLY_CAMERA.md, fly-camera-kernel-report.json and
fly-camera-integration-report.json for scope and evidence.

## Automatic TV director

Original F11 priorities, strict interval gates, screen exclusions, tie/fallback
rules, retained race-slot behavior and collision clears are now reference-tested
across 24,000 sequential updates plus boundary cases. Selected-camera pose and
projection match original comparisons, including changing targets. Native
presentation collision history preserves events across display cadences and
shared screen clears without mutating physics. Race-frame publication,
F11 saved preferences and the single-car picker are integrated. Native three-car
publication and shared screen acknowledgements match original selection in tests;
full standings, multiple visible screens and multi-car GUI acceptance remain pending.
See TV_DIRECTOR.md, tv-director-report.json and tv-integration-report.json for
scope and evidence.


## Per-car projected shadows

Multiple cars now use ordered six-vertex shadow strips with independent normals
and texture resource slots. Identical mip bytes share GPU storage. The original
current-car visibility block is compiled as an oracle; 2,696 cases match, and GPU
fixtures verify overlap order, mirror visibility and separate normal lighting.
Native scripted three-car traffic renders automatic TV target changes with all
three shadows; the Driver mirror submits only the other two. This is not a claim
of native AI, race sorting, multi-car GUI play or whole-scene GL pixel parity.
See MULTI_CAR_SHADOWS.md and multi-car-shadows-report.json for validation, unchanged
single-car captures and the limited stationary timing experiment.

## Generated brake visuals

Original hub/disc/caliper geometry now appears behind detailed wheels, including
original unlit disc color driven by published brake temperature. Attachments
precede wheel spin and respect current-car mirror visibility. Selected geometry
matches original initWheel exactly in 960 cases; generated brakes in the Fly
height graph match 20,736 original PLIB queries. The prepared single-car app and
scripted traffic diagnostic both include the parts. Other generated effects and
whole-scene OpenGL pixel parity remain outside this evidence. See BRAKE_VISUALS.md
and brake-visuals-report.json.

## Car-light groundwork

Original counted/numbered configuration, on/off rules, world transforms,
billboard corners and rotating texture coordinates are reference-tested. Current
brake/headlight commands publish through immutable visual snapshots, and generated
light draws use isolated presentation randomness. Selected vertex/matrix/state
and random-sequence comparisons are exact on this host. GPU light submission,
texture loading, view scheduling and scene-bound integration remain pending;
this is not visible brake/headlight support yet. See CAR_LIGHTS.md.
