# Port status — 2026-09-24

**Early keyboard driving works for one prepared car/track session; not distribution-ready.**
Status meanings: Not started = no implementation; Partial = limited coverage;
Functional = working within stated scope; Parity verified = compared to original
TORCS code for the documented cases. No whole-vehicle or race parity is claimed.

| Feature | Status | Evidence / limitation |
|---|---|---|
| Upstream study and pin | Functional | 1.3.9 archive SHA-256, subsystem mapping, source manifest |
| Full upstream reference race harness | Partial | Original full simuv2 physics, track loader and collisions run; original BT plus ReOneStep completes one selected physical reference lap; a 1–10 car BT field now runs the original starting grid, ReOneStep, ReManage, ReRaceRules and ReSortCars with per-car capture, and repeats exactly; native BT solo runtime completes a lap; opponent handling and complete race-mode coverage pending; see RACE_ORACLE.md |
| Native BT AI | Partial | Single-car Swift policy matches reference lap and pit callbacks exactly; ten native laps repeat, forced-pit five-lap run completes with two services; 287 release tests and 5 ASan tests pass; trajectory parity, traffic, grids, penalties and UI integration pending; see NATIVE_BT.md |
| Reference telemetry / diff | Functional | Strict JSONL comparison, per-field errors and divergence |
| Native app shell | Functional | Packaged .app launches; menus/settings, fullscreen/resize inspected |
| Fixed-step clock | Parity verified | 2 ms matches upstream constant; tests at 60/120/144/240 Hz; not full scheduler parity |
| Snapshot interpolation | Functional | Renderer consumes previous/current value snapshots |
| Coordinates / track queries | Parity verified | Selected fixtures: local/global modes, heights, normals, side transitions; whole-content coverage pending |
| XML parameters | Partial | Seven upstream fixtures; four merge modes; all 292 merged car/category values match original |
| Parameter unit conversion | Parity verified | Both directions against original C++ across 27 unit expressions and seven values |
| Native track construction | Partial | Version-4 road/borders/sides, profiles, banking and surfaces; Aalborg and synthetic geometry match original |
| Track barriers / static pits | Parity verified | Selected fixtures: barrier properties/normals, stall positions, wraparound, flags and pit distances |
| Track metadata / legacy formats | Partial | Graphic lighting/background and version-4 trackside cameras implemented; versions 0–3 remain pending |
| Asset compiler / importer | Partial | Native mesh and SGI/PNG caches plus validated single-model scene packages; installation and full scene integration pending |
| Metal | Partial | Native model inspector plus assembled track/car/wheels from physics snapshots; wheel transforms and GPU states tested; 31 original driving/side/overhead/circuit/trackside/fly/TV cameras with independent saved zoom; rear-view mirror in Driver/Bonnet/Road; terrain-following per-car shadows with shared textures and mirror visibility, optional 4× filtering and 4× geometry edge smoothing; original track sky, configured lighting and linear fog; car reflection and environment-shading maps; projected baked track shadows onto indexed cars; original generated hubs/discs/calipers with published brake heat color; command-driven car lights; other effects pending |
| Car lights | Partial | Original kernels, point culling and light bounds reference-tested; Metal texture/blend/depth/mirror checks pass; selected native brake lights visible; broader transparency state/content and headlight bindings pending |
| Fly camera / scene height | Partial | F10 exposed with saved zoom; original motion and selected scene-height/selector traversal tested; previous-draw car/wheel/brake/shadow/light graph integrated; other LODs, other generated geometry and complete original scene pending |
| Automatic TV director | Partial | Original multi-car priority, timer, screen exclusion and selected projection kernels tested; immutable per-step race-frame collision history, shared screen acknowledgements and F11 picker/zoom integrated; native three-car/two-screen comparison passes; full standings and multi-car GUI pending |
| Suspension update/check-in | Parity verified | Native semantic port versus original, boundary and bellcrank sweeps |
| Brakes / repartition | Parity verified | Torque, temperature, clicks, saturation and sequential tests |
| Steering update | Parity verified | Slew and Ackermann angles versus original over 10,000 ticks |
| Mass/inertia configuration | Parity verified | Selected car mass, CG, inverse inertia, static loads, axle geometry and fuel match original |
| Wheel ride/contact | Parity verified | Native geometry → suspension check-in → brake update; contact sweeps and 5,000 sequential ticks |
| Wheel/tire forces | Parity verified | Selected inputs: unsprung load, slip, load sensitivity, camber, blending, relaxation and feedback match original |
| Tire heat / wear / graining | Parity verified | Skill/rule gates, pressure, grip, reset and 20,000 sequential updates match original |
| Wheel rotation | Parity verified | Free-wheel brake/inertia update and driven-input relaxation; now also checked with real drivetrain output |
| Fresh-car wheel/axle configuration | Parity verified | 155-DTM and 13 authored/default cases; separate pit reconfiguration checks now pass; broader content coverage pending |
| Chassis-to-wheel kinematics / axle loads | Parity verified | Original PLIB transform ordering, anti-roll and third spring; selected input sweeps |
| Four-wheel running gear | Parity verified | Forced-chassis checks plus independent motion: 18,000 ticks without collisions and 30,000 with ground/barriers |
| Chassis force / motion integration | Parity verified | Selected load/pose boundaries and 10,000 independent ticks; original ground/barrier stages explicitly skipped in the oracle |
| Coupled vehicle dynamics | Partial | Active single-car, two/three-car, fixed-wall and mixed pileup SimUpdate comparisons pass; selected removal/towing scenarios pass; selected timed pit service now matches; gameplay pending |
| Driver controls / atmosphere / active-car phases | Parity verified | Nonfinite cleanup, state overrides, steering/brakes, constant atmosphere, settling and prestart versus original |
| Native single-car telemetry | Parity verified | Five scripted scenarios, 142 fields, independent native loading/state/random stream; limited to selected fixtures |
| Owned random stream | Parity verified | Native Park–Miller/Darwin compatibility; 90,000 draws across nine seeds; full replay and other-platform libc parity pending |
| Engine configuration / torque / RPM | Parity verified | Selected curve, limiter, fuel, flags, clutch coupling and exhaust-input cases; 20,000 sequential ticks |
| Differential configuration / update | Parity verified | All five modes, braking, engine reaction and 15,000 coupled kernel ticks; driven routing checked separately |
| Clutch/gearbox / drivetrain routing | Parity verified | Fresh setup, clutch release, cached inertias, RWD/FWD/AWD; 13,500 gearbox and 16,000 driven four-wheel ticks |
| Body/wing aerodynamics and drafting | Parity verified | Fresh setup, damage multiplier, ground effect and traffic thresholds; isolated original comparisons |
| Ground / barrier collision and damage | Parity verified | Original responses, state gates, sequential corners and generated damage; isolated cases and 30,000 coupled ticks |
| Convex collision queries | Parity verified | Selected original box/simplex/polygon support, GJK, affine math, world/relative queries, complex/convex and complex/complex SMART contacts |
| Car-to-car collision | Partial | Native box detection/response and ordered active-car dispatch; selected two/three-car runs match original SimUpdate; broad order/content coverage pending |
| Fixed-object wall collision | Partial | Wall geometry, complex hierarchy, fixed-pair counting, left/right strikes and mixed pileups match selected reference cases; undefined wall-as-car access is diagnosed; broader content/order coverage pending |
| Removal / towing | Partial | Original kernel plus full-update coasting, towing, pit release/contact and surviving-car collision scenarios match; shared stall removal now integrated; broader content pending |
| Pit setup / service physics | Partial | All 89 setup fields and complete SimReConfig; nine services followed by AWD/RWD/FWD driving match original; admission/stall ownership/timing now integrated; penalties/UI pending |
| Human driving | Partial | Native keyboard/controller bindings; prepared 155-DTM/Aalborg; configurable practice/solo qualifying with countdown, pause, restart, retirement, results and JSON export; physical five-lap/controller proof and AI races pending |
| GameController / wheel HID | Partial | Extended-gamepad snapshot adapter, button edges, neutral gating and configurable calibration; original joystick arithmetic exact in 13,032 cases; physical hardware and HID pending |
| Multi-car race oracle | Functional | Verbatim original initStartingGrid; five grid configurations match independently recomputed upstream arithmetic; three-car fields repeat callbacks and final physics exactly; rule/penalty/classification capture available; oracle only, no native comparison yet |
| Race engine / timing / results | Partial | Native prestart clock and race sorting match original; selected eight-car lap/validity/gap/finish transitions reference-tested; solo session results exported as JSON; pits tested separately; integrated AI races, qualifying grid progression, penalties and championships pending |
| Robot API / legacy robots | Partial | Native BT solo commands and pit decisions match selected original runs exactly; independent native ten-lap runs repeat; opponent handling, legacy module loading and full race parity remain pending |
| Replay | Not started | Repeatable component logs are not gameplay replay |
| Native audio | Not started | No sound output |
| Headless simulation | Partial | Native single/multi-car active physics CLI and component kernels; separate original reference; no race engine |
| Profiling | Partial | Simulation/draw signposts; no Instruments race benchmark yet |
| Licensing | Partial | Imported code/XML, six meshes, 27 SGI and three PNG textures retain notices/hashes; eight shared textures still need precise license attribution |
| Distribution | Partial | Ad-hoc signing verified; Developer ID/notarization scripts untested |

