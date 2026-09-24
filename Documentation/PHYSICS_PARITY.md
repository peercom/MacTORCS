# Physics parity evidence

The independent oracle compiles original simuv2 physics, full params.cpp,
track3/track4 construction, rttrack queries, PLIB math and SOLID collisions.
Original dynamics equations are unchanged. Documented platform adaptations are
in UPSTREAM.md; no oracle code is linked into the native app.

## Reproduce

```
Scripts/verify.sh
```

This writes generated results under ignored `Artifacts/`. Committed golden
samples are under `Tests/PhysicsGoldenTests/Fixtures`, separate from build output.
`components.jsonl` was generated using:

```
swift run torcs-reference --ticks 512 --telemetry Tests/PhysicsGoldenTests/Fixtures/components.jsonl
```

Do not regenerate a golden file merely to make a regression pass. Inspect the
reference change and update its provenance first.

## Current coverage

- Suspension: compression/extension flags, packers, bellcrank, preload,
  compression-only spring, piecewise bump/rebound, 10 m/s damper clamp and
  nonnegative combined force. Tests sweep three bellcranks and boundary values.
- Brakes: pressure split with driver click and repartition limits; torque;
  cooling before heating; normalized temperature clamping.
- Steering: slew rate and asymmetric Ackermann wheel angles, including command
  reversals and zero crossings.
- Unit conversion: forward and inverse original functions, compound/unknown units.

The deterministic `component-sweep-v1` scenario carries 10 output fields for
10,000 consecutive ticks (20 s); suspension input is externally forced, while
brake temperature and steering state persist. This is **not a vehicle scenario**.
Debug testing on Apple Silicon with Swift 6.3.3/Xcode 26.6 found maximum absolute,
relative and RMS error of zero on all ten sweep fields. Release results are
recorded in PORT_STATUS.md after verification.

Default acceptance: `abs(candidate-reference) <= 1e-5 + 1e-6*abs(reference)`.
Diff fails on missing/extra fields, tick/time misalignment, scenario mismatch,
empty logs, nonfinite values or unsupported schema. Reports include per-field
maximum, RMS, failure count, first divergent tick and every sample's divergence.
Relative diagnostic error divides by max(abs(reference), 1e-30); pass criteria
use the unmodified reference magnitude. CLI exits 0 for pass, 1 for divergence,
2 for invalid input. The CLI now streams inputs and schema-2 reports; see
TELEMETRY_COMPARISON.md for the versioned divergence layout and RMS summation detail.

Determinism scope is this source/toolchain/architecture and the covered inputs.
Cross-architecture bit identity and long-race stability have not been established.
Native Float arithmetic is deliberate; do not change precision without evidence.

## Full original physics harness

```sh
swift build -c release
python3 Scripts/verify-reference-world.py
```

The harness loads the pinned Aalborg geometry (371 segments, 2587.543457 m)
and merged 155-DTM/category configuration using original code. It executes
SimInit/SimConfig/SimUpdate/SimShutdown and real collisions, with deterministic
scripted driver commands, seed 12345 and 2 ms steps. Initialization applies
501 updates with full brake and race state zero, then starts measured running
time at tick one. This defined setup is not the complete race-engine startup.

Captures contain 142 finite fields per car: pose, local/world velocities,
accelerations, engine/drivetrain outputs, commands, fuel, damage, aero and four
wheels' contact, forces, spin, slip, suspension and brake values. No unimplemented
race or robot fields are populated. Metadata includes source and executable
hashes, seed, starting positions, timestep, track and parser adaptation.

Six release captures repeat byte-for-byte in separate processes: stationary,
acceleration, braking, scripted cornering, combined braking/steering, and two-car
collision. The cornering case reaches the barrier and is **not steady-state
cornering validation**. Compact evidence: `reference-world-report.json`.
Tests additionally rebuild the same world in-process and compare all fields,
verify stationary four-wheel loading, acceleration followed by braking, collision
damage, and rejection of unpinned input. The four world tests pass with Address
Sanitizer; this is bounded scenario coverage, not a long-race memory audit.

Braking golden checkpoints in `Tests/UnitTests/Fixtures` retain every 50th tick
from 3000-tick captures; their metadata identifies this sampling explicitly.
Debug and release have separate baselines because compiler optimization produces
different floating-point trajectories in the original C++ engine. Each build is
compared exactly with its own baseline, never asserted cross-build identical.
The complete generated captures remain under ignored Artifacts/reference-world.

Native additions: all 292 merged car/category values and mass/CG/inertia/static
wheel loads/fuel/axle geometry compare exactly with original configuration in
tests. These are static configuration checks, **not native vehicle dynamics**.

## Native wheel ride/contact stage

`WheelRideState.update` ports SimWheelUpdateRide in the original order: locate
the contact segment, compute road normal/height, derive wheel-space travel from
previous spring-space travel, apply relative wheel velocity, check ground and
packer limits, set airborne state, apply suspension check-in/bellcrank scaling,
calculate suspension velocity and update brake torque/temperature. It preserves
unrelated wheel flags and keeps suspension flags separate.

