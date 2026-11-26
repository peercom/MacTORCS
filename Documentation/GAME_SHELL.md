# The game shell

The application used to open as a desktop document window: a toolbar of
buttons, a file dialog to pick a session folder, a sheet to configure a run.
It opens as a game: one window, a start screen, and the screens a racing game
has — mode, circuit, car, options, loading, the race with a HUD, a pause menu,
results, a championship, settings, controls and credits — over a library of
circuits and cars that combine freely.

## Content: circuits and cars, any with any

Prepared content used to be a *session*: one folder welding one car to one
track. The game now reads three kinds of folder:

- a **track package** (`track.json`): the track document, the shared surfaces
  and objects, the compiled scenery and its images;
- a **car package** (`car.json`): the car and category documents, the compiled
  body and wheels, its shadow and light images;
- a **session** (`driving.json`), as before, which reads as both at once.

`DrivingContent.load(track:car:opponents:)` loads any track with any car and
the further car models a field will use; `DrivingContent.load(_:)` on a
session folder is the same call with one folder for both. `CarContent` and
`TrackContent` are the two halves.

`ContentLibrary` scans the folders the player has added, plus the game's own
`Application Support/TORCSMac/Content`, to a bounded depth (never into a
package, a hidden folder or past three levels) and describes each package
without loading its models:

- `TrackDescriptor` — name, category, author and description from the header,
  the built road's length, width and number of corners, a `TrackMap` (the
  centreline fitted to the unit square, with the transform that puts a world
  position on it), and the package's preview image if it has one;
- `CarDescriptor` — a display name (the original's class cars are named after
  their files, so `car3-trb1` reads "TRB1 No. 3"), its class, mass, gears, rev
  limit, peak power from the torque curve, drivetrain, and its preview.

Duplicates collapse to the package with a preview. A package that cannot be
described is listed under Settings › Content rather than emptying the menus.

### Building a library

```sh
python3 Scripts/prepare-content-library.py /path/to/torcs-1.3.9
```

prepares a selection of circuits and cars (or `--all`, or `--tracks a,b`,
`--cars x,y`) into the game's content folder as single packages, copies the
generated material sets once to `<library>/materials` and the original's sound
samples to `<library>/sounds`, and has the game render a menu preview of each
car standing on a real grid and of each circuit from the back of its grid
(`TORCSMac --render-preview car|track <track> <car> <out.png>`). It can be
run again to add to a library. `prepare-driving-session.py` gained the single
package modes it uses (`--track NAME` or `--car NAME` alone, `--preview`).

Run on the local install here it prepared **18 circuits and 22 cars**, about
1.3 GB. Getting every one of them to import took five corrections, each to
what the original accepts:

| Content | What it does | The original | Now |
|---|---|---|---|
| car3-trb1 | `max="350.0.0"` | reads numbers with `sscanf("%g")` | longest leading number |
| corkscrew | a stray `-->` as text in a section | has no character-data handler | text between elements ignored |
| e-track-4 | references `&default-objects;` undeclared | its parser skips it | skipped, with nothing from it |
| brondehach, e-track-6, g-track-1, wheel-2 | vertices no surface references | leaves their UV storage uninitialised, never draws them | zero, never drawn |
| g-track-3, street-1 | `texture "(null)"` | fails to load it, draws untextured | no texture for that layer |

The preparation script also read a commented-out `Light` section as content
(car1-ow1); it now strips comments first. The packages copy textures and
sounds whose per-file attribution is unresolved, so they stay local, as the
sessions did.

## A field of different cars

A race, a qualifying field and a championship can mix car models. The options
screen offers *Your car*, *Your class* (other cars of the player's class,
nearest in power to weight first; a car alone in its class races the nearest
cars of any class instead) and *Any car*. A field holds up to four models.

- `DrivingContent.opponentCars` holds the further models; `renderScenes` puts
  each after the classic eighteen as seventeen in a row (body, four wheels,
  twelve brake parts), and `FieldCar.model` picks the resources.
- `RaceRuntime` already took one definition per entry; the session builds each
  entry from its own model's parameters.
- The race runtime numbers its cars by **grid slot**, not by entrant, so the
  session keeps the grid it built and maps a published car index back to the
  entrant for its name and model. (Before this, a qualifying-order grid
  labelled the standings by slot.)
- Opponents have names (an invented roster), shown in the standings, the
  results and the championship table.

## Modes

- **Training** — the single-car practice runtime.
- **Qualifying** — the player runs first; each opponent's run is then
  simulated headless in its own car and at the chosen difficulty, the grid
  fills on the results screen, and *Set Up the Race* carries it into a race.
  An opponent's grid time is its fastest lap, valid or not: the BT policy
  rides the curbs, which the original's rule invalidates on every lap.
