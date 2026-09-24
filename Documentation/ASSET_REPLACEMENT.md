# Asset replacement before distribution

Development and distribution are deliberately separated in this project.

**Development** consumes content from the developer's own TORCS 1.3.9
installation. `Scripts/prepare-driving-session.py` reads that install and writes
a session under `Artifacts/`, which is gitignored. Nothing is copied into the
repository and nothing is bundled into the app, so development use never becomes
redistribution. Working with content whose per-file terms are unresolved is fine
on that basis, and is the current, intended workflow.

**Distribution** is a different question, and every item below has to be
resolved or replaced before a build is handed to anyone. This document is the
inventory of what that means. It does not address code licensing, which is a
separate matter recorded in `THIRD_PARTY_NOTICES.md` and `LICENSE`.

## Blocking: unresolved per-file terms

These are used at runtime and have no per-file authorship or licence evidence.
`ASSET_LICENSES.md` records why each was excluded from the pinned fixtures.

| Asset | Used for | Status |
|---|---|---|
| `env.png` | car reflection map | local-only, unresolved |
| `envshadow.png` | car environment shade | local-only, unresolved |
| `breaklight2.rgb` | brake light | local-only, recorded per session in `local-light-sources.json` |
| `concrete.rgb`, `concrete2.rgb` | trackside surfaces | not imported |
| `pylon1.rgb`, `pylon2.rgb`, `pylon3.rgb` | trackside objects | not imported |

The modern renderer reports the last five as missing when rendering Aalborg and
draws those surfaces untextured rather than substituting anything, per the asset
package's rule never to silently replace a missing dependency.

The first three are replaced outright by the modern path rather than
re-sourced: `env.png` and `envshadow.png` are superseded by sky-derived image
based lighting, and the brake light becomes an emissive material.

### Additions found by inventorying a full installation

Three items beyond the eight textures above, from classifying every car and
track in an unmodified 1.3.9 tree:

- `road/brondehach` — its Free Art grant is explicitly scoped to Andrew
  Sumner's contributions. The underlying geometry is a Brands Hatch conversion
  from SBK2001 that the notice itself says was *"released without any license"*.
  The only qualified grant in the whole content tree.
- `cars/models/buggy` and `cars/models/p406` — no artwork notice at all. `p406`
  additionally carries a live trademark.
- `installer/windows/base/stripe.exe` — noncommercial use only, by permission
  from Steven Skiena. The root README's non-free list omits it, but `accc`
  shells out to it, so regenerating any `.acc` with stripification depends on a
  noncommercial tool.

`Scripts/content-inventory.py` reproduces this classification mechanically from
the shipped notices. On a stock 1.3.9 tree it reports 15 usable cars of 42 and
31 usable tracks of 39, with 7 further freely licensed tracks rejected only
because they declare track XML version 3.

## Blocking: copyleft artwork

Six meshes, 27 SGI textures and three PNG textures carry Free Art License terms
with retained attribution (`ASSET_LICENSES.md`, `Resources/asset-manifest.json`).
They are imported as test fixtures and are not bundled.

Free Art License is copyleft. Whether it can travel through a store that imposes
its own terms on the recipient has the same shape of problem as the code
licensing question, so treat these as blocking for any store channel until
someone competent has looked at it.

Affected content: `155-DTM` car body and textures, the four `trb1-3` wheels,
the Aalborg track mesh and its textures.

## Replacement path

The plan's asset generation phase is the answer to both categories at once.
Procedurally generated material sets are authored by project code, are
deterministic and hash-testable, and carry the project's own terms — so they can
be bundled on any channel. Generated terrain already works this way: it comes
from the track's own `Terrain Generation` parameters via project code, with no
imported artwork at all.

Order of replacement, cheapest first:

1. **Surface materials** — asphalt, grass, concrete, kerb, gravel, barrier.
   Generated sets replace both the unresolved trackside textures and the Free
   Art track textures, and are the largest fidelity win regardless of licensing.
2. **Environment maps** — already obsolete, delete once the classic path goes.
3. **Track geometry** — the road, kerbs and barriers can be generated from the
   same version-4 segment model the terrain uses, which removes the dependency
   on the baked `.acc` entirely.
4. **Car** — the hardest. A vehicle mesh and livery cannot be synthesised
   convincingly, so this needs either authored content or a cleanly licensed
   source. It is the one item with no procedural answer.

## Checking

`Scripts/verify-provenance.py` checks the pinned fixtures against
`Resources/asset-manifest.json`. It does not yet assert that a *built app*
bundles nothing with unresolved terms; adding that check is the natural gate
before any distribution build.
