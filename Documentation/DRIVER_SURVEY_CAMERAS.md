# Driver and circuit cameras

Seven additional original cameras bring the native picker to 27 views: the F2
driver camera, F6 circuit-center camera and all five F7 panoramas. They consume
the existing interpolated vehicle pose; they do not change simulation timing.
The driver view appears under **Driving views**, and the other six appear under
**Circuit views**.

The driver eye comes from the original car XML's Driver position, with a target
30 m ahead in car coordinates. The original world-up direction, 67.5° field of
view, 0.1 m near plane and 600 m far plane are preserved. This differs from the
existing bonnet view, whose up direction follows body roll. The renderer hides
the first named DRIVER subtree for the driver view, matching the original
selector behavior, while keeping the remaining body and wheels visible.

The circuit-center view follows the car from a fixed position 120 m above the
track's world coordinates and adjusts field of view and clipping distance using
the original formulas. Panoramas preserve the original five positions, 74° field
of view, clipping, fog and background visibility. In particular, the original
integer rounding in world dimensions and the first panorama is intentional.
The panoramas omit the sky background. No extra render pass, texture or shader
variant is introduced; the driver view omits the selected mesh draws.

## Reference scope

Five new verbatim excerpts use the already-pinned grcam.cpp and grscene.cpp:
the driver class/factory, circuit and panorama classes/factory, and world-size
assignments. The provenance script verifies their bytes before they execute in
the C++ reference target. No new upstream source or artwork is imported.

The oracle compares the default, unzoomed camera factories and updates. User
zoom, saved camera preferences, mirror composition, road cameras, fly camera
and TV director remain outside this increment. The original zoom methods are
compiled with capture stubs but are not exercised or claimed as ported.

Native world dimensions reject nonfinite/negative bounds and dimensions that
could overflow the original signed 32-bit panoramic arithmetic. Undefined
integer-overflow behavior is not reproduced. This is a supported-content limit;
the selected Aalborg world and the tested bounds fit within it.

## Verification

- 600 world/vehicle cases across six circuit views produce 3,600 original/native
  updates with exactly matching eye, target, up direction and world dimensions.
  Tests also check field of view, fog, draw flags and projection at three aspects.
- 1,200 driver poses include roll, pitch and yaw. Maximum position difference
  from original PLIB arithmetic is 0.000003815 m. Projection and visibility flags
  are checked independently.
- GPU fixtures verify nested DRIVER suppression, the first-named-subtree rule,
  triangle counts and panorama background suppression.
- Thirty selected graphics/presentation tests pass in debug, release and under
  Address Sanitizer. These checks include the earlier reflection, projected
  shadow and 360-frame pinned-car raster-repeat regressions.
- Two fresh packaged processes match all 35 saved frames. Every one of the 27
  camera repeat pairs has zero changed channels. All 28 frames saved by the
  previous track-shadow preview retain their hashes.
- Metal API and GPU shader validation pass with no reported fault and no changed
  channels in the camera repeats. The packaged Metal smoke checksum is 1103027.
- The test inventory is now 197; this increment did not rerun the complete suite.

The unchanged chase-scene benchmark measured GPU medians of 0.6349 and 0.6365 ms
with classic filtering and all maps/shadows, or 0.6796 and 0.6751 ms with optional
4× filtering. These are 60 interleaved samples per mode after ten warmups, at
960 × 640 on an Apple M2. They are offscreen command timings, not gameplay FPS,
nor measurements of every new camera or multi-car rendering. Instrumented Metal
validation timings are excluded.

Full-scene packaged checks and source hashes are recorded in
`driver-survey-camera-report.json`. Camera numerical parity is not a claim of
pixel equality with the original OpenGL renderer. The complete port remains
unfinished; the user's camera, visual and shadow work takes priority over
physical controller validation.

## Local preview

Use `build/TORCSSurveyPreview.app`, then **File → Open Driving Session…** and
select `Artifacts/driving-track-shadow-session`. The existing prepared content
works without recompilation. The preview is ad-hoc signed; prepared local-only
content is not included in the app bundle. This increment checks the packaged app
offscreen; a new interactive driving acceptance run has not been performed.
