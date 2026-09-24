#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Verify pinned files. Does not require the external release archive."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
entries = json.loads((root / 'Upstream/source-manifest.json').read_text())['files']
entries += json.loads((root / 'Resources/asset-manifest.json').read_text())
for entry in entries:
    actual = hashlib.sha256((root / entry['path']).read_bytes()).hexdigest()
    if actual != entry['sha256']:
        raise SystemExit('Provenance mismatch: ' + entry['path'])
print(f'Verified {len(entries)} pinned source/content files.')

# The assignment oracle is a verbatim function from the pinned source.
race = (root / "Upstream/Reference/race/raceinit.cpp").read_bytes()
start = race.index(b"static void\ninitPits(void)")
end = race.index(b"\nbool isItThisRobot", start)
assert (root / "Upstream/Reference/race/pit-assignment.inc").read_bytes() == race[:race.index(b"#include")] + race[start:end]
print("Verified verbatim original initPits excerpt.")

# The starting-grid oracle is a verbatim function from the same pinned source.
start = race.index(b"static void\ninitStartingGrid(void)")
end = race.index(b"\nstatic void\ninitPits(void)", start)
assert (root / "Upstream/Reference/race/starting-grid.inc").read_bytes() == race[:race.index(b"#include")] + race[start:end]
print("Verified verbatim original initStartingGrid excerpt.")

# Image oracle uses the complete unmodified original read function.
img = (root / "Upstream/Reference/textures/img.cpp").read_bytes()
start = img.index(b"unsigned char *\nGfImgReadPng")
end = img.index(b"\n\n\n/** Write", start)
assert (root / "Upstream/Reference/textures/png-read.inc").read_bytes() == img[:img.index(b"/** @file")] + img[start:end] + b"\n"
print("Verified verbatim original GfImgReadPng excerpt.")

# Renderer wheel update: original loop, including speed selection and brake color.
graphics = (root / 'Upstream/Reference/graphics/grcar.cpp').read_bytes()
start = graphics.index(b'\t/* wheels */', graphics.index(b'static float maxVel'))
end = graphics.index(b'\n\t/* push the car', start)
assert (root / 'Upstream/Reference/graphics/wheel-update.inc').read_bytes() == graphics[:graphics.index(b'#include')] + graphics[start:end] + b'\n'
print('Verified verbatim original wheel graphics excerpt.')

camera = (root / 'Upstream/Reference/graphics/grcam.cpp').read_bytes()
start = camera.index(b'class cGrCarCamBehind :')
end = camera.index(b'class cGrCarCamBehind2 :', start)
assert (root / 'Upstream/Reference/graphics/camera-behind.inc').read_bytes() == camera[:camera.index(b'#include')] + camera[start:end]
print('Verified verbatim original behind-camera class.')

# The selected human joystick branches are compiled verbatim in the input oracle.
human = (root / 'Upstream/Reference/input/human.cpp').read_bytes()
for role, marker in [('left', 'CMD_LEFTSTEER'), ('right', 'CMD_RIGHTSTEER'), ('pedal', 'CMD_THROTTLE')]:
    start = human.index(b'\t\t\t', human.index(b'case GFCTRL_TYPE_JOY_AXIS:', human.index(b'switch (cmd[' + marker.encode() + b'].type)')))
    end = human.index(b'\t\t\tbreak;', start)
    assert (root / ('Upstream/Reference/input/' + role + '.inc')).read_bytes() == human[:human.index(b'/** @file')] + human[start:end]
print('Verified verbatim original human joystick branches.')

start=camera.index(b'class cGrCarCamInsideFixedCar :')
end=camera.index(b'class cGrCarCamBehind :',start)
assert (root/'Upstream/Reference/graphics/camera-bonnet.inc').read_bytes()==camera[:camera.index(b'#include')]+camera[start:end]
start=graphics.index(b'\t/* vertices */',graphics.index(b'static const int GR_SHADOW_POINTS'))
end=graphics.index(b'\n\tgrCarInfo[car->index].shadowBase =',start)
assert (root/'Upstream/Reference/graphics/shadow-vertices.inc').read_bytes()==graphics[:graphics.index(b'#include')]+graphics[start:end]+b'\n'
print('Verified verbatim original bonnet camera and shadow geometry excerpts.')

