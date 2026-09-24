#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Compile/render selected original models. Shared track textures stay local.

Pass an extracted TORCS 1.3.9 directory explicitly. This does not import assets
into the repository or authorize redistributing the resulting scene directories.
"""
from pathlib import Path
import hashlib
import json
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parent.parent
if len(sys.argv) != 2:
    raise SystemExit('Usage: Scripts/verify-scenes.py /path/to/torcs-1.3.9')
upstream = Path(sys.argv[1]).resolve()
compiler = root / '.build/release/torcs-assetc'
app = root / 'build/TORCSMac.app/Contents/MacOS/TORCSMac'
artifacts = root / 'Artifacts'
records = []
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
for name, car in [('155-DTM', True), ('aalborg', False), ('trb1-3/wheel0', True)]:
    folder, stem = name.split('/') if '/' in name else (name, name)
    source = root / f'Tests/UnitTests/Fixtures/Artwork/{folder}/{stem}.acc'
    flags = ['--car'] if car else ['--texture-root', str(upstream / 'data/data/textures')]
    with tempfile.TemporaryDirectory(prefix='torcs-scene-verify-') as temp:
        temp = Path(temp)
        outputs = [temp / 'first', temp / 'repeat']
        for output in outputs:
            subprocess.run([compiler, '--scene', source, output, *flags], check=True, capture_output=True)
        def hashes(output):
            return {p.name: sha(p) for p in sorted(output.iterdir())}
        first, repeated = [hashes(p) for p in outputs]
        assert first == repeated, 'Non-deterministic scene compilation'
        failure = subprocess.run([compiler, '--scene', source, outputs[0], *flags], capture_output=True)
        assert failure.returncode == 1 and hashes(outputs[0]) == first
        output_image = artifacts / f'scene-{stem}-release.png'
        render = subprocess.run([app, '--scene-smoke-test', outputs[0], output_image],
                                text=True, capture_output=True, timeout=60)
        if render.returncode:
            raise RuntimeError(f'Scene render failed: {render.stdout}\n{render.stderr}')
        assert 'repeat=1' in render.stdout
        records.append(dict(source=str(source.relative_to(root)), sourceSHA256=sha(source),
                            compiledFiles=first, outputImage=str(output_image.relative_to(root)),
                            imageSHA256=sha(output_image), renderLog=render.stdout))
        print(render.stdout, end='')
# Missing dependency must not publish a partial output directory.
with tempfile.TemporaryDirectory(prefix='torcs-scene-missing-') as temp:
    source = Path(temp) / 'missing.acc'
    source.write_bytes((root / 'Tests/UnitTests/Fixtures/Artwork/155-DTM/155-DTM.acc').read_bytes())
    dest = Path(temp) / 'output'
    failure = subprocess.run([compiler, '--scene', source, dest, '--car'], capture_output=True)
    assert failure.returncode == 1 and not dest.exists()
report = dict(files=records, separateProcessRepeatability=True, overwriteRejected=True,
              missingDependencyPreservesAbsence=True,
              licensing='Five shared track textures read from explicit local TORCS directory; not imported or approved for redistribution.')
(artifacts / 'scene-compiler.json').write_text(json.dumps(report, indent=2) + '\n')
print('Verified three compiled scenes, separate-process repeatability and real Metal renders.')
