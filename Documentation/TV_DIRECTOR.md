# Original TV director and presentation collision tracking

The native `TVDirector` and `TVCamera` implement original F11 selection and
selected-car roadside projection. **TV director** is the 31st driving camera,
with independent saved zoom (`fovy-9-0`, default/min/max 9/1/90). The prepared
GUI session contains one human car. Actual native three-car motion is separately
compared against the original director; full standings and multi-car GUI racing
remain pending.

## Selection rules retained

Inputs contain dense car IDs, cars in current race order, current simulation time,
track length and global width, and the other active screens' selected car IDs.
The initial car is found by identity, falling back to race slot zero. After that,
the director stores a race-order slot, not a stable car ID. Reordered standings can
therefore change the followed identity without a director-triggered slot change.
This original behavior is intentionally retained.

Event rescoring occurs only when elapsed event time is strictly greater than the
configured interval. Within that gate, either an event or expired view interval
permits selection. Rescoring without a slot change does not refresh either clock.
Equal timestamps are not universally suppressed: negative finite interval
settings can cause original rescoring even at the same time.

Priorities include race order; the final 200 meters with exactly zero remaining
laps; leaving the global track width; an off-track pit request; pairwise proximity;
and nonzero published collision flags. Proximity uses unwrapped absolute distance
from the start, without lateral-distance filtering. Ordered pairs receive the
original asymmetric bonuses, and only a close pair involving the leader raises a
proximity event. Cars whose low state byte matches `RM_CAR_STATE_NO_SIMU` are not
viewable. Other active screens exclude their cars and apply a 10,000-point penalty
per screen, including repeated penalties when multiple screens show the same car.
Ties retain the first car ID. If every car is unviewable, original selection still
falls back to ID zero. No alternative policy is substituted.

The original default settings are 10 seconds for view change, 1 second for events,
and 10 meters for proximity. Native settings are Float values, matching the
original parameter return type before the interval fields become Double. Finite
negative settings retain original behavior; zero/negative proximity disables
pair bonuses without division by zero. Native validation rejects nonfinite input,
invalid/non-dense IDs and more than three other active screens. The prepared
camera count is fixed, bounded to 1–1024; changing a race's car count requires a
new director. Reference sweeps cover up to 32 cars, not the entire supported bound.

## Camera projection

`TVCamera` chooses the selected subject's own position and roadside-camera metadata
and then applies the original road-zoom projection. Missing track cameras use the
original integer-world fallback. Default FOV scale is 9; this scale is converted
to an angle using camera-to-car distance. Near/far clipping, world-up and fog retain
the original behavior. Projection tests include independent roadside positions,
five zoom scales and three viewport aspects. Invalid/overflowing projections do
not commit selection, priorities or timer changes.

The shared `CameraWorld.tracksideCamera` helper now accepts an optional zoom scale,
with its former default of 9 preserved. Existing trackside, camera-zoom, survey,
Fly and driving-runtime tests are included in the selected regression suite.
No renderer or shader changes are part of this increment.

## Collision ownership

Original simuv2 ORs each step's collision flags into `priv.collision`. The director
clears every car's accumulated flag only when its retained race slot changes.
Manual screen car changes can also clear a particular car's flag. Those writes
must not cross the native immutable simulation-to-rendering boundary.

`PresentationCollisionHistory` observes every physics publication and records the
latest collision and reset ticks. It is copied into immutable presentation frames.
The presentation owner maintains acknowledgement cursors shared across screens:
a director switch advances all cursors to the observed tick; a manual car change
can advance just that car's cursor. Pending events are computed from those cursors
without clearing or changing authoritative simulation flags. Acknowledgements by
one screen consequently affect the next screen, matching original update order.
Inactive stale collision publication does not generate new events. Initial
accumulated flags, source resets and collisions between display frames are kept.
Rejected repeated/backward ticks leave the history unchanged.

`DrivingRuntime` observes every physics publication, before race status changes,
and publishes the history, visual snapshot, local track position and remaining
laps together in `RacePresentationCar`. The current human session has no pit
request control and publishes `pitRequested=false`. `DrivingFrame.raceTime`
uses TORCS's repeated Double additions, rather than tick multiplication; this
matters at strict timer boundaries. Fly now consumes that same original clock.

`TVPresentation` owns four retained directors and shared per-car acknowledgement
cursors. It consumes complete immutable frames in supplied race order, uses the
global Main Track width, and excludes other active screens. Manual car selection
acknowledges only the selected car without resetting the retained director slot.
Inactive, incomplete, mixed-tick, stale and invalid frames are rejected; failed
projections commit no camera, selection, clock or acknowledgement changes.
The application retains this owner across picker changes. The single-camera rig
rejects TV calls without race context instead of manufacturing a default view.