The tests use the native Aalborg XML builder and native geometry queries. The
oracle constructs an isolated original tCar/tWheel from the same input state and
calls unchanged SimWheelUpdateRide; it does not copy the Swift calculations.

```sh
swift test --filter WheelRideTests
swift test -c release --filter WheelRideTests
```

- 3,960 independent contact cases cross road edges, suspension bounds and three
  bellcrank ratios. Observed states include 990 compressed, 660 extended, 2,952
  airborne and 1,008 grounded cases; these counts overlap across flag groups.
- A separate 5,000-tick forced-position sequence carries native and original
  displacement, relative velocity, flags and brake state independently.
- All compared values have zero observed error in tested debug/release builds.
  Track/contact tests also pass under Address Sanitizer; compact evidence is in
  `wheel-ride-parity-report.json`.

This is a coupled geometry/ride/brake stage, not a full tire model or vehicle.
Positions are supplied by the contact-only tests. Later running-gear checks below
cover fresh configuration and wheel kinematics; whole-vehicle integration remains
pending. Forces are checked separately below, not inferred from contact checks.

## Native wheel force, thermal and rotation stages

The semantic force port consumes checked spring-space travel without running
suspension check-in twice. It preserves vertical wheel inertia, load clamping,
slip angle/vector, the original tire force formula, load sensitivity, skill
factors, caster/camber, neighbouring-surface blending, rolling resistance,
RELAXATION2 history and drivetrain feedback. Force entry clears wheel flags as
upstream does, including the ride stage's airborne flag. Previous relaxation
state stores the raw force; the macro's final multiplication uses double 0.01.

Thermal state preserves the original mix of Float and Double arithmetic (wear
is Double), convection and hysteresis, pressure, rubber/gas heat capacity,
graining and grip, skill/rule gating and tire reset. Updated grip applies on the
following force tick. Free-wheel rotation includes tire torque, axle inertia and
braking without reversal. Rotation then relaxes the supplied drivetrain spin,
advances angle and applies the original float-step/double-bound angle wrapping.
Accepting a drivetrain input does not establish differential behavior; that kernel
has separate checks below.

```sh
swift test --filter 'WheelForceTests|WheelThermalRotationTests'
swift test -c release --filter 'WheelForceTests|WheelThermalRotationTests'
swift test --scratch-path .build/asan --sanitize address --filter 'WheelForceTests|WheelThermalRotationTests|WheelRideTests'
```

The oracle adapters populate isolated original structures and call unchanged
SimWheelUpdateForce, SimWheelUpdateTire, SimWheelResetWear, SimUpdateFreeWheels
and SimWheelUpdateRotation. They restore the process-global timestep/tire rule
factor. Geometry comes from the original loader; native tests use the Swift XML
builder. Inputs are shared, but each sequential implementation owns its evolving
travel, relative velocity, force history, brake, thermal and spin state.

- Force sweep: 8,400 cases, all five road/border/side roles, 6,960 surface blends,
  2,800 extension states and 3,500 zero-contact-load cases. These counts overlap.
- Independent ride/force sequence: 10,000 ticks, including 3,278 surface blends.
- Three exactly sideways cases check original NaN/infinity classification
  separately. Finite comparisons do not count these as zero-error samples.
- Thermal sweep: 3,600 cases with skill/rule gates, cold/hot graining and wear
  saturation. Sequential thermal state: 20,000 ticks with one reset; wear uses
  the tighter tolerance 1e-12 + 1e-10*abs(reference).
- Rotation: 30 brake-lock cases and 20,000 ticks spanning both axle indices and
  free/driven inputs, with 1,304 angle wraps.
- Coupled ride → force → thermal → free-wheel → rotation: 6,000 ticks (2,800
  braking ticks), including force-to-spin and grip-to-force feedback.
- All finite compared values have zero observed error in debug/release and the
  selected Address Sanitizer run. Eight new tests pass in each build.

The compact report `wheel-dynamics-parity-report.json` records inputs' scope,
source hashes, build observations and exclusions. These are wheel-stage checks:
position, body velocity and axle loading are supplied by the tests. Wheel XML
configuration and chassis/wheel kinematics are covered separately below; driven
transmission and full vehicle integration are not established. The native app
remains the suspension lab.

## Configured four-wheel running gear

`RunningGearConfiguration` parses native merged car parameters into mass, axle,
wheel, suspension, brake, tire-force and thermal definitions. Defaults and clamps
follow original SimAxleConfig/SimWheelConfig/SimSuspConfig/SimBrakeConfig. This
is fresh-car setup, not a replacement for pit-time reconfiguration. Initial wheel
inertia excludes the later-configured brake inertia, initial relative height
precedes suspension rest setup, and negative tire base mass falls back to 3 kg.
Static attachment coordinates are shifted to the CG only after configuration.

`WheelKinematics` preserves PLIB's radian/degree conversion and exact transform
expression ordering. `AxleDefinition.forces` combines anti-roll and third-spring
forces; third travel is already spring space and its force is gated at a strict
maximum-travel boundary. `RunningGearState` stores four independent wheels
without per-tick array allocation and schedules contacts → axles → force/thermal
→ drivetrain-supplied spin → rotation. It also preserves pre-simulation tire reset.

