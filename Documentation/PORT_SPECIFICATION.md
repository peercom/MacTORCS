# Goal: Build a faithful native macOS Swift/Metal port of TORCS

Implement a production-quality, native macOS reimplementation/port of **TORCS — The Open Racing Car Simulator**, using **Swift and Metal**, while preserving the behavior, simulation characteristics, race logic, AI/robot behavior, content model, and data compatibility of upstream TORCS as faithfully as practical.

The objective is not to wrap the existing TORCS executable or merely make its existing OpenGL/C/C++ application compile on macOS.

The objective is to create a genuinely native modern macOS application that behaves like TORCS while replacing its legacy platform layer with modern Apple technologies.

The implementation must proceed incrementally and be driven by measurable behavioral parity with the upstream reference implementation.

Do not attempt a wholesale rewrite without reference tests.

---

# 1. Reference upstream

Use:

**TORCS 1.3.9**

as the behavioral and content reference unless the repository already contains a deliberately pinned newer upstream revision.

Record the precise upstream source revision, release archive hash, and provenance in:

`Documentation/UPSTREAM.md`

Do not silently substitute Speed Dreams or another TORCS-derived project.

TORCS 1.3.9 is the current stable upstream release and should be treated as the reference implementation.

---

# 2. Licensing

Licensing is a functional requirement of the project.

## 2.1 Application source code

License all newly written application source code under:

**GNU General Public License v2.0 only — SPDX: GPL-2.0-only**

unless an individual imported/upstream source file already has different compatible licensing terms that must be retained.

Create:

`LICENSE`

containing the full GPL v2 license.

Add where appropriate:

```text
SPDX-License-Identifier: GPL-2.0-only
```

to newly created source files.

Do not remove original copyright or license notices from code derived from TORCS.

If a source file is substantially ported from an upstream TORCS implementation rather than clean-room reimplemented, preserve its copyright attribution in that file.

## 2.2 TORCS assets

Do NOT assume that all TORCS content has the same license.

TORCS data includes assets under multiple licenses.

For every imported:

- car
- track
- texture
- model
- sound
- icon
- image
- font
- documentation asset

retain its original copyright and license terms.

Create:

`Documentation/ASSET_LICENSES.md`

and preferably a machine-readable:

`Resources/asset-manifest.json`

with fields such as:

```json
{
  "path": "...",
  "source": "...",
  "author": "...",
  "copyright": "...",
  "license": "...",
  "upstream_revision": "...",
  "modified": true,
  "notes": "..."
}
```

Do not redistribute an asset if its license cannot be determined or does not permit the intended redistribution.

Assets flagged by upstream TORCS as non-free must not simply be bundled without reviewing their individual terms.

## 2.3 Newly created original assets

Original artwork, textures, UI imagery, documentation diagrams, and other newly created non-code assets should default to:

**Creative Commons Attribution-ShareAlike 4.0 — CC BY-SA 4.0**

unless there is a specific reason to use GPL-2.0-only instead.

Do not relicense existing TORCS assets as CC BY-SA.

## 2.4 Dependencies

Prefer permissively licensed dependencies where external dependencies are actually necessary:

- MIT
- BSD-2-Clause
- BSD-3-Clause
- Apache-2.0 where legally compatible with the final distribution arrangement

Avoid introducing dependencies whose licensing creates uncertainty with GPLv2.

Prefer Apple frameworks and project-owned implementations over unnecessary third-party libraries.

Produce:

`THIRD_PARTY_NOTICES.md`

before the project is considered distributable.

---

# 3. Distribution target

Primary initial distribution:

**direct-download native macOS application**

with:

- Developer ID signing support
- hardened runtime
- notarization
- distributable `.app`
- optional `.dmg`

Do not make Mac App Store distribution a finish condition.

Keep the architecture technically compatible with sandboxing where reasonable, but do not compromise TORCS compatibility merely to satisfy App Store constraints.

---

# 4. Technology requirements

Use:

- Swift 6
- current stable Xcode supported by the development environment
- macOS 14+ initially
- Apple Silicon as the primary architecture
- Metal / MetalKit
- SwiftUI for application shell and configuration interfaces
- AppKit when needed
- GameController.framework
- AVFoundation / AVAudioEngine
- simd
- Accelerate where appropriate
- Swift Package Manager