## Validation evidence

- Most recent full debug suite: 257 XCTest cases pass after car-light Metal
  rendering and scene-height integration. The current inventory is 257. The 31
  selected light, Fly-height, brake, shadow, mirror and raster tests also pass
  in release and under Address Sanitizer. Current capture evidence is recorded in
  car-light-rendering-report.json; the kernel report retains its earlier results.
  Most recent full release suite: 182 cases pass (environment increment), including 10,000 sequential component ticks and
  264 suspension input combinations.
- Release `Scripts/verify.sh`: passes; two upstream runs and two native runs are
  byte-identical respectively; all ten compared fields have zero maximum and RMS
  error over 10,000 ticks. Compact checked-in report: `component-parity-report.json`.
- `--metal-smoke-test`: debug and packaged release pass, including a relocated .app
  with explicit bundled shader resolution; RGB checksum 1103027 on
  the tested machine. This is a nonempty-render check, not portable pixel parity.
- Native UI inspected: running simulation, menu pause/resume, fullscreen scene,
  return to window, Settings 60/120 Hz. Restored the original 60 Hz preference.
- The standard `build/TORCSMac.app` retains its previous verified ad-hoc build.
  The input increment uses `build/TORCSInputCheck.app`, also verified with
  `codesign --verify --strict`; linked libraries include GameController and exclude
  direct Expat and C++ runtime dependencies.
- 223 imported source/content/license files pass manifest and pinned-archive checks.
  Two documented PLIB modifications retain both original and current hashes.
- Six original full-physics release scenarios repeat exactly in separate processes,
  covering 16,000 measured ticks per pass with 142 fields per car; see
  `reference-world-report.json`. Cornering reaches a barrier; not steady-state parity.
- Same-process teardown/rebuild reproduces every sampled field. Checked-in debug
  and release braking baselines retain 60 checkpoints each from 3000-tick captures.
  Original debug/release trajectories differ (maximum x-position difference
  0.019227 m in the braking case); no cross-build bit identity is claimed.
- Four reference-world tests pass under Address Sanitizer. This bounded check
  does not establish long-race leak freedom or robustness of arbitrary legacy input.
- Streaming telemetry publishes atomically; abandoned/failed captures preserve
  the existing destination. The CLI now streams inputs and complete divergence reports; the small-array
  reader retains its 128 MiB guard. See TELEMETRY_COMPARISON.md.
- Native XML construction matches all 1123 Aalborg road/border/side segments,
  length/bounds and 66,292 geometry/surface/barrier/pit scalar fields; an additional authored 197-segment track
  checks changing radii, profiles, rough curbs and tapering sides.
- Track queries match 50,535 Aalborg local positions and 70,119 global searches.
  Construction and query errors are zero in the tested debug/release builds.
  See `TRACK_PARITY.md` and `track-parity-report.json` for scope and precision work.
- Eight infrastructure cases cover both pit sides, wrapped/unwrapped lanes,
  missing markers and barrier inheritance. Pit distance: 6,810 original/native
  comparisons. All loaded track race flags are now compared.
- Native wheel ride/contact: 3,960 independent cases and 5,000 sequential ticks
  match original SimWheelUpdateRide exactly in debug/release. Chassis integration
  is not established by these checks.
- Ten track/contact tests pass under Address Sanitizer. No native track data depends on
  the C++ reference after construction; the production builder uses native XML.
- Wheel force: 8,400 independent inputs and 10,000 ride/force ticks match original
  exactly; three sideways-slip cases preserve original NaN/infinity classifications.
- Thermal/wear: 3,600 inputs and 20,000 sequential ticks (including reset) match
  exactly. Rotation: 30 brake-lock cases and 20,000 free/driven-input ticks match exactly.
- A 6,000-tick coupled ride → force → thermal → free-wheel → rotation sequence
  independently carries both implementations' state and matches exactly. Position,
  body velocity and axle loading are forced inputs; this is not a chassis simulation.
- These eight new tests plus the two ride tests pass under Address Sanitizer.
  Compact wheel-stage evidence: `wheel-dynamics-parity-report.json`.
- Fresh running-gear configuration: 280 original 155-DTM values and 3,640 values
  across 13 authored/default cases match exactly, including clamp and initialization order.
- Chassis-to-wheel poses/velocities: 2,400 inputs match exactly. Anti-roll/third
  suspension: 3,750 cases match, including the strict third-spring travel gate.
- Configured four-wheel runtime: 10,000 independent native/original ticks,
  1,920,000 scalar comparisons, 6,973 surface blends and 2,000 pre-simulation
  tire resets match exactly. Both axles are undriven; chassis pose/velocity and
  wheel controls are supplied, not integrated by a native vehicle engine.
