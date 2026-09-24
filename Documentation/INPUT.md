# Native driving input

`TORCSInput` collects keyboard actions and GameController extended-gamepad state
outside the simulation. Only `DriverCommand` values cross into the fixed 2 ms
physics runtime. The selected pad stays selected until disconnected. A connection
change pauses driving; focus loss and pause clear held controls. Returning does
not resume automatically. Controller activation requires all assigned controls to
return to their calibrated neutral positions, independently of curve gain or speed.

## Configure

Open **Controls…** in the driving window or **Settings → Driving Controls…**.
Keyboard actions accept a new physical key; Clear removes that action's keys.
Restore Defaults changes the draft; Save validates and atomically writes
`~/Library/Application Support/TORCSMac/input.json`. Cancel discards the draft.
Duplicate key/controller assignments, unsupported versions, nonfinite calibration
and oversized settings files produce diagnostics. Command, Control and Option
shortcuts remain available to macOS. Escape cancels key capture. Physical key codes
stay within the input/application layer. Saved labels describe the layout at capture.

| Action | Default keyboard | Default gamepad |
|---|---|---|
| Accelerate | Up / W | Right trigger |
| Brake | Down / S / Space | Left trigger |
| Steering | Left / A, Right / D | Left stick horizontal |
| Clutch | C | South face button (A / Cross) |
| Shift up / down | E / Q | Right / left shoulder |
| Pause / resume | P | Menu |

Each controller axis has inversion, dead zone, sensitivity (gain) and linearity
(exponent). Steering also has speed sensitivity. Higher exponents soften the center.
The steering dead zone follows original TORCS arithmetic: its offset reduces the
maximum output unless gain compensates. Pedal dead zones renormalize the remaining
range. Simulation control checking applies output saturation. Inverted pedals
require the opposite physical endpoint for neutral. Native keyboard steering retains
the existing immediate digital behavior; it is not the original human robot's ramp.

## Reference boundary

Pinned `src/drivers/human/human.cpp` and `pref.h` retain their original notices.
Three byte-verified excerpts execute the original left/right joystick steering and
throttle-axis branches in the test-only C++ oracle. The native pedal function is
shared by throttle, brake and clutch. Clamping, Float intermediates, Float `pow`
overloads and the final Double steering denominator preserve original arithmetic.
The original `pub.speed` magnitude, published by physics, feeds speed sensitivity.
The full human driver is not linked into the app. This is not parity for its ABS,
ASR, automatic gears/clutch, keyboard ramp, preference import or robot update cadence.
Input is sampled per main-actor batch using the last published speed; complete
original human-driver scheduling remains pending.

The adapter freezes analog values with `GCController.capture()` and uses the SDK's
`isPressed` state. Main-queue button callbacks preserve short gear/menu presses
between polls. Polling and framework objects never enter the physics worker.
Paused polling does not publish unchanged observable state or invalidate rendering.
Only extended-gamepad profiles are accepted. Xbox, PlayStation and generic devices
exposed through that profile use the same mapping; physical hardware is not yet
verified. Wheel/HID, direct gears, look actions and additional cameras remain open.

## Evidence

Six input tests cover 13,032 exact original axis comparisons, keyboard aliases and
edge/repeat handling, focus/neutral gating, configuration validation and atomic
persistence, Apple writable snapshot profiles and short button callbacks, and
1,000 physics ticks at each of 60/120/144/240 Hz request cadences. The cadence test
compares final position, orientation and RPM with direct native stepping; it is
not an additional upstream whole-vehicle comparison. Snapshot devices exercise the
real framework API but are not physical controller tests. The host reported zero
connected physical controllers during testing. See `input-report.json` for the
verification results and source hashes. Complete laps using a standard controller
remain an explicit unfinished milestone.

The separate packaged-app UI check captured a new key, rejected a duplicate,
scrolled controller calibration and cancelled without saving the test draft.
The prepared driving window accepted E to shift and P to pause. Normal quit while
recording published 2,056 contiguous telemetry records, each with 161 fields.
The existing app bundle was preserved. An initial startup-only Metal diagnostic
hung after requesting deferred AppKit termination during view creation; the
diagnostic now runs synchronously before creating windows and exits directly.
