// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import TORCSConfiguration
import TORCSTrack
import TORCSTrackMesh
import TORCSMaterials

final class GrassGenerationTests: XCTestCase {
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

    /// Aalborg is walled for the whole lap at 0.6 m; grass behind a wall
    /// taller than itself is invisible from the road and must not be placed.
    func testWalledVergesGetNoGrass() throws {
        let road = try aalborg()
        XCTAssertEqual(GrassGeneration.chunks(road.geometry).reduce(0) { $0 + $1.clumpCount }, 0)
    }

    func testClumpsLineBothVergesInChunksAndStayOffTheRoad() throws {
        let road = try aalborg()
        var parameters = GrassGeneration.Parameters()
        parameters.skipBehindBarriersTallerThan = .infinity
        let chunks = GrassGeneration.chunks(road.geometry, parameters: parameters)
        XCTAssertEqual(chunks.count, Int(road.length / 100) + 1, "one chunk per hundred metres")
        let clumps = chunks.reduce(0) { $0 + $1.clumpCount }
        XCTAssertGreaterThan(clumps, 5_000)
        XCTAssertLessThan(clumps, 60_000, "a verge, not a prairie")
        var offRoad = 0, checked = 0
        for chunk in chunks {
            let g = chunk.geometry
            XCTAssertEqual(g.attributes.count, g.positions.count)
            XCTAssertEqual(g.indices.count, chunk.clumpCount * 12, "two quads per clump")
            for (i, p) in g.positions.enumerated() where i % 8 == 0 && i % 64 == 0 {
                checked += 1
                XCTAssertTrue(p.z.isFinite)
                // The clump must sit beyond the main road's edges.
                let hint = road.geometry.mainSegments.min {
                    simd_length_squared(SIMD2(road.geometry.segments[$0].startRight.x, road.geometry.segments[$0].startRight.y) - SIMD2(p.x, p.y))
                        < simd_length_squared(SIMD2(road.geometry.segments[$1].startRight.x, road.geometry.segments[$1].startRight.y) - SIMD2(p.x, p.y))
                }!
                if let local = try? road.geometry.globalToLocal(SIMD2(p.x, p.y), startingAt: hint, mode: .main) {
                    let width = road.geometry.width(segment: local.segment, toStart: local.toStart)
                    if local.toRight < 0 || local.toRight > width { offRoad += 1 }
                }
            }
        }
        XCTAssertGreaterThan(checked, 100)
        XCTAssertEqual(offRoad, checked, "\(checked - offRoad) sampled clumps lie on the main road")
    }

    func testGenerationIsDeterministic() throws {
        let road = try aalborg()
        var parameters = GrassGeneration.Parameters()
        parameters.skipBehindBarriersTallerThan = .infinity
        XCTAssertEqual(GrassGeneration.chunks(road.geometry, parameters: parameters),
                       GrassGeneration.chunks(road.geometry, parameters: parameters))
    }

    /// The blade atlas: four clumps, real coverage in alpha, nothing in the gaps.
    func testGrassCardAtlasHasCoverageInEveryQuadrant() throws {
        let material = try MaterialRecipes.generate("grass-cards", size: 256, seed: 1)
        XCTAssertEqual(material.albedo.count, 256 * 256 * 4)
        for quadrant in 0 ..< 4 {
            let ox = (quadrant % 2) * 128, oy = (quadrant / 2) * 128
            var covered = 0
            for y in 0 ..< 128 {
                for x in 0 ..< 128 {
                    let index = ((oy + y) * 256 + ox + x) * 4 + 3
                    if material.albedo[index] > 128 { covered += 1 }
                }
            }
            let fraction = Double(covered) / Double(128 * 128)
            XCTAssertGreaterThan(fraction, 0.08, "quadrant \(quadrant) is nearly empty")
            XCTAssertLessThan(fraction, 0.7, "quadrant \(quadrant) is a solid block")
        }
        XCTAssertEqual(try MaterialRecipes.generate("grass-cards", size: 256, seed: 1).albedo, material.albedo, "deterministic")
    }
}
