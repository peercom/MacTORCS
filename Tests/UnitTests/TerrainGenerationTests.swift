// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import TORCSConfiguration
import TORCSTrack
import TORCSTrackMesh

final class TerrainGenerationTests: XCTestCase {
    func aalborg() throws -> (document: ParameterDocument, road: TrackRoad) {
        let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let document = try ParameterDocument.parse(
            Data(contentsOf: fixtures.appendingPathComponent("aalborg.xml")),
            entities: [
                "default-surfaces": Data(contentsOf: fixtures.appendingPathComponent("surfaces.xml")),
                "default-objects": Data(contentsOf: fixtures.appendingPathComponent("objects.xml"))],
            allowLegacyLatin1: true)
        return (document, try TrackBuilder.buildRoad(parameters: document))
    }

    /// The parameters exist in every track XML and were never read before.
    func testParametersComeFromTheTrackXML() throws {
        let parameters = TerrainParameters(document: try aalborg().document)
        XCTAssertEqual(parameters.trackStep, 10)
        XCTAssertEqual(parameters.borderMargin, 100)
        XCTAssertEqual(parameters.borderStep, 30)
        XCTAssertEqual(parameters.borderHeight, 20)
        XCTAssertEqual(parameters.surface, "grass-aa")
    }

    func testMissingSectionFallsBackToDefaults() throws {
        let empty = try ParameterDocument.parse(Data("<params name=\"x\"></params>".utf8), entities: [:])
        let parameters = TerrainParameters(document: empty)
        XCTAssertEqual(parameters.borderMargin, 100)
        XCTAssertEqual(parameters.surface, "grass-aa")
    }

    func testApronCoversTheWholeCircuitWithFiniteGeometry() throws {
        let road = try aalborg().road
        let apron = TerrainGeneration.apron(road.geometry)
        XCTAssertFalse(apron.isEmpty)
        XCTAssertGreaterThan(apron.triangleCount, 1000, "apron is too sparse to be ground")
        XCTAssertEqual(apron.positions.count, apron.normals.count)
        XCTAssertEqual(apron.positions.count, apron.uv0.count)

        for position in apron.positions {
            XCTAssertTrue(position.x.isFinite && position.y.isFinite && position.z.isFinite)
        }
        for index in apron.indices {
            XCTAssertLessThan(Int(index), apron.positions.count, "index out of range")
        }
    }

    /// Ground must face the sky. A flipped winding would leave the apron lit
    /// from below and shadowed from above, which reads as black terrain.
    func testNormalsPointUpward() throws {
        let road = try aalborg().road
        let apron = TerrainGeneration.apron(road.geometry)
        var upward = 0
        for normal in apron.normals {
            XCTAssertEqual(simd_length(normal), 1, accuracy: 1e-3)
            if normal.z > 0.5 { upward += 1 }
        }
        let fraction = Double(upward) / Double(apron.normals.count)
        XCTAssertGreaterThan(fraction, 0.95, "only \(Int(fraction * 100))% of apron normals face up")
    }

    /// The rim is measured from the circuit's bounding box, so the infield —
    /// which lies inside it — must stay flat. Measuring from the road edge
    /// instead would build an embankment down the middle of the infield.
    func testInfieldStaysFlatWhileTheOuterRimRises() throws {
        let road = try aalborg().road
        let parameters = TerrainParameters(document: try aalborg().document)
        let apron = TerrainGeneration.apron(road.geometry, parameters: parameters)

        var low = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for index in road.geometry.mainSegments {
            for corner in [road.geometry.segments[index].startRight, road.geometry.segments[index].endLeft] {
                low = simd_min(low, SIMD2(corner.x, corner.y))
                high = simd_max(high, SIMD2(corner.x, corner.y))
            }
        }

        var insideHeights: [Float] = [], outsideHeights: [Float] = []
        for position in apron.positions {
            let xy = SIMD2(position.x, position.y)
            let outside = simd_length(simd_max(simd_max(low - xy, xy - high), SIMD2(0, 0)))
            if outside == 0 { insideHeights.append(position.z) }
            else if outside > parameters.borderMargin * 0.9 { outsideHeights.append(position.z) }
        }
        XCTAssertFalse(insideHeights.isEmpty, "expected apron inside the circuit footprint")
        XCTAssertFalse(outsideHeights.isEmpty, "expected apron beyond the circuit footprint")

        // Track elevation itself spans tens of metres, so compare against the
        // road rather than against an absolute height.
        let trackHigh = road.geometry.segments.map(\.startRight.z).max() ?? 0
        let insideMax = insideHeights.max() ?? 0
        XCTAssertLessThanOrEqual(insideMax, trackHigh + 1, "infield was raised by the rim")
        XCTAssertGreaterThan(outsideHeights.max() ?? 0, insideMax, "outer rim did not rise")
    }

    func testDegenerateParametersDoNotTrap() throws {
        let road = try aalborg().road
        for parameters in [TerrainParameters(trackStep: 0, borderMargin: 0, borderStep: 0, borderHeight: 0),
                           TerrainParameters(trackStep: 1000, borderMargin: 1, borderStep: 1000)] {
            let apron = TerrainGeneration.apron(road.geometry, parameters: parameters)
            for position in apron.positions {
                XCTAssertTrue(position.x.isFinite && position.y.isFinite && position.z.isFinite)
            }
        }
    }

    /// Longitudinal UVs are in metres so a material sets its own texel density.
    func testUVsAreInMetresAndGrowAlongTheTrack() throws {
        let road = try aalborg().road
        let apron = TerrainGeneration.apron(road.geometry)
        let longitudinal = apron.uv0.map(\.x)
        XCTAssertGreaterThan(longitudinal.max() ?? 0, 1000, "expected kilometres of track length in UVs")
        XCTAssertEqual(apron.uv0.map(\.y).max() ?? 0, 100, accuracy: 1, "lateral UV should reach the border margin")
    }
}