## Reference and evidence

The test adapter compiles unchanged notice-retaining excerpts for `GetDistToStart`,
the full `cGrCarCamRoadZoomTVD` class and its original factory from pinned grcam.cpp.
An access-only `class`→`struct` preprocessor substitution exposes the implicit-
private director fields for comparisons; selection/constructor statements are
unchanged. The adapter supplies car arrays, screen callbacks and parameter values,
executes original selection and inherited road-zoom code, and captures priorities,
viewability, clocks, selected ID/slot, collision clears and camera fields. It is
not a whole race engine or OpenGL renderer. It links only into tests.

The original grmain.h is additionally pinned for the four-screen limit. TV
configuration key names are checked against the existing pinned graphic.h.
There are now 175 imported source/license and 46 content entries, all retained
under their original notices. No artwork is added.

The tests cover:

- 24,000 sequential director updates at 1, 2, 3, 8 and 32 cars, using four settings
  sets, race-order changes, time holds/backward jumps and other-screen exclusions.
  All priorities, viewability, clocks, IDs/slots and collision clears match exactly.
- 440 further event/boundary updates, plus focused strict-timing witnesses.
- 2,400 original director-selected camera updates with 303 target changes; poses,
  FOV and projection matrices match exactly at three aspects. An additional 600
  roadside/zoom updates compare the inherited original road-zoom behavior.
- 36,000 per-car physics publications across four display cadences, 4,302 director
  updates and 808 clears, with exact legacy collision-latch equivalence.
- Two TV screens sharing acknowledgements: 8,000 per-car publications, 800 director
  updates and 224 clears, including 27 clears initiated by the second screen.
- A native 4,000-tick driving comparison with 500 TV updates and 139 collision-bearing
  views: all 142 telemetry fields, RNG state/draws and published collision flags
  remain identical to the run without presentation observation.

The earlier kernel build modes, inventory and source/evidence hashes remain in
`tv-director-report.json`. Those tests establish selected behavioral comparisons;
they do not establish whole-race parity or performance.

## Remaining integration

Full race standings, original graph.xml director settings, multi-car GUI driving,
multiple visible screens and interactive picker/pause/zoom/relaunch acceptance
remain open. Subsequent native traffic rendering with per-car shadows is recorded
in MULTI_CAR_SHADOWS.md; the GUI remains single-car. Supplied race-order permutations in tests are authored inputs, not
an implementation of sorting. The packaged/offscreen scene remains single-car.

## Integrated publication checks

Three actual native cars advance for 3,000 ticks. Two screen directors process
752 updates, 37 automatic slot changes and seven manual selections. Selection,
priorities, viewability, clocks and shared acknowledgements match original code
exactly, including authored race-order changes. Another 2,000 physics publications
across 240 display frames verify immutable publication and the repeated-addition
clock; a 600-second pause leaves both unchanged. Original F11 zoom is compared
for 1,221 updates including loaded out-of-factory-range values and saved keys.
The original track loader independently checks global width on selected tracks.

## Earlier kernel validation

All 33 selected camera, collision-history and driving-runtime tests pass in debug,
release and Address Sanitizer. The inventory is 234; no new full-suite run is
claimed. Provenance and archive checks cover all 221 imported source/content/
license entries. Native app targets compile, and the release binary has no direct
C++ runtime or Expat dependency. The existing Fly preview binary, driving UI,
renderer and shaders retain their prior hashes. Detailed counts and source/log
hashes are in `tv-director-report.json`.

## Packaged integration validation

The integration passes all 238 debug XCTest cases and 35 selected release and
Address Sanitizer cases. `build/TORCSTVPreview.app` has a verified ad-hoc signature.
Three fresh processes produce identical TV reports, each with 24 captures and
24 exact immediate raster-repeat pairs across two 901-frame native physics runs.
The third process enables Metal API and GPU validation and reports no faults.
Captures cover four moving frames, paused zoom at 9/1/90, picker deselection gaps,
classic filtering and optional 4× MSAA/4× anisotropic filtering. Existing car
shadows, baked track projection and reflection textures remain enabled.

Renderer and shader sources are unchanged. The capture is a single-car scene;
there is no new performance or multi-car rendering claim. The Fly race-clock
correction is rerendered separately: all 24 captured images and camera poses match
the preceding Fly preview exactly, with 24 exact repeat pairs. Exact comparisons and current source/log
hashes are recorded in `tv-integration-report.json`. Earlier preview binaries
and the user's camera preference file are preserved.

Run the same offscreen diagnostic with a new output directory:

```sh
build/TORCSTVPreview.app/Contents/MacOS/TORCSMac --tv-visual-test \
  Artifacts/driving-track-shadow-session Artifacts/my-tv-capture
```
