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
the last second — and the GPU's span for a frame, once a second while a
session runs. Its ladder, lightest first: the fanless preset at 50, 67, 85
and 100% resolution (scaled up by the spatial scaler), then balanced, then
high. Three slow seconds in a row move it down a rung; twenty steady seconds
with the GPU under half its interval move it up one, a rung that then fails
is not tried again, and it never climbs above the machine's ceiling (high for
Max and Ultra chips, balanced for Pro, fanless otherwise). A base chip starts
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
  [--render-off a,b]` times a frame's passes offscreen.
- `--render-off` switches effects off in the window as well.

## What is left

**The window's own cost is unexplained.** The same frame takes 8.5 ms
offscreen and 13.1 ms in the window, paced or not. The suspect is the system
compositing a full-resolution game layer with the HUD's layers over it every
frame, which also rules out direct display in full screen. The experiment is
ready — `--autoplay … --fullscreen` and `--no-hud` under `TORCS_PASS_LOG=1`,
at a fixed preset — but needs the display on, and it went to sleep before the
runs: they presented no frames. If full screen without the HUD's layers
comes back near the offscreen figure, drawing the HUD inside the frame is
worth about a third of the frame, and native resolution would hold 60.

The forward pass is half the remaining frame and was not touched: its shader
carries another line of work's uncommitted changes. The full-resolution chain
after it — reflection composite, motion blur, tonemap — is three passes that
each read and write the whole HDR target and could be one. The HUD costs
about a fifth of the main thread through SwiftUI layout at twenty updates a
second, which matters to nothing while the GPU is the limit. None of this was
needed to reach 60, and all of it is where the next milliseconds are.