- Six new running-gear tests and four thermal/rotation tests pass under Address
  Sanitizer. Report: `running-gear-parity-report.json`.
- Engine configuration: 315 finite values across 10 cases match; 20 terminal
  curve NaNs are classified separately. Torque: 7,008 cases; RPM/clutch: 648 cases;
  stateful engine: 20,000 ticks. All compared finite values match exactly.
- Differential configuration: 160 values across 16 cases. Update: 9,408 cases,
  all five modes and unknown-type fallback, with optional real engine reaction.
  Five independent engine/differential sequences total 15,000 ticks; zero observed error.
- Nine engine/differential tests pass in debug, release and Address Sanitizer.
  Exhaust randomness is a shared external input obtained from the reference platform;
  full-simulation random-stream/replay parity remains pending. Evidence from that increment:
  `engine-differential-parity-report.json`.
- Transmission configuration: 11 cases and 1,276 finite setup/initial-state values.
  Gearbox: 13,500 ticks, 474 shifts, 3,681 delayed requests and 771 throttle caps;
  607,500 scalar comparisons match exactly.
- Driven four-wheel integration: original 155-DTM AWD and authored RWD/FWD/AWD,
  16,000 ticks total, 1,696,000 powertrain and 3,072,000 wheel scalar comparisons.
  Engine/fuel/clutch/differential/wheel state evolves independently; 11,492 surface
  blends, 16,000 shared random inputs and 8,000 undriven-axle updates match exactly.
  Chassis movement is supplied externally, not integrated.
- Four new transmission tests and existing undriven integration test pass under
  Address Sanitizer. All new comparisons match exactly in debug/release/ASan.
  Evidence from the transmission increment: `transmission-parity-report.json`.
- Aerodynamics: 11 setup cases (176 fields), 1,084 body/wing force cases,
  2,380 drafting cases, 500 original-car samples and 10,000 moving-traffic samples.
  All finite outputs match exactly in debug/release/ASan. Five aero and four
  original-world tests pass under Address Sanitizer. Evidence from that increment:
  `aerodynamics-parity-report.json`. Race scheduling remains open.
- Chassis setup: 12 corner coordinates. Force/motion: 4,050 cases, 384,750
  scalars, 450 yaw-rate caps and 270 roll/pitch caps. Independent chassis sequence:
  10,000 ticks and 950,000 scalars. All match exactly in debug/release/ASan.
- Coupled mechanical vehicle: 18,000 ticks across stationary, acceleration/braking
  and steering scenarios, with independent chassis, engine, fuel, drivetrain and
  wheel state. 6,264,000 scalar comparisons match exactly; 8,060 ticks exceed 5 m/s
  and 1,926 debug/ASan or 1,922 release wheel samples blend surfaces. No chassis output is fed to the other
  implementation. Both deliberately omit environment/car collision response;
  these are not full SimUpdate or race parity scenarios.
- Four new chassis/vehicle tests, two kinematics/axle tests and four original-world
  tests pass under Address Sanitizer. Evidence from that increment:
  `chassis-parity-report.json`. App remains the suspension lab.
- Ground collision: 4,860 cases, 490,860 scalars, 1,800 contacts, 216 hard impacts
  and 108 damage increments. Barrier collision: 1,944 cases, 196,344 scalars,
  1,296 blocked cases, 804 rebounds and 78 damage increments. Integer damage,
  flags and blocked state are checked separately. Finite values match exactly.
- Coupled environment response: 30,000 independently evolving ticks over five
  scenarios, including a drop and a barrier strike. All compared mechanics and
  collision outputs match exactly within each tested build; full SimUpdate,
  car-to-car collision and race parity remain unclaimed.
- Two new environment tests, two vehicle tests, three chassis tests and four
  original-world tests pass under Address Sanitizer. Evidence from that increment:
  `environment-collision-parity-report.json`.
- Driver setup: 20 values; control checking: 1,344 cases and 6,720 finite scalars.
  Tests cover nonfinite input, clamping, broken/finish precedence and thresholds.
- Actual original SimUpdate versus native active-car update: 22,505 ticks,
  8,214,325 scalar fields, including 500 post-settling prestart ticks. Compared
  finite values match exactly; discrete collision/damage/location and wear also checked.
  Original SOLID dispatch remains enabled; selected traces never raise its collision flag.
- Native standalone runtime: five 3,000-tick scenarios after independent 501-tick
  settling, 2,130,000 telemetry values. Native placement, XML/geometry loading,
  mechanical state and continuous random stream are independent of CReference.
- Native random stream: 90,000 original comparisons across nine seeds plus 900
  copied-stream comparisons. Fresh prestart: 200 ticks / 28,400 telemetry values
  plus chassis/control state. The isolated active-car API rejects removal/pit inputs;
  managed runtime support is documented in the later lifecycle increment.
- Six new tests plus four existing original-world tests pass under Address
  Sanitizer. Full-update barrier counts: 1,459 debug/ASan versus 1,432 release;
  native and original match within each build, not across builds.
- Reproduce standalone release captures with `Scripts/verify-single-car.sh`.
  Evidence from that increment: `single-car-parity-report.json`.
- Object collision response: 8,640 pair cases / 552,960 finite fields and 7,776
  wall cases / 248,832 fields. Includes original ordering, prior impulse/blocking,
  pit/finish/removal gates, damage and full transform outputs. Another 120 cases /
  7,680 fields cover separation caps and damage truncation boundaries.
- Chained response: 4,000 contacts across three bodies, 1,000 reset/commit cycles
  and 384,000 fields. Native and original state evolve independently; this is
  response-kernel coverage, not SOLID collision detection or integrated multi-car parity.
  Four new object-response tests, two environment tests, two vehicle tests and
  four original-world tests pass under Address Sanitizer. All response fields
  match exactly in debug/release/ASan; the five single-car release CLIs still
  repeat and match exactly. Signing and Metal smoke checks pass.
  See `COLLISION_PORT.md` and historical `object-collision-parity-report.json`.
- Convex support/query/SMART/boundary coverage: 19,670 cases, 119,352 finite
  scalar fields and 450 separately classified nonfinite outputs. The original
  functions receive identical inputs and retain their own query/cursor state.
- Integrated native two-car collision and three-car pileup: 5,000 measured ticks,
  1,704,000 telemetry fields, independently initialized/evolving state and owned
  random stream. Tests include ticks with multiple intersecting pairs. Stable
  native index ordering matches the selected original dispatches; general
  allocation-order equivalence is not claimed.
- Reproduce the two-car release CLI with `Scripts/verify-car-collision.sh`.
  Current increment evidence: `convex-collision-parity-report.json`.
- All six new convex/multi-car tests pass in debug/release and with Address
  Sanitizer (17 selected sanitizer tests total). All compared fields match
  exactly within each build. Two-car collision ticks: 364 debug/ASan, 362 release;
  three-car collision ticks: 630 debug/ASan, 645 release. Three-car ticks with
  multiple pairs: 110 debug/ASan, 97 release. Cross-build identity is not claimed.
