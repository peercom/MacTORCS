# Rendering a field

The driving renderer drew one car. It now draws a whole field, which is the
prerequisite for putting a race on screen.

## What changed

`ModernDrivingRenderer.FieldCar` is one car to draw this frame: its pose, its
published brake and light commands, and whether it draws, draws its driver and
casts a shadow. Every car shares the session's meshes, so a field differs only by
pose and light state.

- `vehicleInstances(field:)` builds the instances for a whole field — one body,
  then each wheel's three brake parts and the wheel at its own detail level, so
  **17 instances per car**. The single-car form is kept and delegates to it, so
  every existing caller is unchanged.
- `draw(in:field:camera:viewer:…)` submits a field. The old single-pose `draw`
  delegates to it. The viewer is explicit rather than assumed, because the
  viewer's car is the one a cockpit view hides and excludes from shadow casting.
- `mirrorCarInstances(field:viewer:viewerDrawsCar:…)` decides what a mirror
  carries: **every other car whole**, and the viewer's own bodywork only when the
  main view hides it. `mirrorRequest` uses it, so the shipped path and the
  diagnostic check the same code.

## Measured

`--modern-traffic-test <session> <output> [cars]` renders a field offscreen from
the prepared session, placing the cars on the original grid slots the session
already paints — the same `StartingGrid` slots the native grid port produces.

Chasing the car on the **last** grid slot, so the field is ahead of it:

| | One car | Three cars |
|---|---|---|
| Draw calls | 146 | 246 |
| Triangles | 277,247 | 497,247 |

244,739 channels differ between the two images — **5.75%** of the frame — and the
field render repeats byte-identically within the process. Instance accounting is
exact: 51 instances for three cars, and a mirror carries 34 for the two
opponents.

The capture was inspected: three cars stand on their painted slots under the
start gantry, each with its own shadow.

## A measurement that would have lied

Chasing the **pole** car instead puts the rest of the field behind the camera,
where the cars are culled from the view but still render into the shadow
cascades. That capture differed by 0.77% of the frame with no opponent visible
anywhere in it. The diagnostic therefore requires at least one per cent of the
frame to change, which separates opponents in view from opponents merely
shadowing the road.

## Boundaries

- **No per-car visual identity.** `RenderInstance` carries no colour or material
  override, and the session ships one car model, so every car appears in the same
  livery. Telling them apart needs either per-car resources or a per-instance
  tint in the shaders; neither is done here.
- Particle and skid sources are supplied by the caller, so a field emits only for
  the cars the caller asks for. The diagnostic asks for none.
- The cross-process image comparison is not bit-stable for this renderer: the
  field-versus-one-car channel count moved by two between runs. The repeat check
  is within a single process, as the renderer's other diagnostics are.
- This is the renderer half. The driving window still runs the single-car session
  runtime; putting `RaceRuntime` behind the window, with standings, gaps and
  penalties in the HUD, is the next step.
