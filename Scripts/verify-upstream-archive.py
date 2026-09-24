#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Optional archive provenance check: pass torcs-1.3.9.tar.bz2 as the sole argument."""
import hashlib
import json
from pathlib import Path
import sys
import tarfile

root = Path(__file__).resolve().parent.parent
manifest = json.loads((root / 'Upstream/source-manifest.json').read_text())
if len(sys.argv) != 2:
    raise SystemExit('Usage: Scripts/verify-upstream-archive.py /path/to/torcs-1.3.9.tar.bz2')
archive = Path(sys.argv[1])
with archive.open('rb') as source:
    digest = hashlib.file_digest(source, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else None
if digest is None:
    hasher = hashlib.sha256()
    with archive.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            hasher.update(chunk)
    digest = hasher.hexdigest()
if digest != manifest['archive_sha256']:
    raise SystemExit('Release archive SHA-256 mismatch')
entries = manifest['files'] + json.loads((root / 'Resources/asset-manifest.json').read_text())
expected = {'torcs-1.3.9/' + entry['source']: entry.get('source_sha256', entry['sha256']) for entry in entries}
remaining = set(expected)
# Stream only; never extract arbitrary paths or symlinks from the archive.
with tarfile.open(archive, 'r|bz2') as source:
    for member in source:
        name = member.name.removeprefix('./')
        if name not in remaining:
            continue
        if not member.isfile():
            raise SystemExit('Unexpected non-file: ' + name)
        data = source.extractfile(member).read()
        if hashlib.sha256(data).hexdigest() != expected[name]:
            raise SystemExit('Source differs from release archive: ' + name)
        remaining.remove(name)
        if not remaining:
            break
if remaining:
    raise SystemExit('Missing archive members: ' + ', '.join(sorted(remaining)))
print(f'Archive hash and {len(expected)} original source/content files verified.')