- Fixed wall increment: 1,600 affine cases / 96,000 fields, 18,000 complex query
  cases / 206,064 fields, and 25 track-geometry cases / 96 objects / 948 polygons /
  11,376 coordinates. Native hierarchy selection preserves original traversal
  and current/previous-pose distinctions.
- Integrated left/right fixed-wall strikes independently evolve original/native
  geometry, contacts and physics for 6,000 ticks / 852,000 telemetry fields.
  Single-car simulation now uses the multi-car dispatch implementation too.
  See `wall-collision-parity-report.json` for current build evidence and limits.
- Five new affine/complex/wall tests pass in debug/release and under Address
  Sanitizer; the selected sanitizer suite passes 18 tests. All new compared
  values match exactly in each build. Integrated strikes detect 26 wall-contact
  ticks and finish with 948 total damage across the two cases in all three builds.
- Complex/complex queries: 21,600 cases, 54,675 finite fields and 153 classified
  nonfinite outputs. An original-object audit covers 144 fixed pairs, including
  four early-return contacts. Twelve crossing-wall fixtures identify eleven
  invalid wall-as-car accesses, which native code reports explicitly.
- Fixed contacts prevent previous-pose advancement for a 3,000-tick / 426,000-field
  original/native run. Mixed three-car left/right wall pileups compare 7,000 ticks /
  2,982,000 telemetry values and require simultaneous wall/car and car/car contacts.
  Current evidence: `fixed-mixed-collision-parity-report.json`.
- Six new complex-pair/fixed-dispatch/mixed-pileup tests pass in debug/release;
  21 selected tests pass under Address Sanitizer. All compared values match
  exactly within each build. Fixed-contact runs produce 1,188 wall/car contact
  ticks and 310 damage in debug/ASan, versus 1,146 ticks and 319 damage in release.
  Mixed pileups contain four simultaneous wall/car-plus-car/car ticks in
  debug/ASan and three in release. No cross-build trajectory identity is claimed.
- Removal kernel: 2,340 state/threshold cases, six complete independently evolving
  towing sequences (108,498 invocations), and 16 phase/zero-distance boundary cases.
  All 10,309,416 finite values match exactly; six NaN outputs are classified separately.
  Three new tests pass in debug/release and under Address Sanitizer (seven selected
  sanitizer tests total). Actual original collision unregistration is exercised.
  This kernel increment preceded runtime scheduling; see REMOVAL_PORT.md and
  removal-parity-report.json. App remains the suspension lab.
- Runtime removal: eight new tests compare mechanical and published state against
  complete original SimUpdate. Six cases finish towing; fresh inactive/prestart
  and single-car default-flag cases also pass. About 69.7 million values match per
  build; each case also verifies a 32-value RNG tail. Debug/release comparisons
  have zero observed error within each build; their trajectories can differ. Eighteen selected tests
  pass under Address Sanitizer. See lifecycle-parity-report.json for build counts.
  Service physics and pit allocation/timing follow below; full race execution remains open.
- Pit setup/service: five new tests cover all 89 numeric entries, bounds-only
  loading, adjustment thresholds, 40 reconfiguration operations and nine services
  across 13,500 AWD/RWD/FWD simulation ticks. Mechanical and published state match
  exactly, including Float publication of Double tire wear and retained gearbox
  caches. Twenty-one selected tests pass under Address Sanitizer. See
  PIT_SERVICE.md and pit-service-parity-report.json. Race pit management follows in RACE_PITS.md.
- Race pit management: nine new tests cover assignment/admission/timing, menus,
  practice/qualifying/race setup restrictions and shared-stall removal. Independent
  full-physics scenarios compare 16,000 ticks / 5,140,000 mechanical/lifecycle values
  plus per-tick pit/setup state and 96 RNG values. See RACE_PITS.md and
  race-pit-parity-report.json. All 125 debug/release tests and 41 selected
  Address Sanitizer tests pass.
- Asset loading: seven new tests cover original ACC scene parity, materials, UV
  layers, transforms, normals, primitives, malformed inputs and binary caches.
  Selected models match 2,996 nodes / 1,333 meshes / 313,728 scalar values; 80 authored
  cases add 16,028 exact scalar comparisons. Caches round-trip unchanged and compile
  reproducibly in separate processes. CLI failures preserve existing output.
  All 132 debug/release and 48 selected sanitizer tests pass; the seven asset
  tests also pass after final cache-path validation hardening.
  See ASSET_PIPELINE.md and asset-loader-parity-report.json. No texture or visual
  renderer parity is claimed.
- SGI textures: seven new tests verify 27 original files / 118 mip levels /
  34,843,291 pixel bytes against original decoding and custom CPU mipmap routines.
  Sixty-four authored SGI and 64 mip cases plus 22 naming cases also match.
  All 27 caches round-trip; separate-process compilation is deterministic and
  failed writes preserve existing output. Fourteen asset tests pass under Address
  Sanitizer. GPU blit/readback matches all 34,930,672 RGBA bytes across 118 levels
  of 27 cached textures. App debug/release builds, signing and both GPU diagnostics
  pass. Texture transfer is validated separately from visual rendering.
  See texture-parity-report.json and ASSET_PIPELINE.md for scope and limitations.
- PNG textures: six new tests cover two selected images, 1,092 authored layout /
  gamma / filter / Adam7 cases (672 accepted and 420 rejected by both decoders),
  32 metadata cases, malformed inputs, mip caches and four detailed-wheel meshes.
  Original GfImgReadPng uses the release’s pinned libpng 1.6.50; native code uses
  ImageIO decompression with explicit TORCS gamma, palette, alpha and row rules.
  Accepted selected/authored/metadata pixels compare exactly. Two PNG caches
  match 20 original mip levels / 2,970,968 bytes. Four wheel speed-level meshes
  match 48 nodes / 20 meshes / 26,960 scalar values; wheel attachment is pending.
  All 145 debug/release and 20 selected Address Sanitizer tests pass. Six meshes
  and 29 textures compile reproducibly in separate processes. GPU readback matches
  37,901,640 RGBA bytes across all 138 levels of 29 cached textures. Texture cache
  version 2 requires recompiling version 1 caches. App builds, signing and Metal
  smoke checks pass. See png-parity-report.json and ASSET_PIPELINE.md for the
  pinned-library boundary and remaining rendering/content limitations.
