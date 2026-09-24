#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Separate-process native SGI/PNG compilation; build release tools first."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
compiler = root / '.build/release/torcs-assetc'
output = root / 'Artifacts/textures'
output.mkdir(parents=True, exist_ok=True)
entries = json.loads((root / 'Resources/asset-manifest.json').read_text())
textures = [entry for entry in entries if entry['path'].endswith(('.rgb', '.png'))]
records = []
for entry in textures:
    source = root / entry['path']
    cache = output / (source.stem + '.torcstex')
    with tempfile.TemporaryDirectory(prefix='torcs-texture-repeat-') as tmp:
        repeat = Path(tmp) / 'repeat.torcstex'
        for dest in [cache, repeat]:
            subprocess.run([compiler, '--texture', source, dest], check=True, stdout=subprocess.DEVNULL)
        assert cache.read_bytes() == repeat.read_bytes()
    records.append(dict(source=entry['path'], sourceSHA256=entry['sha256'], bytes=cache.stat().st_size,
                        cacheSHA256=hashlib.sha256(cache.read_bytes()).hexdigest()))
with tempfile.TemporaryDirectory(prefix='torcs-texture-invalid-') as tmp:
    src, dst = Path(tmp) / 'broken.rgb', Path(tmp) / 'retained.torcstex'
    src.write_bytes(b'not SGI'); dst.write_bytes(b'previous destination')
    for flags in [[], ['--car'], ['--max-texture-size', '0']]:
        result = subprocess.run([compiler, '--texture', src, dst, *flags], capture_output=True)
        assert result.returncode == 1 and dst.read_bytes() == b'previous destination'
report = dict(files=records, separateProcessRepeatability=True, failurePreservesDestination=True)
(output.parent / 'texture-compiler.json').write_text(json.dumps(report, indent=2) + '\n')
print(f'Verified {len(records)} native texture compilations, repeatability and atomic failures.')
