# Upstream pin

- Project: TORCS — The Open Racing Car Simulator (not Speed Dreams).
- Release: **1.3.9**, published 2026-04-10.
- Release source: https://sourceforge.net/projects/torcs/files/all-in-one/1.3.9/torcs-1.3.9.tar.bz2/download
- Official release listing: https://torcs.sourceforge.net/download/
- Archive SHA-256: `f9c69e86d290295467451b01d7838d85005ba613644a6fe8a3f85a7c6a03cd4c`
- Examined local archive: `/Users/holgervonameln/Downloads/torcs-1.3.9.tar.bz2`.
- Examined extracted tree: `/Users/holgervonameln/Downloads/torcs-1.3.9`.
- Source revision identity: exact release archive above. It contains unresolved
  `$Id$` keywords and no repository metadata; no SVN/Git revision is asserted.
- The SHA-256 identifies the locally supplied archive; it is not claimed to be
  an independently authenticated publisher checksum.

`Upstream/source-manifest.json` pins every vendored reference file. TORCS files
keep their GPL-2.0-or-later notices; bundled SOLID and PLIB dependencies retain
LGPL-2.0-or-later notices and license texts. The original simuv2 dynamics,
track3/track4 loader, track queries, complete parameter parser, SOLID collisions
and PLIB mathematics run in the test-only CReference target. The native app has
no dependency on this target. Original pit management is also exercised through unchanged raceengine.cpp and
a byte-verified initPits excerpt; see RACE_PITS.md for the headless boundary.
The unchanged original ACC parser also runs with headless scene-storage adapters
before SSG optimization or texture loading. Original SGI decoding and TORCS CPU
mipmap generation now run through GL-upload capture adapters; see ASSET_PIPELINE.md. Original BT now runs selected callbacks and a physical one-lap reference race through ReOneStep; full race-mode and native robot execution remain pending (ROBOT_API.md).

The two modified PLIB files record original `source_sha256` and current `sha256`:
`sg.cxx` uses `isfinite` in place of unavailable `finite`; `ulError.cxx` replaces
unbounded `vsprintf` with `vsnprintf`. Neither patch changes physics equations.
Project-authored bridge/platform files are separate from imported files.

The original parameter parser links the macOS Expat tokenizer rather than
vendoring TORCS's historical bundled tokenizer. Reference fixtures are hash
checked before entering the legacy parser. Only the temporary staged copy of
objects.xml changes its incorrect UTF-8 declaration to ISO-8859-1. The original
Latin-1 bytes, fixture, and hash remain unchanged. This substitution and the
scripted harness initialization are recorded in capture metadata.

Archive audit: `Scripts/verify-upstream-archive.py` checks the archive digest and
all 211 imported source/content/license files against archive members, using
original hashes for the two patched files. No archive files are extracted.

PNG reference tests use the release's bundled libpng 1.6.50 with its prebuilt
configuration and generic CPU path, linked to system zlib. The entire original
GfImgReadPng function is a byte-verified excerpt from unchanged img.cpp. Neither
that function nor vendored libpng is linked into native products. PNG behavior is
pinned to this explicit library version; see ASSET_PIPELINE.md.

Original grcar.cpp is also pinned. A byte-verified wheel-update loop runs with
PLIB transforms and capture objects in CReference; no legacy graphics API runs.
See VEHICLE_PRESENTATION.md for the wheel oracle and native snapshot boundary.

The original `grcam.cpp` is pinned for chase-camera parity. Its unmodified
`cGrCarCamBehind` class is byte-verified and compiled through a capture adapter;
the existing original `robottools.h` supplies RELAXATION.

The existing unchanged raceengine.cpp now also provides the selected single-human
lap timing/validity oracle. Its adapter preserves previous segment state, captures
18 fields, no-ops practice result persistence and temporarily bypasses professional
pit penalties during ReManage only. It restores physics skill before SimUpdate.
No additional original files were imported for this increment. See LAP_TIMING.md.

