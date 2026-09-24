# Vehicle removal and towing

`VehicleRemovalState.remove` is a semantic Swift port of the private `RemoveCar`
function in TORCS 1.3.9 `simuv2/simu.cpp`. It executes one removal invocation.
`MultiVehicleSimulation` now schedules it at the original point in the update;
`SingleVehicleSimulation` shares that implementation. The race engine remains unfinished.

The state keeps published body dynamics and the display transform separate from
mechanical dynamics. Once towing starts, the published position moves while
mechanical dynamics remain frozen. This distinction is necessary because the
existing 142-field vehicle telemetry records mechanical state and would miss
errors in towing animation.

## Preserved behavior

- Pull-up, sideways and pull-down flags take precedence in that order, including
  inputs with multiple flags set. Other non-simulating states return immediately.
- A broken car in a pit frees its assigned pit. Other pit states return without
  starting removal. Damage must strictly exceed a nonzero maximum.
- Removal sets broken or out-of-gas status and zeroes both published and
  mechanical gear/RPM before checking the published longitudinal speed. Speeds
  above 1 m/s in magnitude defer towing; equality allows it to begin.
- Starting towing unregisters the collision object, clears collision outputs and
  published skid, wheel-spin and brake-temperature values, and copies mechanical
  body dynamics into published dynamics. Only published longitudinal speed is
  then zeroed. The display matrix remains stale until the next removal invocation.
- Parking uses the outermost side segment on the nearer side of the road and a
  three-metre offset. The other lateral coordinates remain unchanged, preserving
  the original height-query behavior. Vertical and sideways speed is 0.5 m/s.
- Strict phase thresholds, Float arithmetic, angle normalization and per-tick
  sideways velocity recomputation follow the original. A forced zero-distance
  sideways input preserves the original NaN outputs rather than inventing motion.

A broken pit car without an assigned pit throws a native diagnostic. The original
would dereference a null pit pointer; that invalid call is not executed in tests.

## Reference checks

The reference wrapper invokes unchanged original `RemoveCar` on a real entry in
`SimCarTable`. This exercises original collision-object deletion and registration;
using an isolated temporary car would violate the original removal search. The
wrapper supplies a temporary assigned pit and restores the prior pit pointer.
Each test owns and tears down its reference world.

The tests compare 93 outputs: published/mechanical/parking dynamics, flags,
collision registration, pit occupancy, gear/RPM, the complete display matrix and
published wheel values. Native and original trajectories carry their own prior
outputs independently.

| Check | Coverage |
|---|---|
| State and threshold sweep | 2,340 cases; 217,620 values; six track locations, both sides, 13 flag combinations, damage and speed boundaries |
| Complete towing sequences | Six trajectories; 108,498 invocations; 10,090,314 values; all three towing phases and final out state |
| Phase boundaries and zero distance | 16 cases; 1,482 finite values; six separately classified NaNs |

All compared finite values match exactly within the tested debug, release and
Address Sanitizer builds. Source hashes and validation results are recorded in
`removal-parity-report.json`. Original upstream sources and braking goldens remain
unchanged. These are kernel comparisons, not full `SimUpdate` removal scenarios.

## Runtime scheduling and publication

Each tick resets collision and blocked flags for every car before sequential
updates. Existing non-simulating cars enter RemoveCar and skip active physics.
Damage above the configured limit, exact zero fuel and elimination also invoke
removal; a car still moving above the threshold continues through normal physics.
Original neutral-gear/RPM writes retain transmission ratios, clutch state and other
engine caches. Removal runs before the prestart control override.

The simulation owns persistent flags, removal state and collision registration.
It excludes removed cars from wall/car and car/car queries while retaining other
inactive objects, including pit cars. Pit participation can affect both contact
response and the global previous-pose gate. Collision accumulators persist for
inactive cars just as they do upstream.

A pit car's collision object can retain the preceding tick's matrix while its
published car matrix is newer. Detection uses the retained object transform;
response transforms separation points with the published matrix. A response that
refreshes a matrix updates both. Objects never loaded by active dispatch retain
SOLID's identity type flag. These distinctions are checked by pit-contact and
fresh inactive/prestart scenarios.

After collision dispatch, only active cars publish mechanical body/world motion,
speed, gear/RPM, fuel, damage and wheel values. Towing updates published body
motion and its display matrix without replacing frozen mechanical or published
world motion. Published collision bits accumulate until original removal clears
them. Commands supplied for inactive cars remain unprocessed, as upstream does.

`updateCarStatus` accepts external flags, fuel, damage and assigned pit occupancy.
The step's `maximumDamage` is a race input. Omitted flags preserve runtime-owned
state, including through the single-car facade. Reactivation after collision
unregistration requires configuration and is explicitly rejected here. Assigned
pit occupancy is a physics boundary value; shared stall allocation and pit
service policy still belong to the future race layer.

## Full-update reference checks

The original wrapper sets external status and then runs unchanged SimUpdate,
including original collision dispatch. Neither implementation receives the
other's evolving state or contacts. Tests compare all 142 mechanical telemetry
fields plus 115 lifecycle/publication values per car, on every measured tick.
The lifecycle values include the complete published world dynamics, speed,
fuel/damage, matrix, collision outputs, pit occupancy and collision registration.

Six complete removal scenarios cover stationary fuel exhaustion, moving damage,
moving elimination, a broken pit car, surviving-car collisions around a towed
middle car, and a pit car struck before removal. All assert every towing phase
and 32 additional ticks in the final out state. Short cases cover fresh pit/DNF
states, prestart reactivation/removal and persistent single-car flags. A final
32-draw probe of each original RNG stream matches a copy of the native stream;
no reseeding or shared random values are used during the captures.

The eight cases compare 69,729,497 values over 127,597 measured ticks in debug/ASan
and 69,727,441 over 127,593 ticks in release, plus 256 RNG-tail values per build.
Every comparison matches within its build. Debug/ASan contain 532 pit-contact
and 308 surviving-car contact ticks; release contains 528 and 294 respectively.
The native and original versions exhibit the same build-specific differences.

Build-specific measurements, hashes and regression results are recorded in
`lifecycle-parity-report.json`. Kernel evidence in `removal-parity-report.json`
remains a historical snapshot. Cross-build trajectory identity is not claimed.

## Remaining work

Service/reconfiguration physics is now implemented; see PIT_SERVICE.md. Pit
admission, shared stall ownership and service timing now integrate with removal
through RacePitSimulation; see RACE_PITS.md. Full race scheduling and gameplay
remain unfinished. Broader track/content and collision-order
coverage are needed before claiming complete race parity. The app still displays
the suspension lab rather than a driveable track and car.