- Scene rendering: compiled single-model packages resolve every texture dependency,
  reject missing/corrupt bindings and publish only new complete directories. The
  native File menu opens these packages into a Metal orbit inspector. Actual
  155-DTM body, Aalborg track and wheel geometry renders from cached buffers;
  no legacy model/image parsing or disk IO occurs in draw callbacks. Four new
  tests check package failure behavior, hierarchy transforms against original
  PLIB, and actual GPU texture orientation/layering/depth/culling/alpha/emission.
  Three original models plus 16 authored transform scenes compare 18,194 vertices.
  Maximum absolute error is 0.00000190735 units in debug/release/ASan. All
  149 debug/release tests and 24 selected sanitizer tests pass. Three scenes
  compile reproducibly and render repeatedly to identical pixels on this host.
  SIMD/scalar rounding is bounded, not assumed bit-identical. See
  SCENE_RENDERING.md and scene-rendering-report.json for that increment’s evidence.
  Default inspection lighting and center-based transparency sorting are not
  full upstream visual parity. Wheel attachment is implemented by the next increment;
  complete driving scenes remain open.
- Vehicle presentation now publishes immutable body/wheel snapshots at the original
  copy-back stage, including held publication during inactive/towing phases.
  Native wheel placement, rotation, right-side orientation, scaling and speed-level
  selection compare against a verbatim original grcar loop and PLIB transforms.
  A real native 1,000-tick run renders an assembled car on Aalborg with four wheels.
  It is an offscreen integration diagnostic, not realtime human driving. See
  VEHICLE_PRESENTATION.md and vehicle-presentation-report.json for counts and limits.
  All 153 debug/release tests and 16 selected sanitizer tests pass. Across 2,002
  samples, 80,080 published wheel values match exactly and 184,184 matrix/color
  scalars differ by at most 0.000030517578. Another 300 authored graphics cases
  compare 27,600 scalars with maximum error 0.0000009536743. Real GPU instance
  updates and interpolation endpoints/wrap/scales are tested. Close-view raster
  repetition permits at most one byte value of error in 0.01% of channels;
  measured changes are recorded rather than claiming universal pixel identity.
- Native driving: a prepared local session opens original body, four wheel speed
  resources and track; a serial Swift actor owns the real fixed-step simulator.
  Keyboard actions control the car; rendering reads immutable interpolated frames.
  Pausing/focus loss release controls, and long wall-time gaps suspend driving.
  Four new tests cover cadence-independent 142-field telemetry, pauses/backlog,
  prepared-content validation and original chase-camera arithmetic. UI checks
  exercise loading, starting, acceleration, shifting, keyboard pause and focus loss.
  At that increment, all 157 debug/release tests and 12 selected sanitizer tests
  passed. Camera outputs
  match exactly across 6,000 scalars; four cadences produce identical final
  142-field telemetry after 2,000 ticks each. Paused Metal views redraw only when
  invalidated. Native content sheets retain their parent across cancellation.
  See DRIVING_SESSION.md and driving-session-report.json for that historical increment.
  Lap timing and telemetry are now integrated; physical controller validation, audio/replay and complete
  sessions remain open.
- Selected human lap timing: 23 crossing samples and 2,432 validity samples match
  18 original fields exactly. An independent 5,000-tick physical start-line run
  matches 90,000 timing and 710,000 mechanical values. It crosses forward once,
  with no completed physical lap. A 520-record capture preserves all 161 fields
  across pauses and backlog. Nine timing/driving tests pass under Address Sanitizer.
  The native HUD and atomic per-tick telemetry capture are integrated; see
  LAP_TIMING.md and lap-timing-report.json for scope and build evidence.
- Streaming CLI comparison now supports captures above 128 MiB while retaining
  every divergence value in schema-2 reports. Five new tests check chunk/record
  boundaries, numeric agreement, alignment rejection, atomic reports and aliases;
  the eight telemetry tests pass under Address Sanitizer. A 60,000-record,
  161-field IO fixture and fresh-process memory measurements are recorded in
  streaming-telemetry-report.json. This is not a physical race or Instruments proof.
- Native input adds configurable keyboard bindings, GameController extended-profile
  snapshots and button edges, validated atomic settings and calibrated neutral gating.
  Six tests include 13,032 exact original human-axis comparisons, Apple snapshot
  devices, settings failure cases and four fixed-step request cadences. Physical
  controller driving remains unverified; see INPUT.md and input-report.json.
  Separate-app UI checks verified key capture, duplicate diagnostics, cancellation,
  accessible binding values, gear/pause input and normal-quit telemetry finalization
  (2,056 contiguous records / 161 fields). The final test bundle is
  build/TORCSInputCheck.app; the existing build/TORCSMac.app was not replaced.
  Startup Metal diagnostics now exit before UI creation; debug and packaged release
  checks both return checksum 1103027.
- Six native camera views and the original terrain-projected car shadow are
  implemented. Four chase presets match 24,000 original camera scalars exactly;
  1,000 bonnet transforms match exactly; 6,000 projected footprint vertices have
  maximum planar error 7.63e-6 m. GPU checks cover blending, opaque occlusion,
  transparency ordering and toggling. Optional 4× anisotropic filtering keeps
  classic filtering as default. A two-pixel transparent-window repeat variance remains open (maximum channel delta 6). See DRIVING_VISUALS.md and driving-visual-report.json.
- Original BT now completes a selected physical reference lap; two release runs
  produce identical complete summaries and callback hashes. The original marks
  that lap invalid. Debug/release lap times differ and are recorded as separate
  unresolved reference baselines; native robot execution remains pending.
- Native track environment now supplies the original sky cylinder, light colors/
  direction, clear color and camera fog interval. Configuration reads and all
  three sky geometries match original C++ excerpts; Aalborg's sky PNG bytes match
  original libpng. GPU checks cover lighting, fog, shadow lighting and sky depth.
  Repeated frames still expose sparse window-pixel differences even with identical
  captured submissions. See TRACK_ENVIRONMENT.md and track-environment-report.json.
  The separate signed build/TORCSEnvironmentPreview.app loads the prepared
  Artifacts/driving-environment-final session. Its packaged GPU smoke check passes;
  the final preview has not been UI-launched. Eleven graphics tests pass under
  Address Sanitizer; the final four environment tests also include all sky mip bytes.
- Fourteen additional exterior cameras complete the unzoomed F3–F5 preset lists:
  track-aligned chase, reverse, eight world-direction side views and four overhead
  views. Original class and factory excerpts verify 16,800 updates / 151,200 pose
  scalars exactly; 500 switching cycles verify independent smoothing state.
  Seventeen relevant graphics/presentation tests pass in release and under Address
  Sanitizer; the two new camera tests bring the test inventory to 184.
  All 20 views render in the separate signed build/TORCSCameraPreview.app.
  Sixteen strict pixel-repeat pairs pass; four fail with identical captured
  submissions. Side 3 exposes a larger 49-level difference at one window pixel.
  See EXTERIOR_CAMERAS.md and exterior-camera-report.json.