Do NOT use as the main game/rendering engine:

- Unity
- Unreal
- Godot
- SceneKit
- RealityKit
- SDL rendering
- OpenGL

Metal must be the actual rendering backend.

A small amount of C/C++ interoperability is permitted where required for reference compatibility, legacy robot support, test instrumentation, or staged migration.

The eventual runtime must not require the original TORCS executable.

---

# 5. Architectural principle

Separate the system into:

```text
Application/UI
        ↓
Race Engine
        ↓
Simulation
        ↓
Immutable snapshots
        ↓
Rendering / Audio
```

Never allow the renderer to become authoritative for simulation state.

Simulation must use a deterministic fixed timestep independent of display refresh rate.

The design must support:

- 60 Hz displays
- 120 Hz ProMotion displays
- uncapped rendering where appropriate
- headless simulation
- deterministic regression testing

---

# 6. Repository structure

Create or converge toward:

```text
TORCSMac/
├── App/
│
├── Packages/
│   ├── TORCSCore/
│   ├── TORCSMath/
│   ├── TORCSConfiguration/
│   ├── TORCSSimulation/
│   ├── TORCSTrack/
│   ├── TORCSVehicles/
│   ├── TORCSRaceEngine/
│   ├── TORCSRobots/
│   ├── TORCSAssets/
│   ├── TORCSMetal/
│   ├── TORCSInput/
│   ├── TORCSAudio/
│   ├── TORCSReplay/
│   └── TORCSCompatibility/
│
├── Tools/
│   ├── torcs-reference/
│   ├── torcs-diff/
│   └── torcs-assetc/
│
├── Tests/
│   ├── UnitTests/
│   ├── PhysicsGoldenTests/
│   ├── RaceGoldenTests/
│   ├── RobotGoldenTests/
│   ├── AssetCompatibilityTests/
│   └── RenderingTests/
│
├── Resources/
│
├── Upstream/
│
└── Documentation/
    ├── ARCHITECTURE.md
    ├── UPSTREAM.md
    ├── TORCS_COMPATIBILITY.md
    ├── PHYSICS_PARITY.md
    ├── ASSET_PIPELINE.md
    ├── ROBOT_API.md
    ├── ASSET_LICENSES.md
    ├── PORT_STATUS.md
    └── DISTRIBUTION.md
```

Adjust exact package boundaries if evidence from the actual TORCS architecture suggests a better division.

Do not create packages merely for architectural aesthetics.

---

# 7. Phase 0 — Study and map upstream

Before rewriting major systems, inspect the TORCS 1.3.9 source tree.

Document:

- executable lifecycle
- simulation module architecture
- race engine
- track representation
- car representation
- parameter/configuration system
- graphics interfaces
- robot interface
- sound system
- module/plugin loading
- timing model
- filesystem assumptions
- configuration paths
- race result storage

Produce:

`Documentation/ARCHITECTURE_UPSTREAM.md`

Include a mapping such as:

```text
TORCS subsystem        Native replacement
-----------------------------------------------
race manager       →   TORCSRaceEngine
simu               →   TORCSSimulation
track              →   TORCSTrack
robot.h            →   TORCSRobots
plib/OpenGL        →   TORCSMetal
OpenAL             →   TORCSAudio
GLUT/input         →   TORCSInput
parameter XML      →   TORCSConfiguration
```

Do this before substantial architectural decisions are locked in.

---

# 8. Phase 1 — Build an upstream reference harness

Behavioral fidelity must be measurable.

Instrument or build a reference harness around original TORCS capable of running deterministic scenarios and exporting telemetry.

Output a stable machine-readable representation such as JSON Lines or binary records.

Record at every relevant simulation tick:

```text
simulation time

car position
car orientation

linear velocity
angular velocity

acceleration

wheel positions
wheel angular velocities
wheel slip ratios
wheel slip angles
wheel loads

suspension displacement
suspension velocity

engine RPM
engine torque

gear
clutch

throttle
brake
steering

fuel
damage

aerodynamic forces

track segment
distance along track

lap
race position
lap time

pit state

robot input
robot output
```

Create deterministic reference scenarios including:

