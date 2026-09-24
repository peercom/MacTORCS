# Multi-car race reference oracle

The reference harness now runs a **field** of original BT drivers through the
original race loop: `initStartingGrid`, `ReOneStep`, `ReManage`, `ReRaceRules`
and `ReSortCars`. This is the executable baseline every later gameplay increment
compares against. It is a capture harness, not a game: no native gameplay code
depends on it, and it stays confined to tools and tests.

It replaces nothing. The pinned single-car BT path is unchanged and still
finishes its reference lap at tick 44,694 / 87.38799999997774 s with 4,211 drive
callbacks, as recorded in [ROBOT_API.md](ROBOT_API.md).

## Original starting grid

`initStartingGrid` is now compiled verbatim as
`Upstream/Reference/race/starting-grid.inc`, extracted byte-exactly from the
pinned `raceinit.cpp` in the same way as the existing `initPits` excerpt.
`Scripts/verify-provenance.py` asserts the extraction on every run.

The oracle writes the original race-manager attribute names, so the routine reads
an ordinary race handle: `rows`, `distance to start`, `distance between
columns`, `offset within a column`, `initial speed`, `initial height` and the
optional `pole position side`. A track XML `Starting Grid` section still
overrides them inside the original routine, exactly as upstream. Two presets are
provided: `codeDefaults` (raceinit.cpp's own fallbacks — 2 rows, 10, 10, 5, 0,
0.3) and `quickRace` (the values shipped in `quickrace.xml` — 2 rows, 25, 20,
10, 0, 0.2).

Placement is captured immediately after the routine, before any physics step:
per-car main-track position, world position, height, yaw and initial speed.

`ref_world_grid_create` builds a **placement-only** grid world: the original
routine runs with no driver loaded, so a native field can be compared for up to
16 cars rather than BT's ten driver indices, and the world can then be driven
with scripted commands like any other reference world. The native comparison
built on it is recorded in [starting grid](STARTING_GRID.md).

Verified against independently recomputed upstream arithmetic

    startpos = length − (toStart + (i/rows)·columnDistance + (i%rows)·columnOffset)
    toRight  = a + b·((i%rows)+1)/(rows+1)

for five configurations: 3 and 5 cars at 2 rows, 4 cars in a single row, and 6
cars at 3 rows with the pole forced to each side. On Aalborg the first turn is a
right-hander, so the original default pole side is right; the measured track
width is 10 m and the 2-row slots fall at 1/3 and 2/3 of it. Lateral slots match
within 1e-4, and recovered along-track distances within 2e-2 m.

## Field race loop

`ref_world_bt_field_create` builds 1–10 cars (BT provides ten driver indices),
each with its own `tRobotItf`, `rbNewTrack`, `rbNewRace`, callback state,
captured 142-field physics input, observation and pit decision. `btDrive` and
`btPit` key every capture on the car index, so nothing is shared between
drivers. Every driver index receives the same pinned BT-0 setup: real
installations ship per-index setups, but this is a fixed oracle fixture, so the
field differs only by grid slot and driver index.

`ref_world_race_step` performs one original `ReOneStep` for the whole field —
countdown, clock, prestart resynchronization, robot callbacks for every
non-removed car, one physics update, per-car `ReManage`, then `ReSortCars`.

Measured over 1,500 ticks with three cars:

- The original scheduler calls all three drivers in the same block; each
  received exactly 98 callbacks.
- `RM_RACE_PRESTART` (0x10) holds for the first 1,000 ticks and resynchronizes to
  `RM_RACE_RUNNING` (0x1), matching the single-car clock behaviour.
- Two independent runs produced identical captured callbacks for every car and
  identical final physics for all three cars.
- Cars placed on different grid slots produce distinct trajectories, so the
  field is genuinely multi-car rather than three copies of one car.

## Rules, penalties and classification

`ref_world_race_car_state` publishes what `ReManage`/`ReRaceRules` produced for
each car: classification position, gaps behind the leader and neighbours, laps
behind, the `RM_PNST_*` rule state, the penalty list length, the first penalty
and its lap-to-clear, accumulated penalty time, service count, elimination and
callback counts. The original penalty list is a malloc'd tail queue, so world
destruction now releases it exactly as `ReRaceCleanDrivers` does.

`ref_world_race_configure` sets the original rule inputs that `ReRaceRules` gates
on: the `RmRaceRules` bitmask (1 corner-cut invalidation, 2 wall-hit
invalidation, 4 race corner-cut time penalty), the situation race type, and the
per-car skill level and driver type. Penalties and the lap-time DNF rule require
skill 3 and a robot driver; the existing authored-timing oracle deliberately
uses skill 0 and a human driver to isolate timing from penalties, and is
unchanged.

`ref_world_race_classification` returns stable car indices in the current
original race order. Verified at five sample points over 2,500 ticks: the order
is always a permutation of the car indices, is non-increasing in distance raced,
and each car's published position matches its slot.

## Run it

```sh
swift build -c release --product torcs-reference
.build/release/torcs-reference --robot bt --fixtures Tests/UnitTests/Fixtures \
  --cars 3 --grid quickrace --laps 3 --max-ticks 900000 \
  --summary Artifacts/race-oracle-field.json --commands Artifacts/race-oracle-field.jsonl
```

`--cars` selects 1–10 drivers, `--grid code|quickrace` the grid preset and
`--pole left|right` an explicit override. A field implies `--grid quickrace`
when none is given; a single car without `--grid` keeps the pinned centreline
diagnostic start so existing recorded values stay comparable. `--commands`
streams one record per car per callback, each tagged with `car.index`.
`--telemetry` streams all physics ticks for every car. Always read `completed`
in the summary: a maximum-tick bound can produce a partial run.

The schema-2 summary reports the grid configuration, per-car grid slot,
classification, per-car laps, gaps, rules, penalties and callback counts,
alongside the retained single-car fields.

## Boundaries

- The oracle is Aalborg / 155-DTM / BT with pinned fixtures. It is not a general
  race-manager, content importer or robot module loader.
- This increment pins the oracle's own behaviour and repeatability and compares
  no native code itself. Native grid placement is now compared against it in
  [starting grid](STARTING_GRID.md); the race runtime, penalties and traffic AI
  follow in later increments.
- The recorded C++ debug/release trajectory sensitivity in
  [ROBOT_API.md](ROBOT_API.md) is unresolved and applies to field runs too. Do
  not compare captures taken from different build configurations.
- All cars share one car model and one setup, so the field measures grid,
  scheduling, rules and sorting — not heterogeneous-car behaviour.