Track graphics now also pin grscene/grscreen/grcam.h/grutil and the original
Aalborg sky PNG. Verbatim configuration, background geometry and camera excerpts
are byte-verified and executed only in the reference target.

Car reflection work adds unchanged grvtxtable.cpp and grmultitexstate.cpp.
The former supplies a byte-verified texture-matrix excerpt run through a
headless capture adapter; the latter records texture binding behavior.
The current manifest contains 165 source/license entries and 46 content entries.

The track-shadow increment uses existing grvtxtable/grcar/grloadac pins. Three
additional verbatim excerpts exercise the projected texture matrix, detailed-wheel
load loops and subsequent sx/sy assignment. The loader adapter also publishes its
original raw XY bounds. No new original source or artwork was imported.

Driver and circuit-camera work adds five byte-verified excerpts from the existing
grcam.cpp/grscene.cpp pins: driver class/factory, circuit/panorama classes/factory
and world-size assignments. The capture adapter executes their default camera
updates. Zoom and saved preference paths are not exercised. The manifest remains
165 source/license entries and 46 content entries; no artwork was added.

The rear-view mirror adds four verbatim excerpts from the already-pinned grcam.h,
grcam.cpp and grscreen.cpp. Headless GL-call capture executes the original class,
methods, factory and screen layout, recording the viewport, scissor, copy source
and display vertices/UVs. Allocation and the power-of-two helper are stubbed;
legacy texture allocation and original GL pixels are not verified. No additional
original source or artwork is imported. See REAR_VIEW_MIRROR.md.

Optional edge smoothing uses Metal's 4× MSAA and an independent analytic
pixel-coverage fixture. The existing original src/libs/tgfclient/screen.cpp was
also inspected: its "best" video initialization requests a GLUT multisample
visual with fallback paths. The inspected file matches the pinned archive
(SHA-256 59ba3e4d3753ac86ae90058e9dd730a99ce6b1dabd7569e40f985e41ce61b2d8).
It was not imported, and no new original source/artwork was added. The selected
GL visual, sample pattern and resolve are not a native pixel-parity claim.

Trackside camera work adds three byte-verified excerpts from the existing
`grcam.cpp` pin: F8 fixed class, F9 zoom class and their factory. The camera
adapter's empty perspective `limitFov` matches the pinned `grcam.h`. Original
`track4.cpp` runs unchanged; a read-only world adapter exports each segment's
camera name and normalized position. No original source/artwork was added;
165 source/license and 46 content manifest entries remain unchanged. See
TRACKSIDE_CAMERAS.md for native handling of invalid and empty definitions.

Camera zoom adds three verbatim excerpts from the existing grcam.cpp pin: the
complete base zoom method, base default loader and all supported F2–F9 factory
entries. The reference adapter captures parameter reads/writes in memory and
executes original derived zoom/default/update methods through virtual dispatch.
The corresponding command constants and preference-key strings were checked in
the existing grcam.h/private/graphic.h pins. No source/artwork import was added;
manifest counts remain 165 source/license and 46 content entries. Native JSON
persistence is separate from original graph.xml compatibility. See CAMERA_ZOOM.md.

Fly-camera groundwork imports six unchanged PLIB SSG sources from the release's
`src/windows/dependencies/vs2022_win32/plib-code-r2173-trunk-vsproj/src/ssg/`
plus TORCS `grvtxtable.h`. They retain their original LGPL/GPL notices and pinned
archive hashes. The manifest now contains 174 source/license and 46 content
entries. No artwork is added. Twelve notice-retaining PLIB method excerpts,
`grGetHOT` from the existing grutil.cpp pin, and the F10 class/factory from the
existing grcam.cpp pin are byte-verified by the provenance script. The test-only
storage adapter executes original math/traversal rather than an independently
rewritten triangle oracle. Its selected-scene, no-callback/no-optimization boundary is
explicit in FLY_CAMERA.md. Original fly randomness uses this host's libc in tests;
native cameras own separate random state.

