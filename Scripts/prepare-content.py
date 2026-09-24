#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Prepare a driving session for any car and track in a TORCS installation.

Generalises prepare-driving-session.py, which was fixed to one car and one
track and read its meshes from the repository's test fixtures. This reads the
installation directly, resolves each car's own wheel set and category, and
handles both track directory layouts an unmodified 1.3.9 tree uses.

Development preparation, not redistribution. Sessions are written outside the
repository and nothing is bundled; content keeps whatever terms it shipped with.
Refuses content the inventory classifies as non-free unless explicitly forced,
so a licence mistake takes a deliberate act rather than a typo.
"""
from pathlib import Path
import argparse, hashlib, json, re, shutil, subprocess, sys, tempfile

ROOT = Path(__file__).resolve().parent.parent
ASSETC = ROOT / '.build/release/torcs-assetc'
SUPPORTED_TRACK_VERSIONS = {4}


def attribute(text, name, kind='attstr'):
    match = re.search(rf'<{kind}\s+name="{re.escape(name)}"[^>]*val="([^"]*)"', text)
    return match.group(1) if match else None


def find_track(install: Path, name: str):
    """Tracks live under a category directory, or flat with a Makefile saying
    which category they install into. Both occur in an unmodified source tree."""
    tracks = install / 'data/tracks'
    for category in ['road', 'oval', 'dirt']:
        candidate = tracks / category / name
        if candidate.is_dir():
            return candidate, category
    candidate = tracks / name
    if candidate.is_dir():
        category = None
        makefile = candidate / 'Makefile'
        if makefile.is_file():
            match = re.search(r'DATADIR\s*=\s*tracks/(\w+)/', makefile.read_text(errors='replace'))
            category = match.group(1) if match else None
        return candidate, category
    raise SystemExit(f'Track not found: {name}')


def compile_scene(source: Path, destination: Path, car: bool, texture_roots):
    flags = ['--car'] if car else []
    for root in texture_roots:
        flags += ['--texture-root', str(root)]
    subprocess.run([ASSETC, '--scene', source, destination, *flags], check=True)


def compile_texture(source: Path, destination: Path, mipmaps=True):
    flags = [] if mipmaps else ['--no-mipmaps']
    subprocess.run([ASSETC, '--texture', source, destination, *flags], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('install', type=Path)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--car', default='155-DTM')
    parser.add_argument('--track', default='aalborg')
    parser.add_argument('--allow-unlicensed', action='store_true',
                        help='prepare content with non-free or unresolved terms anyway')
    arguments = parser.parse_args()

    install = arguments.install.resolve()
    destination = arguments.destination.absolute()
    if destination.exists():
        raise SystemExit('Destination already exists')
    if not ASSETC.is_file():
        raise SystemExit('Build the release tools first: swift build -c release')

    car_directory = install / 'data/cars/models' / arguments.car
    car_xml = car_directory / f'{arguments.car}.xml'
    if not car_xml.is_file():
        raise SystemExit(f'Car not found: {arguments.car}')
    track_directory, track_category = find_track(install, arguments.track)
    track_xml = track_directory / f'{arguments.track}.xml'

    # Licence gate, using the same classification as content-inventory.py, so
    # the two cannot drift apart.
    with tempfile.NamedTemporaryFile(suffix='.json') as report:
        subprocess.run([sys.executable, ROOT / 'Scripts/content-inventory.py', install,
                        '--json', report.name], capture_output=True, text=True, check=True)
        data = json.loads(Path(report.name).read_text())
    def status(kind, name):
        for item in data[kind]:
            if item['name'] == name:
                return item['status'], item['reason']
        return 'ambiguous', 'Not present in the inventory.'
    for kind, name in [('cars', arguments.car), ('tracks', arguments.track)]:
        state, reason = status(kind, name)
        if state != 'free' and not arguments.allow_unlicensed:
            raise SystemExit(f'{name} is {state}: {reason}\n'
                             f'Pass --allow-unlicensed to prepare it anyway (development only).')

    car_text = car_xml.read_text(encoding='latin-1', errors='replace')
    category = attribute(car_text, 'category')
    category_xml = install / 'data/cars/categories' / category / f'{category}.xml'
    if not category_xml.is_file():
        raise SystemExit(f'Car category not found: {category}')
    # Each car names its own wheel set; the original script assumed one.
    wheel_directory = attribute(car_text, '3d wheel directory') or 'trb1-3'
    wheel_base = attribute(car_text, '3d wheel basename') or 'wheel'
    wheels = install / 'data/cars/wheels' / wheel_directory

    version = None
    if track_xml.is_file():
        match = re.search(r'name="version"\s+val="(\d+)"',
                          track_xml.read_text(encoding='latin-1', errors='replace'))
        version = int(match.group(1)) if match else None
    if version not in SUPPORTED_TRACK_VERSIONS:
        raise SystemExit(f'{arguments.track} is track XML version {version}; '
                         f'the loader supports {sorted(SUPPORTED_TRACK_VERSIONS)}.')

    shared = install / 'data/data/textures'
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.content-', dir=destination.parent) as temporary:
        stage = Path(temporary) / 'session'
        stage.mkdir()

        compile_scene(car_directory / f'{arguments.car}.acc', stage / 'body', True, [car_directory, shared])
        for index in range(4):
            compile_scene(wheels / f'{wheel_base}{index}.acc', stage / f'wheel{index}', True, [wheels, shared])
        compile_scene(track_directory / f'{arguments.track}.acc', stage / 'track', False,
                      [track_directory, shared])

        def optional_texture(candidates, name, mipmaps=True):
            for candidate in candidates:
                if candidate.is_file():
                    compile_texture(candidate, stage / f'{name}.torcstex', mipmaps)
                    return f'{name}.torcstex', candidate
            return None, None

        shadow, _ = optional_texture([car_directory / 'shadow.rgb', shared / 'shadow.rgb'],
                                     'shadow', mipmaps=False)
        background, _ = optional_texture([track_directory / 'background.png',
                                          track_directory / 'background.rgb',
                                          shared / 'background.png'], 'background')
        reflection, _ = optional_texture([track_directory / 'env.png', shared / 'env.png'], 'reflection')
        shade, _ = optional_texture([track_directory / 'envshadow.png', shared / 'envshadow.png'],
                                    'environment-shade')

        lights, light_sources = {}, []
        for light in ['breaklight2.rgb', 'breaklight.rgb']:
            source = shared / light
            if source.is_file():
                cache = light.replace('.rgb', '.torcstex')
                compile_texture(source, stage / cache, mipmaps=False)
                lights[light] = cache
                light_sources.append(dict(source=str(source), texture=light,
                                          sha256=hashlib.sha256(source.read_bytes()).hexdigest()))

        for source, name in [(car_xml, f'{arguments.car}.xml'), (category_xml, f'{category}.xml'),
                             (track_xml, f'{arguments.track}.xml'),
                             (install / 'data/data/tracks/surfaces.xml', 'surfaces.xml'),
                             (install / 'data/data/tracks/objects.xml', 'objects.xml')]:
            if not source.is_file():
                raise SystemExit(f'Missing required file: {source}')
            shutil.copy2(source, stage / name)
        for directory, label in [(car_directory, arguments.car), (track_directory, arguments.track),
                                 (wheels, wheel_directory)]:
            readme = directory / 'readme.txt'
            if readme.is_file():
                shutil.copy2(readme, stage / f'{label}-readme.txt')

        track_index = json.loads((stage / 'track/scene.json').read_text())
        shadow_map = next((f'track/{v}' for k, v in track_index['textures'].items()
                           if 'shadow' in k.lower()), None)

        index = dict(version=1, name=f'{arguments.car} · {arguments.track}',
                     car=f'{arguments.car}.xml', category=f'{category}.xml',
                     track=f'{arguments.track}.xml', surfaces='surfaces.xml', objects='objects.xml',
                     body='body/scene.json', scenery='track/scene.json',
                     wheels=[f'wheel{i}/scene.json' for i in range(4)],
                     shadow=shadow, background=background, reflection=reflection,
                     environmentShade=shade, trackShadow=shadow_map, lightTextures=lights)
        (stage / 'driving.json').write_text(json.dumps(index, indent=2) + '\n')
        if light_sources:
            (stage / 'local-light-sources.json').write_text(json.dumps(light_sources, indent=2) + '\n')
        (stage / 'LOCAL_CONTENT_NOTICE.txt').write_text(
            'Prepared from a local TORCS installation for development. Shared textures under '
            'data/data/textures have no per-file attribution; see Documentation/ASSET_REPLACEMENT.md. '
            'Do not redistribute this directory. Original artwork retains its source terms; the '
            'copied readme files are those terms.\n')

        if destination.exists():
            raise SystemExit('Destination appeared during preparation')
        stage.rename(destination)

    print(f'Prepared {arguments.car} on {arguments.track} '
          f'({track_category or "uncategorised"}, version {version}) at {destination}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
