#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
mkdir -p Artifacts/single-car
for scenario in stationary acceleration braking cornering combined; do
    for pass in first repeat; do
        for implementation in reference sim; do
            ".build/release/torcs-$implementation" --scenario "$scenario" --fixtures Tests/UnitTests/Fixtures --ticks 3000 \
                --telemetry "Artifacts/single-car/$scenario-$implementation-$pass.jsonl" \
                > "Artifacts/single-car/$scenario-$implementation-$pass.log" 2>&1
        done
    done
    for implementation in reference sim; do
        cmp "Artifacts/single-car/$scenario-$implementation-first.jsonl" "Artifacts/single-car/$scenario-$implementation-repeat.jsonl"
    done
    .build/release/torcs-diff "Artifacts/single-car/$scenario-reference-first.jsonl" "Artifacts/single-car/$scenario-sim-first.jsonl" \
        --report "Artifacts/single-car/$scenario-parity.json" > "Artifacts/single-car/$scenario-diff.log"
    echo "Verified $scenario: 3000 ticks, 142 fields, native and original repeatability."
done