- Material alpha-test specialization removes the inactive discard path that triggered
  the selected raster-repeat discrepancy. A portable pinned-car regression fails
  with the previous shader and passes with 120 byte-identical repeated frames.
  Twelve cutoff/blend cases preserve all four material pipeline combinations.
  Two fresh signed-preview processes pass all 20 camera repeat pairs with zero
  changed channels; the old preview still fails in an intervening comparison.
  A third process passes with Metal API/shader validation enabled and no reported
  validation fault. The new separate signed app is build/TORCSRasterPreview.app.
  Selected classic/shadow GPU medians are 0.613–0.616 ms versus 0.641 ms before.
  Nineteen relevant tests pass in debug, release and under Address Sanitizer;
  the test inventory is now 186 (the earlier full-suite counts remain historical).
  See RASTER_STABILITY.md and raster-stability-report.json for scope and evidence.
- Car environment mapping now restores the original scrolling UV1 reflection and
  yaw-rotated UV2 shading in prepared sessions, with independent per-car state.
  Original source capture verifies 6,000 transform cases exactly. GPU fixtures
  check map gates, wrap, motion, alpha cutoff and instance isolation. The portable
  car regression now passes 240 byte-identical repeats with reflection modes on/off.
  Two fresh signed-preview processes pass all 20 camera pairs and match all saved
  image hashes. Metal API/shader validation reports no fault. Selected M2 GPU
  overhead is 0.017–0.024 ms, with no added draw calls or render passes.
  Twenty-one relevant tests pass in debug, release and under Address Sanitizer;
  the test inventory is 188, without claiming a new full-suite run.
  The separate app is build/TORCSReflectionPreview.app; the two new shared artwork
  inputs remain local-only pending attribution. The original indexed track-shadow
  layer on car bodies is still pending. See CAR_REFLECTIONS.md and its report.
- Projected baked track shadows now complete the selected four-texture indexed-car
  path. Raw loader bounds survive mesh cache v2; v1 remains readable. Original
  detailed-wheel load loops verify the scale assignment quirk, and 2,000 projected
  matrices / 16,000 coefficients match exactly. The portable car regression now
  covers 360 unchanged repeats with maps off, two maps and three maps.
  Fresh packaged runs match all 28 saved frame hashes, including a native-settled
  shaded-road witness with 247,172 changed channels when projection is enabled.
  Metal API/shader validation reports no fault. Measured additional GPU cost is
  0.005–0.009 ms in the sunlit diagnostic. Sharing identical scene textures and
  reusing the track map avoids about 12 MiB of duplicate RGBA payload.
  Thirty-three relevant tests pass in debug, release and under Address Sanitizer;
  the inventory is 193 (no new complete-suite claim).
  The separate preview is build/TORCSTrackShadowPreview.app. See
  CAR_TRACK_SHADOWS.md and car-track-shadows-report.json for evidence and limits.
- Seven more original views bring the camera picker to 27: driver, circuit center
  and five panoramas. Original class/factory/world-size excerpts verify 3,600
  circuit updates with exact pose/world dimensions, plus 1,200 driver updates
  with maximum positional difference 0.000003815 m. GPU fixtures verify the first
  DRIVER subtree's suppression and the panoramas' background flag.
  Thirty selected graphics/presentation tests pass in debug, release and under
  Address Sanitizer; the test inventory is 197, without a new full-suite claim.
  Two fresh packaged runs match all 35 saved frames and all 27 repeat pairs have
  zero changed channels. All 28 frames from the previous shadow increment remain
  unchanged. Metal API/GPU validation reports no fault. The separate preview is
  build/TORCSSurveyPreview.app; no new
  interactive driving acceptance run is claimed. See DRIVER_SURVEY_CAMERAS.md
  and driver-survey-camera-report.json for scope and evidence.
- The original rear-view mirror is available in Driver, Bonnet and Road views.
  Original class/method/factory/layout capture verifies 1,200 poses and sizes;
  selected pose, crop and display comparisons match exactly. GPU fixtures check
  horizontal reversal, odd-size cropping, car/shadow exclusion, unchanged pixels
  outside the overlay, toggling and render-target reuse. Thirty-three selected
  tests pass in debug, release and Address Sanitizer; the inventory is 200, without
  a new complete-suite claim. Fresh packaged runs match 42 saved image hashes;
  all 35 earlier images are unchanged. Sixteen mirror repeat pairs and resize
  restoration pass. Metal API/GPU validation reports no faults and identical image
  hashes. Native UI checks found and fixed paused camera/visual-option redraw;
  Driver selection, mirror off/on and window resizing now redraw without advancing
  simulation time. Three mirror tests were rerun in release after that UI-only fix.
  Clean follow-up mirror GPU cost is 0.39–0.41 ms at 960 × 640; the report retains
  noisier first-run evidence and does not claim gameplay FPS.
  The latest separate preview is build/TORCSMirrorPreview.app.
  See REAR_VIEW_MIRROR.md and rear-view-mirror-report.json for scope and evidence.
- Optional 4× geometry edge smoothing now covers both the main scene and mirror.
  All 14 sample-count/material pipelines are prepared at load time, and targets
  are reused; Apple GPUs use memoryless multisample attachments. Classic remains
  the default. An analytic triangle-area fixture measures 86.1% lower squared
  coverage error, with fully covered pixels unchanged. Material cutoff/blend and
  mirror resize/toggle checks pass. The pinned car regression now covers 720
  unchanged repeated renders across both sample counts. Thirty-six selected tests
  pass in debug, release and Address Sanitizer; the inventory is 203, without a
  new complete-suite claim. All 27 cameras pass both sample-count repeat checks,
  and all 42 prior preview images remain unchanged in classic mode.
  Two fresh runs and Metal API/GPU validation match all 76 saved images without
  reported faults. The added median GPU cost is 0.09–0.11 ms for the selected
  960 × 640 views; this is not gameplay FPS. Native UI checks cover paused toggles,
  mirrors, combined filtering and resize, with simulation time unchanged.
  The separate preview is build/TORCSSmoothingPreview.app. See EDGE_SMOOTHING.md
  and edge-smoothing-report.json for measured cost and limits.
- Version-4 trackside metadata and original F8/F9 fixed/zoomed views bring the
  picker to 29 cameras. Original camera poses match exactly in 2,400 updates;
  Aalborg's ten camera positions and all 1,123 segment assignments match exactly.
  Authored tests cover subdivisions, overlaps, wraparound, full-lap ranges,
  absent cameras and invalid references. The full debug suite passes 207 tests;
  release and Address Sanitizer each pass 48 selected track/graphics tests.
  Three fresh packaged diagnostics, including Metal API/GPU validation, match
  all 100 PNGs. The 76 previous baseline images are unchanged. Renderer/shaders
  are unchanged; no new gameplay-performance claim is made. The separate preview
  is build/TORCSTracksidePreview.app. Interactive picker verification was pending
  at that increment because the native UI tool could not unlock the Mac. See TRACKSIDE_CAMERAS.md
  and trackside-camera-report.json for evidence and limits.
