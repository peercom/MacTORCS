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

## What is left

The tonemap pass is still the second dearest thing in the frame at about
1.5 ms: 0.72 to tonemap and store, 0.5 for the blur, 0.19 for the heat haze
and 0.15 for the bloom. Nothing in it is large enough to be worth another
target. The HUD costs
about a fifth of the main thread through SwiftUI layout at twenty updates a
second, which matters to nothing while the GPU is the limit.