The F10 integration additionally pins unchanged `ssgSelector.cxx` and
`ssgRangeSelector.cxx` from the same bundled PLIB source and executes their
notice-retaining HOT excerpts in tests. The full provenance inventory is now
220 source/content/license entries. Native `SceneHeightAssembly` retains PLIB
attribution and LGPL section-3 conversion notice. No artwork is added.

The TV director increment adds unchanged grmain.h for the four-screen limit and
reuses the existing private/graphic.h pin for parameter names. The inventory is
175 source/license plus 46 content entries. The original GetDistToStart helper,
full TV director class and F11 factory excerpts are byte-verified. Only test
instrumentation changes default class-field access to expose original state;
algorithm statements are unchanged. See TV_DIRECTOR.md for the adapter boundary.


The multi-car shadow increment derives a notice-retaining `shadow-visibility.inc`
from the already pinned grcar.cpp. The provenance verifier checks it byte-for-byte;
the test adapter captures only the original per-car visibility decision. No new
original source or artwork files are pinned. Existing shadow-geometry and track
height oracles remain responsible for projection comparisons. Native traffic
rendering and GPU blend/crop tests are documented in MULTI_CAR_SHADOWS.md.

The brake visual increment derives a notice-retaining `brake-init.inc` prefix
from the already pinned `grcar.cpp`. It includes original hub/disc/caliper
initialization through the wheel-position assignment, before wheel loading.
The verifier checks the exact source slice. A test-only storage adapter captures
original arrays and material identities; native BrakeGeometry retains original
attribution. Original wheel-update instrumentation additionally exports the
wheel-position matrix before spin. The inventory remains 221 pinned entries;
no original artwork is added. See BRAKE_VISUALS.md.

The car-light groundwork pins unchanged grcarlight.cpp and grcarlight.h from the
same TORCS 1.3.9 archive (Copyright 2001/2003 Christophe Guionneau). Inventory is
177 source/license plus 46 content entries, 223 total. Verbatim excerpts retain
original notices and execute only in the reference adapter. GL calls are captured;
texture-matrix multiplication uses original PLIB, not an original GL driver.
No light textures are newly imported. See CAR_LIGHTS.md for scope.

The car-light renderer additionally compares point culling through the already
pinned original `sgFrustum` and one-point HOT leaves through `ssgVtxTable`.
Unchanged bundled PLIB `ssgLeaf.cxx`, `ssgDList.cxx` and `ssgTexture.cxx` were
inspected locally for deferred draw order and GL_CLAMP texture setup; they are
not new imported source files. Their archive/source hashes are recorded in
`car-light-rendering-report.json`. The pinned inventory remains 223 entries.
GPU fixtures test native state and sampling, not original OpenGL driver output.

The draw-order increment newly pins unchanged PLIB `ssgDList.cxx`, `ssg.cxx`
and TORCS `grmain.cpp`, reusing
already-pinned ssgLeaf/ssgBranch/ssgEntity and TORCS grscene/grcar/grcam/grscreen.
Fourteen notice-retaining excerpts execute original deferred leaf submission, child
traversal/name search, anchor initialization, driver wrapping and whole-car
comparison, frame depth setup/dispatch and ordinary mesh draw paths. The
provenance verifier checks all excerpts byte-for-byte. Inventory is now 180
source/license plus 46 content entries, 226 total. Adapters supply
storage and visibility, with GL matrix calls stubbed; no original raster driver,
arbitrary callbacks or queue-overflow behavior is claimed. See DRAW_ORDER.md.

The alpha-state increment adds unchanged bundled PLIB ssgSimpleState.cxx,
ssgContext.cxx and ssg.h, with eight exact excerpts for constructors, basic state,
constants, alpha setter, enable/disable and apply/force. The inventory is now 183
source/license plus 46 content entries, 229 total, checked against the archive.
The ACC loader storage adapter additionally records whether alpha setters were
called, distinguishing inherited values from explicit enable/disable. Its new
metadata is checked against the native parser. See ALPHA_STATE.md for scope.