- **Race** — from pole, or from the qualifying order or its reverse when the
  same circuit, car and field have qualified.
- **Championship** — a season in one car against the same drivers:
  three, five, eight or all circuits, shortest to longest; points 10, 8, 6, 5,
  4, 3, 2, 1; each race starts in the reverse of the table, so the player
  starts the first round last. The table breaks ties by wins, then best
  finish, then entry order. A round ended from the pause menu is not recorded
  and can be run again. The season is kept in `championship.json`.

**Difficulty** (easy, medium, hard) is a handicap on the robot drivers:
`RaceRuntime.opponentPace` is the share of the throttle they ask for that
they get — 0.78, 0.9, 1. The original has no such setting; easing the throttle
slows a driver on the straights and leaves its lines and braking its own. On
Aalborg a BT lap goes from 87.7 s to more than a second slower at 0.8.

The player's best valid lap per circuit and car is kept in `records.json` and
shown on the circuit, car and options screens, on the HUD, and as "new
personal best" in the results.

## The race screen

The renderer fills the window. Over it: session, lap and position; current,
last, best and record lap; a rev-counter arc with speed, gear, fuel and
damage; the circuit's outline with every car on it; the standings by name;
five start lights for the original's two-second countdown, then "GO!"; and
messages for an invalid lap, penalties and catching up. Escape pauses; the
pause menu has restart, camera, settings and controls as panels over the
paused session, telemetry, end session and quit. V steps the camera.

The HUD reads a copy of the simulation frame refreshed twenty times a second
(and at once on a phase change). The frame itself changes over a hundred
times a second and is not observed: a view that depended on it was rebuilt as
often, on the thread the renderer draws from.

## Sound

`CarSoundModel` (TORCSPresentation) is the original's per-car sound model
(CarSoundData.cpp): engine pitch from engine speed and the car's scale, a
low-pass that opens with revs and smoothed throttle, turbo spool, tyre skid,
road, grass and curb ride from speed, load and the surface under each wheel,
gear changes and impacts. It is stepped at the original's hundred updates a
second. The slip acceleration and tyre reaction are not published by the
simulation; the static wheel load and a zero slip acceleration stand in.

`GameAudio` plays it: looping samples through a rate unit and a low-pass per
voice, the player's engine and the four nearest opponents' (quieter with
distance), one-shots for gears and impacts, beeps for the start lights and
ticks for the menus. The engine sample is the one the car's document names,
from the library's `sounds` folder; where a sample is missing a generated
stand-in (`SyntheticSound`) plays through the same path, so the game is never
silent. One-shot players are started once and only scheduled onto: starting a
player waits for the audio thread's cycle, which showed up as 5% of the main
thread in a profile, and a car scraping a wall now sounds one impact rather
than one per update. Volume is under Settings.

## Verification

- Unit tests: packages, previews and rivals (`ContentLibraryTests`), a
  two-model content load and heterogeneous race entries, the parser
  tolerances (`ShippedContentToleranceTests`), the sound model against the
  original's formulas and the stand-in samples (`CarSoundTests`), the
  championship and lap records (`ChampionshipTests`), the quality governor
  (`QualityGovernorTests`).
- `--screenshot PATH [--screen NAME]` renders a screen offscreen;
  `--autoplay SECONDS [--autoplay-race] [--autoplay-cars N]
  [--autoplay-measure SECONDS]` runs the real window path and reports the
  frame rate. It must be launched as an application (`open build/TORCSMac.app
  --args …`): a bare binary's window is not on screen and never draws.
- `--autoplay SECONDS --autoplay-season` runs a one-round, one-lap
  championship with the robot policy driving the player's car as well: three
  cars of three models on CG Speedway ran to the flag in 60 s at 60 fps, the
  results came up, the classification went into the table by name (10, 8 and
  6 points), the season completed with its champion, and the check removed
  the season it made.
- Driven and looked at in the real window: the menus with the full library,
  the circuit and car screens, a six-car TRB1 race on Brondehach with four
  car models, the championship set-up, table and first round (the player last
  on the grid, names following the grid), and the pause menu.

## Boundaries

- A game controller works the menus (d-pad through a list, south to choose
  or confirm a screen's main action, east to go back, the menu button to
  resume), but the options screens' individual settings and the pause menu's
  other entries still need the keyboard or mouse, and none of it has been
  tried on a physical controller.
- The sound has not been heard by its author: its numbers are tested and its
  graph runs (16 samples loaded, three engine notes in a three-model race),
  but the mix is by calculation.
- Opponents' qualifying is simulated in turn, not in parallel.
- Replays remain open, as in [gameplay](GAMEPLAY.md). Frame rate is in
  [frame rate](FRAME_RATE.md).