1. stationary vehicle
2. constant throttle acceleration
3. full braking
4. steady-state corner
5. combined braking/cornering
6. curb strike
7. grass/off-track behavior
8. barrier collision
9. vehicle-to-vehicle collision
10. spin
11. pit entry
12. pit stop
13. qualifying lap
14. multi-car race
15. multi-lap race

Store reference data separately from generated build output.

### Finish condition

A command can run upstream TORCS non-interactively and generate repeatable telemetry suitable for machine comparison.

---

# 9. Phase 2 — Native macOS shell

Build the native application before attempting the full simulation.

Implement:

- native app lifecycle
- SwiftUI/AppKit application shell
- menu bar
- preferences/settings window
- Metal-backed game view
- fullscreen
- Retina rendering
- resize handling
- keyboard input
- game loop
- logging
- crash-safe configuration directory

Use `MTKView`.

Implement independent clocks:

```text
simulation clock
render clock
wall clock
```

Use a fixed-step simulation accumulator.

Rendering must interpolate between simulation snapshots rather than changing simulation timestep based on frame rate.

### Finish condition

The app launches as a normal native macOS app, displays a Metal scene, responds to resizing/fullscreen, and runs a deterministic fixed simulation clock.

---

# 10. Phase 3 — Math and coordinate compatibility

Determine TORCS coordinate system conventions precisely.

Document:

- handedness
- axis meanings
- units
- angular conventions
- track coordinates
- car-local coordinates
- wheel-local coordinates

Create explicit conversion utilities instead of scattering sign flips throughout the implementation.

Use `SIMD` types where beneficial.

Avoid unnecessary object allocation.

Simulation math should generally use the precision required to reproduce TORCS behavior.

Do not arbitrarily switch the entire simulation between Float and Double without measuring divergence.

### Finish condition

Coordinate transformations have unit tests based on known upstream values.

---

# 11. Phase 4 — TORCS parameter/config compatibility

Implement the TORCS parameter/configuration model.

The native implementation should load original TORCS configuration XML wherever reasonably possible.

Support:

- numeric values
- units
- ranges
- strings
- sections
- nested configuration
- inheritance/overrides where present
- car setup
- track configuration
- race configuration
- robot configuration

Do not leak XML-specific representations into simulation code.

Translate:

```text
TORCS XML
    ↓
compatibility parser
    ↓
native immutable definitions
```

### Finish condition

Representative upstream car, track, race, and robot configurations parse successfully and can be round-tripped or semantically compared against upstream values.

---

# 12. Phase 5 — Track loading

Implement the native track domain model.

Support:

- straight segments
- curved segments
- width
- banking
- elevation
- borders
- curbs
- barriers
- terrain
- surface types
- friction properties
- pit lanes
- starting positions
- cameras
- timing lines

Represent track topology in a way appropriate for simulation rather than simply mirroring XML.

Implement queries required by physics:

```text
world position → track location

track location → world transform

surface at position

distance along track

track tangent

track normal

track width

barrier proximity
```

### Finish condition

At least one complete original TORCS track can be loaded and queried correctly in the native runtime.

---

# 13. Phase 6 — Asset compiler

Build:

`torcs-assetc`

as a command-line Swift tool.

Its responsibility is to convert legacy TORCS assets into efficient runtime assets.

Initially support the formats actually encountered in the selected reference content.

Pipeline conceptually:

```text
legacy model
    ↓
parser
    ↓
canonical mesh representation
    ↓
normal/tangent generation
    ↓
index optimization
    ↓
material translation
    ↓
native binary asset
```

Preserve:

- vertices
- faces
- normals
- texture coordinates
- materials
- hierarchy/group information required by TORCS
- wheel/body separation
- track objects

Create cache keys using:

- source file hash
- compiler version
- settings

Never silently alter source assets.

Compiled artifacts should be treated as derivatives and retain provenance information.

### Finish condition

A representative TORCS car and track can be compiled from original assets and loaded without parsing the legacy model format during normal gameplay.

---

# 14. Phase 7 — Metal renderer

Implement a custom Metal renderer.

Start deliberately simple.

Recommended initial architecture:

