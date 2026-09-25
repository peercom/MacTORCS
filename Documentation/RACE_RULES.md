# Native race rules and penalties

`RaceRules` in `TORCSRaceEngine` is a semantic port of `ReRaceRules`, the routine
`ReManage` calls after the start-line crossing and before it publishes lap time,
distance and the previous position. Every branch is measured against the original
routine using authored positions, so each rule is triggered deliberately rather
than waited for.

## What the original does, and where it now lives

`RaceRules.applyCommon` is the section the original applies to every car:

- **Lap-time elimination.** A car whose current lap exceeds `84.5 s + length/10`
  is eliminated, unless it is human-driven. On Aalborg the threshold is
  343.254345703125 s. The original compares its float lap time against a double
  threshold, and the port reproduces that, including the float storage.
- **Wall-hit invalidation** and **corner-cut invalidation**, which were already
  ported inside `RaceLapTiming`. The corner-cut geometry — including the rule that
  pit entry and exit count as track on the pit side — now lives once, in
  `RaceRules.cornerCut`, and `RaceLapTiming` calls it.
- **Race corner-cut time penalty.** In a race, with the penalty rule enabled, the
  original adds `speed · 0.002 · (−border − limit) / (minimumRadius − limit)` when
  that radius stays above one metre, accumulating in double and storing into a
  float. `LapValidityRules` gained `.cornerCuttingPenalty` (the original's bit 4)
  and a `.race` preset, so the enabled mask is the original bitmask.

`RaceRules.apply` adds the rules the original applies only at skill level 3 and
above — "only for the pros":

- **The penalty queue.** Drive-through and stop-and-go, each with the original's
  five-lap `lapToClear`. A car still carrying its first penalty past that lap is
  eliminated.
- **The pit-lane rule state machine** over the original `RM_PNST_*` flags, driven
  by the effective segment's race flags for the current and previous position:
  entering through the pit entry begins serving a queued penalty, stopping in the
  box marks a stop-and-go served, leaving through the pit exit clears a served
  penalty and resets the progress, and leaving or entering anywhere else is a new
  stop-and-go.
- **The pit speed limit.** Exceeding it inside a speed-limited segment earns a
  drive-through, once, unless the car is already speeding or under an illegal-use
  penalty.

The rules read the *previous* tick's lap time, because `ReManage` publishes
`_curLapTime` after calling the rules. A runtime must pass the published value,
not a freshly computed one.

## Measured against the original

An authored-position oracle drives the original routine directly:
`ref_world_progress_init` places the car, `ref_world_race_configure` sets the rule
bitmask, race type, skill and driver type the original gates on,
`ref_world_race_public_speed` supplies the total speed the corner-cut penalty
reads, and `ref_world_race_car_state` publishes the resulting rule state, penalty
queue, accumulated penalty time and elimination.

- **Corner-cut penalty:** 200 steps at five different speeds on an Aalborg turn,
  with the car 2.5 m past the inside border. Accumulated penalty time matches the
  original at **every step**, reaching 6.8236117 s.
- **Lap-time elimination:** a robot is eliminated one step after the threshold is
  published and a human is not, matching the original's verdict. The first step
  only publishes the lap time, which is the ordering described above.
- **Pit-lane rules and speed limit:** an eight-step walk — entering over the
  limit, leaving without serving, returning through the entry, serving, leaving
  through the exit, then entering illegally — matches the original's rule state,
  penalty count, first penalty kind and lap-to-clear at every step.
- **Stop-and-go service:** an eight-step walk for each stop type. With a real
  stop-and-go stop the penalty is cleared at the exit; with a repair stop the
  original refuses to count it and the penalty survives. Both match at every step.
- **Mode separation:** practice invalidates a cut lap and never accumulates time;
  the race penalty bit alone accumulates time and leaves the lap valid.

Release suite: 449 tests, 0 failures.

## Boundaries

- `RaceLapTiming` still applies the lap-validity half itself, for the existing
  single-car sessions. A race runtime that calls `RaceRules.apply` should pass no
  validity rules to the timing so the shared section is not applied twice;
  applying it twice would be harmless for invalidation but is not intended.
- The original dereferences its penalty queue head when the rule flags say a
  penalty was served. Those flags can only be set while a penalty exists, so the
  port reports an empty queue as nothing to clear rather than reading it.
- Penalties are verified with authored positions, not by a car driving itself into
  an infringement. The rules are not yet connected to a running race: that is the
  authoritative race runtime, the next increment.
- Nothing consumes `penaltyTime` yet. `RacePitController` already accepts a
  penalty time for pit service timing; wiring the accumulated value into it
  belongs to the race runtime.
- Aalborg / 155-DTM pinned fixtures. The pit rules depend on each track's pit
  flags, and a track without pits exercises none of them.
