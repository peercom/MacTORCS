# Race pit management

`TORCSRaceEngine` now implements the pit branch of TORCS 1.3.9 `ReManage`,
`ReUpdtPitTime` and `initPits`. `RacePitSimulation` connects that policy to the
native multi-car physics scheduler. This is an implemented part of the race
engine; laps, sorting, race startup, results, robots and penalty enforcement are
still unfinished. The app continues to display the suspension lab.

## Ownership and scheduling

`RacePitController` owns team assignment, shared stall occupancy and each car's
pit command, stop count, penalty-time input, admission time and service deadline.
The static road/pit geometry remains immutable. Assignment walks cars and stalls
in upstream order, sharing only with byte-identical team names and clamping cars
per pit to 1…4. The first assigned car supplies the stall's longitudinal margins;
a later teammate with another car length does not change those margins. Cars
left over after all stalls are full retain no assigned pit.

The original assignment expression uses the stored pit `toStart` directly even
on curves, wraps each bound once only when greater than track length, and does
not reinterpret a minimum greater than its maximum as a wrapped interval. The
native implementation retains these details.

Admission requires the request bit, a free assigned stall, acceptable published
damage, strict longitudinal bounds, sufficient lateral placement within the pit
lane and both body-local speed components strictly between -1 and +1 m/s. Damage
equal to the nonzero maximum remains eligible. Zero disables that damage gate.
Side width sums the border and at most one outer strip using the original width
query. Missing required side geometry produces a diagnostic instead of the
original null dereference. Upstream does not add a DNF/finished-state admission
gate, so this policy does not invent one.

On entry the controller sets PIT, increments stops, reserves the resident's index
within the shared stall, records the current time and defaults tire change to
ALL. The driver callback can edit the service command or request an interactive
menu. `RacePitSimulation` pauses subsequent physics ticks while its menu is
pending; completion schedules service at the retained simulation time. This is
the native callback/clock boundary, not a finished pit UI or robot implementation.

## Duration and service

Repair-stop duration preserves the upstream arithmetic types and order:

- base time plus absolute requested fuel divided by fuel flow;
- absolute requested repair converted to Float and multiplied by the Float
  repair factor;
- accumulated penalty-time input;
- all-tire time only when ALL is requested, skill is exactly 3 and tire factor
  is greater than zero.

The absolute requests determine time even when a negative request produces no
physical repair/refuel, or the tank/damage clamps make some requested service
unnecessary. The native defaults/clamps follow the upstream rule configuration
(2 seconds, 8 fuel units/second, 0.007 repair factor, 16 seconds for tires).
Race-manager XML loading of these rules remains part of future session startup.

Practice and qualifying reload setup bounds but preserve requested values. Race
sessions reload original setup values and bounds before service. Differential
metadata follows the already verified bounds-only loader behavior. These setup
rules run after computing duration, then `SimReConfig` runs immediately at entry
or menu completion. The car remains PIT during the subsequent waiting period.
Physics can therefore use newly repaired/refueled state before that period ends.

Stop-and-go uses only penalty time, resets that time, and applies no physical
service or setup reload. An unknown stop type retains the prior timing, matching
the original switch's lack of a default operation.

While PIT is set the request bit is cleared. Release occurs only when
`scheduledTime < currentTime`; equality still holds the car. Release clears PIT
and marks the shared stall free. The entered/released/menu result flags are
available to a future UI; driver status text preserves the original 31-byte
buffer limit. Race message presentation is not implemented.

## Physics integration

`RacePitSimulation.step` advances physics first, then pit management in stable
car-index order, applying returned service immediately and retaining the adjusted
command. It propagates shared occupancy into the separately published lifecycle
records. If `RemoveCar` frees a damaged PIT car during physics, the controller
releases the shared stall before managing later admissions. Per-car skill levels
are supplied to physics. The caller currently creates and settles the underlying
simulation; complete race initialization and position-based car sorting remain
open.

Optional lateral initial placement allows a real vehicle to begin at its pit
position. This exposed an existing initial-yaw discrepancy: `NORM0_2PI` compares
with Double 2π but adds/subtracts a Float period. The native initializer now uses
that exact operation order. Fresh and settled states at the selected pit match
before any pit command is evaluated.

## Original-code oracle

The reference target compiles the complete unchanged `raceengine.cpp` inside
instrumentation, using original type definitions and the existing original
physics/parameter/track implementations. `initPits` is a verbatim excerpt from
the pinned `raceinit.cpp`; the provenance script checks its exact bytes against
that source. Seven additional original files retain their notices and match the
pinned release archive. There are now 117 pinned source/content/license files.

Reference-only UI shims record pit-menu callbacks and tolerate display activation;
unsupported rendering/result-writing paths abort. They provide no OpenGL runtime
or fabricated physics. Tests execute original `ReManage`, `ReUpdtPitTime` and the
actual stored `ReUpdtPitCmd` menu callback. The reference car is marked human to
bypass the unrelated lap-time DNF rule, and previous track position is supplied
unchanged to suppress lap crossings. Consequently this is a pit-management oracle,
not evidence of complete original race execution. Original penalty rules can run,
but their queues are not yet compared to a native penalty implementation.

## Evidence

Nine new tests cover:

- 96 stall comparisons across six capacity settings with 16 cars;
- canonically equivalent but byte-distinct UTF-8 team names;
- 22 admission boundary cases, including nine admissions;
- seven ordered shared-stall/deadline transitions;
- 36 duration/session/skill/menu cases, 24 physical services and 9,720 setup values;
- eight authored left/right, curved, wrapped and missing-marker layouts: 46 stalls,
  44 admissions and 82 unassigned car cases;
- practice/race integrated service and departure over 12,000 ticks, four entries
  and four releases, 3,084,000 mechanical/lifecycle values and 64 final RNG values;
- a damaged car releasing a teammate's shared stall during full physics: two cars,
  4,000 ticks, 2,056,000 values and 32 final RNG values;
- interactive service deferral, a frozen clock and single completion.

The full suite passes 125 tests in debug and release, and 41 selected tests pass
under Address Sanitizer. All six existing release CLI scenarios remain repeatable
and match the reference; the packaged app passes ad-hoc signature verification
and the Metal smoke check (RGB checksum 1103027).

Every integrated tick also compares 13 pit-state checks and 270 setup values per
car. The integrated tests use authored initial pit placement and driver commands;
they do not claim a robot has navigated to the pit. Debug/release/ASan observations,
current source hashes and existing CLI regressions are recorded separately in
`race-pit-parity-report.json`. Earlier reports remain historical snapshots.

Remaining work includes penalties and lane-speed enforcement, complete race
clocks/laps/sorting/results, robot callbacks, session/configuration loading,
native pit UI and broader original content. Pit handling alone does not establish
practice, qualifying or race-mode completion.