```sh
swift test --filter 'RunningGearTests|AxleKinematicsTests|RunningGearIntegrationTests'
swift test -c release --filter 'RunningGearTests|AxleKinematicsTests|RunningGearIntegrationTests'
```

- Full original SimConfig on merged 155-DTM/category: 280 compared wheel/axle
  configuration values. The isolated configuration adapter checks 3,640 values
  across 13 authored/default cases with shared, previously tested mass inputs.
  Cases include all four wheel positions, parameter clamps and 24 mass fallbacks.
- Chassis-to-wheel position/velocity: 2,400 samples, mixed roll/pitch/yaw, zero
  angles, near-boundary angles and translated origins.
- Axle forces: 3,750 samples, 2,012 active third-spring contributions and 900
  travel-gated cases, both axle indices and three bellcrank ratios.
- Four-wheel integration: native Aalborg and 155-DTM configuration, 10,000 ticks,
  40,000 wheel ticks and 1,920,000 finite scalar comparisons. Independently
  evolving wheel state includes 6,973 surface blends and 2,000 tire resets.
  The wear accumulator additionally uses the tighter Double tolerance.
- All compared values have zero observed error in debug, release and Address
  Sanitizer runs. The six new tests pass; evidence from that increment is recorded in
  `running-gear-parity-report.json`.

The integration oracle calls original wheel kinematics, ride, axle, force,
thermal, free-wheel and rotation functions on the configured original car. Both
axles are explicitly undriven in this test. Native and original receive the same
external chassis pose/velocity and wheel controls; neither receives the other's
wheel state. This test does not exercise the powertrain; the driven sequence
below does. The app remains the suspension inspection lab.

## Engine and differentials

The engine port includes fresh XML configuration, metadata, precomputed torque
segments, torque/fuel update and RPM feedback from the axle. It preserves the
original terminal duplicate point (NaN coefficients, separately classified),
strict segment selection, no-match torque retention, limiter and car-state paths,
engine braking, neutral/disengaged free revving, fourth-power clutch transfer,
idle/maximum coupled RPM and reverse-ratio axle correction.

Exhaust pressure and smoke are also ported. Randomness is an explicit callback,
consumed once by a fueled RPM update and never on the no-fuel return. Tests obtain
an external random sample with the unchanged upstream urandom function for a
known seed; the original engine is reset to that seed before its update. Both
implementations thus receive the same random input while owning independent
engine/fuel/exhaust state. This does not implement a portable PRNG, nor validate
the global random stream once other subsystems begin consuming it.

Differential configuration and all five modes are ported. Tests cover stationary
NONE splitting, locked spool behavior, free spider torque, limited-slip bias and
both lock thresholds, the asymmetric viscous coupler, unequal output inertia,
positive/negative/zero rotation, brake locking and real engine RPM reaction. The
primary-differential callback runs in the original position; secondary updates
leave the engine untouched.

```sh
swift test --filter 'EngineTests|DifferentialTests'
swift test -c release --filter 'EngineTests|DifferentialTests'
swift test --scratch-path .build/asan --sanitize address --filter 'EngineTests|DifferentialTests'
```

- Engine setup: original merged 155-DTM plus nine authored cases; 315 finite
  values match, with 20 final-segment NaN values separately classified.
- Torque/fuel/limiter/flags: 7,008 independent cases, including curve boundaries.
- RPM/clutch: 648 cases, 324 random draws and 34 axle-speed corrections. Free
  revving, disengagement, reverse and no-fuel early returns are included.
- Engine sequence: 20,000 ticks, 4,861 axle-speed corrections, independent fuel
  and exhaust state. A separate boundary test checks stale torque at/above the
  final curve endpoint before the limiter; malformed curves are rejected.
- Differential setup: 160 fields over 16 cases, including real front/rear/central
  155-DTM definitions, defaults, clamps and unknown type fallback.
- Differential update: 9,408 cases, 2,352 random draws through real engine reaction.
- Independent engine/differential sequences: five modes, 3,000 ticks each.
- Nine tests pass in debug, release and Address Sanitizer; all compared finite
  values have zero observed error. `engine-differential-parity-report.json`
  records source hashes at that increment, build observations, scopes and exclusions.

The oracle calls unchanged SimEngineConfig/SimEngineUpdateTq/SimEngineUpdateRpm
and SimDifferentialConfig/SimDifferentialUpdate. It does not reimplement the
formulas. Axle resistance in these kernel tests is supplied externally; the
subsequent driven sequence connects wheel-generated feedback through transmission
routing. No driven whole-vehicle result is claimed.

## Clutch, gearbox and driven four-wheel integration

The semantic port of `simuv2/transmission.cpp` includes fresh configuration,
gear selection, clutch release and RWD/FWD/AWD routing. Original equations are
unchanged in the reference. The harness calls SimTransmissionConfig,
SimGearboxUpdate and SimTransmissionUpdate around the original engine and wheel
stages. Authored transmission fixtures override only transmission parameters
before dynamics begin, retaining the original engine and wheel configuration;
they deliberately bypass car-category restrictions for component testing.

