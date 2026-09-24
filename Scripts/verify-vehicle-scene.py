#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Assemble original compiled models and render native vehicle physics snapshots.

The explicit upstream directory supplies five shared track textures for local
inspection only; no new assets are imported or approved for redistribution.
"""
from pathlib import Path
import hashlib,json,subprocess,sys,tempfile
root=Path(__file__).resolve().parent.parent
if len(sys.argv)!=2: raise SystemExit('Usage: Scripts/verify-vehicle-scene.py /path/to/torcs-1.3.9')
upstream=Path(sys.argv[1]).resolve()
compiler=root/'.build/release/torcs-assetc'
app=root/'build/TORCSMac.app/Contents/MacOS/TORCSMac'
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
fixtures=root/'Tests/UnitTests/Fixtures'
with tempfile.TemporaryDirectory(prefix='torcs-vehicle-scene-') as folder:
    folder=Path(folder)
    models=[('155-DTM','155-DTM',True),('aalborg','aalborg',False)]+[('trb1-3',f'wheel{i}',True) for i in range(4)]
    caches={}
    for directory,stem,car in models:
        source=fixtures/f'Artwork/{directory}/{stem}.acc'
        flags=['--car'] if car else ['--texture-root',str(upstream/'data/data/textures')]
        subprocess.run([compiler,'--scene',source,folder/stem,*flags],check=True,capture_output=True)
        caches[stem]={p.name:sha(p) for p in sorted((folder/stem).iterdir())}
    results=[]
    for suffix in ['release','repeat']:
        output=root/f'Artifacts/vehicle-scene-{suffix}.png'
        result=subprocess.run([app,'--vehicle-scene-smoke-test',folder,fixtures,output],capture_output=True,text=True,timeout=60)
        if result.returncode: raise RuntimeError(f'Vehicle render failed: {result.stdout}\n{result.stderr}')
        assert 'ticks=1000 instances=6' in result.stdout and 'repeat=1' in result.stdout
        results.append(dict(image=str(output.relative_to(root)),sha256=sha(output),log=result.stdout))
    pixels=[(root/r['image']).with_suffix('.rgba').read_bytes() for r in results]
    assert len(pixels[0])==len(pixels[1])==960*640*4
    differences=[abs(a-b) for a,b in zip(*pixels) if a!=b]
    maximum=max(differences,default=0)
    assert maximum<=1 and len(differences)<=len(pixels[0])//10_000
    # Physics distance, wheel levels and geometry counts must still be exact.
    states=[r['log'].split('VEHICLE_SCENE ')[1].split(' rgbaChecksum=')[0] for r in results]
    levels=[r['log'].split('Wheel levels: ')[1].splitlines()[0] for r in results]
    assert states[0]==states[1] and levels[0]==levels[1]
    report=dict(compiledModels=caches,renders=results,separateProcessRepeatability=True,
                pixelComparison=dict(changedChannels=len(differences),maxChannelDelta=maximum,
                    allowedMaxChannelDelta=1,allowedChangedChannels=len(pixels[0])//10_000),
                scope='Actual native physics on Aalborg, assembled car body/four wheels, interpolated snapshots; not a playable race or full renderer parity.')
    (root/'Artifacts/vehicle-scene.json').write_text(json.dumps(report,indent=2)+'\n')
    print(results[0]['log'],end='')
    print(f'Vehicle scene repeats within raster tolerance: {len(differences)} changed channels, maximum delta {maximum}.')
