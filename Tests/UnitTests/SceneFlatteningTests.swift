// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import TORCSAssets
import TORCSRender

final class SceneFlatteningTests: XCTestCase {
    func fixture(_ relative: String) throws -> ACScene {
        let root = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let url = root.appendingPathComponent("Artwork").appendingPathComponent(relative)
        return try ACScene.parse(Data(contentsOf: url), car: relative.contains("155-DTM") || relative.contains("wheel"))
    }

    /// ASSET_PIPELINE.md records 4,032 and 13,577 declared vertices and 1,333
    /// mesh batches across both meshes. Tying the new path to those existing
    /// figures catches a flattening regression that bounds checks would miss.
    func testFixtureScenesFlattenToTheDocumentedCounts() throws {
        let car = try RenderScene(fixture("155-DTM/155-DTM.acc"))
        let track = try RenderScene(fixture("aalborg/aalborg.acc"))

        XCTAssertEqual(car.vertexCount, 4032, "car declared vertex count")
        XCTAssertEqual(track.vertexCount, 13577, "track declared vertex count")
        // 1,333 batches across both, minus those whose primitives produce no
        // triangles (the cache retains line loops and strips).
        XCTAssertEqual(car.batches.count + track.batches.count, 1333, "total mesh batches")
        XCTAssertEqual(car.triangleCount + track.triangleCount, 18003, "triangles including degenerates")
        print("FLATTEN car \(car.batches.count) batches / \(car.triangleCount) tris, track \(track.batches.count) / \(track.triangleCount)")
    }

    func testBoundsAreFiniteAndCoverTheTrack() throws {
        let track = try RenderScene(fixture("aalborg/aalborg.acc"))
        for i in 0 ..< 3 {
            XCTAssertTrue(track.minimum[i].isFinite && track.maximum[i].isFinite)
            XCTAssertLessThan(track.minimum[i], track.maximum[i])
        }
        // Aalborg is a real circuit: hundreds of metres across, not centimetres.
        XCTAssertGreaterThan(track.maximum.x - track.minimum.x, 200)
    }

    func testDriverSubtreeIsIdentifiedOnTheCar() throws {
        let car = try RenderScene(fixture("155-DTM/155-DTM.acc"))
        let driverBatches = car.batches.filter(\.isDriver)
        XCTAssertFalse(driverBatches.isEmpty, "the car must expose a DRIVER subtree to hide in cockpit views")
        XCTAssertLessThan(driverBatches.count, car.batches.count, "not everything is the driver")
    }

    /// Every vertex feeding the PBR shader needs a usable tangent frame, or
    /// normal mapping produces visible garbage on those triangles.
    func testEveryFlattenedVertexCarriesAUsableTangentFrame() throws {
        for name in ["155-DTM/155-DTM.acc", "aalborg/aalborg.acc"] {
            let scene = try RenderScene(fixture(name))
            var checked = 0
            for batch in scene.batches {
                for vertex in batch.mesh.vertices {
                    // A zero-packed tangent would decode to a degenerate frame.
                    XCTAssertFalse(vertex.tangent == SIMD2<Int16>(0, 0) && vertex.normal == SIMD2<Int16>(0, 0),
                                   "degenerate packed frame in \(name)")
                    XCTAssertTrue(vertex.positionX.isFinite && vertex.positionY.isFinite && vertex.positionZ.isFinite)
                    checked += 1
                }
            }
            XCTAssertGreaterThan(checked, 4000, "\(name) produced too few vertices")
        }
    }

    func testCutoutAndTranslucentStateSurvivesFlattening() throws {
        let track = try RenderScene(fixture("aalborg/aalborg.acc"))
        // Aalborg's trees are alpha cutouts; the loader marks them by filename.
        let cutouts = track.batches.filter { $0.alphaTestThreshold != nil }
        XCTAssertFalse(cutouts.isEmpty, "expected alpha-tested foliage batches")
        for batch in cutouts {
            let threshold = try XCTUnwrap(batch.alphaTestThreshold)
            XCTAssertTrue(threshold > 0 && threshold <= 1, "implausible cutout threshold \(threshold)")
        }
        // Blending and deferral are independent: TORCS enables blending very
        // widely, where it is a no-op at alpha 1, but defers only genuinely
        // see-through surfaces. Treating the blend flag as transparency marks
        // whole vehicles transparent.
        XCTAssertFalse(track.batches.allSatisfy(\.isDeferred), "not every track batch is transparent")
    }

    func testBaseTexturesAreRetainedForMaterialResolution() throws {
        let track = try RenderScene(fixture("aalborg/aalborg.acc"))
        let named = track.batches.compactMap(\.baseTexture)
        XCTAssertFalse(named.isEmpty, "material resolution needs the source texture names")
        XCTAssertTrue(named.contains { $0.contains("asphalt") || $0.contains("tr-") },
                      "expected recognisable road texture references, got \(Set(named).prefix(5))")
    }

    func testDegenerateTransformsAreRejected() throws {
        var scene = try fixture("155-DTM/155-DTM.acc")
        // Collapse the root basis: no inverse, so no valid normal transform.
        scene.nodes[0].matrix = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        XCTAssertThrowsError(try RenderScene(scene))

        var nonfinite = try fixture("155-DTM/155-DTM.acc")
        nonfinite.nodes[0].matrix = [Float.nan, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        XCTAssertThrowsError(try RenderScene(nonfinite))
    }
}