scene=(root/'Upstream/Reference/graphics/grscene.cpp').read_bytes()
header=scene[:scene.index(b'#include')]
a=scene.index(b'\tGLfloat mat_specular[]');b=scene.index(b'\n\tglShadeModel',a)
assert (root/'Upstream/Reference/graphics/lighting-config.inc').read_bytes()==header+scene[a:b]+b'\n'
at=scene.index(b'    switch (graphic->bgtype)')
for i in range(6):
    a=scene.index(b'\tfor (i =',at);b=scene.index(b'\n\tbg = new',a);at=b
    assert (root/f'Upstream/Reference/graphics/background-{i}.inc').read_bytes()==header+scene[a:b]+b'\n'
track=(root/'Upstream/Reference/track/track.cpp').read_bytes()
a=track.index(b'\tgraphic->background =');b=track.index(b'\n\t/* env map',a)
assert (root/'Upstream/Reference/graphics/background-config.inc').read_bytes()==track[:track.index(b'#include')]+track[a:b]+b'\n'
a=camera.index(b'void cGrBackgroundCam::update');b=camera.index(b'\n\n\nclass cGrCarCamInside',a)
assert (root/'Upstream/Reference/graphics/background-camera.inc').read_bytes()==camera[:camera.index(b'#include')]+camera[a:b]+b'\n'
print('Verified original lighting/background configuration and all six background loops.')

a=camera.index(b'class cGrCarCamBehind2 :');b=camera.index(b'class cGrCarCamCenter :',a)
assert (root/'Upstream/Reference/graphics/camera-exterior.inc').read_bytes()==camera[:camera.index(b'#include')]+camera[a:b]
a=camera.index(b'    /* cam F3 = car behind*/');b=camera.index(b'    /* F6 */',a)
assert (root/'Upstream/Reference/graphics/camera-exterior-presets.inc').read_bytes()==camera[:camera.index(b'#include')]+camera[a:b]
print('Verified original F3/F4/F5 exterior camera classes and factory presets.')

v=(root/'Upstream/Reference/graphics/grvtxtable.cpp').read_bytes()
a=v.index(b'\ttdble ttx =',v.index(b'void grVtxTable::draw_geometry_for_a_car ()'));b=v.index(b'\n\tint num_colours',a)
assert (root/'Upstream/Reference/graphics/reflection-matrices.inc').read_bytes()==v[:v.index(b'#include')]+v[a:b]+b'\n'
print('Verified original car reflection texture matrices.')

a=v.index(b'\tif (mapLevelBitmap <= LEVELC3 && grEnvShadowStateOnCars)',v.index(b'void grVtxTable::draw_geometry_for_a_car_array'));b=v.index(b'\n\n\n\tgrEnvState->apply',a)
assert (root/'Upstream/Reference/graphics/track-shadow-matrix.inc').read_bytes()==v[:v.index(b'#include')]+v[a:b]+b'\n'
print('Verified original track shadow texture matrix.')

for filename,start,end in [('wheel-model-load.inc',b'\t// Create wheels for 4 speeds',b'\n\t\t// if we have a 3D wheel'),('car-shadow-scale-init.inc',b'\t/* add wheels */',b'\n\n\t/* Other LODs */')]:
    a=graphics.index(start);b=graphics.index(end,a)
    assert (root/'Upstream/Reference/graphics'/filename).read_bytes()==graphics[:graphics.index(b'#include')]+graphics[a:b]+b'\n'
print('Verified original detailed-wheel loads and car shadow scale assignment order.')

for name,a,b in [('camera-driver.inc', b'class cGrCarCamInside :', b'/* MIRROR */'), ('camera-survey.inc', b'class cGrCarCamCenter :', b'class cGrCarCamRoadNoZoom :'), ('camera-survey-presets.inc', b'    /* F6 */', b'    /* F8 */'), ('camera-driver-preset.inc', b'    /* cam F2 = car inside with car (bonnet view) */', b'    /* cam F2 = car inside car (no car - road view) */')]:
    start=camera.index(a);end=camera.index(b,start)
    assert (root/'Upstream/Reference/graphics'/name).read_bytes()==camera[:camera.index(b'#include')]+camera[start:end]
a=scene.index(b'\tgrWrldX =');b=scene.index(b'\n',scene.index(b'\tgrWrldMaxSize =',a))
assert (root/'Upstream/Reference/graphics/camera-world.inc').read_bytes()==scene[:scene.index(b'#include')]+scene[a:b]+b'\n'
print('Verified original driver/circuit/panorama classes, presets and world dimensions.')

