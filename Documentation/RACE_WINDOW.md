# Racing in the driving window

The window ran one car. It now runs a race: the authoritative race runtime is
behind it, every car is drawn, and the classification is on screen.

## One frame for both sessions

`DrivingFrame` gained a field, a viewer and a classification, with defaults that
leave the single-car path untouched:

- `field: [DrivingFrameCar]` — each car's two published snapshots, which
  presentation interpolates between, plus what the race knows about it. A
  practice session publishes one entry, so presentation has a single path.
- `viewer` — which entry the cameras follow and the readouts describe. It is the
  human entry when there is one.
- `standings: [RaceStanding]` — position, laps, gap behind the leader, laps
  behind, penalties, accumulated penalty time, best lap, and whether a car is in
  its pit, finished or eliminated.

`RaceRuntime` now publishes that frame. It keeps the previous and current
snapshot per car, and gained `advance(elapsed:humanCommand:paused:)` so the
window drives it by wall-clock time exactly as it drives the practice runtime:
the fixed step owns the simulation, a pause consumes none of it, and a work cap
keeps a late frame from stalling the window. Its presentation step clock is
separate from the original race clock, which still starts at −2.

The session worker holds either runtime and publishes the same frame from both.

## On screen

- **New Session…** offers Race alongside Practice and Qualifying, with a car
  count from 1 to 16. The human starts on pole; the rest of the grid is the
  original BT policy with its opponent handling.
- The status strip shows the session kind and the viewer's position out of the
  field, and flags accumulated penalty time and penalties still to serve.
- A standings board lists every car: position, who it is, lap, gap, best lap,
  and whether it is in its pit, carrying a penalty, out, or finished. The
  viewer's own row is bold. Gaps are the original crossing-time differences, so
  they change as cars complete laps rather than continuously.
- The draw loop submits the whole field. Only the viewer's car answers to the
  view's own exclusions, so a cockpit view hides the driver's own bodywork while
  every other car stays visible, including in the mirror.
- The television director now chooses between the real cars in race order.

## Measured

`--modern-race-test <session> <output> [cars]` runs the window's own data path
headlessly: a race runtime advances, publishes a frame, and the frame's field is
turned into render instances by exactly the code the driving view uses, then
captured.

Four cars, four seconds of race time: the frame carried four cars, the viewer was
the human entry, 68 render instances were produced (17 per car), and the
classification had already changed — the car that started second was leading. The
capture was inspected: the human's car in the chase view with one opponent
alongside and two further up the road, each with its own shadow.

Release suite: 458 tests, 0 failures. A unit test covers the published frame
directly: the field count, the viewer, the classification being a permutation of
the field, the readouts describing the viewer's car, distinct per-car snapshots,
and a pause consuming no simulation time.

## Boundaries

- **The on-screen layout has not been seen.** The window cannot be driven
  headlessly, so the HUD and setup sheet are verified by compiling and by the
  frame they consume, not by a screenshot. The data path behind them is captured
  and inspected; the SwiftUI presentation of it is not.
- **No per-car livery.** Every car wears the same one, as recorded in
  [field rendering](FIELD_RENDERING.md).
- **Telemetry capture stays practice and qualifying only**, and the button is
  disabled in a race. The race telemetry stream is the headless diagnostic in
  [race runtime](RACE_RUNTIME.md).
- Results for a race are published per car by `RaceResult`; the window's Results
  sheet still shows the viewer's own session result. A full race classification
  sheet, qualifying feeding a race grid, and championships remain to do.
- Particle and skid effects are emitted for the viewer's car only.
