// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import TORCSConfiguration
import TORCSTrack
import TORCSTrackMesh
import TORCSRender

final class RoadGenerationTests: XCTestCase {
    func aalborg() throws -> TrackRoad {
        let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let document = try ParameterDocument.parse(
            Data(contentsOf: fixtures.appendingPathComponent("aalborg.xml")),
            entities: [
                "default-surfaces": Data(contentsOf: fixtures.appendingPathComponent("surfaces.xml")),
                "default-objects": Data(contentsOf: fixtures.appendingPathComponent("objects.xml"))],
            allowLegacyLatin1: true)
        return try TrackBuilder.buildRoad(parameters: document)
    }

    func testEverySegmentProducesSurfaceGroupedByMaterial() throws {
        let road = try aalborg()
        let generated = RoadGeneration.road(road.geometry)
        XCTAssertFalse(generated.groups.isEmpty)
        let materials = Set(road.geometry.segments.map(\.surface.material))
        for material in materials {
            XCTAssertTrue(generated.groups.contains { $0.material == material }, "no geometry for \(material)")
        }
        // Grouping is the point: a circuit is a handful of draws, not a thousand.
        XCTAssertLessThan(generated.groups.count, 32)
        XCTAssertGreaterThan(generated.triangleCount, 10_000)
    }

    /// The renderer's front-face convention is counter-clockwise from the
    /// visible side, and road faces up. Every drivable triangle must wind so
    /// its geometric normal has a positive z, or it is culled from above.
    func testDrivableSurfacesWindUpward() throws {
        let road = try aalborg()
        let drivable = Set(road.geometry.segments.map(\.surface.material))
        for group in RoadGeneration.road(road.geometry).groups where drivable.contains(group.material) {
            let g = group.geometry
            var down = 0
            for i in stride(from: 0, to: g.indices.count, by: 3) {
                let a = g.positions[Int(g.indices[i])], b = g.positions[Int(g.indices[i + 1])], c = g.positions[Int(g.indices[i + 2])]
                if simd_cross(b - a, c - a).z < 0 { down += 1 }
            }
            XCTAssertEqual(down, 0, "\(down) downward triangles in \(group.material)")
        }
    }