Preserved ordering includes the initial releasing clutch with a zero timer,
release ticks delaying requests even when the timer expires, automatic clutch
transfer/throttle changes only above the strict 0.99 threshold, and axis inertia
caches refreshing only on a shift. AWD uses the central ratio for resistance and
brake feedback, runs central engine coupling once, then sends the resulting
axis torque through the two secondary differentials. Free-wheel updates precede
rotation on the undriven axle of RWD/FWD vehicles.

```sh
swift test --filter TransmissionTests
swift test -c release --filter TransmissionTests
swift test --scratch-path .build/asan --sanitize address --filter 'TransmissionTests|RunningGearIntegrationTests'
```

- Setup: original 155-DTM, nine authored layout/gear variants and an empty default
  case; 1,276 finite setup/initial-state values, including inactive zero axes.
- Gearbox: 13,500 ticks, 474 shifts, 3,681 delayed requests and 771 throttle caps;
  607,500 scalar comparisons. Three layouts and three shift times include reverse,
  neutral, missing gears, gear limits and clutch boundary values.
- Driven integration: four independent 4,000-tick sequences use the original
  AWD configuration and authored RWD/FWD/AWD layouts. Engine, fuel, transmission
  and all four wheels evolve independently in both implementations.
- These sequences compare 1,696,000 powertrain scalars and 3,072,000 wheel scalars,
  plus discrete flags/locations and Double wear. They include 11,492 surface
  blends, 16,000 random inputs and 8,000 undriven-axle updates.
- All compared values match exactly in the tested debug, release and Address
  Sanitizer builds. `transmission-parity-report.json` records source hashes and
  observations. The four new tests and existing undriven integration test pass
  under Address Sanitizer.

Chassis pose/velocity, brake pressure and steering are external inputs, and
exhaust randomness is still supplied from the original platform. These are
component integration tests; separate chassis/motion checks follow below. Full
vehicle/content parity and portable random streams remain pending. Pit-time
reconfiguration is now checked in the later service increment.

## Body, wings and drafting

`Aerodynamics.swift` semantically ports fresh SimAeroConfig/SimWingConfig and
SimAeroUpdate/SimWingUpdate. The oracle calls these unchanged original routines
on isolated car structures; it temporarily swaps and restores the original
car table to exercise traffic. A live-world test verifies that this helper does
not mutate that world's telemetry and that original stepping still works.

The port retains body longitudinal drag, the damage drag multiplier, front/rear
body ground effect, wing angle of attack and zero wing force when reversing.
Drafting preserves original speed and angle gates, separate front/rear distance
exponents, minimum-factor selection, and self-index exclusion. Its coefficient
includes the body and rear wing only. Ground effect uses supplied 3D speed with
only a lower cosine clamp and the fourth power of the summed ride heights.
The future vehicle scheduler must call it with preceding-tick wheel ride heights,
before SimWheelUpdateRide-equivalent work, and preserve original traffic ordering.

```sh
swift test --filter AerodynamicsTests
swift test -c release --filter AerodynamicsTests
swift test --scratch-path .build/asan --sanitize address --filter 'AerodynamicsTests|FullReferenceTests'
```

- Configuration: 11 cases and 176 finite values, covering defaults, angles, areas,
  CG adjustment and the original merged 155-DTM.
- Body/wing forces: 1,084 cases and 10,840 fields across reverse/zero/forward,
  lateral and vertical motion, speed gates, damage and asymmetric ride heights.
- Drafting: 2,380 cases and 23,800 fields, including next-representable values at
  strict thresholds, yaw wrapping, distance, self index, multiple opponents and
  zero-coefficient/coincident candidates.
- Original 155-DTM: 500 samples and 5,000 fields. Four-car moving traffic:
  10,000 samples and 100,000 fields. Motion and damage are externally prescribed;
  the aero kernel has no integrated vehicle state.
- All compared outputs match exactly in debug, release and Address Sanitizer.
  Five aero tests and four original-world tests pass under Address Sanitizer.
  `aerodynamics-parity-report.json` records the source snapshot at that increment.

Wing pit-time reconfiguration and native race traffic scheduling are not
established by these component checks. Chassis integration is checked below.

## Chassis integration and independently moving vehicle

`Chassis.swift` ports SimCarUpdateForces, SimCarUpdateSpeed,
SimCarUpdateCornerPos and SimCarUpdatePos semantically. Shared `VehicleRotation`
retains the verified PLIB transform expressions, including inverse rotation.
The oracle calls unchanged SimCarUpdate on a copy of the configured car, using
its existing NO_SIMU bit only to skip SimCarCollideZ/SimCarCollideXYScene.
No imported equations or golden files are changed. The full SimUpdate scheduler
is not called under that bit, because it would skip the entire car.

