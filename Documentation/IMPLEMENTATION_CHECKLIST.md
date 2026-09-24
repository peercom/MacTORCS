# Implementation checklist

The original specification is the scope. A checked phase requires its finish
condition, not merely files or placeholder types. See PORT_STATUS.md for evidence.

Current user priority: finish gameplay; defer foliage and further visual experiments.
The concrete session/race work is tracked in GAMEPLAY.md. Native BT single-car
progress and its limits are recorded in NATIVE_BT.md; Phase 11 stays open until
its complete race/compatibility finish condition is demonstrated.

- [x] Phase 0: inspect upstream lifecycle, subsystem interfaces, timing and content.
- [ ] Phase 1: deterministic full upstream race harness and 15 scenario families.
- [ ] Phase 2: native app lifecycle, Metal, independent clocks, input, settings.
- [ ] Phase 3: upstream coordinate transforms and measured precision.
- [ ] Phase 4: car/track/race/robot XML, units, constraints and merge parity.
- [ ] Phase 5: full original track topology, surfaces, elevation, pits and queries.
- [ ] Phase 6: provenance-aware legacy mesh compiler and runtime binary loader.
- [ ] Phase 7: track/car Metal rendering, cameras, lighting, effects, HUD, mirrors.
- [ ] Phase 8: subsystem physics port with bounded upstream divergence.
- [ ] Phase 9: keyboard/controller driving, bindings and calibration.
- [ ] Phase 10: practice/qualifying/races, pits, penalties, results and championships.
- [ ] Phase 11: reference robot compatibility and native snapshot API.
- [ ] Phase 12: commands/seed/content-hash deterministic replay.
- [ ] Phase 13: state-driven spatial native audio.
- [ ] Phase 14: all core modes configurable through native UI.
- [ ] Phase 15: validated, transactional user content importer.
- [ ] First slice: human drives original car/track for five timed laps.
- [ ] Second slice: human/AI, collisions/pits, deterministic ten-lap race.
- [ ] Full content: automated redistributable content compatibility report.
- [ ] Distribution: Developer ID, hardened runtime, notarization, clean build.
- [ ] Quality: rendering checks, repeated races, Instruments memory/performance.
- [ ] Licensing: all shipped code/assets reviewed and provenance retained.

Cross-cutting: fixed 500 Hz simulation independent of render refresh; no renderer
state authority; no fake dynamics; maintain tests and status after every step.