```text
Renderer
├── RenderContext
├── ResourceManager
├── CameraSystem
├── TrackRenderer
├── VehicleRenderer
├── Lighting
├── ShadowRenderer
├── EffectsRenderer
├── ParticleRenderer
├── MirrorRenderer
└── HUDRenderer
```

Initial feature requirements:

- track rendering
- vehicle rendering
- wheel animation
- textures
- directional lighting
- basic materials
- shadows
- sky/background
- brake lights
- skid marks
- dust/smoke
- transparent objects
- race HUD
- mirrors
- TORCS-compatible camera positions

Use a depth buffer correctly.

Support MSAA where appropriate.

Do not introduce a complicated deferred renderer merely because it is fashionable.

Optimize based on measured performance.

Create:

```swift
enum RenderStyle {
    case classic
    case enhanced
}
```

`classic` should prioritize visual comparability with TORCS.

`enhanced` may later support:

- improved lighting
- HDR
- better shadows
- improved materials
- GPU particles
- tone mapping

Both modes must render the same simulation state.

### Finish condition

One reference TORCS track and one reference car can be rendered correctly in Metal from multiple driving cameras.

---

# 15. Phase 8 — Physics port

This is the highest-fidelity component.

Do not simplify TORCS vehicle dynamics merely to reach a playable build.

Port subsystem by subsystem.

Suggested order:

```text
mass/inertia
coordinate transforms

track contact

wheel state

suspension

tire forces

brakes

engine

clutch

gearbox

differentials

drivetrain

aerodynamics

vehicle force accumulation

integration

environment interaction

barrier collision

car-to-car collision

damage
```

For each subsystem:

1. identify original upstream implementation;
2. document its inputs and outputs;
3. implement native equivalent;
4. create deterministic tests;
5. compare against upstream;
6. record known differences;
7. proceed only when differences are understood.

Do not “improve” unusual TORCS behavior during the parity phase.

Preserve quirks if necessary.

Use allocation-free hot loops wherever practical.

Prefer plain value structures for simulation state.

Example:

```swift
struct WheelState {
    var angularVelocity: Double
    var suspensionPosition: Double
    var suspensionVelocity: Double

    var slipRatio: Double
    var slipAngle: Double

    var normalLoad: Double

    var longitudinalForce: Double
    var lateralForce: Double
}
```

Avoid:

- actors inside the physics loop
- Combine
- Observation
- unnecessary reference objects
- runtime reflection

### Physics parity tooling

Implement:

`torcs-diff`

It should compare reference telemetry with native telemetry and produce:

- absolute error
- relative error
- maximum error
- RMS error
- divergence over time
- pass/fail thresholds

Generate human-readable reports.

### Finish condition

The selected reference car completes deterministic test scenarios with documented, bounded divergence from upstream TORCS.

No major physics subsystem should remain stubbed.

---

# 16. Phase 9 — Human driving

Implement native input using:

`GameController.framework`

Create an action abstraction:

```swift
enum DrivingAction {
    case throttle
    case brake
    case clutch

    case steering

    case shiftUp
    case shiftDown
    case gear(Int)

    case handbrake

    case lookLeft
    case lookRight

    case changeCamera
}
```

Support:

- keyboard
- Xbox-compatible controllers
- PlayStation controllers
- generic controllers exposed through GameController

Architect steering-wheel support separately so lower-level HID integration can be added if GameController proves insufficient.

Configuration must support:

- bindings
- inversion
- dead zone
- sensitivity
- steering linearity

Never expose physical key codes directly to simulation code.

### Finish condition

A human can drive the reference car for complete laps using keyboard and a standard game controller.

---

# 17. Phase 10 — Race engine

Model race lifecycle explicitly.

Recommended state model:

```text
idle
configuration
loading
grid
preStart
running
finishing
results
```

Implement independent systems for:

- starting grid
- countdown
- timing
- lap counting
- checkpoints
- race order
- qualifying
- practice
- finishing
- results
- pit stops
- penalties where applicable
- championship scoring
- race/session configuration

Avoid one monolithic `RaceManager`.

### Finish condition

Native runtime can conduct:

- practice
- qualifying
- race

with multiple cars and produce correct results.

---

# 18. Phase 11 — TORCS robot compatibility

TORCS's robot system is a critical feature and must remain first-class.

Define a native API analogous to:

