# Qualifying results and the starting order

How a race decides who starts where, ported from the original and compared
against it.

## What the original actually does

This differed from the assumption the plan was written on, so it is worth
stating plainly.

- **Qualifying runs one driver at a time.** `racemain.cpp` puts a single driver
  into the racing list for a qualifying session and cycles through the field, one
  session per driver. The existing native solo qualifying is the same shape.
- **After each run the driver is inserted into a ranked list.**
  `raceresults.cpp` walks the existing ranks from last to first, shifting each
  entry down while the new run beats it **or** that entry has no time at all,
  then inserts after the first entry it does not beat.
- **The race grid is not ordered by lap time directly.** It reads a `starting
  order` attribute: `drivers list` (the entry order, and the default),
  `last race` (the previous session's ranking), or `last race reversed`.
  Qualifying feeds a grid by being the previous session that `last race` refers
  to.

Three details decide the outcome and are easy to get wrong:

- Comparison and storage are at **millisecond resolution**: the original compares
  `round(best × 1000)` and stores `round(best × 1000) / 1000`, so a ranked time
  is not the raw lap time it was given.
- A driver with **no time** never displaces anyone, so an empty run lands last
  whenever it arrives — but an entry that has no time is displaced by anyone who
  does.
- Ties **keep the earlier qualifier ahead**, because the comparison is strictly
  less and the insertion happens after the first entry not beaten.

## Measured

`raceresults.cpp` and `racemain.cpp` are now pinned from the archive, whose
SHA-256 and 229 existing files were verified before anything was taken from it.
The qualifying ranking is compiled **verbatim** as
`Upstream/Reference/race/qualif-rank.inc`, extracted byte-exactly from the pinned
results code in the same way as the existing `initPits` and `initStartingGrid`
excerpts, and asserted by `Scripts/verify-provenance.py`.

`ref_race_qualif_rank` runs that excerpt over a sequence of finished runs and
returns the ranked list. The native port matches it across **ten cases**: fastest
arriving first, last and in the middle; a driver with no time arriving first, in
the middle and last; two drivers with no time; an exact tie; a sub-millisecond
difference that the original treats as a tie; a one-millisecond difference that
it does not; and a six-car field inserted in arbitrary order. Name, stored time
and driver index match at every rank.

Release suite: 461 tests, 0 failures.

## Boundaries

- The starting order is ported and tested, but **nothing calls it yet**: a race
  is still started with its entries in the order the caller supplies. Applying an
  order means building the entries in grid order, which belongs with the session
  sequence in the window.
- `racemain.cpp` and `raceresults.cpp` are pinned for provenance and the
  qualifying excerpt is compiled; the rest of those files is not built, and the
  championship points and results-file handling around this code are not ported.
- The original's qualifying flow — one driver per session, cycling the field — is
  not yet driven by the window, which runs a single solo qualifying session.

## The session sequence in the window

`RaceWeekend` holds a weekend over one field: which driver qualifies next, the
ranking built so far, and the starting order a race will use. It follows the
original in qualifying **one driver at a time**, so a field of four means four
qualifying sessions, and it refuses a run out of turn rather than reordering it.
Changing the field size or the grid order starts the weekend over, because a
ranking only describes the field that set it.

**New Session…** offers the grid order — drivers list, qualifying order, or
qualifying reversed — and refuses to prepare a race from a ranking that is not
complete. A race builds its entries in grid order, so the car on pole is the
entry on slot one, and the human keeps its identity wherever it starts.

A finished qualifying session records that driver's best lap into the ranking and
names who is next. A finished race shows a **classification**: every car in
finishing order with laps, the gap or laps behind the leader, best lap, penalty
time, and whether it was eliminated or is unclassified.

Release suite: 465 tests, 0 failures.

### Still open

- **The window only runs the human's qualifying session.** The weekend model
  takes a run from any driver, but the window has no flow yet for watching the AI
  drivers qualify one after another, which is what the original does. Until it
  does, a ranking-based grid can only be completed for a one-car field.
- Championship points and persistence across launches are not implemented; a
  weekend lives as long as the window.