Configuration retains overall-width corner placement and original mixed-precision
operations. Dynamics retain fuel-dependent mass, old-world snapshot, weight
rotation, wheel roll-center moments, body/wing loads, rolling-resistance caps,
yaw-rate/pose limits, corner sampling before pose advancement and track lookup.
The legacy Cosz/Sinz corner caches remain zero unless supplied; simuv2 never
updates them. Velocity transforms use the old body orientation, while the body
pose is synchronized only after world position/orientation advances.

```sh
swift test --filter 'ChassisTests|VehicleDynamicsTests'
swift test -c release --filter 'ChassisTests|VehicleDynamicsTests'
swift test --scratch-path .build/asan --sanitize address --filter 'ChassisTests|VehicleDynamicsTests|AxleKinematicsTests|FullReferenceTests'
```

- Chassis configuration: 12 original corner coordinates.
- Force/motion boundaries: 4,050 cases and 384,750 finite scalars; 450 yaw-rate
  caps and 270 roll/pitch caps. Inputs cover mass/fuel, orientations, velocities,
  resistance thresholds/caps, cache values and timestep.
- Independent chassis sequence: 10,000 ticks and 950,000 scalars with changing
  external wheel loads and fuel. Original/native state feeds only its own next tick.
- Coupled vehicle: three 6,000-tick stationary, acceleration/braking and steering
  scenarios on original Aalborg/155-DTM definitions. Both implementations start
  from a common pose and generate their own engine, fuel, wheel and chassis state.
- Compared coupled fields: 1,710,000 chassis, 954,000 powertrain, 3,456,000 wheel
  and 144,000 aero scalars, plus discrete state/locations and Double wear.
  Includes 18,000 shared exhaust-random inputs, 8,060 ticks above 5 m/s and
  1,926 debug/ASan or 1,922 release wheel samples blending surfaces. Previous-tick
  ride heights feed aero. Each build matches its own original reference; the blend
  count difference demonstrates that cross-build identity is not established.
- All compared finite values match exactly in debug, release and Address Sanitizer.
  Four new chassis/vehicle tests, two kinematics/axle tests and four original-world
  tests pass under Address Sanitizer. `chassis-parity-report.json` records source
  hashes, observations and excluded scope.

The coupled oracle calls original gearbox, torque, aero/wing, wheel/axle,
transmission/RPM, rotation and car update functions. Its original chassis state
is never replaced by native output. The 501-tick settling prefix uses supplied
brakes and pre-simulation tire reset, but is not the full race startup scheduler.
Atmosphere values, wheel pressures and steering angles are common external
inputs. That isolated test omits environment/car collision deliberately. The next
comparison adds original ground/barrier response; full control scheduling,
car-to-car collision, full SimUpdate parity and gameplay remain open.

## Ground/barrier response and generated damage

`EnvironmentCollision.swift` ports SimCarCollideZ and SimCarCollideXYScene.
The isolated oracle copies the configured original car, populates common dynamic
inputs and calls these unchanged functions. Ground and barrier functions are also
executed normally inside SimCarUpdate by the coupled vehicle oracle. No ground,
barrier or damage equations are replaced in the reference, and no native state
is supplied to the reference after the common initialization.

The port preserves world-only corrections, stale body/corner/track caches,
per-corner order, strict normal-speed crash threshold, state gates, skill/rule
factors, integer damage accumulation, friction/rebound and ±6 rad/s barrier yaw
cap. It does not add a floor-position clamp or fix upstream's documented convex
barrier-edge limitation. Collision flags/blocked reset each tick while damage
and previous impact metadata persist; the next aero tick consumes that damage.

```sh
swift test --filter 'EnvironmentCollisionTests|VehicleDynamicsTests'
swift test -c release --filter 'EnvironmentCollisionTests|VehicleDynamicsTests'
swift test --scratch-path .build/asan --sanitize address --filter 'EnvironmentCollisionTests|VehicleDynamicsTests|ChassisTests|FullReferenceTests'
```

- Ground: 4,860 cases, 490,860 finite scalars, 1,800 contacts, 216 crash flags
  and 108 damage increments. Includes road/side surfaces, pose and penetration,
  normal velocities near -5 m/s, state gates, skill and rule factors.
- Barriers: 1,944 cases, 196,344 finite scalars, both sides, curved/straight
  geometry, multiple penetrating corners, inward/outward motion, gates/factors.
  Includes 1,296 blocked cases, 804 rebounds and 78 damage increments.
- Coupled response: five independent 6,000-tick scenarios, retaining stationary,
  acceleration/braking and steering, and adding a drop and a barrier strike.
  Fields compared: 2,850,000 chassis, 1,590,000 powertrain, 5,760,000 wheel,
  240,000 aero and 180,000 collision metadata scalars, plus integer flags/damage,
  track locations and Double tire wear. Native damage feeds subsequent aero.
- All compared finite values match exactly within debug, release and ASan builds.
  Event counts are recorded per build in `environment-collision-parity-report.json`;
  cross-build identity remains unclaimed. Eleven selected tests pass under ASan.

The coupled paths still receive checked component controls, atmosphere values and
shared platform random samples externally. These tests establish integrated
mechanics and environment response, not full SimUpdate scheduling, native
car-to-car collision, portable random streams, race behavior or gameplay.

## Driver commands, active-car scheduling and native telemetry

