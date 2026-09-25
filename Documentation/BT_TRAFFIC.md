# Native BT opponent handling

The native BT driver now sees the rest of the field. `BTSoloDriver` is renamed
`BTDriver`, because the restriction the old name recorded is gone.

## What is ported

`BTOpponents.swift` is a semantic port of `cardata.cpp` and `opponent.cpp`:

- **`BTCarData`** (SingleCardata): a car's track angle, its speed projected onto
  the track direction, its angle relative to the track tangent, and the width it
  needs on the track. Computed for every car, the driver's own included.
- **`BTOpponent`** (Opponent): one opponent relative to the driver — the wrapped
  along-track distance, the original `OPP_*` classification (front, back, side,
  front-fast, collision risk, let-pass), the catch distance, the lateral distance
  and the overlap timer. Inside 12 m the distance is remeasured from the driver's
  front edge to the nearest corner of the opponent, as the original does. A car
  out of the simulation is ignored without touching its overlap timer, and a car
  stopped in its pit still counts as an obstacle.

`BTTraffic.swift` is a semantic port of the opponent-aware paths in `driver.cpp`:

- **`updateOpponents`** and **isAlone**.
- **`trafficOffset`** (getOffset): let a lapping car or a less damaged team mate
  through; otherwise pick the nearest car to overtake by catch distance and move
  the offset to its free side, or — when it sits near the middle — toward the
  inside of the turn the track is about to make, found by accumulating left and
  right lengths up to the catch distance. With nobody to pass, the offset decays
  back to zero.
- **`filterOverlap`**: halve the accelerator while being lapped.
- **`filterBrakeCollision`** (filterBColl): full brake when the braking distance
  to a collision-risk opponent exceeds the gap.
- **`filterSteerCollision`** (filterSColl): steer parallel to the nearest car
  alongside, blended by how close it is, with the original's asymmetry between
  the car nearer the middle and the car outside a turn.

The filters are applied in the original nesting order, and `BTLearning` gained
the original `alone` gate: a car in traffic does not learn a cornering radius,
because its line is not its own choice. The driven car's four published corner
positions are now published by the simulation, as the original publishes
`pub.corner`.

## Measured against the original

The reference harness now captures the **whole field** at every drive callback —
each car's position, world pose and velocity, corners, dimensions, distance from
the line, laps, damage and state — which is exactly what the original opponent
model reads. Feeding that capture to the native drivers and comparing their raw
output against the original's:

**Three cars over 20,000 ticks, 1,848 callbacks each: 22,176 control values, all
22,176 exact, maximum absolute difference 0.0.** Gears match at every callback.

The run is not vacuous: opponents were classified on 4,914 callbacks and the
overtaking offset was non-zero on 1,969 of them.

The solo baselines are unchanged, which is what shows the restructuring is inert
for a one-car field: the captured-input comparison still matches all 21,055
controls exactly, the independent native lap still finishes at tick 44,612 in
87.22399999997812 s, and the forced-pit five-lap run still takes 240,464 ticks
with two services.

Release suite: 457 tests, 0 failures.

## Effect on a race

The same three-car, two-lap race as the [race runtime](RACE_RUNTIME.md) increment,
before and after:

| | Without opponent handling | With it |
|---|---|---|
| First lap | 147.9 / 157.6 / 159.3 s | **88.1 / 91.0 / 99.1 s** |
| Second lap | 87.6 / 87.7 / 87.8 s | 82.1 / 82.5 / 83.0 s |
| Total ticks | 124,468 | **91,797** |
| Gaps | 0 / 9.604 / 11.310 s | 0 / 3.776 / 11.372 s |

The field no longer destroys itself at the start, and second-lap times improve
because the drivers now use the width of the track. Damage of 262, 761 and 47
shows they still make contact: this is racing, not a procession. The race repeats
byte-identically.

## Boundaries

- **Team behaviour is reachable but not exercised.** The original reads a team
  mate's name from the driver setup XML; these entries name none, so every car is
  classified as a non-team-mate. The team-order branch of the offset logic is
  ported but untested.
- Control parity is measured on **captured original inputs**. Native physics still
  diverges from the original over a full race, as recorded in
  [native BT](NATIVE_BT.md), so a native race is not a replay of an original one.
- The comparison covers three cars on Aalborg for 20,000 ticks. Larger fields,
  other tracks, pit traffic and lapping situations are not separately measured;
  the let-pass path in particular needs a car a lap down, which does not occur in
  a two-lap race.
- The original's `filterSColl` computes its blending distance from the **last**
  side opponent it iterated while acting on the **nearest** one. With more than
  one car alongside, that upstream quirk and this port may differ; with one car
  alongside they agree, which is all the measured run contains.
- Opponent order must stay stable for the life of a driver, because the overlap
  timer is per-opponent state. The runtime supplies the other cars in ascending
  index order, which is the order the original's array has.
