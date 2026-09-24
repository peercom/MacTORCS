# Third-party notices

## TORCS 1.3.9 reference code and XML fixtures

Copyright Eric Espie, Bernhard Wymann and the other authors named in each file.
License: GNU General Public License version 2 or, at the recipient's option,
any later version (GPL-2.0-or-later). Original notices remain in place.
`Upstream/source-manifest.json` lists exact sources and hashes. Native semantic
ports retain attribution in the Swift files; new application code is offered
under GPL-2.0-only. See LICENSE for the full GPL version 2 text.

## SOLID collision implementation

Copyright (C) 1997-1998 Gino van den Bergen; additional notices retained per file.
`Upstream/Reference/solid`, `private/3D`, and `private/SOLID` contain original
implementation and declarations, under GNU Library General Public License
version 2 or later. Full text: `Upstream/Licenses/SOLID-LGPL-2.0.txt`.
The original implementation is linked into reference tools/tests, never the
native application. `Packages/TORCSSimulation/ConvexCollision.swift`,
`CollisionAffineTransform.swift` and `ComplexCollision.swift` semantically port
support maps, transforms, convex queries and complex-shape hierarchy traversal
with retained attribution. Their derived portions are converted to GPL version 2
under LGPL version 2 section 3, effective 2026-09-23; these Swift files are
GPL-2.0-only.

## PLIB mathematics and reference mesh parser

Copyright (C) 1998,2002 Steve Baker and other contributors named in each file.
Original SG/SGD mathematics and UL diagnostics from the PLIB snapshot bundled
in the pinned TORCS archive are retained under LGPL-2.0-or-later. Full text and
its embedded-system linking exception: `Upstream/Licenses/PLIB-LGPL-2.0.txt`.
The exception is retained verbatim; this project does not rely on it.
Two documented changes use macOS `isfinite` and bounded diagnostic formatting.
The original TORCS/PLIB grloadac.cpp is imported only for reference mesh tests;
no PLIB graphics subsystem is linked into the native application.
The original PLIB source is linked only into reference tools/tests. The native
`Packages/TORCSSimulation/WheelKinematics.swift` semantically ports the rotation
and vector-transform expressions, preserving their attribution and arithmetic
order. Those derived portions are converted to GPL version 2 under LGPL version
2 section 3, effective 2026-09-22; the entire Swift file is GPL-2.0-only.

The original `grloadac.cpp` retains Copyright (C) 2001 Steve Baker and
LGPL-2.0-or-later. Native `Packages/TORCSAssets/ACScene.swift` and `ACParser.swift`
semantically port its scene construction with attribution retained. Their derived
portions are converted to GPL version 2 under LGPL version 2 section 3, effective
2026-09-23; both Swift files are GPL-2.0-only. `ul.cxx` supplies the actual original
token comparison in reference tests. Headless scene-storage adapters are project
code, not a replacement graphics backend.

Original `textures/ssgLoadSGI.cxx` (Steve Baker, 1998/2002, LGPL-2.0-or-later)
and `textures/grtexture.cpp` (Bernhard Wymann, 2005, GPL-2.0-or-later, with separately
noted PLIB LGPL portions) run only in reference tests. Their notices are intact.
`Packages/TORCSAssets/TextureImage.swift` retains both attributions; its derived
LGPL portions are converted to GPL version 2 under LGPL version 2 section 3,
effective 2026-09-23. The native file is GPL-2.0-only. Original CPU mipmaps are
captured through test-only GL function adapters; no original graphics API runs.

## PNG reference library and image compatibility

`Upstream/PNGReference` contains unmodified libpng 1.6.50 source/configuration from
the pinned TORCS archive, under the PNG Reference Library License version 2
(SPDX: Libpng-2.0); full copyright, disclaimer and permission terms remain in its
LICENSE and source files. It uses system zlib and generic CPU code in reference
tests/tools only. Original TORCS img.cpp retains its GPL-2.0-or-later notice,
Copyright (C) 1999-2014 Eric Espie, Bernhard Wymann. Its entire GfImgReadPng function
is reproduced verbatim in the checked reference excerpt.

The native `PNGTextureImage.swift` is GPL-2.0-only and uses Apple ImageIO for PNG
decompression with explicit TORCS compatibility transforms. It retains TORCS
attribution and the libpng notice/license for adapted gamma-table logic. Those
adaptations are marked as modifications; no original libpng binary or source is
linked into the app or native compiler. Full reference library notices remain
available alongside corresponding project source.

## Frameworks and build tools

Uses Apple-provided Swift, Foundation, AppKit, SwiftUI, Metal/MetalKit, ImageIO, CryptoKit, SIMD and
os APIs on macOS. The reference target uses the MIT-licensed Expat supplied by
the macOS SDK/system; its original parameter parser calls that tokenizer.
The reference ACC parser uses the macOS system zlib for its original file reader.
No Expat source/binary is copied into this repository or packaged application.
No Swift package dependencies are downloaded. No upstream executable, OpenGL
renderer or audio runtime is linked into the app.

