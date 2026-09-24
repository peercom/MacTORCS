#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Exercise the native compiler in separate processes; build release first."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
compiler = root / '.build/release/torcs-assetc'
artifacts = root / 'Artifacts'
artifacts.mkdir(exist_ok=True)
records = []
models = [('155-DTM', '155-DTM', True), ('aalborg', 'aalborg', False)]
models += [('trb1-3', f'wheel{i}', True) for i in range(4)]
for folder, name, car in models:
    source = root / f'Tests/UnitTests/Fixtures/Artwork/{folder}/{name}.acc'
    output = artifacts / f'{name}.torcsmesh'
    repeat = artifacts / f'{name}-repeat.torcsmesh'
    flags = ['--car'] if car else []
    for destination in [output, repeat]:
        subprocess.run([compiler, source, destination, *flags], check=True)
    assert output.read_bytes() == repeat.read_bytes(), 'Nondeterministic compilation'
    records.append(dict(source=str(source.relative_to(root)), bytes=output.stat().st_size,
                        sourceSHA256=hashlib.sha256(source.read_bytes()).hexdigest(),
                        cacheSHA256=hashlib.sha256(output.read_bytes()).hexdigest()))
with tempfile.TemporaryDirectory(prefix='torcs-assetc-') as folder:
    folder = Path(folder)
    source, destination = folder / 'invalid.acc', folder / 'retained.torcsmesh'
    source.write_text('invalid asset')
    destination.write_bytes(b'existing destination')
    for args in [[source, destination], [source, source],
                 [source, destination, '--texture-units', '5']]:
        result = subprocess.run([compiler, *args], capture_output=True, text=True)
        assert result.returncode == 1 and 'torcs-assetc:' in result.stderr
        assert destination.read_bytes() == b'existing destination'
        assert source.read_text() == 'invalid asset'
    with source.open('wb') as file:
        file.truncate(64 * 1024 * 1024 + 1)
    result = subprocess.run([compiler, source, destination], capture_output=True, text=True)
    assert result.returncode == 1 and 'byte limit exceeded' in result.stderr
    assert destination.read_bytes() == b'existing destination'
report = dict(files=records, separateProcessRepeatability=True, failurePreservesDestination=True,
              sourceOverwriteRejected=True, excessiveInputRejected=True)
(artifacts / 'asset-compiler.json').write_text(json.dumps(report, indent=2) + '\n')
print('Verified native asset compilation, repeatability, input limit and atomic failure behavior.')
