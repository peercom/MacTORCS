# Trackside cameras

The native camera picker includes **Trackside** and **Trackside zoom**, matching
TORCS 1.3.9's F8 and F9 defaults. The picker now has 29 views. These use the
camera assigned to the vehicle's current simulation segment; they do not change
simulation state. Physical controller validation remains deferred behind visual work.

## Track definitions and selection

The version-4 loader reads each `Cameras` entry's segment, lateral distance,
longitudinal distance and height. As in `track4.cpp`, it uses the first generated
subsegment of a named XML segment, evaluates local-to-global position and ground
height before coordinate normalization, then subtracts the track minimum.
`to start` is metres on straights and radians on curves. Surface roughness,
banking and side heights use the existing native track queries.

`fov start` is inclusive and `fov end` exclusive. Ranges wrap around the lap;
equal endpoints assign a complete lap. Later XML entries override earlier
assignments. Only main segments receive cameras. Unassigned segments use the
original world-center fallback. Missing or unknown segment names produce a
native loading error instead of the original fatal/implicit-zero behavior.
An absent or empty camera section is supported natively; the original reference
fixture omits empty sections because its loader enters a fatal path for one.

## Camera behavior

The fixed view uses 30° vertical FOV, near/far 1/1000 and fog 500/1000. With a
track-defined camera, the target has the camera's height, keeping the view level.
The fallback looks at the car's height from `(0.5 × worldX, 0.6 × worldY, 120)`.

The zoomed view always targets the car's position. Its vertical FOV is
`degrees(atan2(9, distance))`, near is `max(1, carZ − cameraZ − 5)`, far is
`distance + 1000`, and fog remains 500/1000. The original perspective
`limitFov()` is empty, so the factory's nominal min/max do not clamp the update.
Both views draw the car, driver, sky and existing shadows, and disable the mirror.

Defaults use the original `fovFactor = 1`. User zoom, saved per-screen camera
preferences, F10 fly camera and automatic TV camera selection remain pending.

## Verification

Reference tests execute three byte-verified excerpts of the pinned original
`grcam.cpp`: fixed class, zoom class and F8/F9 factory. The original full track
loader supplies camera positions and assignments through a read-only adapter.
The native application has no dependency on either reference adapter.

Tests cover 2,400 camera updates, including 800 fallback cases and close/distant
approaches, with projection checks at three aspect ratios. Aalborg's ten cameras
are compared across all 1,123 geometry segments. Authored fixtures cover profiles,
negative elevations, banking, side heights, absent cameras, unassigned ranges,
wrapping, overlaps, full-lap ranges and invalid references. All tested camera positions and assignments match exactly in debug, release
and Address Sanitizer builds. The full debug suite passes 207 tests; release and
Address Sanitizer runs each pass 48 selected track/graphics tests. GPU images
verify native rendering stability, not original GL pixels.

The renderer/shaders and optional 4× edge smoothing are unchanged. Camera lookup
uses a precomputed segment-index array; no additional scene pass or texture is
introduced by these two views. Camera metadata is built during track loading.
Full race performance and long-running memory behavior remain unmeasured.


## Local preview

Launch `build/TORCSTracksidePreview.app`, use **File → Open Driving Session…**
and select `Artifacts/driving-track-shadow-session`. Choose **Trackside** or
**Trackside zoom** in the **Trackside views** section of the camera picker.
**Smooth edges** remains optional and off by default. These entries reproduce
F8/F9 views; function-key bindings themselves have not been added.

The diagnostic `--driving-visual-test` also saves both views for every assigned
Aalborg camera with 4× smoothing, using ten independently settled native vehicles
(501 settling ticks each). It does not simulate or claim a complete lap.
Prepared artwork stays outside the app bundle and retains its existing local-only
licensing restrictions. See [the machine-readable report](trackside-camera-report.json)
for source hashes, test logs and image-repeat evidence.


Three fresh packaged diagnostic runs (two normal, one with Metal API/GPU
validation) each save 100 PNGs with identical file hashes. All 58 ordinary camera
repeat pairs and 20 trackside placement pairs are exact; all 76 prior smoothing
baseline PNGs remain unchanged. Metal validation reports no faults. The packaged
smoke-test checksum remains 1103027. These checks exercise the actual signed app
binary offscreen, including the new camera-selection inputs.

At this increment, the final interactive picker check was pending: the native UI tool reported a
locked Mac and failed automatic unlocking. No successful interactive check of
the two new picker entries is claimed. After unlocking, verify paused switching,
Smooth edges and disabled mirrors in both new views.

Subsequently, the newer `build/TORCSZoomPreview.app` successfully loaded the same
prepared session. The user was observed driving in Trackside with Smooth edges
enabled and the mirror control disabled. Automation left that session intact;
paused switching and the Trackside zoom picker check remain pending. This does
not change the historical trackside report's binary or UI evidence.
