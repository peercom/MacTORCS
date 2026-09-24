# Vehicle snapshots and wheel presentation

The native renderer can now compose the selected car body, four detailed wheels
and the Aalborg track using immutable simulation snapshots. This is a tested
physics/rendering integration diagnostic. The interactive app now also offers native keyboard driving of prepared sessions;
see DRIVING_SESSION.md. Selected lap timing and capture are now integrated;
see LAP_TIMING.md for scope and the still-pending physical five-lap demonstration.

## Published state

`VehicleVisualSnapshot` copies the public body transform, flags and four wheel
poses, spin rates, dimensions and brake temperatures. `VehicleRemovalState`
retains wheel pose publication from the original copy-back stage. Fresh poses
use the original pre-CG wheel origins and initial radius; subsequent active
updates publish force-stage height/camber/yaw and rotation-stage angle. Prestart
retains the original distinction between updated wheel poses and held published
spin. Inactive/removal phases retain wheel values while towing can change the
body transform. Reading a snapshot cannot mutate physics.

The new original-world adapter reads `carElt` publication independently and runs
a verbatim wheel-update loop from pinned `grcar.cpp`. PLIB calculates its wheel
position and rotation matrices. The excerpt is byte-verified during provenance
checks; the reference never receives native publication values in integrated tests.

## Original wheel rules

- Position uses relative X/Y/Z, heading = relative yaw and pitch = relative camber.
- A separate child transform uses relative wheel rotation as PLIB roll.
- Right-side detailed wheels turn 180 degrees about Z.
- Detailed wheel mesh scale is `(2 × radius, tire width, 2 × radius)`.
- Absolute spin selects levels 0/1/2/3 at strict boundaries 20/40/70 rad/s.
- Brake color retains the original temperature expressions, including negative
  blue at high temperatures. The color is captured; procedural brake geometry
  has not yet been ported.

These rules are not inferred from mesh appearance. The four wheel files are
speed levels shared by all corners, with separate transforms per wheel.

## Metal instances and interpolation

`SceneRenderer` accepts multiple compiled resources and separate instance
transforms. Model buffers and texture bindings are prepared once; four wheel
instances share the chosen speed-level resource. Texture names are scoped per
model, so equal filenames in different models do not alias unrelated textures.
Instance validation rejects invalid resource indices or transforms without
replacing the previous valid state.

`VehiclePresentation.interpolate` preserves exact endpoint matrices, interpolates
translations and positive scales, and uses quaternion shortest-arc rotation for
interior frames. It does not alter timestep or physics. Discrete wheel speed level
uses the current endpoint for interior frames. This presentation policy is tested
separately from original TORCS transform parity; no original interpolation oracle
is claimed. A reference-tested chase camera and realtime session now consume this interface;
additional camera modes remain pending.

## Reproduce

```sh
swift build -c release
Scripts/build-app.sh
python3 Scripts/verify-vehicle-scene.py /path/to/torcs-1.3.9
```

The command compiles six original models into temporary scene packages, initializes
the native car/track, settles for 501 ticks, simulates 1,000 ticks with throttle and
first gear, then renders a half-step interpolated snapshot. It verifies consecutive
GPU readback and separate-process output repeatability within a narrow raster
tolerance: maximum one byte value in at most 0.01% of RGBA channels. The close
vehicle view exposed seven one-value differences around the windshield and a
headlight; this is not a portable GPU golden-image or exact-pixel claim. Every
comparison records the observed count and maximum. Physics distance, geometry
counts and selected wheel levels must match exactly across processes. The car’s motion is computed
by the already reference-tested vehicle simulation, not supplied as animation.
Five shared track textures come from the explicit local upstream directory and
remain excluded from redistributed content. Generated image/cache derivatives
retain their source artwork terms.

For previously compiled scene directories named `155-DTM`, `wheel0` … `wheel3`
and `aalborg`:

```sh
build/TORCSMac.app/Contents/MacOS/TORCSMac --vehicle-scene-smoke-test Artifacts/scenes Tests/UnitTests/Fixtures Artifacts/vehicle.png
```

This diagnostic reads the named selected XML fixtures and binary scene caches
before rendering. Runtime draw callbacks perform no file IO or legacy decoding.
The camera used here is an inspection view; it is not a TORCS driving camera.

## Evidence and limits

Authored graphics checks cover 300 cases / 27,600 matrix and brake-color scalars,
including both directions and exact speed thresholds. Integrated checks cover
2,002 fresh/settled/prestart/driving/removal samples, 80,080 exact published wheel
values and 184,184 matrix/color scalars. Float SIMD multiplication order introduces
small bounded differences from PLIB; compare measured maxima in
`vehicle-presentation-report.json` rather than assuming bit identity.

GPU checks exercise resource selection, dynamic transforms and invalid-state
preservation. Interpolation tests cover exact endpoints, angle wrap, retained
scales and invalid alpha. Brakes/calipers, vehicle deformation, car reflections,
complete visual/race coverage remain open. Selected cameras, projected shadows,
track lighting/sky/fog, input and timing are documented in DRIVING_VISUALS.md,
TRACK_ENVIRONMENT.md, INPUT.md and LAP_TIMING.md. First playable and renderer finish conditions are not achieved.
