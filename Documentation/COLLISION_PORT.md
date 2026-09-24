# Collision port boundaries

The original TORCS 1.3.9 collision path has three distinct parts:

1. Ground and track-side barrier responses inside each car update. These are
   already connected to native vehicle motion and have separate parity evidence.
2. SOLID collision detection, including car boxes and fixed pit-wall polygons.
3. Car/car and car/wall response callbacks, followed by committing accumulated
   collision velocities after all detection callbacks have run.

Native `ObjectCollision.swift` implements the response kernels and state
operations. `ConvexCollision.swift` provides support maps, GJK queries and
previous-pose contacts. `CollisionAffineTransform.swift`, `ComplexCollision.swift`
and `TrackWallCollision.swift` add affine operations, polygon hierarchy queries
and fixed wall construction. `MultiVehicleSimulation.swift` connects car/car and
wall/car detection/response to the active-car loop; `SingleVehicleSimulation`
uses the same dispatcher. Complex/complex fixed pairs now participate in global
contact counting, including contacts whose callback returns without a response.

## Preserved response behavior

- SOLID's double contact points and normal narrow to Float before 2D response.
  A normal that becomes NaN during planar normalization produces no response.
- Car pairs are reordered by car index, with contact points swapped and normal
  negated. This ordering affects the original asymmetric yaw expressions.
- NO_SIMU states except PIT suppress pair response entirely. A pit car remains
  in the pair's impulse denominator but does not move or receive pair damage.
- Public orientation, current world motion and the cached collision transform
  are separate values. Collision-point velocities use public yaw and current
  world velocity; separation distances use the cached transform.
- Position correction happens before the separating-velocity early return.
  Pair correction is capped at 0.05 m; wall correction is clamped to 0.02–0.05 m.
  The blocked flag prevents repeated positional correction during dispatch.
- Impulses accumulate in the separate VelColl equivalent when the car-collision
  flag is already set. Angular correction retains the original pseudo-cross
  expressions and ±3 rad/s cap. World XY/yaw velocity changes only at commit.
- Pair damage scales with absolute impulse; wall damage uses squared impulse.
  The original Double `CAR_DAMMAGE` expression and per-impact integer truncation
  are retained. Finish suppresses damage. Undefined integer overflow is rejected.
- A response refreshes the collision transform using corrected world position,
  static CG height and public orientation. Body dynamics and unrelated impact
  metadata are not implicitly synchronized.
- Tick reset clears collision/blocked for all cars. Dispatch reset and final
  velocity commit skip NO_SIMU cars, preserving pit-car accumulated state.

`collision-instrumentation.cpp` compiles unchanged upstream `collide.cpp` once
and exposes its private callbacks. Test instrumentation registers temporary SOLID
objects so the callbacks' original matrix updates execute normally. It supplies
contact inputs directly and does not claim collision-detection coverage. The
chained oracle retains original state and actual matrices between callbacks;
no native output is fed into the original sequence.

## Tests

- Pair response: 8,640 cases / 552,960 finite scalar fields, both object orders,
  angular/linear velocities, different masses/inertias, prior collisions and
  blocking, skill/rule factors, finish/pit/removal states and degenerate normals.
- Wall response: 7,776 cases / 248,832 fields, both wall/car orders, points in
  different body regions, normal lengths around both correction clamps and
  existing accumulated impulses.
- Pair boundaries: 120 cases / 7,680 fields cover zero and sub-cap separation,
  the 0.05 m boundary, separating/approaching motion, preexisting blocking and
  damage impulses around integer truncation. Twelve cases verify that a value
  just below one damage point remains zero instead of rounding up through Float.
- Chained dispatch: three bodies including a pit car, 4,000 contacts / 384,000
  fields, 1,000 reset/commit cycles, mixed wall and pair contacts. All native and
  original states evolve independently after initialization.
- Each comparison includes position, world velocity, yaw velocity, accumulated
  impulse velocity, all 16 matrix elements, collision metadata and discrete
  damage/flags/blocked state.

All compared finite fields match exactly in debug/release/ASan. Discrete outputs
also match. At the response-only checkpoint, 83 full-suite tests and twelve
selected Address Sanitizer tests passed, including all four response tests.

Reproduce with `swift test --filter ObjectCollisionTests`. Build-specific results,
source hashes and sanitizer evidence are recorded in
`object-collision-parity-report.json`. Existing whole-car reference goldens are
not regenerated when the instrumentation translation unit changes.

## Native convex detection and car dispatch

The native implementation preserves the following upstream behavior:

- `Object.cpp` / `Convex.cpp` first test intersection at **current** transforms,
  then compute closest points at **previous** transforms for DT_SMART_RESPONSE.
  The supplied normal is the difference of those previous transformed points.
- `dtProceed` updates previous transforms only when the entire `dtTest` reports
  no collisions. It is not a per-car or per-pair update.
- SimCarCollideInit disables SOLID caching and sets relative distance tolerance
  to 0.001. The absolute distance threshold remains 1e-10.
- `Convex.cpp` uses Double support points, determinant simplex reduction,
  exact duplicate detection and original termination branches. The box support
  map chooses the positive extent when a direction component is zero.
- Simplex support preserves first-vertex ties; polygon support retains its
  cursor and original forward/backward walk. Relative-frame intersection and
  common-point queries preserve their distinct operation order.
- The original zero-simplex closest-point NaNs are classified explicitly in
  tests. Native queries retain this result; response retains the original
  NaN-normal early return. A 10,000-iteration guard throws instead of inventing
  an approximate contact if a query fails to converge.
- Callback transform changes affect later pairs in the same dispatch. World
  positions/velocities, body state and published collision transforms remain
  separate; publishing does not repair the original state lag.