`DriverCommand.swift` ports ctrlCheck, steering and brake-system setup. Nonfinite
commands become zero before state overrides/clamps; broken/eliminated commands
precede finish handling, and the original strict speed/track-center thresholds
are retained. The test-only `simulation-instrumentation.cpp` includes unchanged
`simu.cpp` once to expose its private ctrlCheck function. Existing original-world
golden files are retained without regeneration.

`stepActiveVehicle` owns command checking, steering slew/Ackermann, brake pressure,
the original constant atmosphere, and settling/running/prestart stage selection.
Prestart forces the requested gear to neutral and updates steering, gearbox,
engine torque and engine RPM, while wheel mechanics, brake pressure, aero and
chassis motion retain their preceding state. Settling runs physics and resets
tire wear. This isolated active-car entry point rejects removal/tow/pit states;
the managed runtime now schedules those separately, as documented below.

`FullSingleCarTests` runs actual original SimUpdate, including its unchanged
collision dispatch, for 22,505 ticks across five independent scenarios. It checks
365 finite scalar fields per tick (8,214,325 total), plus discrete flags, damage,
locations and Double wear; 500 ticks exercise prestart after settling. No native
output is fed into original state. This test still supplies common exhaust-random
samples so all internal mechanical and engine outputs can be inspected together.
No selected tick raises the SOLID car-collision flag; this is verified explicitly,
not achieved by disabling original collision dispatch.

