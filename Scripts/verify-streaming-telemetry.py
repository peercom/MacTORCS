#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Exercise large authored JSONL captures, not physics or race parity.

Generated large files live in a temporary directory and are removed after checking;
compact metrics, process logs and hashes remain under Artifacts/streaming-telemetry.
"""
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
executable = root / '.build/release/torcs-diff'
output = root / 'Artifacts/streaming-telemetry'
output.mkdir(parents=True, exist_ok=True)
fields = {f'car.0.channel.{i:03}': float(i % 13 + 1) for i in range(161)}
small_count, large_count = 2000, 60000

def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

def run(name, reference, candidate, expected, report=None):
    args = ['/usr/bin/time', '-l', str(executable), str(reference), str(candidate), '--abs', '0', '--rel', '0']
    if report:
        args += ['--report', str(report)]
    with (output / f'{name}.stdout.log').open('wb') as out, (output / f'{name}.stderr.log').open('wb') as err:
        result = subprocess.run(args, stdout=out, stderr=err, cwd=root)
    assert result.returncode == expected, (name, result.returncode)
    timing = (output / f'{name}.stderr.log').read_text()
    rss = int(re.search(r'(\d+)\s+maximum resident set size', timing).group(1))
    return {'exitCode': result.returncode, 'maximumResidentBytes': rss,
            'peakMemoryFootprintBytes': int(re.search(r'(\d+)\s+peak memory footprint', timing).group(1)),
            'stdoutSHA256': digest(output / f'{name}.stdout.log'), 'stderrSHA256': digest(output / f'{name}.stderr.log')}

with tempfile.TemporaryDirectory(prefix='stream-validation-', dir=root / 'Artifacts') as temporary:
    folder = Path(temporary)
    reference, candidate, small = [folder / name for name in ['reference.jsonl', 'candidate.jsonl', 'small.jsonl']]
    with reference.open('w') as a, candidate.open('w') as b, small.open('w') as s:
        for tick in range(large_count):
            record = {'schema': 1, 'scenario': 'authored-stream-io', 'tick': tick, 'time': tick * 0.002, 'values': fields}
            line = json.dumps(record, separators=(',', ':')) + '\n'
            a.write(line)
            if tick < small_count:
                s.write(line)
            if tick == large_count - 1:
                record['values'] = dict(fields, **{'car.0.channel.000': 3.0})
                line = json.dumps(record, separators=(',', ':')) + '\n'
            b.write(line)
    assert reference.stat().st_size > 128 * 1024 * 1024
    summary = {'schema': 1, 'scope': 'Authored large-file IO/comparison validation, not physical race parity',
               'fields': len(fields), 'smallRecords': small_count, 'largeRecords': large_count,
               'referenceBytes': reference.stat().st_size, 'referenceSHA256': digest(reference),
               'candidateSHA256': digest(candidate), 'executableSHA256': digest(executable)}
    summary['small'] = run('small', small, small, 0)
    repeats = [folder / 'repeat-1.json', folder / 'repeat-2.json']
    for i, destination in enumerate(repeats, 1):
        run(f'report-repeat-{i}', small, small, 0, destination)
    assert repeats[0].read_bytes() == repeats[1].read_bytes()
    summary['reportRepeatSHA256'] = digest(repeats[0])
    summary['reportRepeatableAcrossProcesses'] = True
    summary['largeEqual'] = run('large-equal', reference, reference, 0)
    report = folder / 'report.json'
    summary['largeDifferentWithReport'] = run('large-different', reference, candidate, 1, report)
    summary['reportBytes'] = report.stat().st_size
    summary['reportSHA256'] = digest(report)
    rows = 0
    metadata = None
    with report.open() as source:
        assert source.readline().strip() == '{"schema":2,"divergenceLayout":"by-record","divergence":['
        for line in source:
            if line.startswith('],'):
                metadata = json.loads('{' + line[2:])
                continue
            row = json.loads(line.rstrip('\r\n,'))
            assert row['tick'] == rows and row['time'] == rows * 0.002
            assert row['fields'].keys() == fields.keys()
            for name, value in row['fields'].items():
                expected = 2.0 if rows == large_count - 1 and name == 'car.0.channel.000' else 0.0
                assert value['absolute'] == expected and value['relative'] == expected
            rows += 1
    assert rows == large_count and metadata['records'] == large_count and not metadata['passed']
    changed = metadata['fields']['car.0.channel.000']
    assert changed['failures'] == 1 and changed['firstDivergentTick'] == large_count - 1
    assert changed['maximumAbsolute'] == 2 and changed['maximumRelative'] == 2
    assert math.isclose(changed['rms'], 2 / math.sqrt(large_count), rel_tol=1e-13)
    assert all(value['failures'] == 0 for name, value in metadata['fields'].items() if name != 'car.0.channel.000')
    summary['checkedDivergenceValues'] = rows * len(fields) * 2
    summary['changedField'] = changed
    # This is a measured process-RSS regression guard, not an Instruments claim.
    for name in ['largeEqual', 'largeDifferentWithReport']:
        for metric in ['maximumResidentBytes', 'peakMemoryFootprintBytes']:
            assert summary[name][metric] < summary['small'][metric] + 96 * 1024 * 1024
    broken = folder / 'broken.jsonl'
    broken.write_text(small.read_text() + '{broken}\n')
    previous = b'previous report remains intact\n'
    report.write_bytes(previous)
    summary['malformedTail'] = run('malformed-tail', reference, broken, 2, report)
    assert report.read_bytes() == previous
    assert not list(folder.glob('.diff-*.tmp'))
    summary['atomicFailurePreservesReport'] = True
summary['largeTemporaryFilesRemoved'] = True
(output / 'report.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
print(json.dumps(summary, indent=2, sort_keys=True))
