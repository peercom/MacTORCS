// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
import TORCSRender
import TORCSAssets
import TORCSTrackMesh

final class TreeForestTests: XCTestCase {
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Artwork/aalborg")

    func aalborg() throws -> RenderScene {
        try RenderScene(ACScene.parse(Data(contentsOf: fixtures.appendingPathComponent("aalborg.acc"))))
    }

    func atlas(_ device: MTLDevice) throws -> TextureImage {
        let store = TextureStore(device: device, roots: [fixtures])
        return try XCTUnwrap(store.image(named: TreeForest.textureName), "tree atlas fixture")
    }

    /// Aalborg's cards are two planes at right angles per tree, three species;
    /// every one of them must be recognised and no other geometry may be.
    func testRecoversAalborgsTreesFromTheirCardSignatures() throws {
        let scene = try aalborg()
        XCTAssertGreaterThan(scene.treeFaces.count, 600, "the cards are triangles with the atlas texture")
        let forest = TreeForest(faces: scene.treeFaces)
        XCTAssertEqual(forest.placements.count, 169)
        XCTAssertEqual(Set(forest.placements.map(\.family)), [0, 1, 2], "all three species present")
        XCTAssertEqual(forest.batchPlacement.count, 169 * 4, "four triangles per tree")
        for tree in forest.placements {
            // The unit tree's z axis is the card height, in metres.
            let up = tree.transform.columns.2
            XCTAssertEqual(simd_length(SIMD3(up.x, up.y, up.z)), tree.height, accuracy: 0.01)
            XCTAssertGreaterThan(tree.height, 10)
            XCTAssertLessThan(tree.height, 20)
        }
    }

    func testTreeMeshesAreDeterministicAndStayInTheUnitBox() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let image = try atlas(device)
        for family in 0 ..< 3 {
            let a = TreeMeshes.mesh(family: family, variant: 1, middle: false, atlas: image)
            let b = TreeMeshes.mesh(family: family, variant: 1, middle: false, atlas: image)
            XCTAssertEqual(a, b)
            XCTAssertEqual(a.attributes.count, a.positions.count)
            XCTAssertEqual(a.normals.count, a.positions.count)
            XCTAssertTrue(a.indices.allSatisfy { Int($0) < a.positions.count })
            for p in a.positions {
                XCTAssertTrue(p.x >= -0.5 && p.x <= 0.5 && p.y >= -0.5 && p.y <= 0.5 && p.z >= 0 && p.z <= 1, "\(p)")
            }
            let middle = TreeMeshes.mesh(family: family, variant: 1, middle: true, atlas: image)
            XCTAssertLessThan(middle.triangleCount, a.triangleCount, "middle detail is lighter")
        }
    }

    func testReplacementGivesEachTreeADetailPairAndMergedModeThreeDraws() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let scene = try aalborg()
        let image = try atlas(device)
        let (replaced, forest) = try TrackSurfaceAssembly.replacingTrees(scene, atlas: image)
        XCTAssertEqual(forest.placements.count, 169)
        let trees = replaced.batches.filter(\.swaysInWind)
        XCTAssertEqual(trees.count, 169 * 2)
        XCTAssertEqual(trees.filter(\.castsShadow).count, 169, "the middle build casts, the near one does not")
        let near = trees.filter { $0.detailRange?.lowerBound == 0 }
        XCTAssertEqual(near.count, 169)
        XCTAssertTrue(near.allSatisfy { $0.detailRange?.upperBound == TrackSurfaceAssembly.nearTreeDistance && !$0.castsShadow })
        XCTAssertEqual(scene.batches.count - 169 * 4 + 169 * 2, replaced.batches.count)
        XCTAssertTrue(replaced.treeFaces.isEmpty, "the cards are consumed")
        // Stripping trackgen afterwards must not disturb the tree batches.
        XCTAssertEqual(TrackSurfaceAssembly.strippingTrackgen(replaced).batches.filter(\.swaysInWind).count, 338)

        let merged = try TrackSurfaceAssembly.replacingTrees(scene, atlas: image, detail: .merged(middle: true)).scene
        XCTAssertEqual(merged.batches.filter(\.swaysInWind).count, 3)
    }

    /// Wind moves nothing at time zero, so verification renders repeat, and
    /// moves the foliage at any other time.
    func testWindIsStillAtTimeZeroAndMovesOtherwise() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        var settings = RenderSettings()
        settings.bloom = false; settings.motionBlur = false; settings.screenSpaceReflections = .off
        let renderer = try ForwardRenderer(device: device, settings: settings)
        let (replaced, forest) = try TrackSurfaceAssembly.replacingTrees(try aalborg(), atlas: try atlas(device))
        let store = TextureStore(device: device, roots: [fixtures])
        let resources = try SceneResources(device: device, scene: replaced, textures: store)
        let tree = forest.placements[0]
        let camera = RenderCamera(eye: tree.centre + SIMD3(25, 0, 2), target: tree.centre)
        let still = try renderer.render(scene: resources, camera: camera, lighting: SunLighting(), width: 256, height: 160)
        XCTAssertEqual(still, try renderer.render(scene: resources, camera: camera, lighting: SunLighting(), width: 256, height: 160))
        renderer.animationTime = 5
        let moved = try renderer.render(scene: resources, camera: camera, lighting: SunLighting(), width: 256, height: 160)
        XCTAssertNotEqual(still, moved, "foliage should sway")
    }
}
