#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Prepare a native driving session from a local TORCS 1.3.9 install.

    Scripts/prepare-driving-session.py /path/to/torcs-1.3.9 new-session-directory [--track NAME] [--car NAME] [--materials DIR]

Without --track and --car this prepares the reviewed pairing, the 155-DTM on
Aalborg, from the repository's own fixtures. With them it imports any track
and car the install has: the track's scene, textures, background and
environment images; the car's scene, shadow, wheel set and light textures;
the category and the shared surfaces and objects.

This is development preparation, not a redistribution license or a general
content installer. The shared textures an imported session copies carry
unresolved per-file attribution; every session is marked for local use and
lists what it took from where. Existing destinations are never replaced.
"""
from pathlib import Path
import json,re,shutil,subprocess,sys,tempfile,hashlib
root=Path(__file__).resolve().parent.parent
args=sys.argv[1:]
track_name=car_name=None
if '--track' in args: i=args.index('--track');track_name=args[i+1];del args[i:i+2]
if '--car' in args: i=args.index('--car');car_name=args[i+1];del args[i:i+2]
materials=root/'Artifacts/materials'
if '--materials' in args: i=args.index('--materials');materials=Path(args[i+1]).resolve();del args[i:i+2]
if len(args)!=2 or (track_name is None)!=(car_name is None):
    raise SystemExit(__doc__)
upstream=Path(args[0]).resolve();destination=Path(args[1]).absolute()
if destination.exists(): raise SystemExit('Driving session destination already exists')
destination.parent.mkdir(parents=True,exist_ok=True)
fixtures=root/'Tests/UnitTests/Fixtures'
assetc=root/'.build/release/torcs-assetc'
if not assetc.exists(): raise SystemExit('Build the asset compiler first: swift build -c release --product torcs-assetc')
LIGHT_TEXTURES={'head1':'frontlight1.rgb','head2':'frontlight2.rgb','brake':'breaklight1.rgb','brake2':'breaklight2.rgb','rear':'rearlight1.rgb'}

def sha(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def attstr(text,name,default=None):
    """The val of the first <attstr name="..."> in the text. TORCS XML is flat
    enough for a text scan, and this Python build has no XML parser."""
    m=re.search(r'<attstr\s+name="'+re.escape(name)+r'"[^>]*?\bval="([^"]*)"',text)
    return m.group(1) if m else default
def section(text,name):
    """The body of the first <section name="..."> block, nesting honoured."""
    m=re.search(r'<section\s+name="'+re.escape(name)+r'"[^>]*>',text)
    if not m: return None
    depth,pos=1,m.end()
    for token in re.finditer(r'<section\b[^>]*?(/>|>)|</section>',text[m.end():]):
        if token.group(0).startswith('</section>'): depth-=1
        elif not token.group(0).endswith('/>'): depth+=1
        if depth==0: return text[m.end():m.end()+token.start()]
    return text[m.end():]
def subsections(text):
    """The bodies of a block's direct <section> children."""
    out=[];depth=0;start=None
    for token in re.finditer(r'<section\b[^>]*?(/>|>)|</section>',text):
        if token.group(0).startswith('</section>'):
            depth-=1
            if depth==0 and start is not None: out.append(text[start:token.start()]);start=None
        elif not token.group(0).endswith('/>'):
            if depth==0: start=token.end()
            depth+=1
    return out
def parse_xml(path): return Path(path).read_text(encoding='latin-1')

