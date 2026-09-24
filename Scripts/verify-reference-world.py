#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Run pinned original physics twice per scenario; this is not native vehicle parity."""
import hashlib
import json
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parent.parent
output = root / 'Artifacts/reference-world'
output.mkdir(parents=True, exist_ok=True)
executable = root / '.build/release/torcs-reference'
report = {'schema': 1, 'scope': 'Original physics repeatability, not native whole-vehicle parity', 'scenarios': {}}
for scenario, ticks in [('stationary', 1000), ('acceleration', 3000), ('braking', 3000), ('cornering', 4000), ('combined', 3000), ('car-collision', 2000)]:
    captures = []
    for run in (1, 2):
        destination = output / f'{scenario}-{run}.jsonl'
        with (output / f'{scenario}-{run}.log').open('wb') as log:
            subprocess.run([str(executable), '--scenario', scenario, '--fixtures', str(root / 'Tests/UnitTests/Fixtures'), '--ticks', str(ticks), '--telemetry', str(destination)], cwd=root, stdout=log, stderr=subprocess.STDOUT, check=True)
        captures.append(destination)
    def digest(path):
        h = hashlib.sha256()
        with path.open('rb') as source:
            for chunk in iter(lambda: source.read(1024*1024), b''): h.update(chunk)
        return h.hexdigest()
    checksum = digest(captures[0])
    if checksum != digest(captures[1]): raise SystemExit(f'Nonrepeatable scenario: {scenario}')
    maximum_speed = maximum_damage = collision_ticks = count = 0
    with captures[0].open() as source:
        for line in source:
            record = json.loads(line); values = record['values']; count += 1
            maximum_speed = max(maximum_speed, abs(values['car.0.velocity.local.x']))
            maximum_damage = max(maximum_damage, sum(v for k,v in values.items() if k.endswith('.damage')))
            collision_ticks += any(v != 0 for k,v in values.items() if k.endswith('.collision'))
    assert count == ticks
    metadata = json.loads(captures[0].with_suffix('.jsonl.metadata.json').read_text())
    report['scenarios'][scenario] = {'ticks': ticks, 'cars': metadata['cars'], 'fieldsPerCar': metadata['physicsFieldsPerCar'], 'identicalAcrossProcesses': True, 'sha256': checksum, 'maximumLocalSpeed': maximum_speed, 'finalLocalSpeed': values['car.0.velocity.local.x'], 'maximumTotalDamage': maximum_damage, 'collisionTicks': collision_ticks}
    print(f'{scenario}: {ticks} ticks, exact repeat, max speed {maximum_speed:.6f} m/s', flush=True)
report['provenance'] = {k: metadata[k] for k in ['archiveSHA256', 'executableSHA256', 'sourceHashes', 'seed', 'stepSeconds', 'settlingTicks', 'startDistanceMetres', 'carSpacingMetres', 'trackLengthMetres', 'trackSegments', 'parser']}
report['initialization'] = '501 original SimUpdate ticks at race state zero with full brake throughout; scripted harness setup, not complete race-engine startup'
report['limitations'] = ['Cornering is a scripted steering response and reaches the barrier; it is not a validated steady-state cornering case.', 'No race-engine, robot, lap, pit, qualifying or native whole-vehicle parity coverage.']
(output / 'report.json').write_text(json.dumps(report, indent=2, sort_keys=True)+'\n')
