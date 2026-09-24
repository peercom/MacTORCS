#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Prepare the selected native driving session using explicitly local textures.

This is development preparation, not a redistribution license or general importer.
The selected source artwork retains Free Art terms; unreviewed shared textures
must remain local. Existing destinations are never replaced.
"""
from pathlib import Path
import json,shutil,subprocess,sys,tempfile,hashlib
root=Path(__file__).resolve().parent.parent
if len(sys.argv)!=3: raise SystemExit('Usage: Scripts/prepare-driving-session.py /path/to/torcs-1.3.9 new-session-directory')
upstream=Path(sys.argv[1]).resolve();destination=Path(sys.argv[2]).absolute()
if destination.exists(): raise SystemExit('Driving session destination already exists')
destination.parent.mkdir(parents=True,exist_ok=True)
fixtures=root/'Tests/UnitTests/Fixtures'
with tempfile.TemporaryDirectory(prefix='.driving-',dir=destination.parent) as temporary:
    stage=Path(temporary)/'session';stage.mkdir()
    models=[('155-DTM','155-DTM',True),('aalborg','aalborg',False)]+[('trb1-3',f'wheel{i}',True) for i in range(4)]
    for directory,stem,car in models:
        flags=['--car'] if car else ['--texture-root',str(upstream/'data/data/textures')]
        subprocess.run([root/'.build/release/torcs-assetc','--scene',fixtures/f'Artwork/{directory}/{stem}.acc',stage/stem,*flags],check=True)
    subprocess.run([root/'.build/release/torcs-assetc','--texture',fixtures/'Artwork/155-DTM/shadow.rgb',stage/'shadow.torcstex','--no-mipmaps'],check=True)
    subprocess.run([root/'.build/release/torcs-assetc','--texture',fixtures/'Artwork/aalborg/background.png',stage/'background.torcstex'],check=True)
    # Aalborg uses default env.png; track-local files take precedence over shared.
    for name,cache in [('env.png','reflection'),('envshadow.png','environment-shade')]:
        local=upstream/'data/tracks/road/aalborg'/name
        source=local if local.is_file() else upstream/'data/data/textures'/name
        subprocess.run([root/'.build/release/torcs-assetc','--texture',source,stage/(cache+'.torcstex')],check=True)
    # Selected 155-DTM has two brake2 lights. Keep this shared texture local.
    light_source=upstream/'data/data/textures/breaklight2.rgb'
    subprocess.run([root/'.build/release/torcs-assetc','--texture',light_source,stage/'breaklight2.torcstex','--no-mipmaps'],check=True)
    (stage/'local-light-sources.json').write_text(json.dumps([dict(source=str(light_source),sha256=hashlib.sha256(light_source.read_bytes()).hexdigest(),texture='breaklight2.rgb',license='Unresolved per-file attribution; local inspection only')],indent=2)+'\n')
    for name in ['155-DTM.xml','Track-4WD-GrB.xml','aalborg.xml','surfaces.xml','objects.xml']:
        shutil.copy2(fixtures/name,stage/name)
    for directory in ['155-DTM','aalborg','trb1-3']:
        shutil.copy2(fixtures/f'Artwork/{directory}/readme.txt',stage/f'{directory}-readme.txt')
    shutil.copy2(root/'Resources/asset-manifest.json',stage/'source-asset-manifest.json')
    (stage/'LOCAL_CONTENT_NOTICE.txt').write_text('For local inspection/driving only. Eight shared track/environment/light textures have unresolved per-file redistribution attribution; do not redistribute this session. Original artwork retains its source terms. See copied source manifests and readmes.\n')
    track_index=json.loads((stage/'aalborg/scene.json').read_text())
    shadow_path='aalborg/'+track_index['textures']['shadow2.rgb']
    index=dict(version=1,lightTextures={"breaklight2.rgb":"breaklight2.torcstex"},trackShadow=shadow_path,reflection='reflection.torcstex',environmentShade='environment-shade.torcstex',background='background.torcstex',shadow='shadow.torcstex',name='155-DTM · Aalborg',car='155-DTM.xml',category='Track-4WD-GrB.xml',track='aalborg.xml',surfaces='surfaces.xml',objects='objects.xml',body='155-DTM/scene.json',scenery='aalborg/scene.json',wheels=[f'wheel{i}/scene.json' for i in range(4)])
    (stage/'driving.json').write_text(json.dumps(index,indent=2)+'\n')
    if destination.exists(): raise SystemExit('Destination appeared during preparation')
    stage.rename(destination)
print(f'Prepared local driving session: {destination}')
