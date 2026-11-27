# Frame rate in the window

The game ran at 33 frames a second on a fanless M2 with a 2560×1664 display.
This records what was measured, what the cause was, and what holds the rate
now.

## What was measured

The renderer's earlier figures were offscreen. In the window (2814×1680
pixels), with a frame meter and per-frame log added for the purpose:

| | Offscreen, one frame at a time | In the window |
|---|---|---|
| Fanless preset, chase view, CG Speedway | 8.5 ms | 13.1 ms |
| High preset, same view | 29.4 ms | 29.8 ms |

- Encoding a frame takes 0.5–2.5 ms of the main thread and the drawable comes
  at once. The main thread's 56% in `nextDrawable` was the GPU not keeping up.
- The frame rate did not depend on the field: one car, two and six all ran at
  32–33.
- It did not depend on the HUD (hidden: the same rate).
- The GPU's time for a frame was a steady 31 ms and frames ran back to back.

**The cause was the quality preset.** The saved setting was High, whose
reflections and occlusion run at full resolution: 8.9 and 8.2 ms of the frame
on this chip, against 0.7 and 1.0 at the fanless preset. Nothing said so and
nothing adapted: the renderer's dynamic resolution is off at High, and at the
fanless preset it is fed command-buffer spans that overlapping frames inflate
(24–27 ms for a 13 ms frame), so it steps down, measures no gain and reverts.

Several wrong turns are worth keeping. An offscreen loop reproduces none of
it unless it uses the preset the application uses; a prebuilt shader library,
the pipeline archive, pacing, the capture stream of a screenshot tool and a
large animation time were each ruled out by measurement; and a busy machine
moves a 9 ms baseline to 22, so a variant is only comparable with a baseline
taken beside it.

At the fanless preset in the window, the passes of one 13.1 ms frame:

| Pass | ms |
|---|---|
| Sky and forward opaque | 6.27 |
| Tonemap resolve | 1.15 |
| Screen-space occlusion and its blur | 1.21 |
| Reflections: trace, blur, temporal resolve, composite | 1.91 |
| Motion blur | 0.48 |
| Four shadow cascades | 0.55 |
| Depth prepass, road paint, bloom, exposure | about 0.7 |

More than half the frame is not the scene but full-screen passes over 4.7
million HDR pixels. The scene itself is about 200,000 triangles in 300 draws.

## What holds the rate now

**Automatic quality** (the default; the old preset setting is no longer
read). `QualityGovernor` is fed what the player sees — frames presented in
the last second — once a second while a session runs. Its ladder, lightest first: the fanless preset at 50, 67, 85
and 100% resolution (scaled up by the tonemap pass), then balanced, then
high. Three slow seconds in a row move it down a rung; twenty steady seconds
at the full rate move it up one as a trial, a rung climbed to that then fails
is not tried again (in that session or later ones, until the mode is chosen
again in Settings), and it never climbs above the machine's ceiling (high for
Max and Ultra chips, balanced for Pro, fanless otherwise). It does not wait
for the GPU's time to fall before climbing; see "The GPU's clock" below for
why that never happened. A base chip starts
one rung under its ceiling. The new settings are applied to the running
renderer; where it settled is remembered. The HUD says when it moves, and can
show the frame rate and GPU time.

**Reflections only on a wet road** at the fanless levels: their four passes
are 15% of the frame and dry asphalt is too rough to show them.

The application also declares Game Mode support, which macOS applies in full
screen.

Measured in the window after the change, on a machine busy with other work:

| | Before | After |
|---|---|---|
| One car | 33 fps | 60 fps |
| Six-car race, four car models | 32 fps | 60 fps |

Started at High on purpose, the governor reached the fanless preset by itself
within the first seconds.

## Diagnostics kept

- `--autoplay … --autoplay-measure SECONDS` prints the frame rate, the main
  thread's share of a frame, the GPU span and the quality level.
- `TORCS_FRAME_LOG=1` prints, for forty presented frames, when the draw
  began, the drawable came, encoding ended, the GPU ran the buffer and the
  frame reached the display.
