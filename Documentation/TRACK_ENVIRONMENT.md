# Track sky, lighting and fog

The repeat-render failures recorded below are historical. See
[RASTER_STABILITY.md](RASTER_STABILITY.md) for the material-specialization fix
and current selected-scene validation.

Prepared driving sessions now use the original track's Graphic configuration.
The model inspector retains its generic inspection lighting. This increment
implements the original scene setup; it does not claim complete renderer parity.

`TrackGraphics` reads background filename/type/color, ambient, diffuse, specular
and light position. Reference tests execute the verbatim TORCS reads through the
original parameter parser: 42 configurations, 756 scalar values, and all type
values match exactly. The PLIB light starts with w=0 and its three-coordinate
setter leaves w unchanged, so this is a directional light. The native shader
normalizes that world direction and preserves the existing color-material,
global ambient and separate-specular model. The original grscene shininess local
is unused; per-material shininess remains authoritative.

The background uses original cylinder types 0, 2 and 4: 36 sides, original heights,
UV repetition/atlas layout, no culling, and source-alpha blending. Other types
produce only the configured clear color, matching the original switch default.
All 228 vertices across the three layouts match verbatim C++ loops exactly.
The background camera follows view orientation and roll, removes translation,
and clamps its vertical field of view to at least 60°. Two hundred camera cases
match the original update within 1e-5 (degrees for FOV). Sky depth cannot occlude
scenery or the car, and the sky itself is not fogged.

Aalborg's original background.png is pinned with its adjacent unversioned Free
Art notice. Native decoding matches all 4,194,304 original RGBA bytes (2048×512),
and all 5,592,412 bytes across 12 mip levels match the original mip builder. The loader
uses screen gamma 2.0 and a full mip chain: grutil.cpp hard-codes those values for
PNG loading despite grscene assigning the unused grGammaValue/grMipMap globals.
The preparation script preserves that behavior. Runtime loading consumes only
the compiled cache. The separate texture/image cache formats are unchanged.

The first six driving cameras provide the original 300–600 m linear fog interval;
the newer exterior families use 500–1000 m (see EXTERIOR_CAMERAS.md).
Fog RGB is 0.8 × the track background color. The shader uses interpolated absolute
eye-space Z, clamps the linear factor, and leaves alpha unchanged. This is an
allowed approximation in the [OpenGL 1.2.1 specification, section 3.10](https://registry.khronos.org/OpenGL/specs/gl/glspec121.pdf).
TORCS sets GL_DONT_CARE for fog quality; no particular original GPU's fog
interpolation or raster result is asserted. Projected car shadows receive the
same fog and use the body's transformed normal for original white color-material
lighting. Their texture alpha remains unchanged.

GPU fixtures check configured lighting, shadow lighting with two normals, linear
fog color/alpha, sky visibility, scene-over-sky depth and clear-color fallback.
Sky texture/buffers are prepared once. The type-4 sky adds one 74-vertex draw
(72 triangles), no additional render pass, and no per-frame texture decoding.

## Reproduce

```
swift build -c release
python3 Scripts/prepare-driving-session.py /path/to/torcs-1.3.9 Artifacts/new-environment-session
.build/release/TORCSMac --driving-visual-test Artifacts/new-environment-session Artifacts/new-environment-images
```

The optional background field in version-1 driving.json names a compiled texture.
Older sessions still load and use their track lighting/fog/clear color; without
a background cache they have no sky image. Prepared track sessions retain their
existing local-only notice for five shared textures with unresolved attribution.

The diagnostic saves all six camera images and four interleaved timing modes,
even if a strict repeat check fails. It still exits nonzero on any repeat failure.
The fourth mode reproduces the previous placeholder lighting/background using
the same new renderer; it is a same-binary configuration comparison, not an
old-versus-new executable benchmark. Submission hashing is diagnostic-only:
normal draw calls do not hash uniforms or resources.

The small transparent-window repeat variance remains unresolved. Selected failed
pairs have identical submitted uniform bytes and draw-resource ordering, with
immutable buffers/textures. This narrows the cause to the GPU rendering path;
it does not establish a driver defect or a particular cause. The existing maximum
one-level / 0.01%-of-channels tolerance is unchanged. Final measurements and
success/failure evidence are in track-environment-report.json.

The final packaged 960×640 release diagnostic measured median GPU command times of
0.642 ms for the configured environment with shadow and 0.625 ms for the previous
placeholder configuration. Optional 4× filtering measured 0.694 ms. Each mode
has 60 interleaved samples after warmup; these are selected stationary-scene GPU
times, not gameplay FPS or a race-wide performance guarantee. Near chase failed
the strict repeat check (5 differing channels, maximum difference 2), despite
identical captured submissions. The other five camera pairs passed. The earlier
release diagnostic also exposed a far-chase failure; both runs are retained.

The separate ad-hoc-signed `build/TORCSEnvironmentPreview.app` uses the prepared
`Artifacts/driving-environment-final` session. Its packaged Metal smoke test
passes with checksum 1103027. This preview has not been UI-launched; the user's
earlier running app was left untouched. Full debug/release suites pass 182 tests.

Remaining graphics work includes reflections, mirrors, remaining camera families,
car lights/brake discs, skid marks, smoke, scene-wide dynamic shadows, and broader
performance/visual coverage. No renderer finish condition is marked complete.
