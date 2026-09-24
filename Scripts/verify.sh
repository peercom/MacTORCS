#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
cd "$(dirname "$0")/.."
python3 Scripts/verify-provenance.py
swift test
swift build -c release
python3 Scripts/verify-assets.py
python3 Scripts/verify-textures.py
mkdir -p Artifacts
.build/release/torcs-reference --ticks 10000 --telemetry Artifacts/reference.jsonl
.build/release/torcs-reference --ticks 10000 --telemetry Artifacts/reference-repeat.jsonl
cmp Artifacts/reference.jsonl Artifacts/reference-repeat.jsonl
.build/release/torcs-sim --ticks 10000 --telemetry Artifacts/native.jsonl
.build/release/torcs-sim --ticks 10000 --telemetry Artifacts/native-repeat.jsonl
cmp Artifacts/native.jsonl Artifacts/native-repeat.jsonl
.build/release/torcs-diff Artifacts/reference.jsonl Artifacts/native.jsonl --report Artifacts/parity.json
echo 'Verified reference/native repeatability and component parity.'
