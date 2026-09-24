# Native architecture

One Swift 6 SPM manifest uses macOS 14+ targets. Targets are introduced only
when they have implementation and tests. Open Package.swift in Xcode or use
`swift build` / `swift test`.

- TORCSCore: tick-derived 500 Hz clock, immutable snapshots, atomic JSON storage.
- TORCSMath: explicit Z-up/yaw transforms and track-distance unit boundary.
- TORCSConfiguration: ordered immutable sections, Float units, XML adapter and reference/target merge semantics.
- TORCSTrack: native version-4 road/border/side construction, immutable indexed
  topology, surfaces, barriers, static pits, local/global and contact queries.
- TORCSSimulation: native mass/inertia configuration, wheel ride/contact, tire forces,
  heat/wear/grip, free-wheel rotation, suspension, brake and steering. Original update
  ordering is exercised with forced-input tests and the selected prepared driving session.
  Fresh wheel/axle configuration feeds a fixed-storage four-wheel runtime with
  chassis-to-wheel kinematics and axle load sharing. Engine and differential kernels
  connect through the original clutch/gearbox and RWD/FWD/AWD routing.
  Body/wing aero, drafting and chassis force/motion connect through an independent
  vehicle runtime with ground/barrier response and damage. Car-to-car collision
  response, control scheduling, atmosphere and removal/towing now run through
  MultiVehicleSimulation. It owns RNG and retained collision/published transforms.
- TORCSRaceEngine: prepared driving-content loading, pit assignment, admission,
  service timing and shared occupancy;
  RacePitSimulation applies policy after physics and pauses for pit-menu completion.
  DrivingRuntime schedules single-human lap timing after physics, stops on finish,
  and exposes per-tick diagnostic capture. Complete race startup, sorting, penalties,
  persisted results and drivers remain pending. CarLightDefinition preserves
  original numbered graphics configuration; prepared content exposes these definitions.
- TORCSTelemetry: streaming atomic JSONL capture and lockstep file comparison,
  strict alignment, online metrics and complete streamed schema-2 error reports.
  Small-array APIs remain for bounded fixtures.
- TORCSInput: validated action bindings, atomic input settings, original human-axis
  arithmetic and a main-actor GameController adapter. Framework snapshots and button
  events produce DriverCommand values; devices and physical keys stay outside physics.
- TORCSAssets: bounded native AC/ACC parsing, scene/state hierarchy, strip-to-triangle
  conversion, SGI/PNG images, faithful CPU mipmaps, binary caches and ordered content
  lookup, plus original generated hub/disc/caliper geometry; torcs-assetc compiles without graphics. Content installation and complete scene rendering remain pending.
- TORCSPresentation: camera and vehicle presentation logic with no renderer
  dependency — 31 original camera presets, saved zoom, the fly camera and TV
  director, the rear-view mirror camera and layout, and `VehiclePresentation`'s
  original wheel placement/LOD rules and snapshot interpolation.
- TORCSRender: the physically based, linear-HDR Metal path (`ForwardRenderer`):
  cascaded shadows, atmosphere, occlusion, screen-space reflections, motion blur,
  bloom, spatial upscaling with dynamic resolution, generated road/terrain/grass/
  tree geometry and generated materials. See RENDERER_REPLACEMENT.md.
- TORCSMac: SwiftUI/AppKit lifecycle, settings, menu, keyboard event collection.
- CReference: original TORCS physics, track loader, parameter parser, SOLID and
  PLIB mathematics and original pit-management routines, linked only into tests
  and the reference CLI. Original ACC parsing uses scene-storage adapters with no GL
  calls; its boundary is in ASSET_PIPELINE.md. GfImgReadPng uses reference-only
  PNGReference (pinned libpng); the native decoder uses ImageIO and explicit
  gamma/palette/alpha compatibility transforms. Headless pit oracle boundaries are in RACE_PITS.md.
- TORCSReferenceSupport: tool-only world lifecycle, pinned fixture staging and
  scripted controls. Upstream global state permits one reference world per process.

Main actor currently runs a small simulation execution context via a 120 Hz wall
clock timer. Each callback drains fixed 2 ms ticks independently of MTKView draw
callbacks. Work caps preserve accumulator backlog; OS sleep (wall gaps >=1 s) is
an explicit application pause. Rendering never advances the clock or mutates
component state. Immutable previous/current snapshots are interpolated only for
display. UI status refresh is 5 Hz, separate from physics and rendering.

This small workload does not justify a dedicated thread yet. Move the execution
context behind a bounded snapshot handoff before multi-car simulation; do not
put actors/Observation/Combine inside physics. Audio and driver interfaces must
consume immutable snapshots. Signposts cover simulation batches and draw
preparation; no performance target is claimed without Instruments evidence.

The native app has no dependency on CReference. Physical controller/HID validation,
audio, full race state and replay remain pending.

`RunningGearState` owns four wheels in fixed value storage. Each tick locates all
contacts, calculates both axle loads, then updates each tire's force and thermal
state. The caller supplies actual chassis state and controls. Undriven axles
produce free-wheel spin inputs; driven inputs come from `TransmissionState`. Rotation runs after those inputs are available.
Pre-simulation mode resets tires after thermal updates in original order.
This runtime does not move the car or emulate engine power with a placeholder.