## Content

Imported content comprises seven original XML fixtures with GPL notices and
the unchanged 155-DTM/Aalborg meshes with their two original directory notices,
plus 27 SGI textures from those directories, Aalborg raceline.png and background.png, and the four
trb1-3 wheel meshes, wheel3d.png and its original 2010 Bernhard Wymann notice.
The artwork files retain unversioned Free Art License notices, original
authors and source access; see `Documentation/ASSET_LICENSES.md` and
`Resources/asset-manifest.json`. They are separately accessible test fixtures,
not GPL-relicensed artwork or current app resources. Other texture dependencies, additional wheel
models, sounds, fonts and icons are not included.
The upstream non-free `kc-*` and `pw-*` assets are excluded.

New non-code artwork defaults to CC BY-SA 4.0 when introduced. The current
inspection geometry is generated by source code as a diagnostic primitive;
that source is GPL-2.0-only. No independent artwork license is asserted for
upstream material. Project-authored engineering documentation uses CC BY-SA 4.0
unless otherwise stated; the specification supplied by the user is not relicensed.

This is a development build. Complete content and distribution review remains
a release requirement, as does providing corresponding source with binaries.

The initial scene renderer interprets the retained TORCS/PLIB mesh and material
states. New renderer sources retain attribution to Steve Baker and Christophe
Guionneau. The local scene verification command can read five shared Aalborg
textures from an explicitly selected upstream directory. Those files and their
compiled derivatives are not added to source fixtures or the distributable app;
precise per-file attribution remains required before redistribution.

`Upstream/Reference/graphics/grcar.cpp` retains its GPL-2.0-or-later notice,
Copyright (C) 2000 Eric Espie. Its wheel-update excerpt is byte-verified and
executes only in the reference harness. Native vehicle presentation and new
simulation publication code retain the corresponding upstream attributions.

The pinned `grcam.cpp` and verbatim behind-camera class retain Copyright (C) 2000
Eric Espie, GPL-2.0-or-later. The native `DrivingCamera.swift` semantic port retains
that attribution and is distributed as GPL-2.0-only.

The pinned human driver `human.cpp` and `pref.h` retain Copyright (C) 2000-2024
Eric Espie, Bernhard Wymann, GPL-2.0-or-later. Three byte-verified joystick branches
execute only in the test reference. The native `AxisCalibration.swift` semantic
port retains that attribution and is distributed as GPL-2.0-only.

The original BT robot source in `Upstream/Reference/robots/bt` and its index-0
setup fixture retain their original GPL-2.0-or-later notices, including Eric
Espie and Bernhard Wymann. They execute only in the reference/test products.
The bonnet-camera and shadow-footprint excerpts are byte-verified against the
pinned grcam/grcar files. `grshadow.cpp` retains Copyright (C) 2001 Christophe
Guionneau, GPL-2.0-or-later; its depth-offset behavior informs the native pass.
The shadow texture is the already-manifested Free Art 155-DTM artwork.

Track lighting/background semantic ports derive from grscene.cpp and grcam.cpp
(Copyright Eric Espie) and the retained scene/texture setup sources. The new
Aalborg background.png fixture retains its directory's unversioned Free Art
notice and separate asset-manifest provenance; it is not relicensed as GPL.

Original grvtxtable.cpp and grmultitexstate.cpp (2001 Christophe Guionneau,
GPL-2.0-or-later) are pinned for car environment-map behavior. A byte-verified
texture-transform excerpt runs only in the test target with GL capture adapters.
Native CarReflection and Metal material integration retain their attribution.
The shared env.png/envshadow.png remain local-only inputs with unresolved
per-file artwork terms; they are not bundled with the app or repository.

Track shadow projection additionally executes byte-verified grvtxtable and grcar
excerpts for the texture matrix, detailed-wheel load loops and later scale
assignment, only in the reference target. Native raw-loader bounds remain under
the existing ACParser/ACScene attribution and LGPL-to-GPL conversion notice.
No additional original artwork is imported: the selected shadow2.rgb was already
in the Aalborg Free Art fixtures.

Driver, circuit-center and panorama cameras additionally execute byte-verified
class/factory excerpts from the pinned grcam.cpp and world-size assignments from
grscene.cpp, only in the reference target. Native DrivingCamera and CameraWorld
retain upstream attribution and use GPL-2.0-only. DRIVER subtree visibility
follows the already-pinned grcar.cpp selector behavior. No artwork is added.

The rear-view mirror executes four additional byte-verified excerpts from those
camera sources and grscreen.cpp through test-only GL-call capture. Native
RearViewMirror, renderer composition and the mirror shaders retain the Eric
Espie attribution for the semantic port and are distributed as GPL-2.0-only.
No additional original source file or artwork is imported.

