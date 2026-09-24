# Streaming telemetry comparison

`torcs-diff` now compares JSONL captures sequentially. There is no total input-size
limit in this command. Reading and metric accumulation retain one record from each
input plus per-field aggregates. Requesting a report streams all divergence samples
to disk; it does not accumulate a race's history in memory.

```sh
swift build -c release --product torcs-diff
.build/release/torcs-diff reference.jsonl candidate.jsonl \
    --abs 0.00001 --rel 0.000001 --report comparison.json
```

Exit codes remain 0 for parity within tolerance, 1 for measured divergence, and 2
for invalid input, incompatible captures or IO failure. Invalid input never replaces
an existing report. A valid comparison outside tolerance does produce a report.
The output path must differ from both input files, including symlink/hardlink aliases.

## Alignment and limits

The comparison preserves the existing strict rules: schema 1, identical scenarios,
identical field sets throughout both captures, matching tick/time pairs, nonnegative
strictly increasing ticks and finite nonnegative strictly increasing times. Missing
or extra records fail. It performs no interpolation, field dropping or decimation.
Field values, absolute errors and relative errors must be finite. A diagnostic
relative error uses `max(abs(reference), 1e-30)` as its denominator; acceptance uses
`abs(error) <= absTolerance + relTolerance * abs(reference)`.

Individual raw JSONL records have a 16 MiB limit checked before decoding. Reads use
64 KiB chunks; UTF-8 characters and records may span chunks. LF and CRLF are supported,
empty lines are ignored, and a final record need not end with a newline. Parse
errors report physical line numbers. This boundary is independent of the total
capture length and is comfortably above the selected 161-field driving records.

Foundation IO/encoding temporaries are drained in per-record autorelease pools.
A headless loop otherwise retained read buffers until a later pool drain; the
large-file measurement caught that behavior before this change was accepted.

The original array APIs (`TelemetryIO.read` and `TelemetryDiff.compare`) remain
available for small tests/callers. `TelemetryIO.read` retains its 128 MiB guard;
`torcs-diff` no longer calls it. `TelemetryReader.next` is the sequential reader
and `TelemetryDiff.compareFiles` is the streaming API. Both callers must supply
finished, stable captures; comparison does not take a filesystem snapshot of files
being concurrently modified.

RMS uses a scaled online sum of squares to avoid overflow/underflow from squaring
large/small errors directly. Maxima, failure counts, first divergent tick and
individual errors retain the original arithmetic. RMS may differ in the last few
bits because online rescaling changes the summation order. The authored numerical
test compares it to the existing array algorithm at a 2e-14 relative tolerance,
including magnitudes near 1e-200 and 1e200; this tolerance is not a physics threshold.

## Report schema 2

New CLI reports explicitly use schema 2. Summary fields retain their names:
`passed`, `records`, `absoluteTolerance`, `relativeTolerance`, and `fields` containing
`maximumAbsolute`, `maximumRelative`, `rms`, `failures`, and optional
`firstDivergentTick` for each channel. Divergence is now stored by tick at the top
level rather than as arrays inside each field:

```json
{
  "schema": 2,
  "divergenceLayout": "by-record",
  "divergence": [
    {"tick": 1, "time": 0.002,
     "fields": {"car.0.fuel": {"absolute": 0, "relative": 0}}}
  ],
  "passed": true,
  "records": 1,
  "absoluteTolerance": 0.00001,
  "relativeTolerance": 0.000001,
  "fields": {
    "car.0.fuel": {"maximumAbsolute": 0, "maximumRelative": 0,
                   "rms": 0, "failures": 0}
  }
}
```

Consumers plotting an individual channel should read
`divergence[i].fields[channel]` with that row's tick/time. No zero-error samples are
omitted. Historical reports and the small-array API's per-field divergence layout
are unchanged. Schema 2 avoids one temporary file or open descriptor per channel,
which would scale poorly with many cars. Complete reports can themselves be large;
read them sequentially when necessary. Without `--report`, only the small aggregate
result and console summary are produced.

## Verification

Five focused tests cover chunk sizes down to one byte, UTF-8/CRLF/final lines,
record-size boundaries, strict alignment and malformed-tail rejection, every
sample in a 1,000-record/five-field report, atomic publication and input aliases.
The unchanged three telemetry tests remain regression checks of the array API.

`Scripts/verify-streaming-telemetry.py` generates authored diagnostic captures
larger than 128 MiB, compares equal captures, introduces one late divergence and
checks every report value. It also checks invalid-tail publication and records
fresh-process peak RSS using `/usr/bin/time -l`. Large temporary files are removed
after validation; compact metrics/hashes and process logs remain under
`Artifacts/streaming-telemetry`. This tests IO and comparison, not physical laps.
Process RSS is a bounded diagnostic; no Instruments race-memory or allocation-free
simulation claim follows from it. See `streaming-telemetry-report.json` for results.

The final release check read 239,778,685 bytes per long input (60,000 records),
wrote a 466,232,000-byte complete report, and verified all 19,320,000 diagnostic
values. Peak RSS was 7,307,264 bytes for 2,000 records, 7,323,648 bytes for 60,000
records without a report, and 8,470,528 bytes with the full report. The 2,000-record
report repeats byte-for-byte across fresh processes. All 167 debug/release tests
and eight selected sanitizer tests pass. The previously captured 46-record native
driving file also self-compares successfully; that check establishes format
compatibility, not upstream driving parity.