```swift
protocol TORCSDriver {
    func initialize(
        car: CarDefinition,
        track: Track
    )

    func drive(
        car: CarSnapshot,
        situation: RaceSnapshot
    ) -> DriverCommand

    func pitCommand(
        context: PitContext
    ) -> PitCommand

    func shutdown()
}
```

Driver command should include at least:

```text
steering
throttle
brake
clutch
gear
pit request
```

During migration, implement a compatibility route allowing legacy TORCS robot code to participate where feasible.

Possible architecture:

```text
Swift race engine
      ↓
C compatibility ABI
      ↓
legacy robot module
```

Do not expose mutable simulation internals to robots.

Robots receive snapshots.

Eventually port representative bundled robots to native Swift while keeping behavior measurable against original implementations.

Document the native robot API in:

`Documentation/ROBOT_API.md`

### Finish condition

At least one original/reference TORCS robot can complete races in the native simulation with behavior comparable to upstream.

---

# 19. Phase 12 — Deterministic replay

Implement replay as an architectural feature rather than screen recording.

A replay should record sufficient information to reproduce a deterministic race, preferably:

```text
simulation version
content hashes
race configuration
random seed
driver commands per simulation step
```

Do not store full transforms every frame unless used as an optional fallback/debug format.

Replay must verify compatibility before playback.

Use replay infrastructure for:

- gameplay replay
- regression testing
- bug reports
- AI research
- benchmarking

### Finish condition

A completed race can be replayed deterministically and arrive at equivalent results.

---

# 20. Phase 13 — Audio

Replace legacy TORCS/OpenAL audio with:

- AVAudioEngine
- AVAudioEnvironmentNode where suitable

Create audio sources for:

- engine
- drivetrain
- tire scrub
- skid
- collisions
- curbs
- wind
- opponents
- environment

Drive engine audio from simulation state including:

```text
RPM
load
throttle
engine characteristics
```

Do not bind audio timing to visual frame rate.

### Finish condition

The driving experience has spatial, state-driven audio without legacy OpenAL dependencies.

---

# 21. Phase 14 — Native user interface

Do not reproduce the old TORCS UI pixel-for-pixel.

Preserve capabilities and information architecture while designing a strong modern macOS application.

Suggested top-level structure:

```text
Race
├── Quick Race
├── Practice
├── Qualifying
└── Championships

Garage
├── Cars
└── Setup

Content
├── Tracks
└── Drivers

Replays

Settings
```

Use native conventions:

- menu commands
- keyboard shortcuts
- sheets
- sidebar navigation
- settings window
- proper focus handling
- VoiceOver/accessibility labels
- native file import/export
- drag-and-drop where useful

Do not make the interface look like a generic web dashboard embedded inside a Mac app.

Gameplay itself remains Metal-based.

### Finish condition

All functionality required to configure and run the core race modes can be reached through native macOS UI without editing files manually.

---

# 22. Phase 15 — Content importer

Implement:

**File → Import TORCS Content…**

Allow selecting:

- a TORCS installation
- a data directory
- compatible car
- compatible track
- compatible robot package

Importer should:

1. inspect package structure;
2. determine compatibility;
3. read metadata;
4. inspect known licensing information where available;
5. validate required files;
6. compile assets;
7. install into application-managed content storage;
8. preserve source/provenance information.

Do not overwrite user content silently.

Unknown/incompatible formats must produce useful diagnostics.

### Finish condition

Supported upstream TORCS content can be imported without rebuilding the application.

---

# 23. Concurrency design

Target architecture:

```text
Main actor
    SwiftUI/AppKit
    menus
    UI state
    input event collection

Simulation execution context
    deterministic fixed timestep
    race engine
    robots

Rendering
    snapshot consumption
    Metal command encoding/submission

Background tasks
    content import
    asset compilation
    file IO
    texture decoding
    cache management
```

Simulation exposes immutable:

`SimulationSnapshot`

objects to presentation systems.

Never allow renderer/audio/UI threads to mutate active physics state.

Avoid gratuitous concurrency.

Correctness and deterministic behavior have priority over maximizing thread count.

---

# 24. Performance requirements

Primary hardware target:

Apple Silicon Macs.

Do not optimize prematurely, but continuously instrument.

Add signposts/profiling for:

