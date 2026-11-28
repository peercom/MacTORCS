# The game shell

The application used to open as a desktop document window: a toolbar of
buttons, a file dialog to pick a session folder, a sheet to configure a run.
It opens as a game: one window, a start screen, and the screens a racing game
has — mode, circuit, car, options, loading, the race with a HUD, a pause menu,
results, a championship, settings, controls and credits — over a library of
circuits and cars that combine freely.

## Content: circuits and cars, any with any

Prepared content used to be a *session*: one folder welding one car to one
track. The game now reads three kinds of folder:

- a **track package** (`track.json`): the track document, the shared surfaces
  and objects, the compiled scenery and its images;
- a **car package** (`car.json`): the car and category documents, the compiled
  body and wheels, its shadow and light images;
- a **session** (`driving.json`), as before, which reads as both at once.

`DrivingContent.load(track:car:opponents:)` loads any track with any car and
the further car models a field will use; `DrivingContent.load(_:)` on a
session folder is the same call with one folder for both. `CarContent` and
`TrackContent` are the two halves.

`ContentLibrary` scans the folders the player has added, plus the game's own
`Application Support/TORCSMac/Content`, to a bounded depth (never into a
package, a hidden folder or past three levels) and describes each package
without loading its models:

- `TrackDescriptor` — name, category, author and description from the header,
  the built road's length, width and number of corners, a `TrackMap` (the
  centreline fitted to the unit square, with the transform that puts a world
  position on it), and the package's preview image if it has one;
- `CarDescriptor` — a display name (the original's class cars are named after
  their files, so `car3-trb1` reads "TRB1 No. 3"), its class, mass, gears, rev
  limit, peak power from the torque curve, drivetrain, and its preview.

Duplicates collapse to the package with a preview. A package that cannot be
described is listed under Settings › Content rather than emptying the menus.

### Building a library

```sh
python3 Scripts/prepare-content-library.py /path/to/torcs-1.3.9
```

prepares a selection of circuits and cars (or `--all`, or `--tracks a,b`,
`--cars x,y`) into the game's content folder as single packages, copies the
generated material sets once to `<library>/materials` and the original's sound
samples to `<library>/sounds`, and has the game render a menu preview of each
car standing on a real grid and of each circuit from the back of its grid
(`TORCSMac --render-preview car|track <track> <car> <out.png>`). It can be
run again to add to a library. `prepare-driving-session.py` gained the single
package modes it uses (`--track NAME` or `--car NAME` alone, `--preview`).

Run on the local install here it prepared **18 circuits and 22 cars**, about
1.3 GB. Getting every one of them to import took five corrections, each to
what the original accepts:

| Content | What it does | The original | Now |
|---|---|---|---|
| car3-trb1 | `max="350.0.0"` | reads numbers with `sscanf("%g")` | longest leading number |
| corkscrew | a stray `-->` as text in a section | has no character-data handler | text between elements ignored |
| e-track-4 | references `&default-objects;` undeclared | its parser skips it | skipped, with nothing from it |
| brondehach, e-track-6, g-track-1, wheel-2 | vertices no surface references | leaves their UV storage uninitialised, never draws them | zero, never drawn |
| g-track-3, street-1 | `texture "(null)"` | fails to load it, draws untextured | no texture for that layer |

The preparation script also read a commented-out `Light` section as content
(car1-ow1); it now strips comments first. The packages copy textures and
sounds whose per-file attribution is unresolved, so they stay local, as the
sessions did.

## The ground's textures

Grass is 60 to 85% of every circuit's surface, and it was drawn as a flat
olive plane. Three things were wrong, and the texture itself was only one.

