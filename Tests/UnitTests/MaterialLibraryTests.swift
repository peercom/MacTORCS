// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import ImageIO
import UniformTypeIdentifiers
import TORCSRender
import TORCSAssets
import TORCSMaterials

final class MaterialLibraryTests: XCTestCase {
    func testNamesMapToTheMaterialList() {
        let cases: [(String, String?)] = [
            ("tr-asphalt-aa-bw1_n.rgb", "asphalt"), ("tr-asphalt-aa-l_n.rgb", "asphalt-patched"),
            ("tr-asphalt-2-aa-r_n.rgb", "asphalt-patched"), ("tr-curb-bw-aa-r.rgb", "kerb"),
            ("grass-aa.rgb", "grass"), ("tr-g-to-asphalt-aa-l_n.rgb", "grass"),
            ("tarmac-wall-2-g2.rgb", "concrete-wall"), ("tr-barrier-aa-1.rgb", "concrete-wall"),
            ("armco-1.png", "armco"), ("tyres.png", "tyre-wall"), ("fence-2.rgb", "chain-link"),
            ("brick-red.png", "brick"), ("wood-fence.png", "wood"), ("pylon1.rgb", "painted-steel"),
            ("sand-pit.rgb", "sand"), ("mud-1.rgb", "mud"), ("155-DTM.rgb", nil), ("shadow2.rgb", nil),
            // Forza's verges, the low-resolution cuttings, snow, slabs and cement.
            ("GRAS2B.png", "grass"), ("rockg0.rgb", "rock"), ("rock4.rgb", "rock"), ("snow.png", "snow"),
            ("concdal.rgb", "concrete"), ("cmnta.png", "concrete"),
            // A photograph of a cliff composed top to bottom keeps its own, and
            // so does a wall with a guard rail painted along its foot.
            ("rock1-w1.png", nil), ("cliff.png", nil), ("conc.png", nil),
            // A tyre wall's two sets, and the barrier that is three guard rails.
            ("furniture-tyre-wall.rgb", "tyre-wall"), ("furniture-tyre-top.rgb", "tyre-top"),
            ("barrier-metal-bw-w1.png", "armco"),
            // A barrier is what its texture is a picture of: TORCS's own is a
            // guard rail, and so are the photographs used in its place.
            ("tr-barrier.rgb", "armco"), ("barrier.png", "armco"), ("barrier-1.png", "armco"), ("barrier.rgb", "armco"),
            ("tr-bar.rgb", "armco"), ("barg2.rgb", "armco"), ("barrierg1.rgb", "concrete-wall"),
            ("barrier-fence.rgb", "catch-fence"), ("tr-barrier-arbor-fence_n.png", "catch-fence"),
            ("fence_arbor_n.png", "chain-link"),
            // Walls: cast concrete, laid stone, brick. A slab stays a slab.
            ("concrete2.rgb", "concrete-wall"), ("swall2.png", "concrete-wall"), ("concrete-wall1.png", "concrete-wall"),
            ("pit-concrete.rgb", "concrete"), ("concrete.rgb", "concrete"),
            ("rock-wall-e2.png", "stone-wall"), ("rockwall2.png", "stone-wall"), ("mur2.rgb", "stone-wall"),
            ("tr-stone-wall2.rgb", "stone-wall"), ("wall4.rgb", "brick"),
            // Pictures of whole things keep their own: a village's house
            // fronts and a pit wall with its windows.
            ("walls.rgb", nil), ("walls2.rgb", nil), ("CWALLPT1.png", nil),
            // A stand's steps and the sheet its back is closed in with.
            ("TRIBB01.png", "stand-seats"), ("TRIBB02.png", "corrugated"), ("TRIBB03.png", nil),
            // A car's own tyre, standing and turning; a wall of tyres is still a wall of tyres.
            ("car-tyre.rgb", "car-tyre"), ("car-tyre-rolling.rgb", "car-tyre-rolling"), ("tyres.png", "tyre-wall"),
            // A crowd keeps its photograph.
            ("PITPPL.png", nil), ("CROWD5.png", nil), ("GSPAtree.png", nil)]
        for (texture, expected) in cases {
            XCTAssertEqual(MaterialLibrary.material(for: texture), expected, texture)
        }
        for material in MaterialLibrary.rules.map(\.material) {
            XCTAssertTrue(MaterialRecipes.all.contains(material), "rule targets an unknown set \(material)")
        }
    }

