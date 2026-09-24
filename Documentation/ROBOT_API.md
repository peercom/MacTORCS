# Robot API migration

The original BT robot now runs in the **reference-only** harness with original
simuv2 physics and `ReOneStep`/`ReManage`/`ReSortCars`. A native Swift BT single-car driver and bounded native race runtime now exist;
see [native BT](NATIVE_BT.md) for its API and measured scope. Legacy binary-module
compatibility and opponent handling remain unimplemented.

The selected fixture is BT index 0, its pinned empty default setup, 155-DTM,
and Aalborg. Initialization calls original newTrack/newRace, sets original
race rules and prestart settling, then drives at the original scheduler's
callback intervals. Placement is a diagnostic centerline start 10 m before
the line; this does not verify the original grid builder. Original driver
learning writes stay inside an isolated temporary content directory. Shutdown
restores data/local roots and closes the original driver.

```
.build/release/torcs-reference --robot bt --fixtures Tests/UnitTests/Fixtures \
  --laps 1 --max-ticks 120000 --summary Artifacts/bt-lap.json
```

Optional `--commands` streams each callback's 142 input physics fields, five
raw output controls, and callback time/delta/count. `--telemetry` streams all
physics ticks. Envelope time is tick × 0.002; original race time, including
prestart, is separately recorded in callback values/summary. A maximum-tick
run may be partial: always inspect `completed` in the summary. This tool is a
bounded capture harness, not a general robot module loader.

On this machine two fresh release runs finished the physical lap at tick
44,694, 87.38799999997774 s, with 4,211 drive calls (the lap was marked invalid by original rules) and identical callback digest
`76d40a78927e1288e6b704313814680043ac1ff67eb25eb30eadbb054ae86cd0`.
The debug C++ build instead consistently finishes at tick 44,617,
87.2339999999781 s, 4,204 calls. The latter repeats both in isolation and after
short in-process driver restarts. This is an unresolved original-driver build
configuration sensitivity; do not compare native code against mixed build
baselines or claim native robot parity. Finding its first divergent arithmetic
operation remains follow-up work. Tests explicitly retain both baselines.

Short in-process restarts compare all 142 inputs and sampled raw controls/time
exactly over 3,000 ticks each (239 callbacks). The native driver now matches every raw command and learned-radius record on
the selected release reference lap. Traffic, complete race modes and integrated
UI racing remain pending; longer native and pit runs are tracked in NATIVE_BT.md. The current user priority is finishing gameplay, including native AI and race
integration. Foliage and further visual experiments are deferred; physical
GameController validation remains lower priority.

The native contract retains a bounded single-car drive/pit path. The complete
future robot contract should retain newTrack, newRace, drive, pitCmd,
endRace and shutdown, callback timing, and per-driver state. Drivers should
receive immutable snapshots and return commands; a C ABI adapter must own its
copied structures and make no Swift memory-layout assumptions.
