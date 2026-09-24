# Exterior camera families

The repeat-render failures recorded below are historical. Material specialization
now stabilizes the selected 20-camera scene; see [RASTER_STABILITY.md](RASTER_STABILITY.md).

The driving screen now has 20 views. This increment adds the remaining two
F3 presets, eight F4 side views and four F5 overhead views at their original
unzoomed settings. The picker groups driving, side and overhead views.

| Views | Original behavior | Vertical FOV | Near / far | Fog start / end |
|---|---|---|---|---|
| Track chase | 30 m behind track tangent, terrain height +5 m; original per-update heading relaxation | 40° | 1 / 1000 m | 500 / 1000 m |
| Reverse | 8 m ahead of vehicle yaw, terrain height +0.5 m; looks back at the car | 40° | 0.5 / 1000 m | 500 / 1000 m |
| Side 1–4 | Fixed world offsets (0,−20,3), (0,20,3), (−20,0,3), (20,0,3) m | 30° | 1 / 1000 m | 500 / 1000 m |
| Side 5–8 | Double the corresponding Side 1–4 offset | 30° | 1 / 1000 m | 500 / 1000 m |
| Overhead 1 | 200 m above car; screen up follows world +Y | 67.5° | 100 / 1000 m | 500 / 1000 m |
| Overhead 2 | 250 m above car; screen up follows world −Y | 67.5° | 200 / 1000 m | 500 / 1000 m |
| Overhead 3 | 350 m above car; screen up follows world +X | 67.5° | 200 / 1000 m | 500 / 1000 m |
| Overhead 4 | 400 m above car; screen up follows world −X | 67.5° | 200 / 1000 m | 500 / 1000 m |

Side views use world offsets, not car-local offsets. Track chase follows the
track tangent even when the car slides or faces the wrong way. Reverse follows
vehicle yaw without chase relaxation. Original terrain queries are retained for
track chase/reverse; the side and overhead cameras do not avoid scenery or walls.
The far and fog settings use the current default fovFactor of 1.

`DrivingCameraRig` owns separate retained yaw state for each chase view and the
track chase. Only the selected camera updates, once per graphics update, matching
the original camera lists. Physics remains independent of camera selection.
The gameplay path and offscreen diagnostic use this same rig. Display positions
are interpolated physics poses; the track tangent is queried at that display
position with the published current segment as the search hint. This is display
interpolation, not a change to track queries or simulation state.

The reference bridge compiles the original four camera classes and the original
F3–F5 factory block verbatim. The provenance verifier checks both excerpts against
the pinned grcam.cpp, including the original GPL notices. Tests compare 16,800
updates and 151,200 position/target/up scalars with zero observed error. FOV, fog,
and projection matrices built from original clipping values also match. Another
500 switching cycles check independent relaxation and confirm that only Road
hides the car and its shadow. The original C++ remains reference-only.

The camera expansion adds no rendering pass. Only the selected view is rendered;
overhead views can expose more scene geometry, so equal frame cost across camera
positions is not asserted. The existing sky, lighting, shadow and optional sharper
filtering paths are shared. Sparse transparent-window repeat differences remain
unresolved; the offscreen diagnostic still enforces its original strict tolerance
and records all 20 views before returning failure for any failing pair.

Validation and preview artifact hashes are recorded in exterior-camera-report.json.
Earlier environment and driving-visual reports remain historical snapshots.

The separate signed `build/TORCSCameraPreview.app` uses
`Artifacts/driving-environment-final`. Its packaged Metal smoke check returns
checksum 1103027. All 20 views were rendered offscreen; the final app has not been
UI-launched. Seventeen relevant release and Address Sanitizer tests pass. Full
182-test debug/release results belong to the preceding environment increment;
the current test inventory is 184, and those full suites were not rerun here.

The final raster run passed 16 of 20 strict repeat comparisons. Far chase,
Reverse, Side 2 and Side 3 failed, with 11, 10, 13 and 16 changed channels and
maximum byte differences 4, 7, 4 and 49 respectively. The largest difference is
one rear-window pixel in Side 3; small opaque-pixel differences also appear in
Side 2. All captured submission hashes are identical within each pair. This
expands the evidence for the unresolved rendering issue; it is not a camera
arithmetic failure or proof of a specific GPU cause. Both images of every failed
pair are retained. Median chase GPU command time was 0.635 ms with classic
filtering/shadow and 0.692 ms with 4× filtering, across 60 interleaved samples.

Still pending: inertial bonnet, circuit-center, panoramic, authored trackside,
flying and TV-director cameras; zoom controls, mirrors, reflections and other
original effects. This increment does not complete the renderer or the full port.
