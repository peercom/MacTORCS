# Human lap timing and driving telemetry

The native driving session now has a five-lap practice timing boundary, an on-screen
current/last/best clock, validity status and a finish summary. It stops physics on
the finishing tick. This is not the complete practice race mode: countdown, selectable
session rules, results files, pit penalties, multiple-car ordering and robots remain
open. Five physically driven laps have not yet been demonstrated.

## Original behavior

`RaceLapTiming` is a semantic port of the selected single-human branches of TORCS
1.3.9 `raceengine.cpp` (`ReManage` and `ReRaceRules`). The pinned, unchanged source
runs in the test oracle. The adapter captures its fields, suppresses only practice
result persistence/UI and isolates timing from professional pit penalties. Physics
retains its original skill level. Native gameplay does not link this C++ adapter.

- A transition from a segment with `TR_LAST` to one with `TR_START` starts lap 1.
  The sixth forward crossing completes a five-lap run. Remaining laps becomes -1.
- Crossing backward increments a counter. Subsequent forward crossings consume
  that counter before they can advance the lap count. Remaining in the same segment
  never registers a crossing. These are original segment flags, not a new checkpoint
  system; authored test jumps are not evidence of physical laps.
- The first crossing does not reset the start time. The first completed lap includes
  elapsed time before that first crossing. Later start times narrow to original
  `tdble` (Float) before being subtracted from Double race time. As a consequence,
  the current-lap clock can be slightly nonzero immediately after a crossing.
- Race time uses repeated Double additions of 0.002. The fixed-step clock and
  telemetry envelope retain tick-derived time. Both are recorded explicitly.
- Wall collision bit 2 and an inside-corner distance strictly below `-0.7 * carWidth`
  invalidate best-lap eligibility. Pit entry through exit, including wraparound,
  exempts the curve on the pit side. Straight segments and the outside of a curve
  do not invalidate a lap. The selected session enables both invalidation rules.
- Crossing updates the completed lap and resets validity before the new tick's
  rule checks. A wall hit on a nonterminal crossing invalidates the new lap; a hit
  on the finishing crossing is ignored. An invalid completed lap still counts
  toward the five-lap target but cannot replace the best time.
- An already-finished car crossing forward returns before changing previous segment,
  time and distance. A race already marked finishing ends the car on its next forward
  crossing. The single-car driving runtime stops immediately at its own finish.

The prepared session now starts 10 m before the line at the road center, after
501 settling updates. The longitudinal placement follows the original default grid
lead distance. Full grid configuration and lateral placement are not implemented.
`DrivingRuntime` now belongs to the race-engine module because it schedules physics
then lap management, publishes finish flags, and emits immutable timing snapshots.
The renderer has no authority over any of these operations.

## Telemetry

Choose **Record Telemetry…**, select a JSONL destination, then **Drive**. Selecting a
file pauses driving. **Finish Recording** atomically publishes the capture. Closing
the driving window, replacing the session, normal application quit or finishing the
run also finishes the active capture. An interrupted/failed capture leaves the prior
destination untouched; force termination is not a successful save.

The first record describes the current state; every subsequent completed simulation
tick contributes one record, regardless of render cadence, pause duration or work-cap
backlog. There are 142 existing mechanical fields and 19 additional timing fields.
`time` is tick-derived and `race.time` is the original accumulated Double clock.
The worker performs diagnostic encoding and disk writes, outside rendering. Recording
has an explicit performance cost and is not an allocation-free physics claim.

These diagnostic files are not replay files: content hashes, replay compatibility,
random seed/configuration manifests and deterministic playback remain separate work.
The writer streams in bounded memory. `torcs-diff` now streams comparisons and complete divergence reports without a
total size limit; see TELEMETRY_COMPARISON.md. The small-array `TelemetryIO.read`
helper retains its 128 MiB guard. No records are silently decimated or truncated.

## Verification scope

- 23 authored samples compare 18 original timing fields exactly, including five
  completed synthetic laps, backward cancellation, invalid best times, finish-tick
  ordering and the already-finished early return.
- 2,432 authored samples compare the same fields across rule masks, strict thresholds,
  collision bits, both pit sides and wrapped/unwrapped pit ranges; 692 invalidate.
- 5,000 independent native/original physics ticks start 10 m before Aalborg's line,
  accelerate and brake, and cross forward once. All 90,000 timing and 710,000
  mechanical field comparisons are exact within each tested build. No complete lap
  is represented by this short physical run.
- A 520-record JSONL capture round-trips all 161 fields and matches direct fixed-step
  execution, including a 600-second pause and retained backlog. Terminal callback and
  failed-writer tests stop batches without advancing additional clock/physics ticks.

See `lap-timing-report.json` for build-specific test outcomes and source hashes.
Physical controller validation, completed laps and Instruments race measurements are
still required for the first playable milestone.

The packaged-app UI check verified the initial timing strip, recording through the
native save sheet, 46 contiguous tick records (0–45), explicit finish/save and
window-close finalization (one paused baseline record at tick 45). A later live
window displayed lap 1 and invalidation at 86.810 s; that was an observed interactive
session, not a controlled reference comparison. The later input increment verified normal-quit finalization in a separate test
app: 2,056 consecutive records (ticks 0–2,055), each with 161 fields, were saved
when quitting with capture active. The original app was not closed or replaced.
See input-report.json; this does not establish physical laps or full race parity.
