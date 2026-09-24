#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Inventory the cars and tracks in a TORCS installation and classify their terms.

Development tooling. Classification is mechanical, from the notices that ship
with the content plus the upstream README's own non-free list; it is evidence
for a decision, not the decision itself. See Documentation/ASSET_REPLACEMENT.md.
"""
from pathlib import Path
import argparse, json, re, sys

# Upstream README section 3 names these two families as non-free. Debian strips
# exactly the same two globs and nothing else.
NON_FREE_PREFIXES = ('kc-', 'pw-')

# Content whose grant does not actually cover the whole work. Kept separate from
# the non-free list because the reason differs: these are unresolved rather than
# refused.
AMBIGUOUS = {
    'brondehach': 'Free Art grant is scoped to Andrew Sumner\'s contributions; the '
                  'underlying SBK2001 geometry is stated to have been released '
                  'without any license.',
    'buggy': 'No artwork notice of any kind.',
    'p406': 'No artwork notice of any kind, and the name is a live trademark.',
}

FREE_ART = re.compile(r'free art licen[cs]e', re.I)
GPL = re.compile(r'GNU General Public License|GPL\s*v?2', re.I)
REFUSAL = re.compile(r'may NOT be used|NOT use this car as a base|NO MODIFICATIONS|'
                     r'may not be sold|NOT BE EDITED', re.I)


def classify(directory: Path, name: str):
    """Returns (status, reason). Status is one of free, nonfree, ambiguous."""
    if name.startswith(NON_FREE_PREFIXES):
        return 'nonfree', 'Listed in the upstream README as non-free content.'
    if name in AMBIGUOUS:
        return 'ambiguous', AMBIGUOUS[name]
    readme = directory / 'readme.txt'
    if not readme.is_file():
        return 'ambiguous', 'No readme.txt; no per-file terms stated.'
    text = readme.read_text(encoding='utf-8', errors='replace')
    if REFUSAL.search(text):
        return 'nonfree', 'Notice refuses modification or redistribution.'
    if FREE_ART.search(text):
        return 'free', 'Free Art License.'
    if GPL.search(text):
        return 'free', 'GPL.'
    return 'ambiguous', 'readme.txt states no recognisable license.'


def track_version(xml: Path):
    if not xml.is_file():
        return None
    text = xml.read_text(encoding='latin-1', errors='replace')
    match = re.search(r'name="version"\s+val="(\d+)"', text)
    return int(match.group(1)) if match else None


def inventory(root: Path):
    cars, tracks = [], []

    models = root / 'data/cars/models'
    for directory in sorted(p for p in models.iterdir() if p.is_dir()):
        name = directory.name
        status, reason = classify(directory, name)
        xml = directory / f'{name}.xml'
        category = None
        if xml.is_file():
            match = re.search(r'name="category"\s+val="([^"]+)"',
                              xml.read_text(encoding='latin-1', errors='replace'))
            category = match.group(1) if match else None
        cars.append(dict(name=name, status=status, reason=reason, category=category,
                         mesh=(directory / f'{name}.acc').is_file()))

    # Tracks live either under a category directory or flat in the source tree;
    # the Makefiles install the flat ones into a category. Both layouts occur in
    # an unmodified 1.3.9 checkout.
    seen = set()
    roots = root / 'data/tracks'
    for category in ['road', 'oval', 'dirt']:
        for directory in sorted(p for p in (roots / category).iterdir() if p.is_dir()) \
                if (roots / category).is_dir() else []:
            seen.add(directory.name)
            status, reason = classify(directory, directory.name)
            tracks.append(dict(name=directory.name, category=category, status=status,
                               reason=reason, version=track_version(directory / f'{directory.name}.xml'),
                               acc=(directory / f'{directory.name}.acc').is_file()))
    for directory in sorted(p for p in roots.iterdir() if p.is_dir()):
        if directory.name in seen or directory.name in ('road', 'oval', 'dirt'):
            continue
        makefile = directory / 'Makefile'
        category = None
        if makefile.is_file():
            match = re.search(r'DATADIR\s*=\s*tracks/(\w+)/', makefile.read_text(errors='replace'))
            category = match.group(1) if match else None
        status, reason = classify(directory, directory.name)
        tracks.append(dict(name=directory.name, category=category, status=status, reason=reason,
                           version=track_version(directory / f'{directory.name}.xml'),
                           acc=(directory / f'{directory.name}.acc').is_file()))
    return cars, tracks


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('install', type=Path, help='path to a TORCS 1.3.9 tree')
    parser.add_argument('--json', type=Path, help='write the full inventory here')
    parser.add_argument('--supported-versions', default='4',
                        help='comma-separated track XML versions the loader accepts')
    arguments = parser.parse_args()
    if not (arguments.install / 'data/cars/models').is_dir():
        raise SystemExit(f'Not a TORCS installation: {arguments.install}')
    supported = {int(v) for v in arguments.supported_versions.split(',') if v.strip()}

    cars, tracks = inventory(arguments.install)
    usable_cars = [c for c in cars if c['status'] == 'free' and c['mesh']]
    free_tracks = [t for t in tracks if t['status'] == 'free']
    loadable = [t for t in free_tracks if t['version'] in supported]
    blocked = [t for t in free_tracks if t['version'] not in supported]

    print(f'cars    {len(cars):3d} total  {len(usable_cars):3d} usable  '
          f"{sum(1 for c in cars if c['status'] == 'nonfree'):3d} non-free  "
          f"{sum(1 for c in cars if c['status'] == 'ambiguous'):3d} ambiguous")
    print(f'tracks  {len(tracks):3d} total  {len(loadable):3d} usable  '
          f"{sum(1 for t in tracks if t['status'] == 'nonfree'):3d} non-free  "
          f"{sum(1 for t in tracks if t['status'] == 'ambiguous'):3d} ambiguous  "
          f'{len(blocked):3d} blocked by track version')
    if blocked:
        print('\nfreely licensed but rejected by the loader:')
        for track in sorted(blocked, key=lambda t: (t['category'] or '', t['name'])):
            print(f"  {track['category'] or '?':5s} {track['name']:14s} version {track['version']}")
    excluded = [x for x in cars + tracks if x['status'] != 'free']
    if excluded:
        print('\nexcluded:')
        for item in sorted(excluded, key=lambda i: i['name']):
            print(f"  {item['name']:16s} {item['status']:9s} {item['reason']}")

    if arguments.json:
        arguments.json.write_text(json.dumps(
            dict(cars=cars, tracks=tracks, supportedVersions=sorted(supported)),
            indent=2, sort_keys=True) + '\n')
        print(f'\nwrote {arguments.json}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
