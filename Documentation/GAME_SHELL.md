# The game shell

The application used to open as a desktop document window: a toolbar of
buttons, a file dialog to pick a session folder, a sheet to configure a run.
It now opens as a game. One window, a start screen, and the screens a racing
game has: mode, circuit, car, options, loading, the race with a HUD, a pause
menu, results, settings, controls and credits.

## Content: from folders to circuits and cars

A prepared session is still a folder pairing one track with one car (see
[driving session](DRIVING_SESSION.md)). The game no longer asks for the
folder. `ContentLibrary` in `TORCSRaceEngine` scans the folders the player has
added, finds every `driving.json` to a bounded depth (never descending into a
session, a hidden folder, or past three levels, so a careless root such as the
home folder stays a bounded walk), and describes each session without loading
its models:

- `TrackDescriptor` — the track header's name, category, author and
  description, the built road's length and width, and a `TrackMap`: the
  main-segment centreline fitted into the unit square, with a mid-arc point
  on longer curves so the outline bends rather than folds. The menus draw it.
- `CarDescriptor` — the car document's name, the category document's name,
  mass, forward gear count and rev limit (in rpm; the parameter store keeps
  rad/s).

Sessions of the same track/car pairing collapse to one; the menus list the
circuits and, for each, the cars prepared on it. A folder that cannot be
described is reported under Settings › Content rather than emptying the
menus. The folders and the last pairing driven are kept in
`library.json` beside the other settings in Application Support.

`--content DIR` adds a folder for one launch without saving it.

## The flow

`GameFlow` owns the screen, the plan (mode, circuit, car, laps, opponents,
grid order, conditions), the library and the race weekend. Screens are plain
SwiftUI views over it. Keyboard navigation is the menu's: arrows move the
selection, Return activates, Escape goes back, and the same keys work with
the mouse.

- **Training** is the single-car practice runtime.
- **Qualifying** is a race weekend. The player qualifies first (car 0 of the
  field). Each opponent's run is then simulated headless
  (`QualifyingSimulation`: one BT entry alone on the circuit, stepped as fast
  as the machine allows, with progress on the results screen) and recorded
  into the same `RaceWeekend` the original sequence uses. The results screen
  shows the grid as it fills, and *Set Up the Race* carries the ranking into
  a race whose grid option is the qualifying order.
- **Race** lines the field up from the drivers list with the player on pole,
  or from the qualifying order or its reverse when the same circuit, car and
  field have qualified. The weekend is reset whenever the field or pairing
  changes, because a ranking only describes the field that set it.

An opponent's grid time is its **fastest lap, valid or not**. The BT policy
rides the curbs on circuits such as Aalborg, which the original's corner-cut
rule invalidates on every lap; ranked on valid laps alone every opponent
would have set no time. The results screen says so.

Conditions (dry, wet, overcast, rain) are the renderer's visual conditions;
grip is unchanged, as the options screen states.

## The race screen

The renderer fills the window. Over it:

- **HUD** — session kind, circuit and car; lap and position; current, last
  and best lap in timing-screen form; a rev-counter arc with the speed, the
  gear and the requested gear, fuel and damage; the live classification (the
  top eight and the player's row) in a race; and centre messages for the
  countdown (Ready, Set, Go!), an invalid lap, penalties to serve, catching
  up and the end of the session.
- **Pause** — Escape pauses and opens the menu; Escape or *Resume* continues.
  Restart, camera (‹ › through every preset plus zoom), settings and
  controls as panels over the paused session (the renderer is not rebuilt),
  telemetry recording outside a race, end session, quit to menu. Losing the
  window's focus pauses as before.
- **V** steps through the driving views while driving; ⌘V does the same
  from the Game menu.
- **Loading** — the circuit draws itself while content loads, and again
  while the renderer prepares its first frame; the countdown starts on that
  first frame rather than on a Start button.
- **Results** — over the frozen scene: the classification (race) or the lap
  sheet (training, qualifying) with the best lap, session time, fuel and
  damage; Save Results; Drive/Race Again; Change Setup; Main Menu; and for
  qualifying the field's progress and the grid.
- A runtime error stops the session and shows it with a way back to the menu.

## Settings

Display (60/120 Hz presentation, the render quality preset — fanless,
balanced, high — applied to the next session, full screen), driving view
(mirror, standings on the HUD, default camera) and content (folders, add,
remove, rescan, warnings). Controls is the existing bindings and controller
calibration editor as a screen. About holds the credits and the key summary.
The menus use the game's own chips and arrows rather than the desktop's
pickers, so the same screens draw under the offscreen renderer used for
screenshots.

The component lab and the model inspector remain under a Developer menu.

## Verification

- `ContentLibraryTests`: a session folder describes to the expected track
  (Aalborg, road, 2.59 km, its author) and car (Alfa Romeo 155 DTM,
  1115 kg, six gears, 12 500 rpm); the map is closed, inside the unit square
  and fills its longer side; a scan groups duplicate pairings, skips hidden
  and nested-in-session folders and the fourth level, reports a broken
  session and a missing root, and the preferences round-trip. A one-lap BT
  qualifying run on Aalborg completes headless in about 45 000 ticks with a
  fastest lap near 88 s and no valid lap, repeats exactly for the same seed,
  and stops on cancellation.
- `--screenshot PATH [--screen NAME] [--size WxH]` renders a screen offscreen
  to a PNG once the content scan is done; `--screen hud --backdrop PNG`
  loads the pairing and draws the HUD over a captured frame, `--paused`
  adds the pause menu. Every menu screen, the HUD and the pause menu were
  rendered this way and inspected.
- `--autoplay SECONDS [--autoplay-race]` starts a training session or a
  three-car race on the first pairing through the real window path and quits
  0 once the countdown has run and the clock passed two seconds: the loading
  veil lifted on the first frame, the session was sent off, pause and quit
  to menu unloaded it. Both ran green on the Artifacts content (about 33 s
  to the first frame in a debug build).

## Boundaries

- No controller navigation of the menus; keyboard and mouse only. The
  controller drives once a session is running, as before.
- No car preview image: the car screen shows a glyph and the car's numbers.
  No per-car livery in the field, as recorded in [field rendering](FIELD_RENDERING.md).
- Opponents' qualifying is simulated in turn, not in parallel; on a debug
  build a lap takes several seconds, on a release build less.
- Championships, replays and audio remain open, as in [gameplay](GAMEPLAY.md).