- All 29 views now support original zoom commands and independent saved native
  camera preferences. A 38,019-update sweep matches original FOV, limits and saved
  values/keys exactly. Persistence tests cover 300 camera switches, round-trips,
  bounded parsing and invalid-write preservation. The 52 selected tests pass in
  debug, release and Address Sanitizer; inventory 211. Three fresh packaged runs,
  including Metal API/GPU validation, match all 120 PNGs with no reported fault.
  All 100 earlier PNGs remain unchanged; 20 zoom repeat pairs and five default/reset
  pairs match exactly. Renderer/shaders are unchanged; preference IO occurs only
  at session creation and control actions. The latest separate preview is
  build/TORCSZoomPreview.app. The native session loaded and the user was observed
  driving in Trackside with both quality options enabled; further interaction
  stopped to preserve the user's session. Interactive zoom/reset and relaunch
  verification remain pending. See CAMERA_ZOOM.md and camera-zoom-report.json.

- F10 groundwork adds a native motion kernel and original raw-AC scene-height
  traversal. Across 28,313 height queries, selected heights, hit counts, triangle
  counts and bounding spheres match original PLIB exactly. Tests retain the 99-hit
  cap, indexed-array enumeration limitation, degenerate hit consumption, face
  culling and edge tolerance. All 48,000 fly updates match original state, clock
  and random-draw counts, with 47,080 original scenery queries. Native camera RNG
  is separate from physics; failed height queries roll back state and draws.
  The full debug suite passes all 218 tests; 63 selected tests pass in release
  and Address Sanitizer. The new kernels are not in the picker; the existing Zoom preview,
  app UI and renderer/shaders remain unchanged. See FLY_CAMERA.md for the required
  assembled-scene integration and fly-camera-kernel-report.json for final evidence.
- F10 is now exposed as **Fly**, the 30th camera, with independent saved zoom.
  Its shared-resource height assembly preserves original selector/range traversal,
  driver insertion order, all-child bounds and the 99-hit cap. Moving graph tests
  compare 12,960 queries exactly; 1,218 additional F10 zoom updates match the
  original factory, limits and preference keys. Integration tests verify previous-
  draw clearance, paused zoom, camera switching and failed-publication rollback.
  Hidden shadows remove both geometry and bounds, matching original leaf removal.
  The final selected suites pass as recorded above. Three fresh packaged processes
  produce identical camera states and all 24 PNGs, each with 24 exact immediate
  raster-repeat pairs and two repeated native physics runs. The third process
  enables Metal API/GPU validation and reports no fault. Visual inspection confirms
  the moving elevated car/track view and a paused narrow-zoom view; the scripted
  drive reaches the track edge at 15 seconds, not a completed lap or AI test.
  The new ad-hoc-signed preview is build/TORCSFlyPreview.app. The running Zoom
  preview, camera preference file, renderer/shaders and all 120 prior PNG files
  retain their hashes; those older PNGs were not rerendered this increment.
  Native picker/zoom/relaunch interaction remains pending to preserve the user's
  driving session. Other LODs, generated brakes/pits/effects, body deformation,
  multiple cars, callbacks and whole-original-scene parity remain open.
  See FLY_CAMERA.md and fly-camera-integration-report.json.
- Automatic TV groundwork now ports original multi-car director scheduling and
  its selected-car roadside projection. Across 24,000 sequential updates with
  1–32 cars and 440 boundary updates, priorities, viewability, clocks, IDs/slots
  and collision clears match original code exactly. The original retained race-
  slot behavior, strict interval gates, screen exclusions and ID-zero fallback
  are preserved. Across 2,400 director camera updates with 303 target changes,
  pose/FOV/projection match exactly; 600 further roadside/zoom cases pass.
  Presentation collision history retains events between display frames and shares
  clear cursors across screens without clearing physics. Tests cover 36,000
  per-car publications at four cadences and 8,000 more across two TV screens.
  A 4,000-tick native run with 500 TV updates retains all 142 telemetry fields,
  random state/draws and published collision flags exactly. All 33 selected tests
  pass in debug/release/ASan; that kernel increment had inventory 234. Its historical
  source/evidence hashes remain in tv-director-report.json.
- TV integration now publishes immutable per-step collision history, race metadata
  and original repeated-addition time. Four retained presentation directors share
  acknowledgements. TV director is camera 31 with original saved F11 zoom. Actual
  native three-car/two-screen tests compare 752 updates, 37 automatic switches and
  seven manual changes exactly against original code. Full standings, multiple
  visible screens and multi-car GUI remain open. Renderer and shader code are
  unchanged; Fly now reads the original race clock. The signed TV preview
  produces 24 identical captures in each of three fresh processes, including
  Metal API/GPU validation. The Fly clock correction preserves all 24 rerendered
  images and camera poses from the preceding preview. No new performance or
  multi-car rendering claim.
  See TV_DIRECTOR.md and tv-integration-report.json.
- Per-car shadow resources now support native traffic, preserving initialization
  order and individual normals/textures. A mirror hides only its current car's
  shadow. Shared mip bytes upload once, while geometry changes remain independent
  of resources. The visibility rule matches 2,696 original cases; GPU tests cover
  overlapping alpha order, individual normal lighting, atomic validation and
  mirror cropping in classic/quality modes. Native traffic captures exercise
  three cars and six automatic TV target switches per 901-frame run. All 80
  captures match in four processes, including clean Metal validation; the prior
  48 single-car TV/Fly captures are unchanged. Shadow-on/off median GPU deltas
  are below 0.003 ms in the selected stationary 960×640 three-car scene, smaller
  than observed variation. This is not race FPS. GUI racing remains single-car.
  See MULTI_CAR_SHADOWS.md and multi-car-shadows-report.json.
- No claims yet about full race performance, controller hardware, memory growth,
  cross-platform bit determinism, clean-machine distribution or notarization.

## Next concrete tasks

The generated brake increment restores original hubs, discs and calipers, with
simulation-driven disc heat color and corresponding Fly height geometry. Across
960 original cases, all 141,120 vertex values match exactly; 20,736 selected PLIB
height queries also match exactly. Five debug/release capture processes agree on
24 images each, including a Metal-validation run. TV/Fly camera records and
scripted three-car TV selection remain unchanged; visible image changes reflect
the added parts. That increment’s ad-hoc-signed preview is `build/TORCSBrakePreview.app`.
Measured stationary M2 GPU cost is below 0.003 ms at the median, with 12 added
draws and 172 triangles per car in the existing pass. No full-race timing claim
is made. See BRAKE_VISUALS.md and brake-visuals-report.json.

Original car lights now render in Metal using separately prepared local textures.
Point culling, per-car mirror exclusions, original blend/depth state and Fly light
bounds are integrated. The selected 155-DTM shows its two brake lights from
published simulation commands. That increment’s preview is `build/TORCSLightPreview.app`.
Four release capture processes match, including Metal validation; median added
GPU cost is 0.0045 ms classic / 0.0105 ms quality in the measured stationary chase
view. Cross-build images differ slightly and are documented separately.
See CAR_LIGHTS.md and car-light-rendering-report.json
for validation, performance and remaining transparency/content limits.

