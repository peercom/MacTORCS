# Camera zoom and saved native preferences

All 29 native driving-camera views support the original TORCS 1.3.9 zoom commands.
The camera row provides **Zoom in**, **Zoom out**, and a **Zoom options** menu with
reset, maximum zoom and minimum zoom. Camera selection and each view's zoom are
saved independently for the native viewport. These settings do not change physics.

## Original behavior

`cGrPerspCamera::setZoom` subtracts one for zoom-in when the current value is above
2; otherwise it halves the value. It then applies the camera's minimum. Zoom-out
adds one and applies the maximum. The other commands select the factory minimum,
maximum or default directly. The UI's **Maximum zoom** means the smallest value;
**Minimum zoom** means the largest value.

Most views use the saved value as vertical field of view in degrees. Circuit
center and Trackside zoom preserve their separate `locfovy`: after a command,
`update` computes `degrees(atan2(locfovy, distanceToCar))`. Their near/far planes,
position and targeting continue to follow the original updates. Mirrors retain
their own original projection and do not inherit the main camera's zoom.

The native camera identifiers match original factory lists and IDs, independently
of native picker order. The corresponding `fovy-head-id` keys are retained. The
original default-loader does not clamp saved values to factory limits; usable
out-of-range preferences are likewise retained natively. Nonfinite, nonpositive
or degenerate projection values are rejected. Original zoom commands can have
surprising results after manually entering an out-of-range value; those command
rules are preserved rather than silently normalized.

## Persistence and rendering

Native preferences use versioned JSON at
`~/Library/Application Support/TORCSMac/cameras.json`. Reads are bounded to 64 KiB;
unknown camera keys, unsupported versions and invalid values are rejected.
Writes are atomic, and an invalid save leaves the previous file unchanged.
Load/save errors are shown in the native driving view. A failed save leaves the
current in-memory view usable and reports that persistence failed.

The app loads preferences at session-object creation and writes on explicit
camera/zoom control actions. The render loop receives cached camera and numeric
zoom values; it performs no preference-file access. Zoom is an explicit value
input to the Metal representable so paused views redraw when it changes. The
existing geometry, textures, lighting, shadows, mirror composition and shaders
are reused; no render pass, shader variant or scene resource is added for zoom.

This is one native viewport's preference store. Import/export of original
`graph.xml`, per-driver preferences and multiple original display screens remain
pending. Keyboard zoom shortcuts and mouse-wheel zoom have not been added.

## Reference and validation

Three byte-verified excerpts from the pinned `grcam.cpp` execute original zoom
commands, default loading and all 29 supported factory entries. Parameter reads
and writes are captured in memory, including the original `Display Mode/0` path
and per-camera keys; the oracle does not write user settings. Dynamic camera
updates execute their already-pinned original classes through virtual dispatch.
The native application does not link this reference adapter.

The test sweep checks 38,019 updates across 29 presets and three saved-value cases,
including saturation, the fractional branch, all five commands, reset, changing
car distances and values outside factory limits. FOV values, factory limits and
saved values/keys match exactly. Sampled full camera/projection comparisons use
three aspect ratios. Additional tests cover per-camera persistence, 300 camera
switches, invalid-write preservation, malformed/oversized files, invalid zoom
rejection and a GPU zoom/reset fixture.

The first GPU fixture was entirely clipped by the panorama near plane; its test
correctly failed to observe zoom changes. The authored fixture was moved into the
valid viewing volume. No renderer behavior or comparison tolerance was changed.

Packaged diagnostics add five views at four zoom settings with optional 4× MSAA,
including the driver's rear-view mirror. Reset must restore the exact default
pixels. These are stationary native-physics rendering checks, not a driving lap,
original GL pixel parity or gameplay-performance measurement. The accompanying
`camera-zoom-report.json` records final test and packaged evidence.


## Local preview

Open `build/TORCSZoomPreview.app`, then use **File → Open Driving Session…** to
select `Artifacts/driving-track-shadow-session`. Choose a camera and use the zoom
buttons or **Zoom options**. Each camera keeps its own zoom, including after
relaunch. Optional Smooth edges, Sharper road textures and existing shadows remain
available. The prepared artwork is not bundled or newly licensed for redistribution.

The selected 52-test suite passes in debug, release and Address Sanitizer builds.
The test inventory is now 211; a new complete-suite run is not claimed. The prior
full debug suite passed 207 tests before this zoom increment.

All 120 packaged PNGs match across three fresh processes, including Metal
API/GPU validation with no reported fault. The 100 previous baseline PNGs remain
unchanged. All 20 zoom repeat pairs are exact, and all five resets restore the
default pixels exactly. No new gameplay-performance claim is made.

The native preview successfully loaded the prepared session and displayed the
new controls. A later observation showed the user driving in Trackside view with
both quality options enabled. Further automation stopped to preserve that active
session and its preferences. Interactive zoom/reset and relaunch checks remain
pending; automated persistence and GPU checks pass. See
`Artifacts/zoom-ui-check.json` for the exact UI verification boundary.
