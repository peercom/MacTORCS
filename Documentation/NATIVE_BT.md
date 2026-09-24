# Native BT gameplay integration

`TORCSRobots` now contains a semantic Swift port of the original BT driver's
single-car policy. `BTSoloDriver` consumes an immutable published-car observation
and returns raw controls plus a pit request. It owns clutch/recovery state,
corner learning, the original SimpleStrategy2 fuel policy and pit trajectory.
There are no process-global car pointers or original C++ dependencies.

The scope is explicit: this driver expects a field of one car. Opponent
classification, overtaking, collision avoidance and team behavior are not yet
ported. It must not be used for human-versus-AI traffic until those are present.
`BTSoloRuntime` connects it to native physics, prestart scheduling, lap timing and
pit service. The diagnostic start is 10 metres before the line, matching the
reference harness, rather than the unported original grid builder. This runtime
is not yet selectable in the interactive driving window.

## Callback contract

Construct a new driver per race with the road, merged car/category parameters,
robot setup (if any), target laps, driver index and assigned pit stall. The
`initialFuel` value is the original pre-merge strategy request: merge it as the
initial-fuel parameter before constructing physics. The runtime implements this
for the selected default BT-0 setup. Per-track setup discovery is not yet wired.

`BTObservation` copies public track position, pose, local/world velocity, wheel
spin, fuel, engine speed, gear, damage, lap counters and pit occupancy. A driver
cannot mutate physics. Angles are radians and engine speed is rad/s. The
single-car runtime carries physics-adjusted controls between callbacks, retains
the repeated-addition race clock, and resets robot callback time at green.
Callbacks are scheduled by the original elapsed-time comparison against 0.02 s,
not by rounding to every ten ticks.

Pit service runs after physics, before lap publication. The original pit command
returns fuel and repair quantities; tire defaults and service timing remain in
RacePitController. Original race penalties, robot timeout and full finishing
behavior are still outside this bounded runtime.

Learning data is explicit input/output (`BTLearning`), with original macOS
little-endian `.karma` records. The session owner chooses the file and calls
`save(to:)`; no implicit destructor IO or global content paths are used. Loading
validates the entire record and IDs before changing state. Local/global/session
fallback lookup remains to be integrated. Degenerate all-straight tracks are
rejected rather than entering the original unbounded previous-turn search.

## Evidence

The release reference test feeds the Swift driver the public tCarElt observation
captured immediately before every original callback. It compares raw controls
before physics control checking and compares shutdown learning data. On the
selected BT-0 / 155-DTM / Aalborg lap:

- 44,694 physics ticks and 4,211 callbacks.
- All 21,055 controls match exactly (16,844 Float values and 4,211 gears).
- Learned radii and update IDs match exactly.
- The reference lap is 87.38799999997774 seconds and is invalid under original
  lap-validity rules. These callback comparisons alone do not prove native
  physics trajectory parity.

The original three-lap forced-low-fuel run additionally exercises 13,418 drive
callbacks and two pit callbacks. Every raw driving control matches exactly,
and both fuel/repair decisions match. A native five-lap run with the same fuel
reduction completes at tick 240,464 after two pit services. This verifies the
selected pit-driving path, not arbitrary tracks, shared stalls or penalties.

Two native one-lap runs finish at tick 44,612, 87.22399999997812 seconds, with
identical complete final physics and timing. The difference from the release
reference is about 0.164 seconds; the native trajectory is not bit-identical to
that reference. Two ten-lap native runs also match every report value exactly:
422,550 ticks, 40,307 callbacks, 843.0999999938871 seconds, zero pit services,
2.7617707 litres left and damage 3,977. The original ten-lap run finishes at tick
422,342 (842.6839999938969 seconds). Individual lap times differ considerably,
so similar total time is not a trajectory parity claim. All ten laps in both
reports are invalid under lap-validity rules; no valid-lap acceptance is claimed.

`Artifacts/bt-native-tests.log` records the initial callback comparison;
`bt-native-runtime-tests.log` records the first independent native lap;
`bt-native-pit-tests.log` records the longer pit comparisons. The ten-lap JSON
reports are `bt-native-ten-laps.json`, `bt-native-ten-laps-repeat.json` and
`bt-reference-ten-laps.json`. The C++ debug/release baseline sensitivity recorded
in ROBOT_API.md remains unresolved. Native debug and release trajectories also
differ: the AddressSanitizer debug one-lap run finishes at tick 44,617 and
87.2339999999781 seconds (the same finish tick/time as the debug reference),
while its forced-pit five-lap run takes 240,726 ticks. Both debug captured-input
comparisons still match controls exactly. This is same-build determinism, not
cross-optimization replay compatibility. All five new tests pass AddressSanitizer
(139.398 seconds). Complete-suite and sanitizer results are
tracked separately in `native-bt-report.json`. The complete release suite passes
287 tests (171.141 seconds); all five new AI tests pass within that run.

## Run the native diagnostic

```sh
swift build -c release --product torcs-sim
.build/release/torcs-sim --robot bt --fixtures Tests/UnitTests/Fixtures \
  --laps 10 --max-ticks 600000 --summary Artifacts/native-bt.json
```

The JSON summary includes the build configuration and executable SHA-256, so
reports from different binaries are distinguishable. Optional `--telemetry`
writes the native physics stream. A maximum-tick bound may
produce a partial run: read `completed` in the summary. This command needs only
the pinned XML fixtures and links no original physics/driver implementation.

The copied original BT algorithm files remain unchanged. The reference-only C
adapter adds public observation capture; production code imports Swift modules
only. Foliage work remains deferred in favor of gameplay.