The latest preview is `build/TORCSOrderPreview.app`. Scene anchors now retain
original deferred insertion order; whole cars sort by squared horizontal camera
distance, with independent mirror ordering and original driver-subtree placement.
Ordinary translucent meshes write depth and the frame uses LEQUAL, as in TORCS.
All 1,353 drawable leaves in six selected original models match the reference
queue. Full debug validation passes 263 tests; 34 focused tests pass in debug,
release and AddressSanitizer, including GPU overlap/depth and mirror fixtures.
Four release capture processes agree on the 24 selected light images, including
Metal validation. Fly/TV/traffic camera and selection records remain unchanged;
24/24/80 immediate image repeats pass with the corrected renderer. Measured
stationary GPU medians show no meaningful increase; fresh publication plus two
view sorts costs 2.92–66.79 μs for 1–32 synthetic cars. No full-race FPS claim.
See DRAW_ORDER.md and draw-order-report.json for evidence and reference boundaries.

Inherited alpha state is now implemented in the working tree, including original
loader setter metadata, generated brakes, shadow/light cutoffs and independent
per-view state. A conservative positive-alpha bound removes unnecessary discard
without changing cutoff behavior. The full debug suite passed 270 tests before
the final zero-threshold effect optimization; 43 affected tests pass in release
and AddressSanitizer after it. The first alpha package passes light/Fly/TV
captures but fails traffic repeatability. The effect optimization's rerun still
fails exact cross-run equality at one wheel pixel (blue 60 versus 59), although
the immediate repeat meets the unchanged one-byte tolerance. A fresh Order
preview traffic run passes all 80 comparisons. Both failed alpha captures remain
available; TORCSAlphaEffectPreview.app is investigative, and the Order preview
above remains the latest validated preview. See ALPHA_STATE.md and
alpha-state-report.json. Resolve the frozen frame-450 wheel regression without
relaxing tolerances before promoting the alpha renderer.

An optional **3D trees** implementation now replaces 169 recognized Aalborg trees
with instanced trunks, branches and foliage clusters. Eighteen shared meshes
cover three families, three variants and two detail levels; distant trees retain
their original geometry. The original option restores exact pixels in the new
GPU fixtures, and mirror detail and Fly canopy height are integrated. The full
release suite passes 274 tests; 38 focused tests pass in release and ASan.
The new build/TORCSTreePreview.app submits the optional opaque geometry before
the original draw stream. Two normal packaged runs now pass all 56 immediate
camera comparisons within the unchanged tolerance, including Fly and mirror;
111 of 112 pairs are exact. A Metal-validation run still fails at smoothed
trackside (32 channels, max delta 6); normal cross-process comparison finds three
one-byte differences in the smoothed TV view. The old preview still reproduces
its original 3,787-channel/max-52 failure. The cause is not established and full
image acceptance is still open. Classic stationary chase GPU medians are about
0.65 ms with either tree mode; quality medians are 0.79 ms original/0.73 ms volume.
This is a narrow offscreen result with variable tails, not a full-race or speedup
claim. The additional Fly canopy query measures 93 µs median/168 µs p95 at tree
centers. Foliage is still visibly procedural; tree shadows remain unimplemented.
See VEGETATION.md and vegetation-order-report.json. The historical failed-prototype
report vegetation-report.json is retained. The Order preview remains the
validated baseline; earlier preview binaries and camera preferences are preserved.

The subsequent build/TORCSFoliagePreview.app replaces closed foliage ellipsoids
with individually oriented sprays throughout each crown. This improves fine
silhouettes but remains procedural. It adds 10.7% to chase tree triangles with
the same ten submissions. Current checks pass 38 focused release tests and three
ASan tree tests; all 28 normal original-mode captures match the preceding package.
The current benchmark records three failed repeat views and withholds timing.
Validation also exposes an original-mode/restoration difference. A fixed foliage
mip-level probe does not resolve the failure and is not retained in source.
The diagnostic now saves all repeat/restoration failures before exiting with
failure. Current evidence is in foliage-report.json; earlier timings above apply
to the preceding geometry only. No performance acceptance is claimed for the
new foliage, and the original default and Order baseline remain unchanged.

The current build/TORCSFoliageDepthPreview.app reconstructs tree fog depth from
the fragment position's reciprocal clip w. The large classic first-frame
difference is absent in the tested runs while the original fog formula remains.
An independent CPU canopy-depth oracle checks partial fog for three families;
full fog and exact fog-off restoration pass in both quality modes. Current
checks pass 43 focused release tests and four ASan tree/fog tests. Two normal
56-view runs pass unchanged tolerance and have identical cross-process image
hashes; all 28 original images match the preceding foliage package. The final
Metal-validation run still fails in smoothed Chase (92 channels, max delta 10)
and broadleaf front (53 channels, max delta 2), so promotion remains open.
The current stationary chase benchmark measures 0.649/0.914 ms original/tree
classic GPU medians and 0.795/1.005 ms quality medians. The extra 0.21–0.27 ms is
a scoped result, with variable tails and no full-race claim. Failed binding and
compiler-option experiments were reverted; original scene/effect shaders are
unchanged. See foliage-depth-report.json and the probe matrix in VEGETATION.md.

The gameplay session increment is packaged as build/TORCSGameplayPreview.app.
The final release suite passes 282 tests; seven new session tests also pass
AddressSanitizer. Original prestart timing matches over 10,000 ticks, race ordering
over 5,000 updates, and eight-car authored lap/gap/finish progression over 500
steps. Practice/solo qualifying have configurable laps, countdown, restart,
retirement and JSON results. The driving window is now the app's entry point.
A subsequent native BT solo runtime now completes ten laps repeatably and a
five-lap forced-pit run with two services. Integrated multi-car races and robot
selection in the driving window remain pending. See NATIVE_BT.md. The packaged UI
walkthrough remains pending because automation yielded to user interaction.
See GAMEPLAY.md and gameplay-report.json for scope and evidence.

The user's current priority is finishing gameplay. Foliage work and further
visual experiments are deferred; existing experimental vegetation remains off by
default. See GAMEPLAY.md for the session implementation and next steps.

1. Validate the packaged practice/solo-qualifying UI through countdown, pause,
   restart, retirement, results and export. Preserve the passing model/reference
   checks while integrating the rest of racing.
2. Extend the working native BT solo driver with original opponent handling,
   then integrate original grid placement,
   multi-car race timing/order, pit service and penalties. Expose live standings,
   opponent selection and race results in the driving window.
3. Demonstrate five physical timed human laps and a deterministic ten-lap AI race,
   including collisions and pits with upstream telemetry comparisons. Investigate
   the known BT debug/release sensitivity using a declared build baseline.
4. Add gameplay audio and deterministic replay, then broaden content/session
   configuration and championship persistence. Physical controller validation
   and HID support remain deferred behind the core gameplay loop.
5. Resume graphical refinement after racing works, retaining the documented
   foliage/alpha-state limitations and required asset attribution work.

The full specification remains open in IMPLEMENTATION_CHECKLIST.md. No phase is
marked finished merely because a type, document or tool entry point exists.
