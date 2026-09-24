# TORCS 1.3.9 architecture study

Inspected against the release archive pinned in UPSTREAM.md on 2026-09-22.
All paths below are relative to that upstream tree.

| Subsystem | Upstream implementation | Native replacement |
|---|---|---|
| Lifecycle | `src/linux/main.cpp`: platform initialization, `TorcsEntry`, GLUT event loop; `-r` selects `ReRunRaceOnConsole` without graphics/audio | SwiftUI App, AppKit, separate CLI |
| Race state | `src/libs/raceengineclient/racestate.cpp`, `racemain.cpp`, `raceengine.cpp` | TORCSRaceEngine, later |
| Physics | `src/interfaces/simu.h` function table; `src/modules/simu/simuv2` owns mutable `tCar` array | TORCSSimulation |
| Car | public `src/interfaces/car.h` versus private `simuv2/carstruct.h` | immutable definitions, value state and snapshots |
| Track | `src/modules/track/track*.cpp`, `src/interfaces/track.h`: linked main segments, sides, borders, barriers, surfaces and pits | TORCSTrack |
| Track queries | `src/libs/robottools/rttrack.cpp` | explicit geometry utilities |
| Parameters | `src/libs/tgf/params.cpp`, `params.dtd`: nested named sections, numeric/string attributes, units, merge handles | TORCSConfiguration |
| Graphics | `src/interfaces/graphic.h`, `src/modules/graphic/ssggraph`: PLIB scene graph/OpenGL | TORCSMetal |
| Robots | `src/interfaces/robot.h`, `src/drivers`: newTrack/newRace/drive/pitCmd/endRace/shutdown callbacks | snapshot-based TORCSRobots, later C bridge |
| Audio | `src/modules/graphic/ssggraph` sound interfaces, OpenAL/PLIB backends | TORCSAudio, AVAudioEngine |
| Input | `src/libs/tgfclient`, human driver, GLUT/joystick | native actions and GameController |
| Modules | `GfModLoad`, platform implementations, shared library interface tables | static Swift targets initially; explicit legacy ABI later |
| Results | `raceengineclient/raceresults.cpp` | native race results plus compatibility export |

## Timing and precision

`raceman.h` defines `RCM_MAX_DT_SIMU=0.002` (500 Hz) and
`RCM_MAX_DT_ROBOTS=0.02` (50 Hz nominal). `ReOneStep` advances a double
simulation time, dispatches drivers based on elapsed time, then calls physics
and manages cars/race order. Robot scheduling uses floating elapsed-time
comparisons, so exact callback ticks must be measured before replacing this
with a simple modulo counter. A render frame can encompass multiple steps.
`tgf.h` defines `tdble` as **float**, not double. Preserve Float state and
operation order; keep time in Double or integral ticks. Do not silently enable
fast-math. Reference harness compilation disables floating point contraction.

## Coordinates

World X/Y are the ground plane, Z is up. Car X is forward, Y is left, Z is up.
Yaw is about positive Z. Distances are metres, mass kilograms, time seconds,
angles radians; engine angular speed is radians/second despite RPM names.
Wheel indices: front right, front left, rear right, rear left. Track `toStart`
is **metres on straights and radians on curves**; `toMiddle` is positive left,
`toRight` measures from the right edge. Keep that distinction at compatibility
boundaries. Metal may keep Z-up world coordinates and transform only in camera
and projection matrices (depth 0…1).

## Configuration and filesystem

Upstream separates library, shared data and local user directories (`-L`, `-D`,
`-l` command options). Linux user files live under `~/.torcs`; races store XML
under `results/<race>/results-YYYY-MM-DD-hh-mm-ss.xml`. Windows has separate
platform paths. The native app uses Application Support/TORCSMac and atomic
configuration writes. Imported source content must remain immutable.

The XML parser normalizes numeric values to SI using Float; unknown unit tokens
have factor one. A slash puts all following tokens in the denominator; a dot
does not reset it. Missing min/max default to the value, and bounds expand to
include it. Track files use external entities for default surfaces and objects;
these must be resolved through an explicit local-content allowlist, not network
or unrestricted XML entity loading. Config merges are not ordinary dictionary
replacement: range and permitted-string reconciliation need separate tests.

## Migration decision

Start with executable original subsystem functions and native regression tests.
The reference target is test/tool-only and is never linked into the app. The
first oracle covers suspension check/update, brakes and Ackermann steering.
The expanded oracle now runs full `SimUpdate`, original track construction and
SOLID collisions. Race scheduling and robot execution still need reference
integration. A Metal inspection
scene is a diagnostic tool and must not be described as a playable simulator.
Use one SPM manifest with only targets that have actual implementations.