**Scale.** A generated set is made to tile every two or three metres. The
original scenery spreads one repeat of a texture over twelve to twenty
metres of ground, because its textures were 256 texels wide, and a
generated set substituted for one was drawn at that size: its grain five
times life size, which reads as a blur. A substituted set is now repeated a
whole number of times within each of the original's repeats, the nearest to
its own tile size (`RenderMesh.metresPerTextureRepeat`, and whole so that
the texture still wraps where the mesh's coordinates do).

**The recipes.** In `RecipesTerrain.swift`:

- *Grass* took its blades from stretched noise, which gives a grain and no
  blade. It is now laid down as blades: strokes five centimetres long, dark
  at the root and light at the tip, three deep, each its own green, more of
  them straw where the ground is drier, with clumps a hand across standing
  higher and lighter. It is made for a tile of eight metres at 2048 texels,
  the same four millimetres a texel it had.
- *Rock*, new: bedded, jointed and broken, with iron below the joints and
  lichen on the faces. It replaces the cuttings whose artwork was 256
  texels over thirty metres of cliff (Alpine 1, G-Track 2). The larger
  rock faces are photographs composed top to bottom, grass at the lip and
  scree at the foot, and keep their own.
- *Snow*, new, for Alpine 2: nearly white and nearly matte, so its surface
  carries it, drifts and ripples and a grain of crystals.
- *Asphalt*: each stone its own grey, a few pale and a few nearly black,
  and slight mottles a pace across.

A tile must not have landmarks. The first grass had dry patches two metres
across, three or four to the tile, and every hillside showed them as a grid:
the eye finds a repeat by what stands out in it. Nothing in these sets is
much over a metre, a hundred or more of each thing to the tile, and a test
holds the grass to that.

**What a tile cannot hold** is what changes over tens of metres, a lighter
rise or a darker hollow. That is laid over the ground by the renderer from
the place itself: two scales of noise in world space, taken at the vertices,
lighter and a little yellower one way and darker the other
(`DrawUniforms.fade.w`, `MaterialLibrary.macroVariation`). Grass drifts
most, rock and bare earth less, asphalt and concrete a little, and what a
factory made not at all.

**Names.** Forza's verges (`GRAS2B.png`, a fifth of its surface) were not
matched by the grass rule and kept their original; they, the low-resolution
rock, snow, concrete slabs and cement are now in `MaterialLibrary.rules`.

One fault showed only once the rock had joints. A face turned away from the
sun was lit along every crack: a crack's wall leans toward the sun where the
face leans away, and an open face is in no shadow the map knows of. Direct
light now fades out as the face itself, not its normal map, turns from the
sun.

The cost, previous commit on the previous library against this one, medians
of five at 2880 x 1720: 5.05 to 5.11 ms on CG Speedway 1, 5.78 to 5.91 on
Alpine 1, 6.67 to 6.81 on Forza, where the verges now carry a normal map
they did not have. The two grass sets are 8 MB each on the GPU, four times
what they were.

### The road's wear, and two surfaces remade

The road is two fifths of every frame and was one even surface from kerb to
kerb. Its asphalt is a tile two metres across and can hold nothing larger
than a hand; but a road's history is all landmarks. So it has a second map
(`RoadWear`, `road-wear.png`), laid along the road and across it rather
than tiled: 96 m of road by its whole width, edge to edge. In it:

- the three strips the mat was laid in and the days' work it was laid by,
  each piece its own tone, with the joints between them, sealed with tar
  in the stretches where they have opened;
- cracks running with the road, most of them sealed, and a few short ones
  across it;
- repairs, a rectangle cut out and filled, darker while newer than what is
  round it and paler once older;
- spills, drawn out along the road;
- dust and clippings along both edges, where no tyre clears them.

Four quantities, a channel each: tone, roughness, tar and grime. The road's
shader takes it with one more sample, in the pipeline only a road with
markings uses, and applies it under the paint. The same joints come round
every 96 m, so how heavily they show follows the ground's drift along the
lap: a stretch where they are faint keeps the eye from counting them.

*Concrete* was an even grey, which is new concrete and why every wall
looked like card. It is now concrete that has stood outside: pits where air
was trapped against the form, crazing, sand showing where the skin has worn
through, lime in pale blooms and damp in small mottles. The first version's
damp was a dozen dark blots to the tile and the wall had spots.

*Sand* was a beach, rippled every fifteen centimetres, which across a
run-off read as corduroy. It is now a trap's bed: coarse sand with stones
in it and hollows that hold the damp.

The cost of the three, previous commit against this one on the same
library: 5.32 to 5.39 ms on CG Speedway 1, 5.97 to 6.09 on Alpine 1, 6.79
to 6.89 on Forza. The wear map is 1.4 MB on the GPU.

To regenerate and install:

```sh
swift run -c release torcs-matgen --all --out Artifacts/materials
python3 Scripts/prepare-content-library.py /path/to/torcs-1.3.9
```

The second now copies the sets again whenever they have changed; it used to
copy them once.

### What stands along the track

The ground's sets are the same all over; a tyre wall, a kerb and a guard
rail are objects, and their sets (`RecipesFurniture.swift`) are laid out as
the object is.

*The tyre wall* was drawn as rings, a tyre seen from its side, two to a
stack: on the wall's face that was a wall of tyres standing on their treads
with their holes toward the track. Tyres in a wall lie flat in bolted
columns and show their tread. The set is now that: six tyres up a tile
1.3 m high, two stacks along it, each tyre a drum with shoulders, three
grooves and its own sipes, some worn nearly smooth, none quite plumb on the
one below, the top row painted white and scuffed. The wall's top is the
same tyres from above and so is another picture: its geometry is a batch
of its own (`FurnitureGeneration.tyreWallTops`) on a set of its own
(`tyre-top`), one painted ring to a stack. The back face's normal pointed
up, left from when the top shared its vertices, and now points back.

*The kerb* was paint on flat stone. It is now what a kerb is to the eye:
precast blocks a metre long, red and white by turns, with sixteen sawtooth
ribs to the two metres; paint worn from the crests, dirt in the troughs,
rubber laid along it and flakes gone.

*The guard rail* was one W-beam the height of whatever it was drawn on, so
a metre of barrier was one beam a metre tall. At a circuit rails go up
three deep, and the tile is that: three beams, each two ribs and a valley,
lapped and bolted at its middle, zinc spangle, white bloom, rust at the
bolts and the cut edges, and rubber, paint and bright metal along the ribs
where cars have been. Wheel 1's `barrier-metal` walls, which were flat
grey, now take it too. It is steel and is not drawn as metal: as a metal
the ribs mirrored the sky on their upper faces and the ground on their
lower, and in shade the rail was blue and tan stripes at any roughness.
Weathered zinc is a dull grey skin, and drawn as one it is right in sun
and shade.

These three are not repeated to their own scale as the ground's sets are
(`MaterialLibrary.tilesFreely`): three beams across a rail repeated twice
is six. They are drawn once across the artwork's own repeat.

Cost, previous commit against this one, each on its own library, taken
alternately on a machine warm from a test run (so compare across, not with
the figures above): 7.35 to 7.31 ms on Wheel 1, 6.50 to 6.52 on CG Speedway
1, 7.29 to 7.36 on E-Track 6, 6.96 to 7.00 on E-Track 3. Nothing: the same
samples from maps of the same size, and one more draw for the tops.

### Walls, fences and buildings

What is built beside a circuit was three sets, concrete for anything named
`wall` or `barrier`, a brick and a chain link, and none of them was right.

**A barrier is what its texture is a picture of.** The road's barriers are
generated from the track's segments and were named for their surface:
`barrier`, `wall-1-e2`, `barrierg3`, whatever the circuit's author called
it, and every one of them came out a concrete slab. But the surface also
names a texture, and that says what the barrier is. TORCS's own
`tr-barrier.rgb` is a photograph of a guard rail, and so are the ones
E-Track 2 and 3 and Wheel 1 use in its place; Alpine 1's `mur2` is a stone
wall; Corkscrew's is a fence above a rail. So a barrier whose texture maps
to a set is grouped under the texture's name (`TrackSurfaceAssembly.
roadBatches`, `RoadGeneration.Parameters.barrierGroups`), and the rules
send the rail photographs to `armco`. Street 1, the Alpines, E-Track 2, 3
and 4 and Corkscrew have guard rails where they had grey slabs.

A rail or a fence is drawn once up its barrier whatever the barrier's
height (`MaterialLibrary.fittedTile`, `Parameters.fittedBarriers`): by the
metre, a barrier a metre high showed a beam and a half of a two-metre tile.

**The sets** (`RecipesStructures.swift`), each with the top of the picture
at the top of the wall, because what marks a wall runs down it:

- *concrete-wall*: cast in place. Panels 2.4 m wide with a joint between,
  lifts 1.2 m high with a fin of grout between, four form-tie holes to a
  sheet each weeping rust, bug holes, the rain's runs dark and the lime
  pale. The slab set stays for what lies down: paddocks, pit aprons.
- *stone-wall*: field stone in mortar, each stone its own colour, tilt and
  grain, lichen on the damp ones.
- *brick*: the old one had four bricks to the metre, a quarter of a metre
  long. A brick is 215 by 65 mm: eight to a tile of 1.8 m, twenty-four
  courses, stretcher bond, red and orange and burnt, joints struck back.
  The pit garages on every circuit are built of it.
- *chain-link*: one panel, three metres from post to post: a 60 mm diamond
  of woven wire, a rail along the top, a tension wire along the foot. The
  old one was eight diamonds to the metre, drawn as a mirror, and on
  Corkscrew's barriers, which are not alpha-tested, it was a wall-high band
  of reflected sky and ground.
- *catch-fence*: that panel above the guard rail's three beams, for the
  barriers that are both.

**Cutouts.** A set with holes in it (`MaterialLibrary.isCutout`) makes
its generated barrier alpha-tested and two-sided, keeps its coverage down
the mip chain, and is the only kind of set an alpha-tested batch of the
original scenery takes: a fence for a fence. Nothing with holes takes a
solid set.

**What keeps its own** (`MaterialLibrary.keeps`). `walls.rgb` and
`walls2.rgb` are the fronts of a village's houses, doors and shutters and
all, and matched the rule for `wall`: on Alpine 1, G-Track 3 and Street 1
the houses were concrete boxes. They are houses again.

**Buildings** are boxes with a photograph of a building on them, composed
top to bottom, and no tile can replace that. But the photograph says where
the windows are. So a building keeps its picture and is given, from the
picture, the maps it never had (`FacadeStructure`, bound in
`SceneResources` to textures `MaterialLibrary.isFacade` names): glass where
a patch is darker than the wall round it and grey, smooth and set back a
little, and wall everywhere else. Windows show the sky. Three things were
tried and taken out: sky-blue as glass (a blue shed and every slate roof
became mirrors), the picture's light and shade as relief (an office front
of blinds became crumpled foil), and the answer texel by texel (the shadow
under each sill became a row of glints). What is left is modest and uneven:
on a pale front with its blinds down it finds the few windows whose blinds
are up.

Not done: a barrier whose texture is a row of trees or a line of parked
cars is still a concrete wall. (One whose texture is an advertisement now
keeps it: see *Advertising* below.) Wire and bar fences in the original
scenery keep their artwork.

Cost, previous commit against this one, taken alternately: nothing on
Street 1, Alpine 1, Wheel 1 and E-Track 2 (7.5 ms both); 6.96 to 7.12 ms on
Corkscrew, whose barriers are now fences seen through from both sides. A
first run after installing new sets read 2.5 ms slow on E-Track 2 and did
not repeat: the sets were being encoded.

`--frame-cost` has two new switches: `--turn DEGREES` looks that far to
the left of the road at each viewpoint, at what stands beside the track,
and `--substitutions` lists which textures a set replaced.

### Trees, grandstands and crowds

**Trees.** Away from Aalborg a tree is a photograph on a card, or two
crossed, and a card has one normal: all of the tree bright when the sun is
before it, all of it black when the sun is behind, and from the card's back
it was lit with its front's normal, so half of every crossed pair was black
paper. Now a tree's card keeps its photograph and gets, from it, a form
(`FoliageStructure`): the cut-out blown up like a balloon, so that every
texel faces the way a crown of that outline would there, with a little of
the photograph's own light and dark for its clumps. It is bound to cut-out
batches whose texture's name begins as a tree's (`MaterialLibrary.
isFoliage`), at half the picture's size, and those batches are lit as the
Aalborg trees are: from both sides, with the normal mirrored in the card
for the back face, and a little light through the leaf. Their roughness is
set matt; several were written shiny, and a crown with a form glinted.

Two versions were taken out. With more of the fine scale in the form, every
gap in the leaves tipped the light its own way and a tree seen close was
smears, like wet paint. And `_tree` anywhere in the name is not a tree:
these circuits end the name of every cut-out that way, flags (`GBtree`),
trusses, rows of spectators (`GSPAtree`, `ppla_tree`).

The result is plainest on walls of forest (Forza, Brondehach), which were
milky and are green, and on single trees against the light (Street 1),
which were black and have a lit side. A card seen close is still a card.

**Grandstands.** Two sets (`RecipesStands.swift`): *stand-seats*, the
steps of a stand from above, a concrete tread with a painted nosing and a
row of blue tip-up seats, for the sixteen-texel plaid (`tribb01`) five
circuits lay on their stands' treads; and *corrugated*, ribbed painted
steel sheet with laps and fixings, for the cladding (`tribb02`). On the
stands looked at, both are almost wholly hidden by the people sitting on
them.

**Crowds** keep their photographs. Most of a circuit's crowd is rows of
seated people cut out on cards, and those are good. Three textures are a
small photograph of a crowd laid over a whole deck, twelve centimetres to
the texel, and a set was drawn for them: ten rows of fourteen figures in
the shirts and caps of a race crowd. On the deck it replaced, at the
distance and the angle a stand is seen from, it was darker and streakier
than the blur it replaced, and it is not in the tree.

**Barriers again.** The guard rail drawn once up its barrier, from the
last commit, was three beams a metre and a half deep each on Brondehach,
whose barriers are four and five metres high. A rail's tile is now a metre
of rail and a taller barrier takes a whole number of them
(`MaterialLibrary.fittedHeight`); and a barrier over 1.8 m with a rail for
its texture is what such a barrier is at a circuit, a rail with a catch
fence on it (`TrackSurfaceAssembly.tallestRail`).

Cost, previous commit against this one, each track run once first: 8.35 to
8.47 ms on Forza, 7.33 to 7.44 on Brondehach, 7.48 to 7.54 on Alpine 1,
nothing on Street 1 and E-Track 2. The forms are uncompressed, a quarter
of each tree picture's texels.

### The sky, its clouds, and the land round the horizon

The sky is the atmosphere's own and stays so. What it lacked was anything
in it. A dry day was a bare blue dome; an overcast one was four octaves of
value noise worked out at every pixel and cut off at a threshold, a tan
ceiling with holes; and where the circuit's terrain ended, a few hundred
metres past the track, there was the sky's own ground, a pale band along
the foot of it. TORCS drew a photograph round each circuit; nothing here
drew anything.

Two kinds of map are now generated with the sets (`SkyMaps.swift`, written
by `torcs-matgen --all` beside them) and the sky pass is drawn from them
(`skyFragment` with `skyMapped`, a second pipeline; `ForwardRenderer.
cloudMap`, `horizonMap`, set by `dressSky(from:directory:track:)`):

- *cloud-map*, a tile with a shape to a channel: where cumulus is, billows
  inside billows; the fine lumps that eat at a heap's edge; cirrus, the
  same noise drawn out along the wind; and how thick the heap is
  thereabouts. The sky samples the heaps at 1500 m and the cirrus at 9000,
  thresholds the first by the coverage as the noise was, and shades it:
  the side of a heap toward the sun is white, the far side in its own
  shade, the middle of a thick one grey underneath. A cloud's light is
  taken most of the way to grey: with the sun's own yellow the clouds were
  beige.
- *horizon-hills*, *-mountains*, *-snow*, *-dry*: the land beyond the
  circuit, all the way round, 14° of it: a plain running out to the
  horizon and ridges standing behind one another above it. Its colour is
  the land's, lit when it is drawn; its alpha is how much of the sky behind
  the air between lets it hide, which is how haze is kept without knowing
  what colour the sky will be. Which one a circuit gets is told by its
  name (`HorizonMap.kind(forTrack:)`): the Alpines and Aalborg are in
  mountains, Corkscrew and E-Track 6 in dry country, the rest among hills.

A fair day now has a third of its sky in cumulus and some cirrus above
(`ForwardRenderer.fairSky`). They are in the sky and nowhere else: the
ground is lit as under a clear sky, so the heaps keep twenty degrees clear
of the sun, where a cloud over ground in full sun would be a lie. The
weather's overcast is the same map at full cover and still hides the sun.

Without the maps (a library made before them, or a test) the sky is what
it was, noise and all, from the first pipeline.

Cost, previous commit against this one: 7.58 to 7.71 ms on E-Track 2, 7.13
to 7.28 on Corkscrew, 7.03 to 7.13 on Street 1: five samples at each pixel
of sky. The maps are uncompressed, 13 MB together.

Not done: the clouds cast no shadow on the ground and are not in the
reflections, which still see the clear sky; and the horizon is hidden by
the circuit's own banks from most of most laps.

`--frame-cost` has an `--overcast` switch for the sky under full cloud.

### The cars: tyres, rims and lamps

A car keeps its own painted atlas; that is the car. What the atlas could
not give it is its tyres. A modelled wheel (`wheel3d.png`) is textured
from a picture of a wheel seen from its side, rim and sidewall, and the
tread, from the side, is the picture's last ring of texels: one colour.
Nothing drawn in that picture can put a groove on a tyre, and from behind
a car a tyre is all tread.

- **Parts.** A wheel's nodes had no names the classifier knew, so the tyre
  was paint under a clear coat with everything else, and the spoked face,
  `WIRIM`, was glass by the rule for windows. They are now `tyre`, matt
  rubber, and `rim`, alloy under lacquer (`CarMaterials`). All metal and
  no coat, a rim took the colour of the ground it mirrored and every
  silver wheel was bronze.
- **Its own coordinates.** `TyreUnwrap` makes a tyre's coordinates again
  from its shape: `u` round the axle, twice round to the texture, `v`
  across the section from bead over tread to bead, the tread always the
  same band of `v` whatever the tyre's proportions. The axle is found as
  the one way the tyre is not round: the wheel models are a unit across
  every way, scaled to the car's wheel when drawn, so their width says
  nothing, and going by the shortest side put the sidewall's letters on
  the open-wheeler's tread. Vertices stay shared but along the line where
  the angle wraps.
- **The set** (`car-tyre`, `RecipesCars.swift`), drawn to those
  coordinates: four grooves round the tread, sipes across its ribs, blocks
  on its shoulders, polished down the middle with dust in the grooves; on
  each sidewall a rim protector, ribs under the shoulder, and TORCS RACING
  in raised white letters, twice round.
- **Turning.** The wheel has four models by speed, their rims more blurred
  each. The tyre of the three that turn takes `car-tyre-rolling`, the same
  tyre averaged round: the grooves stay, the sipes and the letters become
  bands. A sharp tread on a wheel at speed strobes.
- **Lamps.** Head, tail and other lamp lenses take a moulded pattern over
  the atlas's colour (`lens`, a detail set like the paint's flake): rows
  of flutes crossed by pillows.

Without the sets (`MaterialLibrary.has`) a tyre keeps its atlas and the old
tread detail.

Not measured cleanly: the Mac was running another workload when this was
timed, and the previous commit's own frame read 13 ms offscreen against
its usual 7.5. Interleaved under that load the two builds were level,
13.19 and 12.92 ms on E-Track 2; the wheels are a few thousand pixels and
a few thousand vertices a car. In the window a six-car race held 60 fps,
after a first run at 41 while the new sets were being encoded.

### Cabins and drivers

A car's cabin and its driver are painted on its atlas with everything
else, and had one surface between them: a cloth weave tiled over
dashboard, steering wheel, roll cage, dials, helmet and overalls alike,
all of it matt. From the seat of the 155 DTM the red A-pillar was woven
red cloth.

The picture says what each thing is, by its colour, well enough to tell
four materials apart, and a map is made from it for the car's `interior`
and `driver` parts when the car is loaded (`CabinStructure`, bound in
`SceneResources`, one map to a picture):

- *paint*, anything strongly coloured, a helmet, a cage, a pillar: smooth
  and glossy;
- *trim*, anything dark, dashboard, wheel rim, harness: a fine twill, half
  matt;
- *skin*, the tan of a face or a hand: smooth, a little shine;
- *cloth*, what is left, pale grey to white, overalls and seats: a plain
  weave quilted in diamonds, quite matt.

The map is finer than the picture, four texels to one for a 256-texel
atlas, because a weave is finer than anything painted at that size. Two
things were changed on the way. Trim was first a moulded grain, and where
the atlas is stretched over a dashboard it was blobs; and the line between
trim and cloth was first drawn near black, so a grey dashboard was half
one and half the other, texel by texel.

It shows from the seat, in the few cars that have a cabin modelled (the
155 DTM, the Impreza), and there mostly as what is no longer cloth. From
outside, through the glass or over an open cockpit, the difference is
slight: the open-wheeler's helmet looks as it did. Loading a field of four
models took 2.8 s where it took 2.6.

`--frame-cost` takes `--view NAME` for any of the game's cameras (`driver`
is the seat) and writes that view with `--dump`.

### Advertising: boards, banners and painted walls

The advertisements are the circuits' own artwork and stay so. Three things
were wrong with how they were drawn, and none of them was the artwork.

**The pit walls were not there.** A circuit's pit wall is a *border* whose
style is `wall`, a metre high, and five circuits paint a sponsor's name
along it: MEGAFUEL on E-Track 3, FlatSpot on Wheel 1, IMPROVEYOU on
E-Track 2, www.torcs.org on Michigan. The cars are stopped by such a
border (`TrackWallCollision`), but the road generator drew every border
as a flat strip, so the wall stopped them unseen. `RoadGeneration` now
stands a wall-style border up, as the three strips of a barrier: the face
to the road, the top across the border's width, the back. Corkscrew and
Brondehach gain walls the same way, with no advertisement on them.

**A wall's paint was dropped.** A generated wall was drawn with a set
chosen by its texture's name, and `megafuel-wall.png` was a wall, so
concrete. The walls that are pictures of paint are now named
(`MaterialLibrary.paintedWalls`: the four above, Michigan's red and white
striped wall, G-Track 1's green and yellow one, E-Track 2's
hazard-striped plank) and keep their picture,
where the circuit's compiled textures hold it. The picture is laid as
trackgen laid it and as it was drawn to be: a third up the inner face, a
third across the top, a third down the back, one repeat every `texture
size` metres (`TrackSurface.textureSize`, runtime only, like the name),
and from right to left on the right of the track so that the lettering
runs forward seen from the road (`RoadGeneration.wallCoordinates`).

**The lettering was a smear.** A board ten metres long was drawn from a
picture 256 texels wide: four centimetres to the texel. `SignArtwork`
makes two things from each sign's picture when the circuit is loaded, for
boards and banners (`MaterialLibrary.isSign`, by how these circuits name
them: `logo…`, `sign…`, the `turn` and `dist` markers and a dozen more)
and for the painted walls:

- *The picture again, four times larger, its edges put back*
  (`enlarged`). Printed artwork is flat colour meeting flat colour. Round
  each point the sixteen nearest texels are sorted into two colours, and a
  point lying between the two is moved toward the nearer, so the edge
  falls where the blur was half way and is a texel and a half wide. Where
  there are not two colours, in a gradient, in a photograph's grain, where
  three colours meet, nothing is moved. Two versions were thrown away:
  taking the two *extreme* texels for the colours drew a dark rim round
  every letter, and taking plain means let the half-covered texels of the
  edge itself pull both colours toward the middle and left the edge soft.
  The colours are means weighted toward the ends.
- *A surface to be printed on* (`surface`), by what the sign is. A
  **board** is sheets butted together, each about half as wide as the
  board is high, with a joint between, not quite flat, with a film of dirt
  the rain has drawn downward. A **banner**, any picture six times as long
  as it is high, is cloth held at eyelets along its hems, billowing a
  little between. A **wall** is cast concrete under the paint: pores, the
  grain of the cast, a joint at each repeat.

All three are matt. A board was first given a satin sheen, and a black
board under a clear sky turned navy blue.

The enlarged artwork is block-compressed and kept in the texture cache
under the picture's own hash, like the original artwork; uncompressed it
was fifty megabytes on Brondehach, which has twenty-three signs. A surface
depends only on the kind of sign and its shape, so all boards of one shape
share one.

`torcs-matgen --sign board.png` writes what the game makes of one picture.

Cost, previous commit against this one, taken alternately, 2880 × 1720:
E-Track 3 7.57 → 7.59 ms, Forza 8.57 → 8.53, Wheel 1 7.59 → 7.64,
Brondehach 7.52 → 7.58, Michigan 7.19 → 7.22; nothing that can be told
from the noise. Loading Brondehach, the circuit with most signs, takes as
long as it did once its signs are in the cache (2.7 to 3.0 s for a whole
tool run, both), and a second longer the first time (4.4 s against 3.4
with the cache empty). A six-car race in the window holds 60.

Not done, and why: the surfaces are subtle from the road, the joints
most visible, the banner's folds a faint shading, and the pores of a
painted wall are sized to the picture, not the wall, so Michigan's wall,
whose picture runs twelve metres, has pores four times the size of
E-Track 3's. Lettering that was drawn soft stays soft: CTD Racing's gold
script on Forza's gantry is sharper by little. A banner is told from a
board by its shape alone. Barriers that are rows of trees or parked cars
are still concrete walls.

## A field of different cars

A race, a qualifying field and a championship can mix car models. The options
screen offers *Your car*, *Your class* (other cars of the player's class,
nearest in power to weight first; a car alone in its class races the nearest
cars of any class instead) and *Any car*. A field holds up to four models.

- `DrivingContent.opponentCars` holds the further models; `renderScenes` puts
  each after the classic eighteen as seventeen in a row (body, four wheels,
  twelve brake parts), and `FieldCar.model` picks the resources.
- `RaceRuntime` already took one definition per entry; the session builds each
  entry from its own model's parameters.
- The race runtime numbers its cars by **grid slot**, not by entrant, so the
  session keeps the grid it built and maps a published car index back to the
  entrant for its name and model. (Before this, a qualifying-order grid
  labelled the standings by slot.)
- Opponents have names (an invented roster), shown in the standings, the
  results and the championship table.

## Modes

- **Training** — the single-car practice runtime.
- **Qualifying** — the player runs first; each opponent's run is then
  simulated headless in its own car and at the chosen difficulty, the grid
  fills on the results screen, and *Set Up the Race* carries it into a race.
  An opponent's grid time is its fastest lap, valid or not: the BT policy
  rides the curbs, which the original's rule invalidates on every lap.
- **Race** — from pole, or from the qualifying order or its reverse when the
  same circuit, car and field have qualified.
- **Championship** — a season in one car against the same drivers:
  three, five, eight or all circuits, shortest to longest; points 10, 8, 6, 5,
  4, 3, 2, 1; each race starts in the reverse of the table, so the player
  starts the first round last. The table breaks ties by wins, then best
  finish, then entry order. A round ended from the pause menu is not recorded
  and can be run again. The season is kept in `championship.json`.

**Difficulty** (easy, medium, hard) is a handicap on the robot drivers:
`RaceRuntime.opponentPace` is the share of the throttle they ask for that
they get — 0.78, 0.9, 1. The original has no such setting; easing the throttle
slows a driver on the straights and leaves its lines and braking its own. On
Aalborg a BT lap goes from 87.7 s to more than a second slower at 0.8.

The player's best valid lap per circuit and car is kept in `records.json` and
shown on the circuit, car and options screens, on the HUD, and as "new
personal best" in the results.

## The race screen

The renderer fills the window. Over it: session, lap and position; current,
last, best and record lap; a rev-counter arc with speed, gear, fuel and
damage; the circuit's outline with every car on it; the standings by name;
five start lights for the original's two-second countdown, then "GO!"; and
messages for an invalid lap, penalties and catching up. Escape pauses; the
pause menu has restart, camera, settings and controls as panels over the
paused session, telemetry, end session and quit. V steps the camera.

The HUD reads a copy of the simulation frame refreshed twenty times a second
(and at once on a phase change). The frame itself changes over a hundred
times a second and is not observed: a view that depended on it was rebuilt as
often, on the thread the renderer draws from.

## Sound

`CarSoundModel` (TORCSPresentation) is the original's per-car sound model
(CarSoundData.cpp): engine pitch from engine speed and the car's scale, a
low-pass that opens with revs and smoothed throttle, turbo spool, tyre skid,
road, grass and curb ride from speed, load and the surface under each wheel,
gear changes and impacts. It is stepped at the original's hundred updates a
second. The slip acceleration and tyre reaction are not published by the
simulation; the static wheel load and a zero slip acceleration stand in.

`GameAudio` plays it: looping samples through a rate unit and a low-pass per
voice, the player's engine and the four nearest opponents' (quieter with
distance), one-shots for gears and impacts, beeps for the start lights and
ticks for the menus. The engine sample is the one the car's document names,
from the library's `sounds` folder; where a sample is missing a generated
stand-in (`SyntheticSound`) plays through the same path, so the game is never
silent. One-shot players are started once and only scheduled onto: starting a
player waits for the audio thread's cycle, which showed up as 5% of the main
thread in a profile, and a car scraping a wall now sounds one impact rather
than one per update. Volume is under Settings.

## Verification

- Unit tests: packages, previews and rivals (`ContentLibraryTests`), a
  two-model content load and heterogeneous race entries, the parser
  tolerances (`ShippedContentToleranceTests`), the sound model against the
  original's formulas and the stand-in samples (`CarSoundTests`), the
  championship and lap records (`ChampionshipTests`), the quality governor
  (`QualityGovernorTests`).
- `--screenshot PATH [--screen NAME]` renders a screen offscreen;
  `--autoplay SECONDS [--autoplay-race] [--autoplay-cars N]
  [--autoplay-measure SECONDS]` runs the real window path and reports the
  frame rate. It must be launched as an application (`open build/TORCSMac.app
  --args …`): a bare binary's window is not on screen and never draws.
- `--autoplay SECONDS --autoplay-season` runs a one-round, one-lap
  championship with the robot policy driving the player's car as well: three
  cars of three models on CG Speedway ran to the flag in 60 s at 60 fps, the
  results came up, the classification went into the table by name (10, 8 and
  6 points), the season completed with its champion, and the check removed
  the season it made.
- Driven and looked at in the real window: the menus with the full library,
  the circuit and car screens, a six-car TRB1 race on Brondehach with four
  car models, the championship set-up, table and first round (the player last
  on the grid, names following the grid), and the pause menu.

## Boundaries

- A game controller works the menus (d-pad through a list, south to choose
  or confirm a screen's main action, east to go back, the menu button to
  resume), but the options screens' individual settings and the pause menu's
  other entries still need the keyboard or mouse, and none of it has been
  tried on a physical controller.
- The sound has not been heard by its author: its numbers are tested and its
  graph runs (16 samples loaded, three engine notes in a three-model race),
  but the mix is by calculation.
- Opponents' qualifying is simulated in turn, not in parallel.
- Replays remain open, as in [gameplay](GAMEPLAY.md). Frame rate is in
  [frame rate](FRAME_RATE.md).
