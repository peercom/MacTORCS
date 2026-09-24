# Car environment maps

The subsequent [track-shadow increment](CAR_TRACK_SHADOWS.md) adds the third
indexed-car layer. The measurements and remaining-work notes below describe this
earlier two-layer increment.

Prepared driving sessions now use TORCS's original scrolling car environment map
and yaw-dependent environment shading. UV1 translates by lap distance / 50; UV2
rotates about the texture origin using the original RAD2DEG → PLIB conversion.
These are the precomputed coordinates already retained from each ACC mesh.
Per-car presentation state is attached to instances, including their wheels, and
never feeds back into physics. Graphics interpolate yaw and resolve track distance
at the displayed body position so reflection motion follows presentation.

The selected modern multitexture path binds the track's first environment image
(`env.png` for Aalborg) and `envshadow.png`. Original `grMultiTexState::apply`
changes the binding, not the texture environment equation: the layers use
[OpenGL's default MODULATE equation](https://registry.khronos.org/OpenGL-Refpages/gl2.1/xhtml/glTexEnv.xml).
RGBA modulation precedes separate specular, alpha rejection, blending and fog.
The original map-level gates apply: negative levels receive UV1, levels ≤ −2
also receive UV2. Track material layers keep their existing behavior.

Two shared textures are uploaded at session load. A 16-byte per-draw reflection
uniform carries the translation and rotation coefficients. There are no extra
draw calls, render passes or scene captures. Classic filtering stays the default;
the existing optional 4× anisotropic mode also works with these maps.
The existing alpha-test pipeline specialization remains in use.

## Reference and renderer checks

Unchanged `grvtxtable.cpp` and `grmultitexstate.cpp` are pinned with original
Christophe Guionneau notices. A verbatim texture-matrix block runs through capture
adapters and original PLIB mathematics in the test-only reference target.
`Scripts/verify-provenance.py` checks the excerpt byte for byte. The release
archive check now covers 211 files: 165 source/license and 46 content entries.

- 6,000 distance/yaw/map-level cases match the original transform coefficients
  exactly in debug, release and Address Sanitizer builds. The float trigonometric overload matters here.
- Authored GPU fixtures verify map selection, scrolling, repeat wrapping, yaw,
  independent instance state, missing-map fallback, disabling and alpha cutoff.
- The pinned-car raster regression now covers both reflection modes: four views
  × 30 repeats × two modes, with zero changed channels in all 240 repeats.
- 21 relevant graphics/presentation tests pass in debug, release and under
  Address Sanitizer. The test inventory is 188; the full suite was not rerun
  for this increment. See `car-reflections-report.json` for evidence.
- Two fresh signed-preview processes pass all 20 camera repeat pairs with zero
  changed channels; all 25 saved image hashes match across processes.
- Metal API and GPU shader validation also pass all 20 repeat pairs, with no
  reported validation fault. Validation timings are excluded from performance.

These are native raster stability and selected behavior checks. They do not
claim pixel equality against an original OpenGL screenshot, all-content coverage,
or validation on Apple GPUs other than the tested M2.

## Measured cost

At 960 × 640 in the stationary, single-car Aalborg diagnostic, 60 interleaved
samples per mode after ten warmups gave these GPU medians:

| Fresh run | Classic shadows, no reflections | Classic shadows + reflections | Added GPU time |
|---|---:|---:|---:|
| First | 0.6181 ms | 0.6425 ms | 0.0245 ms |
| Second | 0.6151 ms | 0.6320 ms | 0.0169 ms |

The optional 4× filtering mode with reflections measured 0.6675–0.6740 ms.
Timing tails were noisy (classic reflection GPU p95 2.45–2.72 ms); these medians
are a selected offscreen comparison, not gameplay FPS or a multi-car guarantee.
Reflection enable/disable changes 279,356 output channels in this chase view.

## Local preview

The separate ad-hoc signed preview is `build/TORCSReflectionPreview.app`.
Its prepared session is `Artifacts/driving-reflection-session`. Open that folder
with **File → Open Driving Session…**, then click **Drive**. All 20 camera presets
are available. This preview was checked offscreen; a new interactive driving
acceptance run has not been performed for this increment.

To prepare another local session after building release tools:

```sh
python3 Scripts/prepare-driving-session.py /path/to/torcs-1.3.9 Artifacts/new-driving-session
```

The two shared environment images have unresolved per-file artwork attribution.
They remain local-only inputs, excluded from the repository and app resources.
The session notice now covers seven shared track/environment textures. Their
source hashes and compiled-cache hashes are recorded in the machine report.
Aalborg's already-pinned sky PNG remains under its original Free Art notice.
Older version-1 sessions without the optional reflection fields continue to load.
A packaged run of the previous session passes all 20 camera repeat checks.

## Remaining fidelity work

The indexed car path also projects `shadow2.rgb` from track space onto car bodies.
That third environment layer is still omitted and reported by the scene warning.
Its original scale uses raw loader vertex bounds, and `grcar.cpp` stores the
ratio *after* detailed wheel loading: the last wheel mesh can replace the body
ratio. Faithful coverage requires retaining these loader bounds and testing this
initialization order. Using world-space scene bounds would silently change it.
The original nonindexed car path does not apply that third layer.

Mirrors, remaining camera families, scene-wide dynamic shadows, smoke, skid marks,
and other original effects remain open. Physical GameController validation stays
behind the requested camera and visual work. The full port goal remains active.