Trackside cameras execute three additional byte-verified grcam.cpp excerpts in
the test-only reference target. Native TrackRoadCamera retains the track4.cpp
attribution to Eric Espie and Bernhard Wymann; CameraWorld and DrivingCamera
retain their grcam.cpp attributions. These semantic ports use GPL-2.0-only.
No original artwork or additional original source file is imported.

Camera zoom executes three further byte-verified grcam.cpp excerpts only in the
reference target. Native CameraZoom command arithmetic and factory metadata
retain Eric Espie's attribution and use GPL-2.0-only. Native JSON preference
storage and UI controls are new GPL-2.0-only source. No original artwork is added.

The static scene-height kernel is a semantic port of TORCS grGetHOT (Copyright
2000 Eric Espie) and PLIB SG/SSG code (Copyright 1998–2004 Steve Baker and
contributors). `SceneHeightQuery.swift` retains attribution and records conversion
of derived LGPL-2.0-or-later portions to GPL v2 under LGPL v2 section 3, effective
2026-09-23. Eight original PLIB source files are retained unchanged under their
original LGPL notices in `Upstream/Reference/graphics/height`; original
`grvtxtable.h` retains both Christophe Guionneau's GPL and Steve Baker's LGPL
notices. Original license texts are already included in Upstream. The original
method excerpts execute only in CReference. `FlyCamera.swift` retains Eric Espie's
attribution for the GPL-2.0-only semantic port of the F10 class. No artwork is added.

`SceneHeightAssembly.swift` likewise preserves Steve Baker's attribution and the
LGPL v2 section-3 conversion notice for selector/range and bound propagation.
`DrivingSceneHeight.swift` retains Eric Espie's attribution for original scene
anchor, car and wheel graph ordering. Additional selectors remain test-only
original PLIB code; native runtime stays Swift/Metal.

`TVDirector.swift` and `TVCamera.swift` retain Eric Espie's attribution for the
GPL-2.0-only semantic port of original F11 selection and projection. The original
class/helper/factory excerpts and grmain.h retain their GPL-2.0-or-later notices.
`PresentationCollisionHistory.swift` credits the original collision accumulation
and screen acknowledgement behavior while separating native presentation state
from simulation. No original artwork is imported by this increment.

Car-light configuration, state, billboard and texture-rotation semantic ports
retain Eric Espie and Christophe Guionneau attribution. The pinned original
grcarlight.cpp/h (Copyright 2001/2003 Christophe Guionneau) retain GPL-2.0-or-later
notices. Original routines execute only through test-only storage/GL-call capture
adapters. Native CarLightDefinition and CarLightGeometry are GPL-2.0-only.
Original light textures are not newly imported or bundled.

The native Metal light submission and shader retain Christophe Guionneau's
car-light attribution. `CarLightFrustum.swift` retains Steve Baker's PLIB
attribution and converts its derived LGPL-2.0-or-later portions to GPL v2 under
LGPL v2 section 3, effective 2026-09-23. The original SG source and license
remain in Upstream. One-point light bounds use the existing attributed HOT port.
The local session preparation consumes `breaklight2.rgb` from the user's TORCS
installation; this shared image has unresolved per-file attribution and is not
redistributed or bundled in the application.

Original SSG draw scheduling now executes in tests using newly pinned unchanged
`ssgDList.cxx` and existing leaf/branch/entity pins, all retaining Steve Baker's
LGPL-2.0-or-later notices. Native SceneRenderer/SceneGeometry record conversion
of derived scheduling portions to GPL v2 under LGPL v2 section 3, effective
2026-09-23. SceneDrawOrder also credits TORCS grscene/grscreen/grcam (Eric Espie
and contributors) for anchors and the whole-car comparator. The macOS native
planner calls the system libc sort; no original C++ or OpenGL queue is linked
into the application. No new artwork is imported.

Depth dispatch checks additionally pin unchanged PLIB `ssg.cxx` (Steve Baker,
LGPL-2.0-or-later) and TORCS `grmain.cpp` (Eric Espie, Bernhard Wymann,
GPL-2.0-or-later), retaining original notices. Notice-retaining excerpts of these
and already pinned vertex sources execute only in test adapters.

Inherited alpha-state interpretation retains PLIB ssgSimpleState/ssgContext
attribution (Steve Baker and contributors). Unchanged ssgSimpleState.cxx,
ssgContext.cxx and ssg.h retain their LGPL-2.0-or-later notices in the test
reference tree. SceneAlphaState converts derived portions to GPL v2 under LGPL
v2 section 3, effective 2026-09-23. The original partial-state routines execute
only through test GL/state adapters; the native application links no original
C++ or OpenGL state implementation. No artwork is added by this change.