    /// The ground's colour drifts over tens of metres and a tile cannot hold
    /// that; how far it drifts is the set's own, most for grass and none
    /// for what a factory made.
    func testTheGroundDriftsAndFurnitureDoesNot() {
        XCTAssertEqual(MaterialLibrary.macroVariation(for: "grass"), 1)
        XCTAssertGreaterThan(MaterialLibrary.macroVariation(for: "rock"), MaterialLibrary.macroVariation(for: "asphalt"))
        XCTAssertGreaterThan(MaterialLibrary.macroVariation(for: "asphalt"), 0)
        for made in ["armco", "kerb", "tyre-wall", "chain-link", "paint-flake", "glass"] {
            XCTAssertEqual(MaterialLibrary.macroVariation(for: made), 0, made)
        }
    }

    /// The ground's sets are the same all over and are repeated to their own
    /// scale. A set drawn as the object it covers is drawn once across it.
    func testASetLaidOutAsItsObjectIsNotRetiled() {
        for object in ["armco", "tyre-wall", "tyre-top", "kerb", "chain-link", "catch-fence"] {
            XCTAssertFalse(MaterialLibrary.tilesFreely(object), object)
            XCTAssertTrue(MaterialRecipes.all.contains(object), object)
        }
        for ground in ["asphalt", "grass", "concrete", "rock", "sand", "gravel", "brick", "concrete-wall", "stone-wall"] {
            XCTAssertTrue(MaterialLibrary.tilesFreely(ground), ground)
        }
    }

    /// A fence has holes and is drawn once up whatever it stands on, and a
    /// rail likewise; the span the mesh is given is the set's own tile.
    func testFencesAreCutoutsAndFittedSetsMatchTheirTile() throws {
        XCTAssertTrue(MaterialLibrary.isCutout("chain-link")); XCTAssertTrue(MaterialLibrary.isCutout("catch-fence"))
        for solid in ["armco", "concrete-wall", "brick", "tyre-wall"] { XCTAssertFalse(MaterialLibrary.isCutout(solid), solid) }
        for fitted in ["armco", "catch-fence", "chain-link"] {
            let tile = try XCTUnwrap(MaterialLibrary.fittedTile(for: fitted), fitted)
            XCTAssertEqual(tile, try MaterialRecipes.generate(fitted, size: 32).worldSize, fitted)
            XCTAssertFalse(MaterialLibrary.tilesFreely(fitted), fitted)
        }
        // A rail's three beams are a metre and may be stacked; a fence goes up once.
        XCTAssertEqual(MaterialLibrary.fittedHeight(for: "armco"), 1)
        XCTAssertNil(MaterialLibrary.fittedHeight(for: "catch-fence"))
        XCTAssertNil(MaterialLibrary.fittedTile(for: "concrete-wall"))
        XCTAssertNil(MaterialLibrary.fittedTile(for: "stone-wall"))
    }

    /// A tree is a name that begins as one. These circuits end the name of
    /// any cut-out in `tree`: a flag, a truss, a row of spectators.
    func testTreesAreFoundByHowTheirNamesBegin() {
        for tree in ["tree1_n.png", "TREEL4_n.png", "treeg10.rgb", "tree-border_n.rgb", "rk_tree_2_n.png", "alltree.rgb",
                     "arbor01.rgb", "arb02_n.png", "forest1-tree-m1_n.rgb", "michigan-arbor_n.rgb", "BUtree_n.png", "treeline.png"] {
            XCTAssertTrue(MaterialLibrary.isFoliage(tree), tree)
        }
        for other in ["GBtree_n.png", "GSPAtree.png", "ppla_tree_n.png", "tr-barrier-tree_n.png", "treewate.rgb", "GFtree_n.png",
                      "arbor_frame_n.rgb", "poutre3_arbor_n.rgb", "fencwire_arbor_n.png", "town-border-arbor.png", "grass.rgb"] {
            XCTAssertFalse(MaterialLibrary.isFoliage(other), other)
        }
    }

