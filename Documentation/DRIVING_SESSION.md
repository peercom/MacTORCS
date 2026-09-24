# Native driving session

The selected 155-DTM can now be driven on Aalborg in a native Metal window.
This integrates the existing reference-tested physics, compiled assets and
immutable vehicle presentation. Configurable practice and solo qualifying now include a two-second countdown,
restart, retirement, lap results and JSON export (see GAMEPLAY.md). Per-tick
telemetry and original lap timing remain available (LAP_TIMING.md). Physical
five-lap/controller acceptance, integrated AI races, audio and replay remain open.

## Prepare and drive

```sh
swift build -c release
Scripts/build-app.sh
python3 Scripts/prepare-driving-session.py /path/to/torcs-1.3.9 Artifacts/driving-session
open build/TORCSMac.app
```

Choose **File → Open Driving Session…** (⇧⌘O) and select `Artifacts/driving-session`.
Use **New Session…** to select practice/solo qualifying and a lap count.
Click **Start**; the Metal view receives keyboard focus. Arrow keys or WASD control
acceleration, braking and steering; Space also brakes. E shifts up, Q shifts down,
C operates the clutch and P pauses/resumes. First gear is initially requested;
gear requests clamp to the loaded car’s range, including neutral and reverse.
These are native digital bindings, not a port of the legacy human robot’s input
curves. Controls… provides configurable keyboard bindings and GameController
calibration; see INPUT.md. Hardware driving validation and wheel/HID support remain pending.

Opening another window or switching away pauses and releases held input. Returning
does not resume automatically. Closing the driving window stops its timer. Opening
a new session stops and clears the current session; the new car becomes available
after loading. A failed load displays its error. The app opens directly into driving; the component lab is available under
Simulation → Open Component Lab, and the separate model inspector remains available.

The preparation script compiles body, four wheel speed resources and track, copies
five selected XML inputs and retained artwork notices, and publishes a new folder.
Existing destinations are rejected. Five shared track textures come only from the
explicit local upstream directory; their per-file redistribution attribution is
still unresolved, so this generated package must remain local. This script is not
the planned user content importer. No source artwork is newly bundled in the app.

## Simulation and presentation ownership

A Swift actor owns `DrivingRuntime` and the mutable single-car simulator. The main
actor collects input and requests batches through an independent 120 Hz timer.
Only one batch is outstanding at a time. Elapsed time since the last request is
accumulated; it is never derived from draw calls. Every physics step remains
0.002 seconds. A batch cap of 125 ticks retains backlog. A wall-clock gap of at
least one second is an explicit suspension, avoiding catch-up after sleep.

The prepared car starts 10 m before the line. Use **Record Telemetry…** to capture
every tick and **Finish Recording** to save. The timing strip shows current/last/best
laps and invalidation. Completing the configured lap count opens results;
**End Session** also preserves completed laps with an ended-early status.
**Results…** exports JSON and **Drive Again** resets the settled car. The previous
result stays available after restarting. Audio/replay and an AI race grid are
not supplied by these solo modes.

The worker returns immutable previous/current `VehicleVisualSnapshot` values plus
interpolation, tick-derived time, speed, RPM, gear, fuel, damage and track segment.
The renderer can only read these frames. It shares GPU resources, interpolates
body/wheel transforms and draws the track. Parsing, cache reads, simulation settling,
shader creation and texture upload happen before driving. Drawing does not parse
content, read files or advance physics. The runtime must be discarded after a
physics error; the application stops and presents the error.

The current SwiftUI status strip updates from frames. There is no claim yet of
allocation-free draw preparation, stable 60/120 FPS or long-session memory behavior.
Paused views render only when invalidated, so an idle paused track does not
continuously submit its full draw list. A process sample also identified array/
resource retention while sorting copied draw records; optimization of that path
remains open. The paused-rendering fix is not a frame-rate benchmark.
An Instruments pass remains necessary for performance claims. Signposts mark
simulation batches and draw preparation.

## Original chase camera

The implemented camera follows the original `cGrCarCamBehind` F2 “very near”
configuration: 6 m distance, 2 m above track height, 40° vertical field of view,
1 m near plane and 600 m far plane. Its center follows the original forward-offset
rule. Original `RELAXATION` uses a constant 0.01 per graphics update, independent of
elapsed time; that cadence-dependent behavior is preserved rather than silently
replaced with a time-based filter. Yaw wrap correction also follows the source.

The original complete camera class is pinned, byte-verified and compiled behind
a capture adapter. Its height query receives a supplied value, so the 1,000-update
comparison isolates camera arithmetic. Native track-height queries have separate
original-code tests. The driving view queries the immutable loaded track geometry
near the published car segment. The camera consumes interpolated position and shortest-arc published yaw;
projecting the pitched forward vector would incorrectly flip yaw past 90° pitch.
This does not change physics or assert original snapshot-interpolation parity.
Fog, sky, mirrors and other camera modes are not included in this increment.

## Verification

Four new tests check:

- Four render/request cadences (60/120/144/240 Hz), 2,000 physics ticks each,
  comparing the final 142 telemetry fields exactly with direct fixed-step simulation.
- A 600-second pause with retained catch-up backlog, and invalid time inputs.
- A complete prepared package, 501 settling ticks, and four rejected package forms.
- 1,000 original chase-camera updates / 6,000 output values, including yaw wrap.

The prepared-package test uses one model resource in all six roles to isolate
loading/validation. The actual native-window check uses the real body, four wheel
speed files and Aalborg geometry. That UI check covers opening the package,
starting, keyboard acceleration, a gear request, pausing and focus-loss suspension.
An accessibility-triggered modal chooser problem found during testing was corrected
by using asynchronous native sheets attached to the owning window. Menu commands
open the destination window after selection; cancellation retains the parent. See `driving-session-report.json` for measured
results and source hashes. This evidence does not prove five completed timed laps,
controller hardware behavior or complete race parity.

New sessions include a `lightTextures` dictionary mapping the selected car's
configured light texture names to single-level caches. The 155-DTM uses two
brake2 lights sharing `breaklight2.rgb`; the compiler records its original local
path and hash separately. This shared image remains local-only pending precise
artwork attribution. Legacy version-1 sessions without the optional dictionary
remain loadable and omit light quads; prepare a new folder to enable them. See
CAR_LIGHTS.md for native captures and remaining renderer scope.
