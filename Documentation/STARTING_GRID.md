# Native starting grid and heterogeneous fields

The native code now places a field exactly where TORCS does, and
`MultiVehicleSimulation` accepts one car definition per car instead of one
definition for the whole field. This is the first gameplay increment compared
against the [race oracle](RACE_ORACLE.md).

## Original placement, ported

`StartingGrid` in `TORCSTrack` is a semantic port of `initStartingGrid`:

- The pole side defaults to the inside of the first turn, found by walking the
  main segments from the first until one is not straight. A track with no turn
  has no original answer and is rejected rather than guessed.
- `a`/`b` are selected from the pole side and the **Main Track** width, so
  `toRight = a + b·((i%rows)+1)/(rows+1)`.
- `startpos = length − (toStart + (i/rows)·columnDistance + (i%rows)·columnOffset)`,
  evaluated in the original's order and float precision.
- The segment is found by walking **back** from the last main segment while
  `startpos` is below its distance from start, as the original does.
- `toStart` is the remaining length, divided by the radius on a turn; yaw is the
  segment's start heading, minus `toStart` on a right turn and plus it on a left
  turn, then normalized by the original `NORM0_2PI` — including its strict upper
  comparison in double against a float period.
- Height is the original local track height plus the configured initial height.

`StartingGridConfiguration` reads the original attribute names from
`<race name>/Starting Grid` and then lets the track's own top-level `Starting
Grid` section override them — except `initial speed`, which the original does not
let a track change. A track section naming only some values keeps the rest, and
only an explicit `left` selects the left side, matching the original string
comparison. The shipped `quickrace.xml` values and raceinit.cpp's own code
defaults are both covered.

Where the original is undefined, the native port reports instead of guessing: a
grid longer than the track would walk off the front of the segment list, so it is
rejected with a diagnostic. `rows` below one is clamped to one, which is what the
original does after reading the value.

## Measured against the original

A placement-only oracle (`ref_world_grid_create`) runs the original routine with
no driver loaded, so a field can be compared beyond BT's ten driver indices.

**Placement is bit-exact.** Across 15 configurations — 1, 2, 3, 5, 8 and 16 cars
on the shipped grid, 5 and 16 on the code defaults, 1 to 4 rows, both pole sides
and the default, and a grid deep enough to be walked back across several
segments — all 770 compared values (segment index, position mode, `toStart`,
`toRight`, world x/y/z, yaw and initial speed) match with a maximum absolute
difference of **0.0**.

**A grid-placed field steps identically.** Four cars placed on the shipped grid,
settled and driven for 1,200 ticks, match the same field in original simuv2
across all 142 published fields per car: 681,600 values, maximum absolute
difference **0.0**.

**Grid contacts match too.** The grid puts cars side by side in rows, which is a
different contact geometry from the single-file centreline cases already covered
by `MultiVehicleTests`. Holding the front row while the row behind accelerates
into it produces 218 ticks with detected car pairs over 1,500 ticks, and all
852,000 compared values still match exactly.

## Heterogeneous fields

`MultiVehicleSimulation(definitions:road:grid:)` takes one
`VehicleDynamicsDefinition` per car and builds each car's collision box from its
own dimensions, so a mixed field collides correctly. The existing
`init(definition:road:carCount:…)` centreline initializer is unchanged and now
delegates to the same private initializer, so every existing physics and
collision comparison keeps its previous behaviour.

The reference harness reads one car XML per world, so a mixed field has no
original counterpart. It is checked natively instead: three variants with
different mass, length and width are placed on their grid slots, keep their own
definitions, and reproduce 255,600 field values exactly across two independent
600-tick runs, with the three cars remaining on distinct trajectories.

## Boundaries

- A nonzero grid **initial speed** is rejected by the simulation. The original
  writes the public longitudinal speed before configuring the car; no shipped
  race configuration uses a rolling start, and guessing the body/world split
  would be a silent physics error. Placement itself carries and matches the
  value, so only the simulation entry point is restricted.
- Heterogeneous fields are verified natively only, for the reason above.
- The field cap remains 16 cars, as in `MultiVehicleSimulation` and `RaceOrder`.
  The original grid itself accepts more; `StartingGrid.slots` allows up to 64 so
  the cap lives in one place.
- Aalborg / 155-DTM pinned fixtures. Other tracks are not covered, and the pole
  side in particular depends on each track's first turn.
- This increment places and steps a field. Race progression, pit assignment,
  penalties and driver selection are later increments.