    /// The whole reason to generate from the segment model: every vertex must
    /// sit exactly on the surface the physics drives on.
    func testVerticesLieOnThePhysicsSurface() throws {
        let road = try aalborg()
        let generated = RoadGeneration.road(road.geometry)
        let drivable = Set(road.geometry.segments.map(\.surface.material))
        var checked = 0, worst: Float = 0
        for group in generated.groups where drivable.contains(group.material) {
            for (i, p) in group.geometry.positions.enumerated() where i % 97 == 0 {
                // Query from the nearest main segment, as a car would.
                let hint = road.geometry.mainSegments.min {
                    simd_length_squared(SIMD2(road.geometry.segments[$0].startRight.x, road.geometry.segments[$0].startRight.y) - SIMD2(p.x, p.y))
                        < simd_length_squared(SIMD2(road.geometry.segments[$1].startRight.x, road.geometry.segments[$1].startRight.y) - SIMD2(p.x, p.y))
                }!
                guard let local = try? road.geometry.globalToLocal(SIMD2(p.x, p.y), startingAt: hint, mode: .segment) else { continue }
                let h = road.geometry.height(local)
                guard h.isFinite else { continue }
                worst = max(worst, abs(h - p.z))
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 200)
        // Surface roughness is a sine of a few centimetres; the tolerance
        // covers it and nothing more.
        XCTAssertLessThan(worst, 0.06, "worst height error \(worst) m over \(checked) vertices")
    }

    func testBarriersStandOnTheGroundAtTheirDeclaredHeight() throws {
        let road = try aalborg()
        let generated = RoadGeneration.road(road.geometry)
        let barriers = road.geometry.segments.compactMap(\.rightBarrier) + road.geometry.segments.compactMap(\.leftBarrier)
        let barrierMaterials = Set(barriers.map(\.surface.material))
        // Aalborg declares 0.6 m walls along most of the lap and taller ones
        // in places; every generated rise must be one of the declared heights.
        let heights = Set(barriers.map { ($0.height * 1000).rounded() / 1000 })
        XCTAssertFalse(barrierMaterials.isEmpty, "Aalborg declares barriers")
        XCTAssertTrue(heights.contains(0.6), "expected the 0.6 m default wall among \(heights)")
        for group in generated.groups where barrierMaterials.contains(group.material) {
            let g = group.geometry
            XCTAssertFalse(g.isEmpty)
            // Rows of four: foot, top, top, foot. Each rise is a declared height.
            for row in stride(from: 0, to: g.positions.count, by: 4) {
                let rise = ((g.positions[row + 1].z - g.positions[row].z) * 1000).rounded() / 1000
                XCTAssertTrue(heights.contains(rise), "rise \(rise) is not a declared barrier height \(heights)")
                XCTAssertEqual(g.positions[row + 2].z, g.positions[row + 1].z, accuracy: 1e-4)
            }
            // No wall face may be wound to show its back to the road side it
            // is drawn from: normals and winding agree.
            for i in stride(from: 0, to: g.indices.count, by: 3) {
                let a = Int(g.indices[i]), b = Int(g.indices[i + 1]), c = Int(g.indices[i + 2])
                let face = simd_cross(g.positions[b] - g.positions[a], g.positions[c] - g.positions[a])
                XCTAssertGreaterThanOrEqual(simd_dot(face, g.normals[a] + g.normals[b] + g.normals[c]), 0)
            }
        }
    }

    /// A lap is kilometres long and `uv0` is a half: at 2,500 m its quantum is
    /// 2 m, which turned every other row of the road behind the start line
    /// into a streak. Folded storage must reconstruct to the centimetre.
    func testMetreUVsSurviveHalfPrecisionPacking() throws {
        let along: [Float] = [0, 7.99, 8, 100.3, 1023.7, 2499.4, 2999.9]
        let positions = along.map { SIMD3<Float>($0, 0, 0) }
        let uv = along.map { SIMD2<Float>($0, 12.34) }
        let indices: [UInt32] = [0, 1, 2, 2, 1, 3, 3, 4, 5, 5, 4, 6]
        let mesh = try RenderMesh.build(positions: positions, normals: positions.map { _ in SIMD3(0, 0, 1) },
                                        uv0: uv, indices: indices, uvInMetres: true)
        for (i, vertex) in mesh.vertices.enumerated() {
            let remainderX = Float(vertex.uv0.x), remainderY = Float(vertex.uv0.y)
            let countX = Float(vertex.uv1.x), countY = Float(vertex.uv1.y)
            let unfoldedX = remainderX + countX * RenderMesh.metresPeriod
            let unfoldedY = remainderY + countY * RenderMesh.metresPeriod
            XCTAssertEqual(unfoldedX, along[i], accuracy: 0.01, "along \(along[i])")
            XCTAssertEqual(unfoldedY, 12.34, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(Float(vertex.uv0.x), 0)
            XCTAssertLessThan(Float(vertex.uv0.x), RenderMesh.metresPeriod)
        }
        // And the naive packing really does lose it, or this test guards nothing.
        let naive = try RenderMesh.build(positions: positions, normals: positions.map { _ in SIMD3(0, 0, 1) },
                                         uv0: uv, indices: indices)
        XCTAssertGreaterThan(abs(Float(naive.vertices[5].uv0.x) - along[5]), 0.2)
    }

    /// The shader paints from these; a wrong lateral coordinate puts the edge
    /// line in the middle of the road.
    func testAttributesEncodeLateralPositionWidthAndRole() throws {
        let road = try aalborg()
        let generated = RoadGeneration.road(road.geometry)
        let mains = Set(road.geometry.mainSegments.map { road.geometry.segments[$0].surface.material })
        for group in generated.groups {
            XCTAssertEqual(group.geometry.attributes.count, group.geometry.positions.count, group.material)
        }
        let main = try XCTUnwrap(generated.groups.first { mains.contains($0.material) })
        let attributes = main.geometry.attributes
        // Rows of nine across the main road: lateral climbs 0 → 255 within each row.
        for row in stride(from: 0, to: min(attributes.count, 90), by: 9) {
            XCTAssertEqual(attributes[row].x, 0)
            XCTAssertEqual(attributes[row + 8].x, 255)
            XCTAssertLessThan(attributes[row + 4].x, attributes[row + 5].x)
            XCTAssertEqual(attributes[row].z, 0, "main road role")
            // Aalborg's main road is 10 m wide: 80 eighths.
            XCTAssertEqual(Int(attributes[row].y), 80, accuracy: 4)
        }
        XCTAssertEqual(RoadGeneration.attributes(toRight: 2.5, width: 10, role: .leftSide), SIMD4(64, 80, 1, 128))
        XCTAssertEqual(RoadGeneration.attributes(toRight: 2.5, width: 10, role: .main, line: 0.25).w, 64)
        XCTAssertEqual(RoadGeneration.attributes(toRight: 0, width: 2, role: .rightBorder).z, 2)
    }

    func testGenerationIsDeterministic() throws {
        let road = try aalborg()
        XCTAssertEqual(RoadGeneration.road(road.geometry), RoadGeneration.road(road.geometry))
    }

    func testStepControlsDensity() throws {
        let road = try aalborg()
        var coarse = RoadGeneration.Parameters(), fine = RoadGeneration.Parameters()
        coarse.step = 4; fine.step = 0.5
        let a = RoadGeneration.road(road.geometry, parameters: coarse).triangleCount
        let b = RoadGeneration.road(road.geometry, parameters: fine).triangleCount
        XCTAssertGreaterThan(b, a * 4)
    }
}

final class RacingLineTests: XCTestCase {
    /// Outside on the approach, inside at the apex, outside on the exit: the
    /// shape every line has, checked on Aalborg's tightest corner.
    func testLineGoesInsideAtTheApexAndOutsideOnTheApproach() throws {
        let road = try RoadGenerationTests().aalborg()
        let g = road.geometry
        let line = RacingLine(g)
        XCTAssertEqual(line.lateral.count, Int(line.lapLength.rounded(.up)))
        let tightest = try XCTUnwrap(g.mainSegments.filter { g.segments[$0].curve != .straight }
            .min { g.segments[$0].radius < g.segments[$1].radius })
        let s = g.segments[tightest]
        // TORCS splits a corner into many short arcs; the apex is the middle
        // of the run of same-hand arcs containing the tightest one.
        var first = tightest, last = tightest
        while g.segments[g.segments[first].previous].curve == s.curve { first = g.segments[first].previous }
        while g.segments[g.segments[last].next].curve == s.curve { last = g.segments[last].next }
        let start = g.segments[first].distanceFromStart
        let end = g.segments[last].distanceFromStart + g.segments[last].length
        let apex = (start + end) / 2
        let inside = line.lateral(at: apex)
        let before = line.lateral(at: start - 40), after = line.lateral(at: end + 40)
        // Right-handers pull toward the right edge (lateral 0), left-handers
        // toward the left (1). Approach and exit sit on the other side.
        if s.curve == .right {
            XCTAssertLessThan(inside, 0.4); XCTAssertGreaterThan(before, inside); XCTAssertGreaterThan(after, inside)
        } else {
            XCTAssertGreaterThan(inside, 0.6); XCTAssertLessThan(before, inside); XCTAssertLessThan(after, inside)
        }
    }

    /// The band must never leave the road, must have no kinks, and must
    /// close on itself at the start line.
    func testLineStaysOnTheRoadAndIsContinuous() throws {
        let road = try RoadGenerationTests().aalborg()
        let line = RacingLine(road.geometry)
        var worstStep: Float = 0
        for i in line.lateral.indices {
            XCTAssertGreaterThanOrEqual(line.lateral[i], 0.1); XCTAssertLessThanOrEqual(line.lateral[i], 0.9)
            worstStep = max(worstStep, abs(line.lateral[(i + 1) % line.lateral.count] - line.lateral[i]))
        }
        // Crossing the road in under ten metres would be a swerve, not a line.
        XCTAssertLessThan(worstStep, 0.05, "worst per-metre change \(worstStep)")
        XCTAssertEqual(line.lateral(at: 0), line.lateral(at: line.lapLength), accuracy: 1e-4)
        // Not the centre line: the whole point.
        XCTAssertGreaterThan(line.lateral.map { abs($0 - 0.5) }.max() ?? 0, 0.25)
    }

    /// The generator carries the line per row in the fourth attribute.
    func testRoadRowsCarryTheLine() throws {
        let road = try RoadGenerationTests().aalborg()
        let generated = RoadGeneration.road(road.geometry)
        let mains = Set(road.geometry.mainSegments.map { road.geometry.segments[$0].surface.material })
        let main = try XCTUnwrap(generated.groups.first { mains.contains($0.material) })
        let w = main.geometry.attributes.map(\.w)
        XCTAssertGreaterThan(Set(w).count, 20, "the line varies along the lap")
        // Constant across a row of nine.
        for row in stride(from: 0, to: min(w.count, 900), by: 9) {
            XCTAssertEqual(Set(w[row ..< row + 9]).count, 1)
        }
    }
}
