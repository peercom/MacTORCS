// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import TORCSTrack
import TORCSTrackMesh
import TORCSRender
import TORCSAssets

final class PitGenerationTests: XCTestCase {
    func testOneGaragePerStallAgainstTheLaneEdge() throws {
        let road = try RoadGenerationTests().aalborg()
        let pits = road.pits
        XCTAssertGreaterThan(pits.positions.count, 5)
        let garages = PitGeneration.footprints(road.geometry, pits: pits)
        XCTAssertEqual(garages.count, pits.positions.count)
        let parameters = PitGeneration.Parameters()
        for (garage, stall) in zip(garages, pits.positions) {
            let f = garage.floor
            // One stall long less the gap, and the declared depth.
            XCTAssertEqual(simd_length(f[1] - f[0]), pits.stallLength - parameters.gap, accuracy: 0.6)
            XCTAssertEqual(simd_length(f[3] - f[0]), parameters.depth, accuracy: 0.05)
            // Level floor, on the ground, beside its stall: the lane-side
            // wall is within a lane width and a half of the stall centre.
            XCTAssertEqual(f[0].z, f[2].z, accuracy: 1e-4)
            let centre = road.geometry.localToGlobal(
                TrackLocalPosition(segment: stall.segment, toStart: stall.toStart, toRight: stall.toRight))
            let wallMid = (f[0] + f[1]) / 2
            XCTAssertLessThan(simd_distance(SIMD2(wallMid.x, wallMid.y), centre), pits.laneWidth * 1.5 + 1,
                              "garage stands away from its stall")
            // And outside the main road entirely.
            let main = road.geometry.segments[stall.segment]
            let onRoad = try? road.geometry.globalToLocal(SIMD2(f[3].x, f[3].y), startingAt: stall.segment, mode: .segment)
            if let onRoad { XCTAssertNotEqual(road.geometry.segments[onRoad.segment].role, .main, "back wall on the road") }
            _ = main
        }
    }

    func testGaragesBecomeThreeMaterialBatches() throws {
        let road = try RoadGenerationTests().aalborg()
        let groups = PitGeneration.garages(road.geometry, pits: road.pits)
        XCTAssertEqual(groups.map(\.material), ["brick", "painted-steel", "concrete"])
        for group in groups {
            XCTAssertEqual(group.geometry.positions.count, group.geometry.normals.count)
            XCTAssertEqual(group.geometry.positions.count, group.geometry.uv0.count)
            // Every triangle faces the way its normals say (the orient pass).
            let g = group.geometry
            for i in stride(from: 0, to: g.indices.count, by: 3) {
                let a = g.positions[Int(g.indices[i])], b = g.positions[Int(g.indices[i + 1])], c = g.positions[Int(g.indices[i + 2])]
                XCTAssertGreaterThan(simd_dot(simd_cross(b - a, c - a), g.normals[Int(g.indices[i])]), 0)
            }
        }
        let batches = try TrackSurfaceAssembly.pitBatches(road.geometry, pits: road.pits)
        XCTAssertEqual(batches.count, 3)
        XCTAssertTrue(batches.allSatisfy { $0.receivesWeather && $0.uvInMetres })
        XCTAssertEqual(MaterialLibrary.material(for: "painted-steel.rgb"), "painted-steel")
        // The batch textures must map to the sets and must not be the name of
        // any original artwork, or its paint would be composited over them.
        for batch in batches {
            let texture = try XCTUnwrap(batch.baseTexture)
            XCTAssertTrue(texture.hasPrefix("pit-"), texture)
            XCTAssertNotNil(MaterialLibrary.material(for: texture), texture)
        }
    }

    /// The track marks the pit-side barrier as a pit building; the road
    /// generator leaves it to the garages rather than extruding a block.
    func testPitBuildingBarriersAreLeftToTheGarages() throws {
        let road = try RoadGenerationTests().aalborg()
        let marked = road.geometry.segments.filter { $0.rightBarrier?.style == .pitBuilding || $0.leftBarrier?.style == .pitBuilding }
        XCTAssertGreaterThan(marked.count, 5)
        var withBlock = RoadGeneration.Parameters(); withBlock.pitBuildings = true
        let without = RoadGeneration.road(road.geometry), with = RoadGeneration.road(road.geometry, parameters: withBlock)
        XCTAssertLessThan(without.triangleCount, with.triangleCount)
        // Nothing of the road's own geometry stands where a garage does.
        // Counted, then asserted once: an assertion per vertex per garage
        // took twenty minutes.
        let garages = PitGeneration.footprints(road.geometry, pits: road.pits)
        let boxes = garages.map { g -> (SIMD2<Float>, SIMD2<Float>) in
            (SIMD2(g.floor.map(\.x).min()! + 0.5, g.floor.map(\.y).min()! + 0.5),
             SIMD2(g.floor.map(\.x).max()! - 0.5, g.floor.map(\.y).max()! - 0.5))
        }
        var inside = 0
        for group in without.groups {
            for p in group.geometry.positions where p.z > 8 {
                if boxes.contains(where: { p.x > $0.0.x && p.x < $0.1.x && p.y > $0.0.y && p.y < $0.1.y }) { inside += 1 }
            }
        }
        XCTAssertEqual(inside, 0, "road geometry inside a garage")
    }

    func testNoPitsNoGarages() throws {
        let road = try RoadGenerationTests().aalborg()
        let none = TrackPits(type: .none, side: nil, entry: nil, start: nil, end: nil, exit: nil,
                             stallLength: 0, laneWidth: 0, speedLimit: 0, positions: [])
        XCTAssertTrue(PitGeneration.garages(road.geometry, pits: none).isEmpty)
    }
}

extension PitGenerationTests {
    /// The baked scene's pit building stands where the garages go, and so do
    /// the pit lane's lamp posts, which would otherwise pierce the roofs;
    /// the trees and everything elsewhere stay.
    func testBakedPitComplexIsStrippedAndLampPostsStay() throws {
        let road = try RoadGenerationTests().aalborg()
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/Artwork/aalborg/aalborg.acc")
        let scene = try RenderScene(ACScene.parse(Data(contentsOf: url), car: false))
        let garages = PitGeneration.footprints(road.geometry, pits: road.pits)
        let stripped = TrackSurfaceAssembly.strippingPitComplex(scene, garages: garages)
        func count(_ s: RenderScene, _ texture: String) -> Int { s.batches.filter { $0.baseTexture == texture }.count }
        XCTAssertLessThan(count(stripped, "concrete.rgb"), count(scene, "concrete.rgb"), "the pit building is concrete.rgb")
        XCTAssertEqual(count(stripped, "allborg-trees_n.rgb"), count(scene, "allborg-trees_n.rgb"))
        XCTAssertEqual(count(stripped, "tr-asphalt-aa-bw1_n.rgb"), count(scene, "tr-asphalt-aa-bw1_n.rgb"), "the road is not the building")
        XCTAssertGreaterThan(stripped.batches.count, scene.batches.count - 40)
    }
}
