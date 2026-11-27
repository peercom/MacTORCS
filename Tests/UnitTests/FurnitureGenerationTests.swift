// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import TORCSTrack
import TORCSTrackMesh
import TORCSRender

final class FurnitureGenerationTests: XCTestCase {
    func testCornersGetTyreWallsOnTheOutside() throws {
        let road = try RoadGenerationTests().aalborg()
        let runs = FurnitureGeneration.runs(road.geometry)
        XCTAssertGreaterThan(runs.count, 4)
        for run in runs {
            let hand = road.geometry.segments[run.segments[0]].curve
            XCTAssertNotEqual(hand, .straight)
            XCTAssertEqual(run.side, hand == .right ? .left : .right, "the wall is on the outside")
            for index in run.segments { XCTAssertEqual(road.geometry.segments[index].curve, hand) }
            let length = run.segments.reduce(Float(0)) { $0 + road.geometry.segments[$1].length }
            XCTAssertGreaterThanOrEqual(length, FurnitureGeneration.Parameters().minimumLength)
        }
        // A kink between two straights gets nothing.
        var strict = FurnitureGeneration.Parameters(); strict.minimumLength = 1000
        XCTAssertTrue(FurnitureGeneration.runs(road.geometry, parameters: strict).isEmpty)
    }

    func testTyreWallGeometryStandsOnTheEdgeAndWindsOutward() throws {
        let road = try RoadGenerationTests().aalborg()
        let g = FurnitureGeneration.tyreWalls(road.geometry)
        XCTAssertGreaterThan(g.triangleCount, 100)
        XCTAssertEqual(g.positions.count, g.normals.count)
        XCTAssertEqual(g.positions.count, g.uv0.count)
        XCTAssertEqual(g.positions.count, g.attributes.count)
        // Winding agrees with the vertex normals, judged as the orient pass
        // judges it: against the sum of the three, since a strip's rows share
        // vertices between faces of different orientation.
        var wrong = 0
        for i in stride(from: 0, to: g.indices.count, by: 3) {
            let ia = Int(g.indices[i]), ib = Int(g.indices[i + 1]), ic = Int(g.indices[i + 2])
            let a = g.positions[ia], b = g.positions[ib], c = g.positions[ic]
            if simd_dot(simd_cross(b - a, c - a), g.normals[ia] + g.normals[ib] + g.normals[ic]) <= 0 { wrong += 1 }
        }
        XCTAssertEqual(wrong, 0, "\(wrong) faces wound against their normals")
        // Every foot vertex sits on the physics surface within the roughness tolerance.
        var worst: Float = 0
        for (i, p) in g.positions.enumerated() where i % 4 == 0 && i % 40 == 0 {
            let hint = road.geometry.mainSegments.min {
                simd_length_squared(SIMD2(road.geometry.segments[$0].startRight.x, road.geometry.segments[$0].startRight.y) - SIMD2(p.x, p.y))
                    < simd_length_squared(SIMD2(road.geometry.segments[$1].startRight.x, road.geometry.segments[$1].startRight.y) - SIMD2(p.x, p.y))
            }!
            guard let local = try? road.geometry.globalToLocal(SIMD2(p.x, p.y), startingAt: hint, mode: .segment) else { continue }
            let h = road.geometry.height(local)
            if h.isFinite { worst = max(worst, abs(h - p.z)) }
        }
        XCTAssertLessThan(worst, 0.1, "tyre wall foot off the surface by \(worst)")
    }
}

extension FurnitureGenerationTests {
    /// A wall's face is tyres seen edge on and its top is tyres seen from
    /// above: two pictures, so two batches, each on its own set.
    func testTyreWallsBecomeAFaceBatchAndATopBatch() throws {
        let road = try RoadGenerationTests().aalborg()
        let batches = try TrackSurfaceAssembly.furnitureBatches(road.geometry)
        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(try batches.map { MaterialLibrary.material(for: try XCTUnwrap($0.baseTexture)) }, ["tyre-wall", "tyre-top"])
        XCTAssertTrue(batches.allSatisfy(\.uvInMetres))
    }

    /// The faces stand upright and carry no part of the top; the top lies
    /// flat at the wall's height, a stack's depth across, and runs the same
    /// length as the faces.
    func testTheTopIsItsOwnGeometryAtTheWallsHeight() throws {
        let road = try RoadGenerationTests().aalborg()
        let parameters = FurnitureGeneration.Parameters()
        let faces = FurnitureGeneration.tyreWalls(road.geometry, parameters: parameters)
        let tops = FurnitureGeneration.tyreWallTops(road.geometry, parameters: parameters)
        XCTAssertFalse(tops.isEmpty)
        XCTAssertEqual(tops.positions.count * 2, faces.positions.count, "two top vertices to a row of four")
        XCTAssertEqual(tops.triangleCount * 2, faces.triangleCount, "a top quad to a front and a back")
        for normal in faces.normals { XCTAssertEqual(normal.z, 0, "a face's normal is level") }
        for normal in tops.normals { XCTAssertEqual(normal, SIMD3(0, 0, 1)) }
        for row in stride(from: 0, to: tops.positions.count, by: 2) {
            let front = tops.positions[row], back = tops.positions[row + 1]
            // The same two points as the faces' upper edge.
            XCTAssertEqual(front, faces.positions[row * 2 + 1])
            XCTAssertEqual(back, faces.positions[row * 2 + 2])
            XCTAssertEqual(front.z - faces.positions[row * 2].z, parameters.height, accuracy: 1e-4)
            XCTAssertEqual(simd_distance(front, back), parameters.depth, accuracy: 1e-3)
            // Metres back from the front, so one ring of the top set falls on one stack.
            XCTAssertEqual(tops.uv0[row].y, 0); XCTAssertEqual(tops.uv0[row + 1].y, parameters.depth)
            XCTAssertEqual(tops.uv0[row].x, faces.uv0[row * 2].x)
        }
        // Up the stack on the back as on the front, so neither is upside down.
        for row in stride(from: 0, to: faces.uv0.count, by: 4) {
            XCTAssertEqual(faces.uv0[row].y, 0); XCTAssertEqual(faces.uv0[row + 3].y, 0)
            XCTAssertEqual(faces.uv0[row + 1].y, parameters.height); XCTAssertEqual(faces.uv0[row + 2].y, parameters.height)
        }
        var wrong = 0
        for i in stride(from: 0, to: tops.indices.count, by: 3) {
            let a = tops.positions[Int(tops.indices[i])], b = tops.positions[Int(tops.indices[i + 1])], c = tops.positions[Int(tops.indices[i + 2])]
            if simd_cross(b - a, c - a).z <= 0 { wrong += 1 }
        }
        XCTAssertEqual(wrong, 0, "\(wrong) top faces wound downward")
    }
}
