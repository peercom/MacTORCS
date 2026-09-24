# Track geometry parity

`TORCSTrack` is a native Swift library with immutable indexed topology and no
CReference dependency. `TrackBuilder.buildRoad(parameters:)` constructs version-4
main road, border/side geometry, barriers and static pits directly from the native
XML parameter model.
Reference geometry transfer exists only in TORCSReferenceSupport for independent
query tests; it is never a production content-loading path.

## Implemented behavior

- Ordered straight/left/right segments, changing radii, constant main-track width.
- Linear and Hermite spline elevation profiles, segment subdivision, persistent
  grades and tangents, explicit left/right elevations and banking overrides.
- Original surface defaults/inheritance, friction, rebound, rolling resistance,
  damage coefficient, roughness amplitude and angular wave number.
- Border and side inheritance, level/tangent banking, tapering widths, curb
  profiles, stable main-road ring indices and outward-only side chains.
- Barrier defaults/inheritance, fence/wall/pit-building styles, surface parameters
  and inward normals computed before coordinate translation.
- Pit entry/start/end/exit markers, stall allocation/positions, wraparound lanes,
  pit/speed-limit flags and original pit-distance queries.
- Original 36-sample curve bounds and positive-coordinate translation.
- Local/global transforms with right/middle/left origins; global searches in
  main-road, contact-segment and outer-track coordinate modes.
- Height, width, tangent, distance, contact-surface selection, side-neighbour,
  side-normal and original chord-based road-normal queries.

Straight toStart values are metres; curved toStart values are radians. Queries
preserve upstream extrapolation and side-selection quirks. A road-normal query
is not replaced by the normal of a smoothed mesh. Invalid topology, nonfinite
geometry and unbounded subdivision requests are rejected. Global searches are
bounded to a road-ring traversal; angular normalization rejects magnitudes over
65536 radians rather than allowing a pathological loop.

## Evidence and reproduction

```sh
swift test --filter TrackGeometryTests
swift test -c release --filter TrackGeometryTests
swift test --scratch-path .build/asan --sanitize address --filter TrackGeometryTests
```

The independent C++ oracle is unchanged rttrack.cpp/track4.cpp. Instrumentation
exposes original geometry and calls the original queries. Native construction is
compared separately, directly from XML, against that geometry.

- Aalborg: all 371 main segments, 1123 total road/border/side segments, track length
  and bounds; 66,292 numeric geometry/surface/barrier/pit values plus names and
  topology, all 742 barriers and 16 pit stalls.
- Aalborg query sweep: 50,535 local positions and 70,119 global searches,
  including segment boundaries, forward/backward search, lateral extrapolation,
  all position modes and all lateral origins.
- Authored synthetic fixture: 197 segments, 11,088 construction values and 3,152
  query samples. Covers changing radii, >180-degree turn definition, linear and
  spline profiles, independent left/right tangents, inherited grade, tangent/level
  sides, zero-width side transitions, rough curbs and rough road surfaces.
- Eight additional infrastructure fixtures: both pit sides, wrapped/unwrapped
  lanes, missing markers, barrier material/height inheritance and fence-to-wall
  transitions. All geometry, barrier values, pit positions and race flags compare.
- 6,810 pit-distance queries across all main segments/stalls in enabled fixtures.
- Invalid-definition/topology tests exercise early rejection and bounded search,
  including zero/excessive pit allocation and absent pit-lane surfaces.

The test compares scalar values at the existing threshold
`1e-5 + 1e-6*abs(reference)`; observed maximum error is reported independently,
including values below that threshold. The selected debug/release results are
recorded in `track-parity-report.json`; no cross-build bit identity is asserted.

## Floating-point investigation

An initial release build differed by up to 0.00006103515625 m while debug matched
exactly. Both optimizers keep ordinary arithmetic unfused, but Clang's original
loader used only Apple's paired `__sincosf_stret` routine; the initial Swift port
also emitted standalone sinf/cosf calls. A direct system-library probe confirmed
that these routines can differ by one Float ULP. For example, at angle
-3.9269914627075195, standalone cosf returned -0.7071062922477722 while the paired
routine returned -0.707106351852417.

The native loader now retains sine/cosine as one non-inlined pair, allowing the
release compiler to preserve the original paired math. Its optimized object
references only the paired routine. Debug still uses ordinary unoptimized math,
as does the debug reference. This removed all observed construction differences
in both fixtures. The oracle and acceptance tolerances were not changed.

## Remaining boundaries

This is tested version-4 geometry/infrastructure coverage, not full Phase 5 or
whole-content compatibility. Camera/scenery metadata and versions 0–3 remain
unimplemented. All loaded raceFlags are now included in constructor comparison.
Pit occupancy, driver assignment, service operations and enforcement of speed
limits belong to the race engine and are not implemented by the static loader.

The native pit loader preserves original conventions: a missing marker disables
the lane; changing a fence back to a wall without an explicit width retains zero
width; pit stall toStart is stored in metres even on curved subdivisions, and
RtDistToPit subsequently applies its radius conversion. These quirks are covered
by oracle tests instead of silently corrected. Invalid dimensions or missing side
surfaces that would cause unsafe legacy behavior fail explicitly in native code.

No mesh/textures are imported or rendered from this geometry yet. Wheel ride
contact now has separate coverage in PHYSICS_PARITY.md. Tire forces, car physics,
race logic and full-track driving still require their own reference comparisons. Exact results here apply to the pinned fixtures,
Apple Silicon and tested Xcode/Swift build, not every upstream track/platform.