`EngineDefinition` owns the immutable original torque segments and metadata;
`EngineState` owns RPM, torque and exhaust state, while fuel stays with the caller.
RPM coupling takes a nonescaping random-input callback and consumes it only when
upstream does. `DifferentialDefinition.update` implements every original mode
and invokes engine reaction only when explicitly marked as the primary differential.
`TransmissionDefinition` holds gear ratios/inertias and the active differentials.
`TransmissionState` retains selected gear, clutch timing and cached axis inertias.
Gearbox update precedes engine torque; wheel forces precede transmission routing,
and wheel rotation follows it. AWD runs the central differential first, calls
engine RPM once, then applies both axle differentials. RWD/FWD update the other
axle through a nonescaping free-wheel callback. Tests connect these native stages
with independent state against original routines; the app remains the lab.
MultiVehicleSimulation owns the tested Darwin-compatible random stream.

`AerodynamicsDefinition` owns body and wing coefficients and positions. It returns
body drag/front-rear lift and wing forces using supplied motion, damage and traffic.
It uses the existing wheel ride heights, before the next ride update. Drafting
consumes traffic in simulation car-index order and skips the subject car; the
vehicle loop preserves which opponent states upstream has already updated.
These aerodynamic kernels now also feed the coupled vehicle runtime.

`VehicleRotation` shares the original PLIB arithmetic between wheel transforms,
body/world force and velocity transforms, and corner positions. `ChassisState`
retains both original dynamic records and their previous-world snapshot; they
must remain distinct because later collision stages can update them unequally.
Force accumulation uses current fuel mass and existing wheel/aero loads. Velocity
advances before corner sampling and position/orientation advances. Track lookup
then locates the new center. Rolling resistance uses the preceding speed cache;
the legacy corner yaw sine/cosine caches retain their original zero defaults.

`VehicleDynamicsState.stepWithoutCollision` connects native gearbox → engine
torque → aero → wheel contacts/axles/forces/thermal → drivetrain/RPM → wheel
rotation → chassis integration. Brake pressures and steering angles arrive at
the component boundary; the active scheduler supplies them after driver checks.
It owns all evolving mechanical state; comparison tests send no chassis/wheel
results between implementations. The method name explicitly excludes environment
and car collision. MultiVehicleSimulation supplies atmosphere, driver checks,
owned randomness and collision/removal scheduling. Native keyboard driving now connects these stages to Metal snapshots;
complete race logic, physical controller validation and presentation remain pending.

`VehicleDynamicsState.step` adds ground then barrier response after chassis motion.
`CollisionState` retains cumulative integer damage and last impact metadata;
only collision flags and blocked state reset each tick. The original updates only
world-space pose/velocity during environment response. Body-local dynamics,
corner samples and the track-location cache remain untouched, preserving their
upstream timing. Ground contacts can rotate corners and remove incoming normal
velocity without pushing the center vertically onto the surface. Barriers apply
position correction, friction, yaw-rate cap, damage and rebound per corner.
The explicitly named `stepWithoutCollision` remains useful for isolated regression.
These component entry points remain separate from the complete physics stage
ordering in MultiVehicleSimulation. RacePitSimulation layers verified pit policy
on that scheduler without making it a complete race engine.

The scene inspector loads a bounded `scene.json` index and binary mesh/texture
caches on a background task. `SceneGeometry` resolves hierarchy transforms;
`ForwardRenderer` draws from `SessionRenderResources` prepared once per session.
Inspector orbit state is independent from simulation. `torcs-assetc --scene`
resolves explicit content roots and stages a complete new directory; it is not
yet the user content installer or a redistributable content bundle.

`VehicleVisualSnapshot` copies published body/wheel state at the simulation boundary.
`VehiclePresentation` applies original wheel placement/LOD rules and interpolates
transforms without mutating physics. `ForwardRenderer` shares prepared mesh resources
across instances and scopes texture bindings per resource. The assembled
vehicle diagnostic connects these pieces to real native physics; a realtime driving
session and original chase camera are integrated below. See VEHICLE_PRESENTATION.md.

The native driving window now uses an isolated Swift actor owning `DrivingRuntime`,
with an independent timer and fixed 2 ms updates. Main-actor keyboard state becomes
driver commands; the worker returns immutable `DrivingFrame` values. Metal draws
interpolated body/wheel instances and a reference-tested chase camera. See
DRIVING_SESSION.md for ownership, suspension and current limits.

DrivingRuntime resides in TORCSRaceEngine. RaceLapTiming preserves original crossing,
validity and Float lap-start behavior; timing and completed-lap values travel in the
immutable frame. Optional telemetry observers execute once per completed fixed tick
on the worker, never in draw callbacks. A continuing clock callback ends a batch at
the terminal tick. See LAP_TIMING.md.

Car lights publish configuration and current command state independently of
simulation randomness. The renderer receives the raw brake and light commands
and lights the car's lens geometry through an emissive material channel, so
brake lights and headlights need no billboard, culling or mirror bookkeeping.
The classic point-billboard path and its `CarLightRenderState` are retired; see
RENDERER_REPLACEMENT.md.

Scene submission no longer reproduces the original anchor order. The forward
path sorts opaque batches by pipeline and material, draws cutouts and
translucents after opaques, and reads depth through a prepass; the original
draw-order and alpha-state comparisons are retired with the classic path. See
RENDERER_REPLACEMENT.md for the decision record.