for source,name,start,end in [('grcam.h','mirror-class.inc',b'class cGrCarCamMirror :',b'#define GR_ZOOM_IN'),('grcam.cpp','mirror-methods.inc',b'cGrCarCamMirror::~',b'class cGrCarCamInsideFixedCar :'),('grscreen.cpp','mirror-factory.inc',b'\tif (mirrorCam == NULL)',b'\n\t// Scene Cameras'),('grscreen.cpp','mirror-layout.inc',b'\tif (mirrorCam) {',b'\n\tif (curCam)')]:
    data=(root/'Upstream/Reference/graphics'/source).read_bytes();a=data.index(start);b=data.index(end,a)
    header=data[:data.index(b'#include')] if source!='grcam.h' else data[:data.index(b'#ifndef')]
    assert (root/'Upstream/Reference/graphics'/name).read_bytes()==header+data[a:b]
print('Verified original mirror class, methods, factory and layout.')

for name,a,b in [('camera-road-fixed.inc',b'class cGrCarCamRoadNoZoom :',b'class cGrCarCamRoadFly :'),('camera-road-zoom.inc',b'class cGrCarCamRoadZoom :',b'static tdble\nGetDistToStart'),('camera-road-presets.inc',b'    /* F8 */',b'    /* F10 */')]:
    start=camera.index(a);end=camera.index(b,start)
    assert (root/'Upstream/Reference/graphics'/name).read_bytes()==camera[:camera.index(b'#include')]+camera[start:end]
print('Verified original F8/F9 trackside classes and factory presets.')

assert b'void limitFov(void)  {}' in (root/'Upstream/Reference/graphics/grcam.h').read_bytes()
print('Verified empty original perspective limitFov used by trackside capture.')

for name,a,b in [('camera-zoom.inc',b'void cGrPerspCamera::setZoom(int cmd)',b'void cGrOrthoCamera::setProjection'),('camera-load-defaults.inc',b'void cGrPerspCamera::loadDefaults',b'/* Give the height'),('camera-supported-presets.inc',b'    /* F2 */',b'    /* F10 */')]:
    start=camera.index(a);end=camera.index(b,start)
    assert (root/'Upstream/Reference/graphics'/name).read_bytes()==camera[:camera.index(b'#include')]+camera[start:end]
print('Verified original zoom commands, defaults loader and all 29 supported factory entries.')

import re
zoom_header=(root/'Upstream/Reference/graphics/grcam.h').read_text()
for name,value in [('IN',0),('OUT',1),('MAX',2),('MIN',3),('DFLT',4)]:
    assert int(re.search(r'#define\s+GR_ZOOM_'+name+r'\s+(\d+)',zoom_header).group(1))==value
settings_header=(root/'Upstream/Reference/private/graphic.h').read_text()
for name,value in [('GR_SCT_DISPMODE','Display Mode'),('GR_ATT_FOVY','fovy')]:
    assert re.search(r'#define\s+'+name+r'\s+"([^"]+)"',settings_header).group(1)==value
print('Verified original zoom command numbers and preference path/key constants.')

# Height query executes original PLIB methods without graphics dependencies.
height=root/'Upstream/Reference/graphics/height'
for filename,name,marker in json.loads((height/'excerpts.json').read_text()):
    source=(height/filename).read_bytes();a=source.index(marker.encode());b=source.index(b'{',a)+1;depth=1
    while depth:
        if source[b:b+1]==b'{':depth+=1
        elif source[b:b+1]==b'}':depth-=1
        b+=1
    assert (height/(name+'.inc')).read_bytes()==source[:source.index(b'#include')]+source[a:b]+b'\n'
source=(root/'Upstream/Reference/graphics/grutil.cpp').read_bytes();a=source.index(b'float grGetHOT(')
assert (height/'gr-height.inc').read_bytes()==source[:source.index(b'#include')]+source[a:]
source=(height/'ssgIsect.cxx').read_bytes()
assert b'#define MAX_HITS  100' in source
assert b'int _ssgIsHotTest = FALSE' in source
source=(height/'grvtxtable.h').read_bytes()
assert b'int getNumTriangles ()  { return ssgVtxTable::getNumTriangles();}' in source
assert b'ssgVtxTable::getTriangle(n,v1,v2,v3);' in source
print('Verified original scene-height traversal, triangle enumeration, hit limit and grGetHOT excerpts.')

for name,start,end in [('camera-fly.inc',b'class cGrCarCamRoadFly :',b'class cGrCarCamRoadZoom :'),('camera-fly-preset.inc',b'    /* F10 */',b'    /* F11 */')]:
    a=camera.index(start);b=camera.index(end,a)
    assert (root/'Upstream/Reference/graphics'/name).read_bytes()==camera[:camera.index(b'#include')]+camera[a:b]