- simulation tick
- AI update
- track queries
- collision processing
- asset loading
- draw preparation
- GPU duration

Set initial goals:

- stable 60 FPS on ordinary Apple Silicon
- support 120 Hz rendering where hardware permits
- simulation rate unaffected by render rate
- no recurring allocations in principal physics hot loops
- no shader compilation stalls during active racing after loading
- no synchronous disk IO in the race render loop

Use Instruments to validate major optimization claims.

---

# 25. Headless mode

Retain TORCS's utility for simulation and AI research.

Implement a headless executable or command-line mode capable of:

- running races
- loading tracks/cars/robots
- setting seeds
- setting lap counts
- writing telemetry
- writing results
- running faster than real time where possible

Suggested:

`torcs-sim`

Example conceptual usage:

```text
torcs-sim \
  --track aalborg \
  --cars car1,car2 \
  --drivers robotA,robotB \
  --laps 20 \
  --seed 12345 \
  --telemetry output.jsonl
```

Do not require Metal or a graphical session for headless simulation.

### Finish condition

Automated test/AI races run from the command line without launching the GUI.

---

# 26. Testing strategy

Tests are not optional.

## Unit tests

Cover:

- math
- configuration parsing
- units
- track geometry
- transforms
- drivetrain calculations
- race timing
- results
- content lookup

## Golden tests

Compare native output against upstream TORCS telemetry.

## Integration tests

At minimum:

- load car
- load track
- create race
- initialize driver
- simulate laps
- pit
- finish
- produce results

## Determinism tests

Run the same race multiple times.

Output should remain identical within the explicitly defined deterministic model.

## Rendering tests

Use selected fixed camera scenes and image comparison where practical.

Do not require exact GPU pixel equality when nondeterministic raster effects make that inappropriate.

---

# 27. Compatibility matrix

Maintain:

`Documentation/PORT_STATUS.md`

Use a matrix such as:

```text
Feature                  Status        Parity
------------------------------------------------
XML parameters           Complete      Exact
Track geometry           Complete      Exact
AC model loading         Complete      Semantic
Engine simulation        Complete      < tolerance
Tire simulation          ...
Differential             ...
Damage                   ...
Pit stops                ...
Robot API                ...
Replay                   ...
Audio                    ...
```

Status values should mean something concrete:

- Not started
- Partial
- Functional
- Parity verified

Do not label something "complete" merely because a stub exists.

---

# 28. Engineering rules

Follow these rules throughout the project.

## Preserve behavior before improving behavior

Never intentionally change simulation behavior without:

1. documenting the old behavior;
2. establishing parity;
3. introducing the change as an explicitly separate enhancement.

## No speculative abstractions

Do not invent generalized systems until actual TORCS requirements demonstrate the need.

## No giant translation

Do not mechanically translate thousands of lines of C/C++ into Swift and call the result complete.

Port semantically subsystem by subsystem.

## No fake functionality

Do not:

- hard-code demonstration telemetry;
- substitute simplified arcade physics;
- fake AI output;
- fake asset parsing;
- render static screenshots;
- claim compatibility based solely on loading filenames.

## Keep the project buildable

At every major stage:

- project builds;
- tests run;
- completed functionality continues working.

Avoid enormous unbuildable migration branches.

---

# 29. First playable vertical slice

The first major integrated milestone is:

1. launch native macOS app;
2. load one original TORCS road track;
3. load one original TORCS car;
4. render both through Metal;
5. initialize simulation;
6. accept native keyboard/controller input;
7. allow user to drive;
8. support TORCS-style cameras;
9. complete five timed laps;
10. produce telemetry;
11. compare telemetry against equivalent upstream scenarios;
12. run at stable interactive performance.

Prefer a representative track such as Aalborg unless investigation identifies a simpler track that is materially better for bringing up the simulation.

Do not attempt to port all cars/tracks before this works.

---

# 30. Second vertical slice

Once human driving is stable:

1. add one reference TORCS AI robot;
2. run AI-only headless races;
3. run human versus AI;
4. add multiple AI cars;
5. implement starting grid;
6. implement timing/results;
7. test collisions;
8. test pits;
9. run a 10-lap deterministic race;
10. compare against upstream.

This milestone proves the race engine rather than just the driving model.

