# Inherited alpha testing

The original ACC loader calls `setAlphaClamp(0)` for base materials, enables
alpha testing for cutouts/translucent track materials, and otherwise leaves the
enable flag untouched. A missing flag therefore does not mean disabled. PLIB's
per-view basic state enables alpha testing with threshold 0.01. Ordinary draw
states partially update that state; generated brakes, car shadows and car lights
inherit both enable and threshold. Extra texture-unit states bind textures only
through grMultiTexState and do not apply their alpha properties to the GL context.

`ACRenderState.alphaCare` records the two independent setters: bit 0 for enable,
bit 1 for threshold. The ACC parser and original loader's test storage adapter
record the same calls. The existing v1/v2 binary cache stores enough information
to recover this metadata exactly from layer number and flags; its payload and
identity remain unchanged. Only ACC parsing creates binary cache payloads.
Generated brake states explicitly inherit both properties. Authored native state
initializers retain explicit defaults so a flag value of zero can intentionally
disable alpha testing.

Each scene view begins with `SceneAlphaState`, applies states in actual draw
order and ignores hidden draws. Mesh and effect shaders receive the resulting
threshold. Shadows test their sampled texture alpha; lights test texture alpha
multiplied by the original 0.75 light alpha. Separate pipeline specializations
remove discard from draws where alpha testing is disabled, preserving the
renderer’s previous inactive-discard workaround. No new passes or textures are
needed. Pipeline variants are created during loading.

Initial broad checks exposed repeated-frame variation when previously untested
car surfaces gained an active discard path. The correction now measures each
uploaded texture's minimum alpha, including every uploaded mip and LA/RGBA
formats. A mesh can omit discard only when its constant color alpha multiplied
by all active texture lower bounds exceeds the threshold with a floating-point
margin. Zero-alpha and near-threshold cases retain the actual alpha test. Texture
bounds are derived from actual bytes during loading; no per-frame texture scan is
performed. Effect shaders retain their alpha test for positive thresholds,
including border sampling. At a zero threshold, shadows and lights can omit
discard: their nonnegative alpha, source-alpha blending on all channels and
read-only depth make fully transparent fragments leave the destination unchanged.
This optimization does not apply to ordinary meshes, which write depth.
The initial failed full/ASan logs are retained as evidence; the revised checks
are running, with the original raster tolerance unchanged.

Reference adapters execute unchanged PLIB constructors, enable/disable,
setAlphaClamp, apply and force routines plus original basic-state initialization.
The GL alpha calls and enables are captured; material/texture/callback operations
are adapters. This proves partial-state transitions, not original GL pixels or
arbitrary callbacks. Full original mesh frustum/LOD selection is still incomplete;
that can change which state is inherited in a whole scene. GL reference values are clamped to [0,1], following the
[Khronos OpenGL specification, section 4.1.4](https://registry.khronos.org/OpenGL/specs/gl/glspec14.pdf).
Native comparison uses floating-point fragment alpha; the original driver's
fixed-point alpha-test precision is not reproduced or claimed as pixel parity.

Focused tests currently pass 1,024 original sequential state transitions, six
selected model cache/metadata round trips (2,765 states), and GPU checks for
transparent depth occlusion, shadow/light cutoffs, strict comparison and separate
mirror state. Additional GPU cases exercise actual base/detail/overlay and
external reflection/shade/track-shadow bindings, ensuring zero-alpha texture
samples still reject depth writes. The corrected focused raster suite passes
720 repeats with no changed channels. The full debug suite passed 270 tests before
the final zero-threshold effect optimization. That optimization adds a GPU test
covering four alpha values and both quality modes; all 43 affected asset/rendering
tests pass in release and AddressSanitizer, including the unchanged 720-frame
raster test with zero changed channels.

The first packaged alpha preview passed its light, Fly and TV captures but failed
the traffic repeat check (eight changed channels, maximum byte delta two). The
zero-threshold effect optimization removes that redundant active-discard path,
but does not fully resolve traffic stability. Its rerun fails the exact cross-run
comparison at frame 450, classic mode, shadows disabled: pixel (107,592) differs
only in blue, 60 versus 59, on a wheel. The immediate repeat is within the existing
one-byte tolerance; the cross-run exact-hash check remains unchanged and failing.
A fresh run of the preserved Order preview passes all 80 traffic comparisons.
This is an unresolved regression in the inherited-alpha path, not a validated
replacement preview or proof that effect discard caused the wheel difference.

Artifacts/alpha-traffic and Artifacts/alpha-effect-traffic preserve both failed
captures. The new build/TORCSAlphaEffectPreview.app is an investigative, ad-hoc
signed build; build/TORCSOrderPreview.app remains the latest validated preview.
No final performance claim is made for the effect optimization. Next, isolate
required wheel cutout discard at the frozen frame-450 pose while retaining depth
and blend behavior; do not hide the failure by increasing image tolerances.
See alpha-state-report.json for the validation boundary and VEGETATION.md for
the requested volumetric-tree follow-up; alpha correction alone adds no volume.