- Drafting reads other cars at each car's sequential update, so earlier cars
  have advanced while later cars still hold their prior state. One owned random
  stream advances in this same car order.

Native dispatch uses stable car indices, visiting (0,1), (0,2), (1,2), etc.
Uncached original dtTest visits its object map and Encounter can reorder by
allocation address. The selected two/three-car runs match exactly, including
ticks with multiple contacts. This does not establish equivalence for every
allocation layout, car count or platform.

`convex-instrumentation.cpp` invokes unchanged original support/query functions
and Object previous-transform operations. It accepts explicit input transforms;
native output is never used to supply original contacts. End-to-end multi-car
tests call actual original SimUpdate with its detection enabled, independently
of the native query and response path.

Query coverage includes 5,070 support checks; 5,000 world/relative query cases;
9,000 SMART previous/current-pose checks; and 600 degenerate/near-touching and
tolerance-boundary cases. See `convex-collision-parity-report.json` for build
results, classified nonfinite outputs and source hashes.

The two-car scenario compares 3,000 ticks and the three-car pileup compares
2,000 ticks after independent 501-tick settling. Each checks 142 telemetry
fields per car (1,704,000 total values), damage and continuous RNG ownership.
The two-car release CLI also repeats native and original captures in separate
processes; reproduce with `Scripts/verify-car-collision.sh`.

## Fixed wall construction and contacts

Transform type flags preserve an important numerical distinction: a matrix
import is marked affine even if it represents a pure rotation. Inversion then
uses original cofactor arithmetic; identity/translation/quaternion operations
without scaling use the original transpose branch. Relative transforms subtract
origins before applying the inverse. Singular matrices and zero quaternions
throw at the original assertion threshold rather than entering invalid math.

The hierarchy preserves the original bounding-box accumulation, longest-axis
ties, in-place leaf partition, midpoint fallback and left-child-first traversal.
It carries the separating axis through failed leaf queries and chooses the first
intersecting primitive. SMART contact generation then uses that primitive with
previous object poses. This implementation retains a static vertex base; moving
or deforming complex vertices are not supported yet.

Wall construction visits left then right sides and excludes outer barriers.
It retains x-only continuity checks, Float height/0.01 thresholds, start caps,
the absence of top polygons and the upstream end-cap behavior that uses start
vertices. Unfinished closed rings and the 100-object overflow are rejected with
diagnostics. The reference builder explicitly documents closed rings as broken.

Test instrumentation observes the vertices supplied by unchanged `buildWalls`
while forwarding each call to original SOLID construction. Capture storage is
released when original shapes are deleted. Geometry comparisons cover Aalborg
and 24 authored variants: 96 objects, 948 polygons and 11,376 coordinates.

Affine tests compare 1,600 input pairs / 96,000 scalar fields. Complex tests
compare 9,000 primitive-selection queries / 108,000 fields and 9,000 SMART
queries / 98,064 fields, with 1,896 hits and 7,104 misses in each family.
Coincident leaves exercise partition fallback; a 31-polygon grid selects 30
distinct primitive identifiers. Box and polygon query partners exercise support
cursor effects during bounding-box construction.

Integrated left/right wall strikes compare actual original SimUpdate against
native independently initialized state for 6,000 ticks / 852,000 telemetry
values. Both worlds generate their own geometry and contacts. Current evidence
and build results are in `wall-collision-parity-report.json`.

## Fixed pairs and mixed pileups

The current dispatcher visits each car's fixed walls before its earlier-index
car partners, after testing the fixed pairs. This matches fixed-object/car
reference ordering on the tested host. Complex/complex traversal retains the
original six bounding-axis tests, relative-transform inverse, extent-based
choice of which tree to split, strict ties and first-hit primitive pair.
Previous-pose closest points use that pair's original support cursors.

The original wall callback casts its partner to tCar. Its planar-normal NaN
gate can return before any car dereference; such contacts still increment
dtTest and prevent dtProceed. Native dispatch preserves that behavior. If the
gate would continue and dereference a wall as a car, native code throws an
explicit invalid-track diagnostic. No physical response is invented for this
undefined upstream case.

Reference diagnostics query actual original fixed objects and Encounter order,
then evaluate the callback's original PLIB planar-normal gate without invoking
an invalid car dereference. They are separate from full SimUpdate tests and
never supply contacts to those runs. Twelve crossing-wall fixtures produce
twelve fixed contacts; eleven would enter the invalid car-access path. Native
diagnostics reject those eleven; the remaining early-return contact is counted.

Two 10,800-case query families cover complex/complex primitive selection and
SMART contacts. Each contains 2,492 hits and 8,308 misses; selection visits 326
distinct primitive pairs. Finite results match exactly and 153 nonfinite SMART
outputs are classified separately. An audit of twelve track variants checks
144 fixed pairs, including four early-return contacts.

A full SimUpdate run with fixed contacts compares 3,000 ticks / 426,000 telemetry
values and verifies that previous poses stay frozen. Mixed three-car left/right
wall pileups compare 7,000 ticks / 2,982,000 values and require ticks containing
both wall/car and car/car contacts. Each implementation independently builds
geometry, generates contacts and evolves physics/RNG state. Build-specific
counts and source hashes are in `fixed-mixed-collision-parity-report.json`.

## Remaining work

Broader content, car-count and allocation-order coverage remain open; stable
native identifiers do not establish universal equivalence to upstream pointer
ordering. Moving complex vertex bases are outside this static-wall scope.
Removal/towing is now integrated; REMOVAL_PORT.md documents the separate retained
collision-object and published transforms required by pit contacts. Pit allocation
and service timing now integrate with physics (RACE_PITS.md); complete race
execution remains pending. Service physics is described in PIT_SERVICE.md. The app still
displays the suspension lab.