`SingleVehicleSimulation` adds placement, a 501-tick settling prefix, 500 Hz stepping
and an owned random stream. The mathematical Park–Miller recurrence and Darwin
zero-seed substitution match the macOS reference's rand/urandom sequence. The
algorithm specification is [Apple Libc rand.c](https://github.com/apple-oss-distributions/Libc/blob/main/stdlib/FreeBSD/rand.c);
the Swift implementation expresses the recurrence using UInt64 multiplication
and does not call or modify process-global libc random state. Nine seeds (including
zero and UInt32 boundaries) cover 90,000 exact original comparisons plus 900 copied
stream comparisons. Other platforms' libc sequences are not assumed identical.

`SingleVehicleRuntimeTests` compares native and original continuous streams over
five 3,000-tick measured scenarios after independent settling: 2,130,000 telemetry
scalars, with no per-tick seed reset or shared random sample. A separate 200-tick
fresh prestart test compares 142 public telemetry fields and frozen chassis/control
state. `VehicleTelemetry` maps native state to the existing 142-field schema;
`torcs-sim --scenario` uses only native configuration, track and simulation modules.

```sh
swift test --filter 'DriverControlTests|FullSingleCarTests|SingleVehicleRuntimeTests'
Scripts/verify-single-car.sh
```

Driver setup compares 20 values; command checking covers 1,344 cases / 6,720
scalars, including NaN/infinity, clamping, state priority and boundary thresholds.
The standalone script checks five release scenarios, 3,000 ticks each, with repeated
native and reference captures and strict field/tick/schema comparison. These are
selected active-car scenarios, not whole-engine, race or gameplay completion.
All six new tests pass in debug/release and, with the four existing original-world
tests, under Address Sanitizer. Full-update barrier-response counts are 1,459 in
debug/ASan and 1,432 in release; each matches its own reference with zero observed
error. Cross-build trajectory identity remains unclaimed. Source hashes and
per-build observations are recorded in `single-car-parity-report.json`.

## Object collision response kernels

`ObjectCollision.swift` now ports the original private car/car and car/wall
callbacks, including index reordering, Float narrowing/normalization, pit state,
separation before early return, blocked corrections, accumulated impulses,
Double damage arithmetic, yaw cap and cached matrix updates. The original
callbacks execute through `collision-instrumentation.cpp`, which includes
unchanged upstream collide.cpp once. Original detection is not invoked by these
isolated response oracles.

Pair sweeps compare 8,640 cases / 552,960 scalars; wall sweeps compare 7,776 cases /
248,832 scalars. Another 120 cases / 7,680 scalars test separation and integer
damage boundaries. A three-body chained test retains each implementation's own state
for 4,000 contacts / 384,000 scalars and exercises dispatch reset/commit, a pit car
and multiple contacts within the same tick. Discrete damage, blocked and collision
flags are checked separately. Detailed boundaries and next detection work are in
`COLLISION_PORT.md`; per-build evidence is in `object-collision-parity-report.json`.
All four new tests match exactly in debug/release/ASan. At that checkpoint the full suite had 83
passing tests; twelve selected tests pass under Address Sanitizer. Existing
single-car CLI captures remain repeatable and exactly match the original.

## Convex detection and integrated multi-car physics

`ConvexCollision.swift` ports original box/simplex/polygon support maps, Double
GJK determinant reduction, relative/world intersection and common points,
closest points and SMART contacts. Its workspace and polygon cursors persist
independently of the original oracle. Queries preserve exact duplicate tests,
strict thresholds and original nonfinite classifications; convergence guard
failures throw explicitly rather than selecting a substitute contact.

- Support maps: 5,070 checks / 15,210 finite scalars.
- World/relative queries: 5,000 cases / 57,852 finite scalars and 12 classified
  nonfinite values; 3,288 hits across the tested modes.
- SMART contacts: 9,000 checks / 43,488 finite scalars; 4,832 intersections and
  4,168 previous-transform advances. Tests vary current and previous poses.
- Degenerate and boundary cases: 600 queries / 2,802 finite scalars, 438
  classified nonfinite values and 360 hits, including zero-size boxes,
  near-touching surfaces and distance-tolerance boundaries.

`MultiVehicleSimulation.swift` connects detection to the existing native active-car
update and response. The two-car run covers 3,000 measured ticks; the three-car
pileup covers 2,000. Each independently loads XML/geometry, settles 501 ticks and
owns continuous mechanics/RNG state. Together they compare 1,704,000 telemetry
values, including collision flags and damage. Original SimUpdate performs its
actual SOLID dispatch; native contacts are not injected into the oracle.

The native loop uses stable car-index pair ordering, sequential traffic reads,
global zero-hit previous-pose advancement, callback transform updates and delayed
velocity commit. Broader allocation-order/car-count coverage is still needed.
The release CLI adds repeated original/native two-car captures with 284 fields
per tick; reproduce with `Scripts/verify-car-collision.sh`.

Build-specific results and source hashes are in
`convex-collision-parity-report.json`. Prior reports are historical snapshots;
their source hashes are not rewritten for subsequent increments.

All finite fields match exactly in debug/release/ASan, with nonfinite outputs
classified separately. The full debug/release suite passes 89 tests; 17 selected
tests pass under Address Sanitizer. The two-car run detects 364 collision ticks
in debug/ASan and 362 in release. Three-car counts are 630/645, including 110/97
ticks with multiple pairs. Each native run matches its own original build;
cross-build whole-trajectory identity remains unclaimed.

## Fixed-wall geometry, complex queries and integrated strikes

Native affine operations preserve original type flags and cofactor/transpose
branches. The complex/convex hierarchy preserves bounding-box accumulation,
partition order, midpoint fallback, first-hit selection and support cursor
effects. Tests compare 1,600 affine cases / 96,000 scalars, 9,000 primitive
queries / 108,000 scalars and 9,000 SMART queries / 98,064 scalars. Each complex
family includes 1,896 hits and 7,104 misses. All finite outputs match exactly.

Wall construction observes unchanged original buildWalls calls while forwarding
them to SOLID; no upstream equation or geometry source is edited. Native and
original independently build Aalborg and 24 authored variants. Comparisons
cover 96 objects, 948 polygons and 11,376 coordinates, retaining the upstream
end-cap/start-vertex quirk and absence of top polygons.

Integrated left/right wall strikes compare actual SimUpdate to the shared
native car dispatcher over 6,000 measured ticks / 852,000 telemetry values.
Geometry, contacts, accumulated response and random state evolve independently.
The single-car facade now uses that same dispatcher. Source/build evidence is
recorded in `wall-collision-parity-report.json`; older reports remain historical.
At that checkpoint, complex/complex fixed pairs and mixed pileups remained open;
the next increment adds the coverage below. Moving vertex bases and general
allocation-order equivalence remain outside the verified scope.

All five new tests pass in debug/release/ASan with zero observed error. The full
debug/release suite passes 94 tests; 18 selected tests pass under Address
Sanitizer. Integrated wall strikes record 26 contact ticks and 948 combined
final damage in all three builds. This does not establish cross-build identity
for other trajectories or input families.

## Fixed-pair queries, pose freezing and mixed pileups

Two complex/complex query families compare 10,800 cases each. Selection covers
32,400 finite scalar fields and 326 distinct primitive pairs; SMART contacts
cover 22,275 finite fields and 153 classified nonfinite outputs. Both families
have 2,492 hits and 8,308 misses. They preserve original hierarchy split choice,
six-axis bounds checks, separating-axis reuse and first-hit selection.

An audit of actual original fixed objects compares 144 pairs, including four
contacts whose normalized planar normal triggers the callback's early return.
Twelve crossing-wall fixtures yield twelve contacts; eleven would pass that gate
and dereference the other wall as tCar. Diagnostic queries inspect original
contact generation and PLIB normalization without executing the invalid callback.
Native dispatch reports those eleven invalid inputs; the safe contact is counted.

Actual original SimUpdate and native dispatch compare 3,000 ticks / 426,000
telemetry values with fixed contacts present every tick, proving the effect on
previous-pose advancement. Mixed three-car left/right wall pileups compare
7,000 ticks / 2,982,000 values and assert that some ticks contain both car/car
and wall/car contacts. The original engine supplies no state or contacts to the
native runtime. Both independently construct and evolve geometry, physics and RNG.

Current source hashes, build observations and regression evidence are recorded in
`fixed-mixed-collision-parity-report.json`. Original archive sources and existing
braking goldens remain unchanged; earlier reports retain historical hashes.

All six new tests matched within each debug/release/ASan build. At that increment,
the full suite passed 100 tests in debug and release; 21 selected tests pass under Address
Sanitizer. The fixed-contact run has 1,188 wall/car contact ticks / 310 damage in
debug/ASan and 1,146 / 319 in release. Mixed pileups have 8 wall-contact, 2,120
car-contact and 4 mixed ticks in debug/ASan; release counts are 9 / 2,117 / 3.
These build differences occur in both native and original runs; same-build
maximum observed telemetry error is zero.

## Removal and towing kernel

The native VehicleRemovalState executes one original RemoveCar invocation with
separate mechanical and published dynamics. State sweeps cover 2,340 cases /
217,620 values. Six complete independent towing trajectories compare 108,498
invocations / 10,090,314 values, requiring pull-up, sideways, pull-down and out
phases. Sixteen boundary/zero-distance cases compare another 1,482 finite values
and classify six NaNs. Every compared finite value matches exactly.

The oracle invokes unchanged original RemoveCar on an actual SimCarTable entry,
including original collision-object removal. Tests compare 93 outputs per normal
invocation, covering display matrices, published wheel values, pit occupancy,
collision registration and frozen mechanical state. A broken pit input without
an assigned pit is diagnosed natively; the original null dereference is not run.

At that increment, the full suite passed 103 tests in debug and release. All three new removal tests
and four original-world tests pass with Address Sanitizer. All six release CLI
scenarios still repeat and match. See REMOVAL_PORT.md for preserved quirks and
removal-parity-report.json for source hashes and results.

Those checks established kernel parity only. The runtime increment below connects
it to complete updates. No complete race or gameplay lifecycle is claimed.

## Removal lifecycle in full simulation updates

Native single/multi-car updates now call removal at the original SimUpdate stage,
carry flags across ticks, preserve coasting physics and unregister towing cars
from collision detection. Pit objects remain registered. Collision detection and
response retain distinct cached-object and published-car transforms where the
original does; this matters during pit contacts. Published towing body motion
remains separate from frozen mechanical and published world motion.

Eight new tests compare 142 mechanical fields and 115 publication/lifecycle values
per car against original SimUpdate. Six scenarios complete towing and verify 32
additional final-out ticks; two short cases exercise fresh inactive/prestart state
and the single-car facade. All state/contact generation is independent. Each
scenario ends with 32 original/native random-stream comparisons without reseeding.
Build-specific counts and source hashes are in lifecycle-parity-report.json.

At that increment, the full suite passed 111 tests in debug and release. Eighteen selected tests pass
under Address Sanitizer, including the eight new lifecycle tests, kernel removal,
existing pileups and original-world teardown. All six release CLI regressions
remain repeatable and match. See REMOVAL_PORT.md for detailed scope.

## Pit setup and service physics

PitSetup and complete SimReConfig now have native equivalents. Adjustment tests
cover 180 cases; XML loading checks 270 original car values and 4,860 authored
values. Forty repeated reconfigurations compare adjusted commands, running gear,
controls/aero, fuel/repair and gearbox/differential state. The live drivetrain keeps
its cached current ratio/inertias and clutch state, matching the original.

Three independently initialized AWD/RWD/FWD worlds perform nine services and
13,500 complete SimUpdate ticks. They compare 3,836,556 mechanical/publication
values, 2,430 adjusted setup values, 1,044 transmission values and 96 RNG-tail
values. Tire replacement acts on worn tires, and no-change requests retain wear.
Published tire wear uses the original Float conversion from Double mechanical
wear; publication remains frozen during PIT. All compared values match within
each tested build. See PIT_SERVICE.md and pit-service-parity-report.json.

At that increment, the full suite passed 116 tests in debug and release; 21 selected tests passed
under Address Sanitizer. Existing CLI repeatability, provenance, app signing and
Metal smoke checks pass. Earlier reports retain their historical source hashes.
That report predates race pit management, described below.

## Race pit management and integration

Original initPits, ReManage pit handling, ReUpdtPitTime and the interactive
completion callback now have native policy/integration equivalents. Nine tests
exercise team assignment, timing, shared stalls, session setup rules and menus.
Full-physics cases compare 16,000 ticks / 5,140,000 mechanical/lifecycle values,
plus 20,000 per-car pit/setup records and 96 final RNG values. Pit-lane
placement also exposed and fixed initial yaw normalization's Float period.

See RACE_PITS.md and race-pit-parity-report.json for exact coverage and source
hashes. The full suite now passes 125 tests in debug and release; 41 selected
tests pass under Address Sanitizer. Six existing release CLI regressions,
archive/provenance checks, app signing and Metal smoke checks also pass.
The oracle suppresses lap crossings and unrelated lap-time DNF; complete
race timing, penalty queues and robot execution are not claimed.

## Remaining reference work

Complete race-engine and robot execution and the fifteen requested scenario
families remain open. Full-scheduler steady-state cornering, curb, grass, dedicated barrier,
spin, pit entry/stop, qualifying and multi-lap race fixtures are still needed.
Two-car collision coverage does not establish multi-car race parity. Native track geometry/queries now have separate coverage in TRACK_PARITY.md.
Full race implementations remain pending. The original `-r` race executable has not been built or run here.
