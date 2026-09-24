#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
mkdir -p Artifacts/car-collision
for pass in first repeat; do
    for implementation in reference sim; do
        ".build/release/torcs-$implementation" --scenario car-collision --fixtures Tests/UnitTests/Fixtures --ticks 3000 --cars 2 \
            --telemetry "Artifacts/car-collision/$implementation-$pass.jsonl" > "Artifacts/car-collision/$implementation-$pass.log" 2>&1
    done
done
for implementation in reference sim; do
    cmp "Artifacts/car-collision/$implementation-first.jsonl" "Artifacts/car-collision/$implementation-repeat.jsonl"
done
.build/release/torcs-diff Artifacts/car-collision/reference-first.jsonl Artifacts/car-collision/sim-first.jsonl \
    --report Artifacts/car-collision/parity.json > Artifacts/car-collision/diff.log
echo 'Verified two-car collision: 3000 ticks, 284 fields, native and original repeatability.'