print('Verified original F10 fly-camera class and factory excerpt.')

for name,start,end in [('camera-tv.inc',b'static tdble\nGetDistToStart',b'\n\nvoid\ngrCamCreateSceneCameraList'),('camera-tv-preset.inc',b'    /* F11 */',b'\n}')]:
    a=camera.index(start);b=camera.index(end,a)
    assert (root/'Upstream/Reference/graphics'/name).read_bytes()==camera[:camera.index(b'#include')]+camera[a:b]
print('Verified original TV director helper, class and factory excerpts.')

for file,line in [('graphic.h','#define GR_SCT_TVDIR\t\t"TV Director View"'),('graphic.h','#define GR_ATT_CHGCAMINT\t"change camera interval"'),('graphic.h','#define GR_ATT_EVTINT\t\t"event interval"'),('graphic.h','#define GR_ATT_PROXTHLD\t\t"proximity threshold"'),('grmain.h','#define GR_NB_MAX_SCREEN 4')]:
    assert line in (root/'Upstream/Reference'/('private' if file=='graphic.h' else 'graphics')/file).read_text()
print('Verified TV director configuration keys and four-screen limit.')

# Shadow visibility, including mirror/current-car exclusion.
graphics=(root/'Upstream/Reference/graphics/grcar.cpp').read_bytes()
a=graphics.index(b'\tif ((car == curCar) && (dispCarFlag != 1)) {',graphics.index(b'grCarInfo[index].carTransform->setTransform(grCarInfo[index].carPos);'))
b=graphics.index(b'\n\t\n\tgrUpdateSkidmarks',a)
assert (root/'Upstream/Reference/graphics/shadow-visibility.inc').read_bytes()==graphics[:graphics.index(b'#include')]+graphics[a:b]+b'\n'
print('Verified original per-car shadow visibility block.')

# Entire original initWheel prefix, through hub, disc, caliper and attachment.
graphics=(root/'Upstream/Reference/graphics/grcar.cpp').read_bytes()
a=graphics.index(b'static ssgTransform *initWheel(');b=graphics.index(b'\n\t/* wheels */',a)
assert (root/'Upstream/Reference/graphics/brake-init.inc').read_bytes()==graphics[:graphics.index(b'#include')]+graphics[a:b]+b'\n'
print('Verified original hub/disc/caliper initialization prefix.')

light=(root/'Upstream/Reference/graphics/grcarlight.cpp').read_bytes()
header=light[:light.index(b'#include')]
a=light.index(b'void ssgVtxTableCarlight::draw_geometry ()');b=light.index(b'\n\nssgSimpleState',a)
assert (root/'Upstream/Reference/graphics/carlight-draw.inc').read_bytes()==header+light[a:b]
a=light.index(b'void grUpdateCarlight(')
assert (root/'Upstream/Reference/graphics/carlight-update.inc').read_bytes()==header+light[a:]
a=graphics.index(b'\tsnprintf(path, PATHSIZE, "%s/%s", SECT_GROBJECTS, SECT_LIGHT);');b=graphics.index(b'\n\tgrLinkCarlights',a)
assert (root/'Upstream/Reference/graphics/carlight-config.inc').read_bytes()==graphics[:graphics.index(b'#include')]+graphics[a:b]+b'\n'
header=(root/'Upstream/Reference/graphics/grcarlight.h').read_bytes();a=header.index(b'#define MAX_NUMBER_LIGHT');b=header.index(b'typedef struct',a)
assert (root/'Upstream/Reference/graphics/carlight-constants.inc').read_bytes()==header[:header.index(b'/** @file')]+header[a:b]
print('Verified original car-light draw, update, configuration and constants excerpts.')