with tempfile.TemporaryDirectory(prefix='.driving-',dir=destination.parent) as temporary:
    stage=Path(temporary)/'session';stage.mkdir()
    sources=[]
    def compile_scene(acc,out,car,roots=()):
        flags=['--car'] if car else [f for r in roots for f in ('--texture-root',str(r))]
        subprocess.run([assetc,'--scene',acc,out,*flags],check=True);sources.append(acc)
    def compile_texture(src,out,mipmaps=True):
        subprocess.run([assetc,'--texture',src,out,*([] if mipmaps else ['--no-mipmaps'])],check=True);sources.append(src)

    if track_name is None:
        # The reviewed pairing from the fixtures, as before.
        models=[('155-DTM','155-DTM',True),('aalborg','aalborg',False)]+[('trb1-3',f'wheel{i}',True) for i in range(4)]
        for directory,stem,car in models:
            compile_scene(fixtures/f'Artwork/{directory}/{stem}.acc',stage/stem,car,[upstream/'data/data/textures'])
        compile_texture(fixtures/'Artwork/155-DTM/shadow.rgb',stage/'shadow.torcstex',mipmaps=False)
        compile_texture(fixtures/'Artwork/aalborg/background.png',stage/'background.torcstex')
        for name,cache in [('env.png','reflection'),('envshadow.png','environment-shade')]:
            local=upstream/'data/tracks/road/aalborg'/name
            compile_texture(local if local.is_file() else upstream/'data/data/textures'/name,stage/(cache+'.torcstex'))
        light_source=upstream/'data/data/textures/breaklight2.rgb'
        compile_texture(light_source,stage/'breaklight2.torcstex',mipmaps=False)
        light_textures={'breaklight2.rgb':'breaklight2.torcstex'}
        for name in ['155-DTM.xml','Track-4WD-GrB.xml','aalborg.xml','surfaces.xml','objects.xml']:
            shutil.copy2(fixtures/name,stage/name)
        for directory in ['155-DTM','aalborg','trb1-3']:
            shutil.copy2(fixtures/f'Artwork/{directory}/readme.txt',stage/f'{directory}-readme.txt')
        shutil.copy2(root/'Resources/asset-manifest.json',stage/'source-asset-manifest.json')
        car_xml,category_xml,track_xml='155-DTM.xml','Track-4WD-GrB.xml','aalborg.xml'
        body,scenery,name='155-DTM/scene.json','aalborg/scene.json','155-DTM · Aalborg'
        car_shadow='shadow.torcstex';track_dir_name='aalborg'
    else:
        # Any track and car the install has.
        candidates=[p for p in (upstream/'data/tracks').glob(f'*/{track_name}/{track_name}.acc')]+[p for p in (upstream/'data/tracks').glob(f'{track_name}/{track_name}.acc')]
        if not candidates: raise SystemExit(f'No track {track_name}.acc under {upstream}/data/tracks')
        track_acc=candidates[0];track_dir=track_acc.parent
        car_dir=upstream/'data/cars/models'/car_name;car_acc=car_dir/f'{car_name}.acc'
        if not car_acc.is_file(): raise SystemExit(f'No car {car_acc}')
        car_doc=parse_xml(car_dir/f'{car_name}.xml')
        category=attstr(car_doc,'category')
        if not category: raise SystemExit('Car XML names no category')
        # Categories are directories holding their XML in the install; the
        # fixtures flattened Aalborg's. Accept either.
        category_file=upstream/'data/cars/categories'/category/f'{category}.xml'
        if not category_file.is_file(): category_file=upstream/'data/cars/categories'/f'{category}.xml'
        if not category_file.is_file(): raise SystemExit(f'No category {category} under {upstream}/data/cars/categories')
        wheel_set=attstr(car_doc,'3d wheel directory','trb1-3')
        wheel_base=attstr(car_doc,'3d wheel basename','wheel')
        shared=upstream/'data/data/textures'
        compile_scene(car_acc,stage/car_name,True)
        for i in range(4):
            compile_scene(upstream/'data/cars/wheels'/wheel_set/f'{wheel_base}{i}.acc',stage/f'wheel{i}',True)
        compile_scene(track_acc,stage/track_name,False,[track_dir,shared])
        car_shadow=None
        if (car_dir/'shadow.rgb').is_file():
            compile_texture(car_dir/'shadow.rgb',stage/'shadow.torcstex',mipmaps=False);car_shadow='shadow.torcstex'
        track_doc=parse_xml(track_dir/f'{track_name}.xml')
        graphic=section(track_doc,'Graphic')
        background_name=attstr(graphic,'background image','background.png') if graphic is not None else 'background.png'
        env_name=attstr(graphic,'env map image','env.png') if graphic is not None else 'env.png'
        def track_or_shared(name):
            local=track_dir/name
            return local if local.is_file() else shared/name
        compile_texture(track_or_shared(background_name),stage/'background.torcstex')
        for name,cache in [(env_name,'reflection'),('envshadow.png','environment-shade')]:
            source=track_or_shared(name)
            if source.is_file(): compile_texture(source,stage/(cache+'.torcstex'))
        # Light textures: one per light type the car declares, shared art.
        light_textures={}
        lights=section(car_doc,'Light')
        for light in (subsections(lights) if lights is not None else []):
            texture=LIGHT_TEXTURES.get(attstr(light,'type',''))
            if texture and texture not in light_textures and (shared/texture).is_file():
                compile_texture(shared/texture,stage/(Path(texture).stem+'.torcstex'),mipmaps=False)
                light_textures[texture]=Path(texture).stem+'.torcstex'
        for src,dst in [(car_dir/f'{car_name}.xml',f'{car_name}.xml'),(category_file,f'{category}.xml'),(track_dir/f'{track_name}.xml',f'{track_name}.xml'),
                        (upstream/'data/data/tracks/surfaces.xml','surfaces.xml'),(upstream/'data/data/tracks/objects.xml','objects.xml')]:
            shutil.copy2(src,stage/dst);sources.append(src)
        for directory,label in [(car_dir,car_name),(track_dir,track_name),(upstream/'data/cars/wheels'/wheel_set,wheel_set)]:
            readme=directory/'readme.txt'
            if readme.is_file(): shutil.copy2(readme,stage/f'{label}-readme.txt')
        car_xml,category_xml,track_xml=f'{car_name}.xml',f'{category}.xml',f'{track_name}.xml'
        body,scenery,name=f'{car_name}/scene.json',f'{track_name}/scene.json',f'{car_name} · {track_name}'
        track_dir_name=track_name

    # The generated material sets, which the renderer substitutes for the
    # original textures by name; without them a session renders the baked
    # art alone. Generate with torcs-matgen --all --out Artifacts/materials.
    if (materials/'materials.json').is_file():
        shutil.copytree(materials,stage/'materials',ignore=shutil.ignore_patterns('*.torcsbc','*-sheet.png'))
    else:
        print(f'note: no generated materials at {materials}; the session will render the original art only')
    (stage/'local-sources.json').write_text(json.dumps([dict(source=str(s),sha256=sha(s)) for s in sources],indent=2)+'\n')
    (stage/'LOCAL_CONTENT_NOTICE.txt').write_text('For local inspection/driving only. Shared track/environment/light textures copied from the TORCS install have unresolved per-file redistribution attribution; do not redistribute this session. Original artwork retains its source terms. See local-sources.json and the copied readmes.\n')
    track_index=json.loads((stage/track_dir_name/'scene.json').read_text())
    shadow_texture=track_index.get('textures',{}).get('shadow2.rgb')
    index=dict(version=1,lightTextures=light_textures,background='background.torcstex',name=name,car=car_xml,category=category_xml,track=track_xml,
               surfaces='surfaces.xml',objects='objects.xml',body=body,scenery=scenery,wheels=[f'wheel{i}/scene.json' for i in range(4)])
    if car_shadow: index['shadow']=car_shadow
    if shadow_texture: index['trackShadow']=f'{track_dir_name}/{shadow_texture}'
    for cache,key in [('reflection','reflection'),('environment-shade','environmentShade')]:
        if (stage/f'{cache}.torcstex').is_file(): index[key]=f'{cache}.torcstex'
    (stage/'driving.json').write_text(json.dumps(index,indent=2)+'\n')
    if destination.exists(): raise SystemExit('Destination appeared during preparation')
    stage.rename(destination)
print(f'Prepared local driving session: {destination}')