- `TORCS_PASS_LOG=1` times each pass of the presented frames (the frame is
  waited for, so the frame rate under it is not the game's).
- `--frame-cost <track> <car> [WxH] [preset] [--chase] [--pace HZ]
  [--render-off a,b]` times a frame's passes offscreen. With `--lap N` it
  does so from N viewpoints round the circuit instead of the start grid, and
  `--dump DIR` writes each viewpoint's picture; `--speed MPS` moves the
  viewpoints forward at that speed, so there is motion to blur, and
  `--full-blur` gathers every streak from the scene itself. Unpaced, the timing repeats
  to a hundredth of a millisecond and the pictures bit for bit, which is
  what makes a shader change measurable: time and picture, before and after.
- `--render-off` switches effects off in the window as well.

## The window against the offscreen frame

**The window's own cost is not compositing.** The same frame took 8.5 ms
offscreen and 13.1 ms in the window, and the suspect was the system
compositing a full-resolution game layer with the HUD's layers over it. The
experiment ran on 2026-11-27, Fanless preset at full resolution, one car,
two runs of each variant, GPU median per frame:

| | HUD | no HUD |
|---|---|---|
| Window, 2880 x 1720 | 12.3, 12.3 ms | 12.6, 12.6 ms |
| Full screen | 12.7, 12.5 ms | 12.7, 13.4 ms |

No difference in either direction. Drawing the HUD inside the Metal frame
would save nothing, and full screen buys nothing either.

What the gap is instead, as far as it is known:

- **The window is bigger than the offscreen test was.** The display runs in
  its default scaled mode: 1470 x 956 points, a 2940 x 1912 backing store on
  a 2560 x 1664 panel. The game window is 2880 x 1720 pixels, 16% more than
  the panel-sized offscreen frame. Offscreen at the window's size costs
  9.0 ms, against 7.9 ms at the panel's size on the same day.
- **The rest is the GPU's clock, not the view.** Viewpoints round the lap
  cost no more offscreen than the grid does (3.4 ms for the scene pass
  against 4.0). See the next section.

Two things follow from the display mode. At "100%" the game draws 32% more
pixels than the panel has, and the system scales them down. The automatic
level of 85% is the panel's own resolution to within 3%, so it is not the
loss it sounds like.

**Low Power Mode costs 60%.** The first runs of the experiment were on
battery with Low Power Mode on, and the same frame took 17 to 23 ms instead
of 12.5. Automatic quality held 60 there by dropping to 67% in the window
and 50% in full screen. The level it settles on is now saved apart for Low
Power Mode (`renderQualityLevelLowPower`), so a session on battery no longer
sets where the next one on mains starts. That path was not exercised after
the change: Low Power Mode was switched off before it could be.

## The GPU's clock

The GPU slows down when it has time to spare, so a frame's GPU time in a
window says little about the work in it. The same offscreen frame, 2880 x
1720, Fanless preset:

| | Whole frame | Scene pass |
|---|---|---|
| Back to back | 8.1 ms | 3.4 ms |
| Paced at 60 Hz | 8.1 ms | 3.4 ms |
| Paced at 30 Hz | 15.0 ms | 7.0 ms |

In the window the reported span sits near 15 ms whatever the load: 15.9 ms
at full resolution and 15.1 ms at half. Two things follow.

- **Measure offscreen and unpaced.** In-window GPU times, the pass log
  included, are for comparing like with like on one day, not for costing
  work.
- **Automatic quality could never climb.** It waited for twenty steady
  seconds with the GPU under half its interval, and the span never falls
  that far. Started at 50% it sat there for 70 seconds at a steady 60. It
  now climbs by trial (see above): started at 50% it reached 100% in under
  two minutes and held 60 there.

## The scene pass

Measured back to back over twelve viewpoints of a lap, with each part of the
fragment shader removed in turn, the 3.4 ms of the scene pass at 2880 x 1720
divided like this (each part timed by its own removal, so they overlap a
little and add up to slightly more than the pass):

| Part | ms |
|---|---|
| Sun shadow, eight filtered taps | 0.72 |
| Aerial perspective | 0.52 |
| Normal map | 0.30 |
| Sky reflection lookup | 0.29 |
| Sun's direct light | 0.25 |
| Road markings and rubber | 0.23 |
| Sky light, diffuse and specular weights | 0.37 |
| Roughness map, occlusion lookup | 0.29 |
| Everything else: rasterising, base colour, three targets, the sky | 0.69 |

Three changes took it to 2.7 ms, a fifth less, and between 20 and 24% less
on each of the six circuits tried (CG Speedway, Alpine 1, E-Track 3,
Street 1, Wheel 2, Forza):

- **Aerial perspective per vertex.** The air's effect over the length of a
  circuit is within a part in a thousand of linear in distance, so it is
  evaluated in the vertex stage and interpolated. 0.52 ms became 0.04.
- **The shadow filter stops early.** Four taps ring the filter disc; where
  they agree, sixteen texels are all lit or all dark and the other four taps
  are not taken. A surface turned away from the sun is not filtered at all.
  The arithmetic round the taps turned out not to matter: five variants of
  it measured within 0.04 ms.
- **The sky lookup's two inverse trigonometric functions are polynomials**,
  good to a ten-thousandth of a radian. 0.06 ms.

The pictures before and after differ in single pixels along the soft edges
of dappled shadow, where the ring of four misses a fringe the inner four
would have caught: under 0.3% of pixels by more than two steps of 255 on the
worst view of the six circuits.

Moving the aerial perspective showed up a fault it had always had. The
integrator it shares with the sky adds sunlit bare earth wherever a ray ends
below sea level, which is right for the sky's table and wrong for a ray that
ends on scenery: far scenery set below sea level was lit as earth. Per pixel
that was a few pixels; per vertex it spread over whole triangles (a tunnel
mouth on Alpine 1 came out orange). Aerial perspective no longer asks for
the bounce.

What is left in the pass is many parts of 0.1 to 0.3 ms each, none of which
gave way to rearranging. The next real saving there is shading fewer pixels.

## After the scene: one pass

Between the scene and the picture there were up to six passes that each
loaded and stored the scene-sized HDR target: road paint, skid marks, the
reflection composite, the particle composite, motion blur, and the scaler.
There is now one that does (the reflections and the smoke together, and only
when there are any), and the tonemap pass does the rest as it reads the
scene.

- **Road paint and skid marks are drawn at the end of the scene pass.** The
  paint is a few quads at the start grid; its own pass cost a quarter of a
  millisecond every frame of the lap, all of it loading and storing five
  million pixels and their depth. The picture is bit for bit the same.
- **Reflections and particles share one pass** over the scene colour, in the
  order they had.
- **Motion blur is taken by the tonemap pass**, along with the scale. Its
  target, a second scene-sized HDR texture, is gone. The bloom and the lens
  blur are now built from the unblurred scene.
- **A lower resolution is scaled up by the tonemap pass's own filter**
  (`UpscalingMode.resolve`): Catmull-Rom from five taps, on exposed values
  through a reversible tonemap so the sun's disc does not ring. The game
  uses it for every level and preset. MetalFX stays in the renderer as
  `.spatial` and `.temporal`; `--render-off metalfx` puts it back for a
  comparison.

Measured offscreen with the viewpoint travelling at 50 m/s, 2880 x 1720,
Fanless preset, reflections off, whole frame:

| Resolution | Before | After |
|---|---|---|
| 100% | 6.4 ms | 6.4 ms |
| 85% | 7.5 ms | 5.5 ms |
| 67% | 6.2 ms | 4.5 ms |
| 50% | 5.3 ms | 3.8 ms |

Two findings in that table.

- **The MetalFX spatial scaler cost 2.4 ms at this size**, more than
  rendering at 85% saved. The 85% level was dearer than native and the 67%
  level no cheaper: automatic quality's first two steps down bought
  nothing. The levels now cost what their order says.
- **At 100% the merge saved nothing.** Blur and tonemap were 0.93 and
  0.80 ms apart and are 1.74 ms together. A pass that only reads the scene
  and writes another target is cheap on this GPU; the blur's cost is its
  taps, about 0.6 ms for the half of the frame that moves, and neither
  fewer taps for short streaks nor wider spacing changed that by more than
  0.1 ms. What is saved at 100% is the paint's quarter millisecond and
  40 MB of target.

Side by side on still views of Alpine 1, 85% through the new filter is as
sharp as 85% through MetalFX and close to native; at 67% MetalFX holds
painted lines a little crisper.

## The blur's long streaks, from a half-resolution copy

A streak of more than a few pixels is gathered from a copy of the scene at
half its size each way, with four taps where the scene took eight. Streaks
under four pixels stay on the scene; between four and eight the choice is
dithered per pixel.

The saving is not where it was expected. A tap costs the same from either
texture, in a 64-bit or a 32-bit format: this GPU's cost is per filtered
sample, not per byte fetched. With all eight taps on the copy the tonemap
pass fell from 1.74 to 1.67 ms and the copy's own pass cost 0.24 ms, a net
loss. The copy pays only because its texels are already averages of four,
so half the taps cover a streak as closely.

Whole frame, viewpoint at 50 m/s, the same binary with the copy and with
`--full-blur`, two runs each:

| Resolution | Scene only | With the copy |
|---|---|---|
| 100% | 6.56, 6.49 ms | 6.33, 6.34 ms |
| 85% | 5.50, 5.50 ms | 5.35, 5.37 ms |
| 67% | 4.45, 4.47 ms | 4.35, 4.30 ms |
| 50% | 3.80, 3.77 ms | 3.64, 3.62 ms |

About 0.15 ms, 2 to 4% of the frame. The streaks are a little smoother
across their length and otherwise the same picture; the copy is 10 MB at
2880 x 1720.

## The tonemap pass

Most of what the pass cost at full resolution was code it never ran.

It carries paths most frames do not take: the filter that scales a smaller
scene up, the lens blur's mix, the rain on the glass. Each was a branch on
a uniform, and a branch not taken was not free. What in it has no side
effect the compiler works out ahead of the branch, so the filter's weights
were computed for every pixel of a frame at 100%, where there is nothing to
filter. Compiled out one at a time, same frame at 2880 x 1720:

| Compiled out | Tonemap pass |
|---|---|
| nothing | 1.34 ms |
| the rain | 1.31 |
| the lens blur | 1.24 |
| the upscale filter | 1.09 |
| all three | 1.05 |

Marking the filter `noinline`, so that it would sit behind a real call, made
it worse: 1.52 ms. The haze, the glare, the bloom and the motion blur cost
the same compiled out as switched off, and stay as they were.

So the pass is now compiled eight ways, a function constant for each of the
three (`resolveUpscales`, `resolveLensBlur`, `resolveRain`), and a frame
takes the one with exactly the paths it uses (`ResolveVariant`). All eight
are built at launch and kept in the pipeline archive: which one a frame
takes changes with the render scale, in the middle of a race.

The rest is arithmetic, and smaller:

- **AgX**: the sigmoid's polynomial in Horner's form, one clamp ahead of the
  logarithm for a floor before it and a clamp after, `powr` for `pow` where
  the base cannot be negative. 0.72 to 0.66 ms for the bare tonemap.
- **The haze** leaves on the stored depth, before a division and two
  smoothsteps, where the pixel is nearer than 60 m or beyond 1400 m.
- **One noise value a pixel** for the blur's jitter and the dither, which
  were the same expression written twice.

| Resolution | Frame before | Frame after | Tonemap before | Tonemap after |
|---|---|---|---|---|
| 100% | 6.23 ms | 5.82 ms | 1.46 ms | 1.05 ms |
| 100%, standing | 5.93 | 5.65 | 1.17 | 0.84 |
| 85% | 5.36 | 5.13 | 1.48 | 1.24 |
| 67% | 4.24 | 4.07 | 1.41 | 1.19 |
| 50% | 3.58 | 3.37 | 1.40 | 1.16 |

Below 100% the filter is in use and its variant keeps it; the gain there is
the lens blur, the rain and the arithmetic. Without the dither the pictures
are the old ones to within one level of 255, at every scale.

What the pass costs now, at 100% and 50 m/s: 0.49 ms to read the scene,
tonemap it and store it, 0.37 for the blur, 0.12 for the haze, 0.07 for the
bloom, 0.01 for the glare.

### The dither was in the wrong place

Sharing the noise showed it. The dither was added to the linear value, after
the decode, and the target encodes on write. Half a level of linear light is
a fifth of a display level near white and seven levels in the shadows, where
the encoding is steepest. Measured from frames with and without it:

| Display level | Dither before | Dither after |
|---|---|---|
| 1 to 10 | up to 8 levels | 1 |
| 10 to 40 | up to 8 | 1, rarely 2 |
| 40 to 160 | up to 3 | 1 |
| above 160 | 1 | 1 |

It is now added to the encoded value, before the decode: half a level
either way at every brightness, black left black. The dark parts of the
picture lose a grain they were not meant to have. This is the one change
here that alters the picture.

### Tried and not kept

- **A lookup table for the tonemap.** A sample costs the same wherever it
  lands: the bloom's, taken at one fixed coordinate for every pixel, cost
  the 0.13 ms it costs across the frame. A 3D sample is at least that, and
  the arithmetic it would replace is 0.25. At 32 entries a side the table
  also strays by more than a level on saturated colours.
- **The look's power folded into the sigmoid's polynomial.** It needs a
  seventh order to stay within a level, which is the cost of the power.
- **The blur's taps from a start and a step** worked out ahead of the loop,
  and no blur under a one-pixel streak: neither moved the pass by 0.01 ms.
  The taps are the cost, not the arithmetic around them.

## The bloom's prefilter, from the blur's copy

When the blur has made its half-resolution copy of the scene, the bloom's
prefilter reads that instead of the scene. The prefilter takes the mean of
a four-by-four box for each pixel of the pyramid's first level, four
bilinear taps on the scene. A texel of the copy is already the mean of two
by two, so the same box is one tap at the corner four of them share, from a
quarter of the memory. For that the copy is no longer clamped as it is made;
the blur clamps its taps from it, as it always did those from the scene.

Whole frame at 2880 x 1720 and 50 m/s, the same binary reading the scene and
reading the copy, four runs each, medians:

| | From the scene | From the copy |
|---|---|---|
| CG Speedway 1, 100% | 5.95 ms | 5.77 ms |
| 85% | 5.11 | 5.04 |
| 67% | 4.05 | 3.99 |
| 50% | 3.36 | 3.31 |
| 100% with reflections | 7.22 | 7.09 |
| Alpine 1, 100% | 6.69 | 6.50 |
| Street 1, 100% | 6.12 | 5.97 |

The pictures are the same to within one level of 255. Without motion blur
there is no copy and the prefilter reads the scene as before.

**The exposure meter stays on the scene.** It was to move as well, and its
own timer fell from 0.17 to 0.04 ms when it did, but the frame grew by
0.04 ms, five runs against five:

| Meter reads | Prefilter reads | Frame |
|---|---|---|
| scene | scene | 5.88 ms |
| scene | copy | 5.74 |
| copy | scene | 5.92 |
| copy | copy | 5.79 |

The meter takes 4096 samples whatever it reads, so there was no memory to
save; where it sits relative to the copy's pass made no difference either.
The lesson is about the timers: a pass's time is the span between two
samples of the GPU's clock, passes overlap, and the spans do not add up to
the frame. The meter's 0.17 ms was mostly another pass's work. A change is
costed on the whole frame, interleaved with its baseline.

## The scene pass, compiled for each material

The scene's shader is bound by its arithmetic: a handful of operations at
every pixel of 2880 x 1720 is two or three hundredths of a millisecond. Five
things came out of it, none of which changes the picture by more than a
level of 255.

**Paths a draw does not take.** The shader carries the leaf's lighting, the
clear coat, the road's paint and the weather as branches on a draw's flags.
Each costs every draw, as in the tonemap pass. Compiled out one at a time:

| Compiled out | Scene pass, CG Speedway 1 | Alpine 1 |
|---|---|---|
| nothing | 2.62 ms | 2.69 ms |
| cloud cover | 2.55 | 2.62 |
| the clear coat | 2.50 | 2.56 |
| the leaf | 2.48 | 2.57 |
| the three, and wet ground | 2.32 | 2.36 |

The clear coat and the leaf were tried with the code left in and the flag
never set, and cost what they cost before: it is their presence. The leaf is
three lines, a normal flipped on a back face, a tint and a transmission.

So the scene pass has a function constant for each (`forwardFoliage`,
`forwardClearcoat`, `forwardRoadPaint`, `forwardWeather`) and a pipeline for
every combination with the cutout and the blend, sixty-four in all
(`ForwardVariant`). A draw takes the one for its material and the frame's
weather. All are built at launch and kept in the pipeline archive. With
nothing cached, the renderer's pipelines now take about two seconds to
compile on this machine, once for each version of the shaders; after that
they are read back.

**The road's paint**, where it does run, was about 0.2 ms. Every line is a band
about a centre, and the paint is the nearest band: one signed distance and
one smooth step where each of four lines took its own. The rubber's core is
now its halo to the sixth power, one exponential for two and a core a
thirtieth narrower than it was. And what varies only
along the lap, over fifty metres and more, is taken at the vertices: three
of five sines. 0.07 ms less.

**The shadow lookup** was 0.58 ms, the dearest thing in the shader:

| | Scene pass |
|---|---|
| as it was | 2.24 ms |
| without the division by w | 2.20 |
| and the cascade counted, not searched | 2.17 |
| with the cascade fixed (a floor, not a picture) | 2.10 |
| one tap for four (not a picture either) | 2.12 |

The light is parallel, so w is one. The cascade was found by a loop with an
early exit. And each pixel read its cascade's whole matrix from wherever its
index said. The cascades are one view of the world at four sizes and
places, so now one matrix serves every pixel and the cascade's index picks
two vectors, a scale and an offset from the first cascade to its own map
(`cascadeScale`, `cascadeOffset`, computed in double precision). That needs
the four to look along one light: a slice kept from an earlier frame while
the sun moved would not, so a moved sun refreshes every slice
(`ShadowCascades.shareOrientation`). 0.09 to 0.13 ms less.

**The sky's irradiance** was nine harmonics summed term by term for every
pixel. They add up to a quadratic in the normal, so the kernel that projects
the sky now stores that quadratic and the shader evaluates it nested: nine
multiply-adds of a colour. About 0.05 ms less. A test holds the two forms
equal.

**The environment term**, with its exponential, was taken three times a
pixel: by the sun's lobe for its energy compensation, by the sky's, and by
the weight the reflections are composited with. Once now (`SurfaceView`),
with the reflectance and the angle they also shared. 0.08 to 0.11 ms less.

The previous commit and this one, built side by side and run alternately,
medians of five, at 50 m/s:

| | Frame before | Frame after | Scene before | Scene after |
|---|---|---|---|---|
| CG Speedway 1, 100% | 5.90 ms | 5.32 ms | 2.62 ms | 2.05 ms |
| 85% | 5.13 | 4.67 | 1.96 | 1.51 |
| 67% | 4.00 | 3.82 | 1.25 | 0.99 |
| 50% | 3.37 | 3.18 | 0.75 | 0.59 |
| 100% with reflections | 7.73 | 6.99 | 2.96 | 2.28 |
| Alpine 1 | 7.09 | 6.17 | 2.91 | 2.12 |
| Street 1 | 6.34 | 5.72 | 2.71 | 2.06 |
| E-Track 3 | 6.57 | 5.63 | 2.74 | 2.04 |
| Forza | 8.12 | 6.91 | 2.92 | 2.09 |

The machine was warm from building both; the pairs are fair to each other
and a few percent above the tables earlier in this document. The pictures
agree to within one level, but for one pixel on a shadow's edge in one view
of Alpine 1.

### Tried and not kept

- **Arithmetic by hand**: Fresnel's fifth power as multiplications, the sun's
  direction not normalised again, the view depth from the fragment's w,
  the lamp's state flat across a triangle, the motion vector from three
  components of clip space for four. None moved the pass. The compiler had
  them already.
- **The shadow disc turned by a parabola** for a sine and a cosine, and the
  inner taps left out: nothing either. The cost is the first four taps and
  what leads up to them.
- **The cascade's matrix chosen by comparisons** instead of an index:
  0.1 ms worse.
- **The sky**: its whole shader is under a tenth of a millisecond of the
  pass.
- **Less anisotropy**. The albedo at 4 for 8 is 0.07 ms and at 1, 0.13; the
  detail maps at 1 for 2, 0.05. Those are the road's sharpness at a
  distance, a setting and not a saving.

## What is left

The scene pass is 2.05 ms of 5.3. What it costs now, in the order it was
measured: the shadow lookup about 0.45 ms, the normal map 0.22, the
roughness map 0.13, the albedo's anisotropy 0.13, the sky's light 0.3, the
sun's 0.2, the occlusion's sample 0.13 and the road's paint 0.13. The normal and roughness maps could share one texture, which is
a change to the materials and not to the shader. The tonemap pass at
1.05 ms is near what its features cost. The sky's tables are recomputed
whenever the camera's height changes by ten centimetres, three small passes
that a wider tolerance would mostly spare. The HUD costs
about a fifth of the main thread through SwiftUI layout at twenty updates a
second, which matters to nothing while the GPU is the limit.