# Original scene traversal, deferred ordering, anchors and whole-car comparator.
order_parts = [
  [
    "leaf-cull.inc",
    "height/ssgLeaf.cxx",
    "void ssgLeaf::cull (",
    "\nvoid ssgLeaf::hot ("
  ],
  [
    "branch-cull.inc",
    "height/ssgBranch.cxx",
    "void ssgBranch::cull (",
    "\nvoid ssgBranch::hot ("
  ],
  [
    "entity-name.inc",
    "height/ssgEntity.cxx",
    "ssgEntity* ssgEntity::getByName (",
    "\n\n/*"
  ],
  [
    "branch-name.inc",
    "height/ssgBranch.cxx",
    "ssgEntity *ssgBranch::getByName (",
    "\n\nssgEntity *ssgBranch::getByPath"
  ],
  [
    "deferred-list.inc",
    "order/ssgDList.cxx",
    "enum _ssgDListType",
    "\nvoid _ssgPushMatrix ("
  ],
  [
    "deferred-append.inc",
    "order/ssgDList.cxx",
    "void _ssgDrawLeaf (",
    None
  ],
  [
    "anchor-init.inc",
    "grscene.cpp",
    "\t/* Landscape */",
    "\n\n\tinitBackground();"
  ],
  [
    "driver-wrap.inc",
    "grcar.cpp",
    "\t/* Set a selector on the driver */",
    "\n\n"
  ],
  [
    "car-distance.inc",
    "grcam.cpp",
    "float\ncGrCamera::getDist2 (",
    "\n\nstatic void"
  ],
  [
    "car-compare.inc",
    "grscreen.cpp",
    "static class cGrPerspCamera *ThedispCam;",
    "\nvoid cGrScreen::camDraw("
  ]
]

for name,source,start,end in order_parts:
    data=(root/'Upstream/Reference/graphics'/source).read_bytes()
    a=data.index(start.encode());b=len(data) if end is None else data.index(end.encode(),a)
    if name=='driver-wrap.inc':b=data.index(b'\n\n',data.index(b'grCarInfo[index].driverSelectorinsg = false;',a))
    assert (root/'Upstream/Reference/graphics/order'/name).read_bytes()==data[:data.index(b'#include')]+data[a:b]
print('Verified original scene anchors, driver wrapper, SSG deferred queue and car comparator excerpts.')

# Original frame depth comparison and mesh draw paths.
depth_parts = [('frame-depth.inc', 'grmain.cpp', '    glDepthFunc(GL_LEQUAL);', '\n    glClear('), ('frame-draw.inc', 'order/ssg.cxx', 'void ssgCullAndDraw (', '\n\n\nconst char *ssgAxisTransform'), ('vertex-draw.inc', 'height/ssgVtxTable.cxx', 'void ssgVtxTable::draw ()', '\n\nvoid ssgVtxTable::pick ('), ('car-vertex-draw.inc', 'grvtxtable.cpp', 'void grVtxTable::draw ()', '\nvoid grVtxTable::draw_geometry_multi (')]
for name,source,start,end in depth_parts:
    data=(root/'Upstream/Reference/graphics'/source).read_bytes();a=data.index(start.encode());b=data.index(end.encode(),a)
    assert (root/'Upstream/Reference/graphics/order'/name).read_bytes()==data[:data.index(b'#include')]+data[a:b]
print('Verified original LEQUAL frame setup, deferred dispatch and depth-preserving mesh draw excerpts.')

# Original PLIB partial state and per-view basic state.
alpha_parts = [('apply.inc', 'ssgSimpleState.cxx', 'void ssgSimpleState::apply (void)', '\nvoid ssgSimpleState::force (void)'), ('force.inc', 'ssgSimpleState.cxx', 'void ssgSimpleState::force (void)', '\n\n\nint ssgSimpleState::isEnabled'), ('constructors.inc', 'ssgSimpleState.cxx', 'ssgSimpleState::ssgSimpleState ( int', '\nssgSimpleState::~ssgSimpleState'), ('disable.inc', 'ssgSimpleState.cxx', 'void ssgSimpleState::disable', '\nvoid ssgSimpleState::enable'), ('enable.inc', 'ssgSimpleState.cxx', 'void ssgSimpleState::enable', '\n\nint ssgSimpleState::load'), ('basic.inc', 'ssgContext.cxx', '  basicState->setTexture ( (ssgTexture*) NULL ) ;', '\n\n  for ( int i = 0 ; i < 6 ; i++ )'), ('constants.inc', 'ssg.h', '#define SSG_GL_TEXTURE_EN', '\n#define SSG_CLONE_RECURSIVE'), ('alpha-setter.inc', 'ssg.h', '  virtual void setAlphaClamp ( float clamp )', '\n \n\t/*int getWrapU')]
for name,source,start,end in alpha_parts:
    data=(root/'Upstream/Reference/graphics/state'/source).read_bytes();a=data.index(start.encode());b=data.index(end.encode(),a)
    assert (root/'Upstream/Reference/graphics/state'/name).read_bytes()==data[:data.index(b'*/')+2]+b'\n\n'+data[a:b]
print('Verified original SSG apply/force, constructors, alpha setter, enable/disable and basic-state excerpts.')
