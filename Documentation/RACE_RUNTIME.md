# The authoritative native race runtime

`RaceRuntime` in `TORCSRaceEngine` is one runtime that runs a native field in the
original `ReOneStep` order. It is the first place the clock, robot scheduling,
multi-car physics, pit management, lap timing, gaps, the complete rules and
sorting all meet.

## Order of a step

Exactly `ReOneStep`, then `ReManage` per car:

1. The race clock advances; the countdown holds `prestart` until the original
   resynchronizes to zero.
2. When `time − lastRobotTime ≥ 0.02`, every car that is still simulated is
   driven: a BT car from its own policy, the human car from the command the
   caller sampled for this step. The original calls its human driver module on
   the same schedule, so the runtime samples human input at that interval too —
   unlike the existing practice `DrivingRuntime`, which applies input every
   physics tick.
3. One `MultiVehicleSimulation` step for the whole field. The commands the
   physics mutated (notably the prestart gear and throttle) stay published until
   the next callback, as the original does.
4. Per car, `ReManage`'s pit block: stall release, admission, the driver's pit
   command, service and occupancy.
5. `RaceProgress` performs `ReManage`'s timing, gaps and the complete
   `ReRaceRules`, then `ReSortCars`.

The rules run where the original runs them: after the crossing, which may have
raised the lap count and reset lap validity, and before the previous position and
lap time are published, which they read from the previous tick. `RaceProgress`
captures both before the crossing and retains each car's whole previous position,
which is what `ReRaceRules` reads, while lap timing needs only its segment.

Two ordering notes. The runtime runs every car's pit block before any car's
timing, where the original interleaves them per car; nothing in the pit block
feeds another car's timing, so the results are the same. And the runtime passes
lap timing no validity mask, so the complete rules are the only thing that can
invalidate a lap — which is what makes the wiring observable.

## Measured

- **A native race completes and repeats exactly.** Three cars over two laps
  finish in 124,468 ticks with final order 2, 0, 1 and gaps of 0, 9.604 and
  11.310 s. A second run produces a byte-identical report. A three-car 3,000-tick
  run also repeats exactly across every published per-car value.
- **Scheduling matches the original.** Over 1,500 ticks each of three cars
  receives exactly 98 callbacks and the countdown holds for 999 ticks — the same
  figures the [race oracle](RACE_ORACLE.md) records for the original harness over
  the same range. Callback cadence is a property of the clock, not the trajectory,
  so this is a real comparison.
- **Rules are wired.** With no validity mask given to lap timing, this driver's
  lap is invalidated at tick 34,198 with the original wall-hit collision bit set.
  A race enables the original corner-cutting time penalty and practice does not.
- **A human entry is driven in the field.** One human among three cars is
  scheduled in the same block as the robots, accelerates on the caller's command,
  and is exempt from the lap-time elimination rule.
- **Results** carry the classification, per-car position, laps, total and best
  times, gap and laps behind the leader, penalty count and accumulated penalty
  time, fuel, damage, state, finished and eliminated flags, and every completed
  lap.

Release suite: 455 tests, 0 failures.

## What this shows about opponents

In the three-car race the first lap takes 147.9 to 159.3 s, while the second lap
takes 87.6 to 87.8 s — essentially the single-car lap time. The field interferes
with itself at the start and then runs cleanly once spread out, because the
drivers are still the single-car policy from [native BT](NATIVE_BT.md) and cannot
see each other. That is the next increment, not a defect in this one.

## Run it

```sh
swift build -c release --product torcs-sim
.build/release/torcs-sim --race race --fixtures Tests/UnitTests/Fixtures \
  --cars 3 --laps 2 --max-ticks 900000 --summary Artifacts/native-race.json
```

`--race race|practice|qualifying` selects the session, `--cars` 1 to 16,
`--human <index>` makes one entry human (a headless run holds its brake, since
nobody is driving it), `--grid quickrace|code` selects the grid preset, and
`--telemetry` streams every physics tick for every car. Always read `completed`
and `reason` in the summary: a maximum-tick bound can end a run early.

## Boundaries

- **No trajectory parity with the original is claimed.** The drivers, physics and
  scheduling are native; the recorded native/reference difference in
  [native BT](NATIVE_BT.md) applies, and a field amplifies it because cars
  interact. What is compared here is scheduling, structure and repeatability.
- **BT drivers have no opponent handling.** They must not be presented as a
  traffic AI until that is ported. The first-lap times above are the evidence.
- The field is one car model and one setup per race in the diagnostic, though the
  runtime accepts a different definition per entry.
- Only one human entry is supported, and the human car has no robot policy.
- `DrivingRuntime` still serves the existing single-car practice and qualifying
  window and is unchanged. The driving window is not yet connected to this
  runtime: opponent selection, live standings and race results in the UI are
  later work.
- Nothing feeds accumulated penalty time into pit service timing yet.
- Qualifying does not feed a race grid, and championships and replay remain
  unimplemented.