    /// A building's face is found by name, and what is not a face is not.
    func testFacadesAreBuildingsFrontsOnly() {
        for face in ["tr-building8.rgb", "house23facade.png", "block2.rgb", "BLOCK5F.png", "pitbld.png", "house17facade.png"] {
            XCTAssertTrue(MaterialLibrary.isFacade(face), face)
        }
        for other in ["house17roof.png", "house26ceil.png", "house26parking.png", "house22base.png", "walls.rgb",
                      "tree1_n.png", "concrete2.rgb", "tr-asphalt-1.png"] {
            XCTAssertFalse(MaterialLibrary.isFacade(other), other)
        }
    }

    func testCarPartsTakeDetailSets() {
        XCTAssertEqual(MaterialLibrary.detail(for: .paint)?.material, "paint-flake")
        XCTAssertEqual(MaterialLibrary.detail(for: .wheel)?.material, "rubber-tread")
        XCTAssertEqual(MaterialLibrary.detail(for: .interior)?.material, "fabric")
        XCTAssertNil(MaterialLibrary.detail(for: .glass))
        XCTAssertNil(MaterialLibrary.detail(for: .rim))
        // A lamp's lens is moulded; a tyre without its own set falls back on the tread detail.
        for lamp in [CarMaterials.Part.lens, .brakeLens, .headLens] { XCTAssertEqual(MaterialLibrary.detail(for: lamp)?.material, "lens") }
        XCTAssertEqual(MaterialLibrary.detail(for: .tyre)?.material, "rubber-tread")
        XCTAssertFalse(MaterialLibrary.tilesFreely("car-tyre")); XCTAssertFalse(MaterialLibrary.tilesFreely("car-tyre-rolling"))
        for part in CarMaterials.Part.allCases {
            if let choice = MaterialLibrary.detail(for: part) {
                XCTAssertTrue(MaterialRecipes.all.contains(choice.material), "\(part)")
                XCTAssertGreaterThan(choice.uvScale, 1)
            }
        }
    }

    /// Writes a few small sets to a temporary directory, as the generator would.
    /// - Parameter metals: sets the manifest calls metal whatever the recipe says.
    func materialsDirectory(_ names: [String], metals: Set<String> = []) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("torcs-materials-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var manifest: [[String: Any]] = []
        for name in names {
            let material = try MaterialRecipes.generate(name, size: 32, seed: 1)
            for (suffix, bytes) in [("albedo", material.albedo), ("normal", material.normal), ("orm", material.orm)] {
                let space = CGColorSpace(name: CGColorSpace.sRGB)!
                let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
                let image = try XCTUnwrap(CGImage(width: 32, height: 32, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 128,
                                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
                let url = directory.appendingPathComponent("\(name)-\(suffix).png")
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
            manifest.append(["name": name, "size": 32, "worldSize": material.worldSize,
                             "metal": material.isMetal || metals.contains(name)])
        }
        try JSONSerialization.data(withJSONObject: ["materials": manifest]).write(to: directory.appendingPathComponent("materials.json"))
        return directory
    }

    /// A car's paint takes the flake set's structure under its own atlas,
    /// and a metal set marks its binding as metal.
    func testCarBatchesBindDetailStructureAndMetalSetsAreFlagged() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        // No set that replaces scenery is a metal now, so the manifest is
        // made to call one: it is the manifest's word that is under test.
        let directory = try materialsDirectory(["paint-flake", "rubber-tread", "fabric", "lens", "armco", "brick"], metals: ["brick"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try MaterialLibrary(device: device, directory: directory)
        let marked = try XCTUnwrap(library.resolve(texture: "brick-red.png", directory: directory))
        XCTAssertTrue(marked.metallic)
        // A guard rail's zinc has weathered dull: it is steel and is not drawn as a mirror.
        let armco = try XCTUnwrap(library.resolve(texture: "armco-1.png", directory: directory))
        XCTAssertFalse(armco.metallic)
        XCTAssertFalse(armco.tilesFreely)
        let flake = try XCTUnwrap(library.detailBinding("paint-flake", directory: directory))
        XCTAssertTrue(flake.metallic)

        let scene = try MotionBlurTests().fixtureScene()
        XCTAssertTrue(scene.batches.contains { $0.carPart == .paint })
        let resources = try SceneResources(device: device, scene: scene, materials: library, materialDirectory: directory,
                                           resolveTexture: { _, _ in nil })
        XCTAssertGreaterThan(resources.structuredBatches, 0, "no car batch took a detail set")
        XCTAssertEqual(resources.structuredBatches, scene.batches.filter { $0.carPart.flatMap(MaterialLibrary.detail) != nil }.count)
    }
}