---

# 31. Full content milestone

After architecture is proven:

- systematically test all redistributable bundled tracks;
- systematically test all redistributable cars;
- systematically test bundled robot implementations;
- catalog unsupported content;
- resolve parser edge cases;
- build compatibility test fixtures.

Produce an automated content validation report.

Do not allow one malformed asset to crash the entire application.

---

# 32. Documentation requirements

Maintain useful engineering documentation while implementing.

At minimum:

```text
README.md
LICENSE
THIRD_PARTY_NOTICES.md

Documentation/
    ARCHITECTURE.md
    ARCHITECTURE_UPSTREAM.md
    UPSTREAM.md
    TORCS_COMPATIBILITY.md
    PHYSICS_PARITY.md
    ROBOT_API.md
    ASSET_PIPELINE.md
    ASSET_LICENSES.md
    PORT_STATUS.md
    DISTRIBUTION.md
```

README must contain actual working build/run instructions rather than aspirational documentation.

---

# 33. Final completion criteria

Do not declare the project complete until all of the following are true.

## Build

- clean checkout builds with documented commands;
- application builds in current stable Xcode;
- automated tests pass;
- no undocumented local dependencies are necessary.

## Native implementation

- application uses Swift/AppKit/SwiftUI for native application behavior;
- rendering uses Metal;
- audio uses native Apple frameworks;
- standard controller input uses native Apple frameworks;
- original TORCS executable is not required at runtime.

## Simulation

- car dynamics are genuinely implemented;
- tires, suspension, engine, gearbox, drivetrain, aero and collisions are functional;
- simulation runs independently of display refresh;
- upstream parity is measured and documented.

## Content

- selected TORCS source content loads correctly;
- cars are functional;
- tracks are functional;
- asset compilation works;
- licensing/provenance is documented.

## Racing

- practice works;
- qualifying works;
- races work;
- multiple cars work;
- AI drivers work;
- timing/laps/results work;
- pit behavior required by reference content works.

## Presentation

- Metal renderer is functional;
- cameras work;
- HUD works;
- shadows and core effects work;
- audio works;
- application supports Retina/fullscreen.

## Input

- keyboard works;
- at least one modern game controller works;
- bindings and calibration are configurable.

## Research capability

- headless simulation works;
- telemetry works;
- deterministic replay works;
- robot API is documented.

## Quality

- no major subsystem consists solely of placeholder code;
- no obvious race-loop crashes;
- no known high-severity memory-safety problems;
- Instruments reveals no obvious runaway memory growth during repeated races;
- representative races can run repeatedly.

## Licensing

- GPL-2.0-only LICENSE exists;
- source headers are appropriate;
- upstream attribution is preserved;
- asset provenance is recorded;
- third-party notices exist;
- unidentified/non-redistributable assets are excluded;
- redistributable build contains only assets whose distribution terms were verified.

---

# 34. Definition of success

The project succeeds when a user unfamiliar with its internals can:

1. install the application on an Apple Silicon Mac;
2. launch it like a normal Mac application;
3. choose a TORCS car and track;
4. configure a race;
5. drive using keyboard or controller;
6. race against TORCS-compatible AI;
7. experience vehicle behavior measurably consistent with the reference TORCS simulation;
8. finish the race and see results;
9. save/replay the race;
10. import supported TORCS content;
11. run the same simulation headlessly for AI/research use.

The finished application should feel as though TORCS had been designed today specifically for macOS and Apple Silicon while retaining TORCS's simulation identity, AI/research capabilities, content model, and open-source nature.

---

# 35. Execution instruction

Begin by inspecting the repository and upstream TORCS rather than immediately writing large amounts of code.

Create an implementation checklist from the requirements above and work through it autonomously.

Make reasonable engineering decisions without repeatedly asking for approval.

When uncertainty exists:

1. inspect upstream behavior;
2. write a test;
3. prefer compatibility;
4. document the decision.

Do not stop after scaffolding.

Continue through the phases as far as the available environment permits.

At every stopping point, leave:

- a compiling project;
- tests for implemented behavior;
- updated `PORT_STATUS.md`;
- documented next concrete tasks.

The authoritative measure of progress is working, tested functionality—not the quantity of generated source code.