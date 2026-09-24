# Stable repeated scene rendering

The asset shader specializes alpha testing from the resolved per-view state.
States with alpha testing disabled use a function with no fragment discard.
Draws whose material and all active uploaded texture alpha bounds guarantee a
pass also omit discard. All other draws retain `alpha <= threshold` rejection.
The original flag-only specialization described in the historical evidence below
was insufficient: an unset original flag can mean inherited enable. The later
ALPHA_STATE.md increment preserves that behavior and validates conservative
elision against actual texture bindings, depth rejection and repeated frames.
Its 720-frame selected test passes, but the broader traffic capture exposes an
unresolved one-byte wheel difference between native simulation runs. The
inherited-alpha package has not replaced the validated Order preview; see
ALPHA_STATE.md for the failing capture and unchanged acceptance checks.
Opaque and blended variants are prepared during scene loading; no geometry,
texture, mip or filtering change is used to hide repeat variation.

Metal function constants select the paths when the pipeline is created; see
[Apple's function-specialization documentation](https://developer.apple.com/documentation/metal/using-function-specialization-to-build-pipeline-variants).
This is material-state specialization, not removal of alpha testing from scenery.
There is no per-frame shader compilation or additional render pass.

## Evidence and scope

The previous camera increment exposed sparse repeat differences around car
windows and a few opaque pixels. The largest recorded difference was 49 byte
levels at one Side 3 window pixel, despite identical submitted uniforms and draw
resources. A car-only reproducer retained the issue, so track scenery and car
shadow rendering were not required to trigger it.

Controlled experiments kept one settled pose and four camera views, comparing
30 repeats per view. Disabling lighting or floating-point optimizations did not
resolve the issue. Explicit gradients, unconditional sampling, raster-order
annotations, programmable blending and original strip boundaries did not resolve
it either. Disabling mip selection, blending or depth writes did; these were
rejected as behavior-changing workarounds. Splitting every blended triangle into
its own draw also stabilized the reproducer, but would add many draw calls.
Removing the *inactive* runtime discard path stabilized all 120 repeated frames
while preserving the required material behavior.

These observations isolate an interaction involving the conditional-discard
shader, mip sampling, blending and depth writes on the tested Apple M2/macOS
26.2 system. They do not establish a particular compiler or GPU-driver defect.
The shader specialization follows the actual material state and does not depend
on diagnosing the undocumented implementation mechanism.

`RasterRepeatTests` compiles only the already-pinned 155-DTM model/textures into a
temporary scene. It uses a frozen display pose and the four reproducing views;
it does not depend on an external TORCS installation or local prepared session.
The original maximum one-byte-level / 0.01%-of-channels tolerance is unchanged.
A negative-control run with the previous renderer/shader fails three assertions
(maximum difference 9, up to 24 changed channels). The specialized shader passes
with zero differing channels in 120 comparisons. Twelve authored cutoff/blend
cases independently verify all four pipeline combinations, including equality
at the alpha-test threshold.

The investigation also ran [Apple's Metal API and shader validation](https://developer.apple.com/documentation/xcode/validating-your-apps-metal-shader-usage).
The old shader's visual variance reproduced without a reported resource-access
or invalid-interpolant fault. Validation coverage does not prove all GPU behavior
is defined or establish stability across every material, scene and device.

Temporary experiments are retained only under Artifacts/raster-investigation;
there are no probe environment variables or alternate experimental rendering
paths in the production app. Source/log hashes, the old-shader negative control,
selected full-scene results and measured costs are in raster-stability-report.json.
Earlier reports remain historical snapshots of the issue before specialization.

The separate signed `build/TORCSRasterPreview.app` loads the existing prepared
`Artifacts/driving-environment-final` session. Its packaged smoke check returns
checksum 1103027. It has not been UI-launched; older preview apps were left intact.
Two fresh release processes each passed all 20 camera repeat comparisons with
zero differing channels. The previous camera preview, run between those two
checks, still reproduced the issue with maximum channel difference 49.
All saved raw image hashes also match between the two new processes, including
the enhanced-filtering benchmark capture. A third process with Metal API and
shader validation enabled passes all 20 repeat pairs with zero differing channels
and no reported validation fault. Instrumented timings are excluded from the
performance comparison below.

At 960×640, median GPU command times for classic filtering plus shadow were
0.616 and 0.613 ms in the new runs, versus 0.641 ms in the intervening old run.
The optional 4× filtering mode measured 0.656 ms versus 0.695 ms previously.
Each mode has 60 interleaved samples after warmup. These are selected stationary
scene measurements, not gameplay FPS, CPU frame-cost or race-wide guarantees.
Debug, release and Address Sanitizer runs each pass 19 relevant tests. The current
test inventory is 186; full-suite results from the preceding environment increment
remain historical 182-test results, not a current full-suite claim.

The full renderer remains incomplete: reflections, mirrors, additional camera
families, dynamic scene shadows and other effects still need implementation.
Broader cars/tracks and Apple GPU generations still need raster coverage.
