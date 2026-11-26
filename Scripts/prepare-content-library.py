#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Build the game's content library from a local TORCS 1.3.9 install.

    Scripts/prepare-content-library.py /path/to/torcs-1.3.9 [library-directory]
        [--tracks a,b,...] [--cars x,y,...] [--all] [--no-previews]

Each circuit becomes a track package under <library>/tracks/<name> and each
car a car package under <library>/cars/<name>; the game combines any car with
any circuit. The library defaults to the folder the game scans by itself:
~/Library/Application Support/TORCSMac/Content. Packages already there are
kept, so the script can be run again to add to a library.

Without --tracks/--cars a selection is prepared; --all takes everything the
install has. The generated material sets (Artifacts/materials) are copied
once, to <library>/materials, and shared by every circuit. Menu previews are
rendered by the game itself (.build/release/TORCSMac).

This is local preparation, not a redistribution licence: the packages copy
textures from the install whose per-file attribution is unresolved, and each
is marked for local use.
"""
from pathlib import Path
import json,shutil,subprocess,sys
root=Path(__file__).resolve().parent.parent
args=sys.argv[1:]
def option(name):
    if name in args:
        i=args.index(name);value=args[i+1];del args[i:i+2];return value
    return None
def flag(name):
    if name in args: args.remove(name);return True
    return False
tracks=option('--tracks');cars=option('--cars');everything=flag('--all');previews=not flag('--no-previews')
if not 1<=len(args)<=2: raise SystemExit(__doc__)
upstream=Path(args[0]).resolve()
library=Path(args[1]).absolute() if len(args)==2 else Path.home()/'Library/Application Support/TORCSMac/Content'
TRACKS=['aalborg','alpine-1','alpine-2','brondehach','corkscrew','e-track-2','e-track-3','e-track-4','e-track-6',
        'forza','g-track-1','g-track-2','g-track-3','ruudskogen','street-1','wheel-1','wheel-2','michigan']
CARS=['car1-trb1','car2-trb1','car3-trb1','car4-trb1','car5-trb1','car6-trb1','car7-trb1','car8-trb1','car1-trb3',
      '155-DTM','acura-nsx-sz','p406','car1-ow1','car1-stock1','kc-cobra','kc-gt40','kc-daytona','kc-p4','kc-dino',
      'pw-imprezawrc','pw-focuswrc','pw-evoviwrc']
def available_tracks():
    found=list((upstream/'data/tracks').glob('*/*/*.acc'))+list((upstream/'data/tracks').glob('*/*.acc'))
    return sorted({p.stem for p in found if p.stem==p.parent.name})
def available_cars():
    return sorted(p.name for p in (upstream/'data/cars/models').iterdir() if (p/f'{p.name}.acc').is_file())
track_list=tracks.split(',') if tracks else (available_tracks() if everything else TRACKS)
car_list=cars.split(',') if cars else (available_cars() if everything else CARS)

for product in ['torcs-assetc','TORCSMac'] if previews else ['torcs-assetc']:
    subprocess.run(['swift','build','-c','release','--product',product],cwd=root,check=True,stdout=subprocess.DEVNULL)
prepare=root/'Scripts/prepare-driving-session.py'
game=root/'.build/release/TORCSMac'
(library/'tracks').mkdir(parents=True,exist_ok=True);(library/'cars').mkdir(parents=True,exist_ok=True)
generated=root/'Artifacts/materials'
if (generated/'materials.json').is_file() and not (library/'materials/materials.json').is_file():
    shutil.copytree(generated,library/'materials',ignore=shutil.ignore_patterns('*.torcsbc','*-sheet.png'),dirs_exist_ok=True)
    print('materials: copied to the library')

# The original's sound samples, shared by every car: engine notes by the name
# each car's document gives, tyres, surfaces, gears and impacts. Without
# them the game generates stand-ins.
sounds=upstream/'data/data/sound'
if sounds.is_dir():
    (library/'sounds').mkdir(exist_ok=True)
    copied=0
    for wav in sorted(sounds.glob('*.wav')):
        if not (library/'sounds'/wav.name).exists(): shutil.copy2(wav,library/'sounds'/wav.name);copied+=1
    if copied: print(f'sounds: {copied} copied to the library')

failed=[]
def package(kind,name):
    destination=library/f'{kind}s'/name
    if destination.exists(): return destination
    # Materials are shared from the library, so none are copied per circuit.
    result=subprocess.run([sys.executable,prepare,upstream,destination,f'--{kind}',name,'--materials',library/'.none'],capture_output=True,text=True)
    if result.returncode!=0 or not destination.exists():
        failed.append(f'{kind} {name}: {(result.stderr or result.stdout).strip().splitlines()[-1] if (result.stderr or result.stdout).strip() else "failed"}')
        return None
    print(f'{kind}: {name}')
    return destination
track_dirs=[d for d in (package('track',n) for n in track_list) if d]
car_dirs=[d for d in (package('car',n) for n in car_list) if d]

def preview(kind,directory,track,car):
    index_file=directory/f'{kind}.json'
    index=json.loads(index_file.read_text())
    if index.get('preview') and (directory/index['preview']).is_file(): return
    out=directory/'preview.png'
    result=subprocess.run([game,'--render-preview',kind,track,car,out],capture_output=True,text=True)
    if result.returncode!=0 or not out.is_file():
        failed.append(f'{kind} preview {directory.name}: {(result.stderr or result.stdout).strip()[-200:]}');return
    # A menu image, not a screenshot: half the size is plenty and a tenth the bytes as JPEG.
    jpeg=directory/'preview.jpg'
    subprocess.run(['sips','-s','format','jpeg','-s','formatOptions','82',out,'--out',jpeg],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    out.unlink()
    index['preview']='preview.jpg';index_file.write_text(json.dumps(index,indent=2)+'\n')
    print(f'preview: {kind} {directory.name}')
if previews and track_dirs and car_dirs:
    # Cars are pictured on the first circuit's grid; circuits need a car only to load.
    stage=next((d for d in track_dirs if d.name=='aalborg'),track_dirs[0])
    for d in car_dirs: preview('car',d,stage,d)
    for d in track_dirs: preview('track',d,d,car_dirs[0])
print(f'Library: {library} ({len(track_dirs)} circuits, {len(car_dirs)} cars)')
if failed:
    print('Not prepared:');[print('  '+f) for f in failed]
