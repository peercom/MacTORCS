# Track definition versions

TORCS dispatches on the version its track XML declares: 0 through 3 to
`ReadTrack3`, 4 to `ReadTrack4`, with no other case. The native port
implemented version 4 only, which rejected seven of the thirty-nine shipped
tracks — including five of the eight dirt tracks, leaving that category
effectively unreachable.

| Version | Tracks | Status |
|---|---|---|
| 4 | 32 | Verified against the original reader |
| 3 | 7 | Six verified exactly; dirt-4 has a known gap |

## The two schemas describe the same road

Segment attributes are identical between them: `type`, `lg`, `radius`, `arc`,
`grade`, `banking end`, `profil`, `profil end tangent`, `z end`, `surface`.

What differs is how sides, borders and barriers are written. Version 3 puts
them in flat attributes on the owning section — `lside width`,
`rborder style`, `lbarrier height` — where version 4 uses a named subsection,
`Left Side/width`. Both take defaults from `Main Track` and allow a per-segment
override, so the *model* is the same and only the spelling changed. Cameras
differ only by an extra `list` nesting level, and the segment list is called
`segments` rather than `Track Segments`.

`TrackVersion3` therefore translates rather than reimplements, and the
version-4 builder — already verified against the original — does the work. A
second geometry implementation would have been 1,600 lines of opportunity to
diverge.

## Verification

Six of the seven version-3 tracks reproduce the original reader **exactly**:
identical segment counts, and zero error in segment length, width and world
position.

| Track | Segments | Length | Width | Position |
|---|---|---|---|---|
| dirt-5 | 585 | 0.0 | 0.0 | 0.0 |
| dirt-6 | 1,431 | 0.0 | 0.0 | 0.0 |
| mixed-1 | 690 | 0.0 | 0.0 | 0.0 |
| mixed-2 | 930 | 0.0 | 0.0 | 0.0 |
| a-speedway | 732 | 0.0 | 0.0 | 0.0 |
| e-track-5 | 1,005 | 0.0 | 0.0 | 0.0 |

The reference harness had its own version-4 preflight — project-authored
instrumentation, not upstream code — which now accepts versions 0 through 4 so
`ReadTrack3` can serve as the oracle. Pinned upstream sources are untouched.

## The dirt-4 gap

dirt-4 is the only version-3 track with a pit lane. It declares
`pit type = "track side"`, and version 4 has no `type` at all.

Its shape comes out correct — segment count, lengths and widths all match
exactly — but the whole track sits 705.5 m away in Y. Every vertex is
translated so the bounding box's minimum corner is at the origin, so a bound
that includes pit geometry the translation does not produce moves everything
uniformly. Measured: the original spans 1515.1 m in Y, the translation 748.5 m.

This is not cosmetic. The visible track is a baked mesh in the original
coordinates, so an origin shift separates the road the driver sees from the
road the physics uses. `prepare-content.py` refuses dirt-4 for that reason, and
`testDirt4PitLaneRemainsAKnownGap` pins the exact signature — including that the
error is a pure translation rather than a shape difference — so any change to it
is noticed.

Closing it means porting version 3's pit-lane construction, which is the part of
`track3.cpp` with no version-4 counterpart to translate onto.

## Two upstream behaviours this uncovered

Both are cases where shipped content depends on the original parser being more
forgiving than the native one was.

**Repeated parameters are not an error.** `GfParmReadFile` appends to a hash
bucket without checking for duplicates and resolves lookups from the head of
that bucket, so the first occurrence in document order wins. dirt-6 declares
`profil` twice in two of its segments. The native parser rejected the file;
it now matches the original and records what it ignored.

**An unresolvable camera segment reference selects segment 0.** The original
looks up the named segment's id with `GfParmGetNum`, which returns its default
of 0 when the name does not exist, then scans for the segment with that id.
a-speedway writes `fov start val="segment s2"` — the value mistakenly includes
the word "segment" and matches nothing. The native builder rejected the track
over a typo in its camera list; it now falls back the same way the original
does.
