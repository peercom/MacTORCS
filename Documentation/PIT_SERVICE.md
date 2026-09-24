# Pit setup and physics reconfiguration

`PitSetup` ports TORCS 1.3.9 `RtInitCarPitSetup` and
`SimAdjustPitCarSetupParam`. `VehicleDynamicsState.service`, exposed through both
single- and multi-car simulation, ports the complete `SimReConfig` operation.
This applies service to physics. RacePitSimulation now supplies admission, shared
stall ownership, duration and timed release; see RACE_PITS.md. Pit penalties and
complete race execution remain unfinished.

## Setup model

The model contains 89 numeric value/minimum/maximum triples and three differential
method identifiers. It reads steering, wheel alignment/ride height, brakes,
suspension, anti-roll bars, third elements, eight forward gears, wings and
six settings for each differential. Native XML values and bounds are already in
SI units. Fresh setup defaults are zero, independently of physical configuration
fallbacks used by the dynamics constructors.

Bounds-only loading retains requested values but still reloads differential type
metadata. Missing or nonnumeric parameters set the requested value to zero during
a full load, while retaining existing bounds. The original boundary lookup fails
without writing its output pointers; the port preserves that behavior.

Adjustment uses the original Float range-width threshold, `0.0001f`. A narrower
range sets the request to its maximum and returns false. Most reconfiguration
stages then retain the live setting. Reversed bounds retain the original ordered
upper/lower checks. The adjustment kernel also preserves tested NaN/infinity
behavior; four NaN outputs are classified separately from finite comparisons.

## Service operation

The operation preserves original ordering:

1. Add positive fuel and cap at tank capacity; subtract positive repair and floor
   damage at zero. Zero/negative requests do nothing.
2. Reconfigure steering lock and brake repartition/pressure.
3. For each axle, reconfigure its wing, anti-roll spring and third suspension.
4. Reconfigure each wheel's alignment and suspension. An all-tires request resets
   mechanical pressure, temperature, wear, graining and grip.
5. Reconfigure the driven differentials and gear definitions, then select neutral.

Live definitions are updated without recreating dynamic state. Wheel travel,
rotation, force histories, clutch state, cached current ratio/inertia and
transmission output-axis inertias survive service. Differential feedback inertia
is recalculated only when that differential's ratio is adjustable. AWD updates
front and rear feedback before the central differential.

Several upstream quirks are intentional:

- Ride height and third-element travel are applied even for fixed parameters.
  Wheel preload/rest and damper offsets are refreshed; third-element maximum
  travel becomes the requested travel.
- Rear-wing changes add the old drag contribution and subtract the new one in
  Float order. They do not recompute the entire drafting coefficient.
- Maximum torque bias below the live minimum is raised to that minimum, including
  updating the command value even if it then exceeds its supplied upper bound.
- Requested differential types are retained as metadata but do not change live
  differential types.
- Only existing positive forward overall ratios are rebuilt. A ratio changed to
  zero cannot be re-enabled by a later service call. Existing reverse uses the
  original configured reverse ratio; neutral and gear-count limits are retained.
- Selecting neutral does not perform a normal gearbox shift or reset its caches.
- Tire replacement uses the current local atmospheric temperature. Before the
  first atmospheric update that value is zero, matching the original fresh state.

Requests are passed `inout`, so callers receive the same adjusted setup values
that TORCS leaves in its pit command. The vehicle also retains the resulting
`pitSetup`. A repair that would overflow the original signed damage storage
produces a native diagnostic instead of reproducing undefined integer overflow.

## Published state

Service updates mechanical fuel/damage and tires immediately. Published dynamic
values remain unchanged until an active simulation update copies them back; a car
still flagged PIT continues to expose its preceding published tire state.
Steering lock and gear-ratio metadata change immediately, as upstream does.

Published tire wear uses Float, although mechanical wear remains Double. This
conversion is checked explicitly. Pressure, temperature, graining and wear are
stored separately in the published lifecycle state so a renderer cannot mistake
new mechanical tires for already-published race state.

Example physics-boundary call after race logic has authorized service:

```swift
var command = PitServiceCommand(
    setup: simulation.vehicle.pitSetup,
    fuel: 25,
    repair: 400,
    changeAllTires: true
)
command.setup[.wingAngle, 1].value = 0.2
try simulation.service(&command)
```

This call does not allocate/free a stall, advance a service timer or clear PIT.
The tests supply those external state transitions explicitly; they do not claim
race-engine pit entry or stop timing parity.

## Reference evidence

Test wrappers call unchanged original setup loading, adjustment and SimReConfig.
They expose the adjusted commands and live state. Original source files and
previous braking goldens remain unchanged. Native simulation receives no original
state, contacts or random draws while running.

- Adjustment: 180 threshold/reversed/nonfinite cases, 716 compared values and four
  separately classified NaNs.
- Loading: 270 original car setup values plus 18 authored full/bounds-only cases,
  4,860 values, including missing entries, wrong types, units and all 89 fields.
- Repeated complete reconfiguration: 40 operations, 21,600 setup values, 11,200
  running-gear values, 4,640 transmission values and 440 additional control,
  aerodynamic, fuel and repair values.
- Integrated service: AWD, RWD and FWD; nine service operations and 13,500 full
  simulation ticks. Each measured tick and each service boundary compares 142
  mechanical fields, 115 lifecycle values and 27 published setup/tire values.
  Total: 3,836,556 values, plus adjusted setup and cached transmission checks.
  Six replacements act on worn tires; no-change requests preserve wear. Ninety-six
  final RNG-tail values check stream ownership across the three scenarios.

The layout variants modify only temporary staged XML, changing both car and
category drivetrain types. Pinned fixtures remain unchanged. These are authored
layout variants of the selected car, not claims about all original TORCS cars.

All compared values match within the tested builds. Build observations, source
hashes and regression results are in `pit-service-parity-report.json`. The full
race engine, broader content validation and playable track/car rendering remain
unfinished; the app still displays the suspension lab.
