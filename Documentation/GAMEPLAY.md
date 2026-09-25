# Gameplay completion

The current priority is playable sessions and racing. Foliage refinement,
vegetation shadows and further visual experiments are deferred at the user's
request. The existing 3D-tree option stays experimental and off by default.

## Session loop

The driving window now provides New Session with practice or solo qualifying
and a lap count. Preparing a session resets to the loaded, settled car without
recompiling content. Start runs the original two-second prestart; the car's
engine uses existing prestart physics while movement is held by that physics.
Pause consumes no simulation time. End Session preserves completed lap times
and labels the run ended early. Fuel exhaustion/removal produces retirement,
not a successful finish. Natural completion stops on the terminal physics tick.

Results include valid/invalid laps, best valid lap, elapsed race time, fuel and
damage. Save Results writes an atomic JSON file; Drive Again prepares a fresh
run. The results schema is a native session report, not original TORCS result
XML or a deterministic replay. Solo qualifying does not yet feed a race grid.

The old no-countdown DrivingRuntime initializer is retained for existing
physics/render regression tools. The interactive app uses an explicit session
configuration and the TORCS race clock, starting at -2 and resynchronizing to
zero on the first nonnegative fixed tick. Render cadence does not set race time.

## Race controller foundation

RaceOrder ports ReSortCars' strict distance comparisons and finished-car rules.
RaceProgress manages the field in the preceding race order, tracks per-car
lap times and crossing-time gaps, starts finishing when the leader completes,
finishes lapped cars on their next crossing, and retains the original extra
cooldown-lap termination safeguard. These consume real published track samples;
they do not generate opponent driving commands.

This is not yet an integrated human-versus-AI race. Remaining gameplay work:

0. **Done:** the multi-car original reference oracle. A 1–10 car BT field runs
   the original grid, race loop, rules and sorting with per-car capture and
   exact repeatability. See [race oracle](RACE_ORACLE.md). Everything below is
   compared against it.
1. Extend the working native BT single-car driver/runtime with original opponent
   handling, and resolve the measured native/reference trajectory difference.
   See [native BT](NATIVE_BT.md): ten native laps repeat exactly and a five-lap
   forced-pit run completes with two services. All driving/pit commands match
   the captured-input reference cases; full physical trajectory parity is open.
2. Original grid placement is **done** and matches the original exactly, and the
   multi-car simulation now takes one car definition per car; see
   [starting grid](STARTING_GRID.md), and the original race rules and penalties
   are ported and measured; see [race rules](RACE_RULES.md). Still to do: connect
   multi-car simulation, race progress, pit service and penalties to one
   authoritative race runtime.
3. Expose opponent selection, live standings, finish handling and race results in
   the driving window; use actual cars in cameras, mirrors and collisions.
4. Complete a physical five-lap human session and deterministic ten-lap AI race,
   with upstream telemetry comparisons and pit coverage.
5. Add state-driven audio and compatible deterministic replay, followed by wider
   content selection and championship/session persistence.

Physical controller validation and HID support remain lower priority than this
core gameplay loop. Full application completion is still governed by
PORT_SPECIFICATION.md and IMPLEMENTATION_CHECKLIST.md.

## Native AI verification

The subsequent native BT increment passes all 287 release tests and five new
AddressSanitizer tests. Ten autonomous native laps repeat exactly; the five-lap
forced-low-fuel case completes two pit services. Native and original trajectories
remain different. See NATIVE_BT.md and native-bt-report.json; the packaged
interactive preview still uses the human-driving session runtime.

## Session preview verification (before native BT)

The final release build passes all **282 tests** (144.917 s), including the seven
new session tests. Those seven also pass AddressSanitizer (3.484 s). The unchanged
original clock is compared over 10,000 ticks; sorting is compared over 5,000
updates with 1–16 cars. Eight-car authored timing samples cover 500 steps, seven
finished sessions and 46 invalid laps, comparing 23 per-car timing/gap/position
fields. A separate case verifies externally published finish flags at a crossing.
These timing samples are not a physical AI race.

`build/TORCSGameplayPreview.app` is ad hoc signed, strictly verified, and passes
its Metal smoke test. It has no direct original C++/Expat runtime dependency and
bundles no TORCS artwork. Open an existing prepared driving session, then use
New Session… to select a mode and lap count. The final UI walkthrough remains
pending: automation yielded when the user was interacting with the preview.
No complete physical race or UI acceptance is claimed from the model tests.

See gameplay-report.json for source/package hashes, evidence logs and limits.
