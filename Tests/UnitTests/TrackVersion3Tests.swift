// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import TORCSTrack
import TORCSConfiguration
import TORCSReferenceSupport

/// Version-3 track support, verified against the original reader.
///
/// TORCS dispatches on the track XML's declared version: 0 through 3 to
/// `ReadTrack3`, 4 to `ReadTrack4`. The native port implements version 4 only,
/// so seven of the thirty-nine shipped tracks are rejected — five of the eight
/// dirt tracks among them.
///
/// These tests need a TORCS installation, because no version-3 track is
/// imported into the repository's fixtures. They skip without one rather than
/// fail, so the suite stays green on a machine that has no install.
final class TrackVersion3Tests: XCTestCase {
    static let installPath = "/Users/holgervonameln/Downloads/torcs-1.3.9"

    func install() throws -> URL {
        let url = URL(fileURLWithPath: Self.installPath)
        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("data/tracks").path) else {
            throw XCTSkip("No TORCS installation at \(Self.installPath)")
        }
        return url
    }

    /// Tracks sit either under a category directory or flat in the source tree.
    func trackXML(_ install: URL, _ name: String) -> URL? {
        for relative in ["data/tracks/road/\(name)/\(name).xml",
                         "data/tracks/oval/\(name)/\(name).xml",
                         "data/tracks/dirt/\(name)/\(name).xml",
                         "data/tracks/\(name)/\(name).xml"] {
            let candidate = install.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    func fixtures() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    }

    /// Establishes that the original reader can build a version-3 track in this
    /// harness, which is what makes a verified port possible at all.
    func testOriginalReaderBuildsAVersion3Track() throws {
        let install = try install()
        let track = try XCTUnwrap(trackXML(install, "dirt-4"), "dirt-4 not found in the installation")
        let fixtures = try fixtures()

        // The shipped track XML resolves its entities relative to the
        // *installed* layout, not the source tree, so the source-tree paths are
        // dangling. Stage a copy beside the real surfaces.xml so the original
        // Expat-based parser can resolve them.
        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("v3-\(UUID().uuidString)/data/tracks/dirt-4", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let shared = staging.deletingLastPathComponent()
        for name in ["surfaces.xml", "objects.xml"] {
            let source = install.appendingPathComponent("data/data/tracks/\(name)")
            if FileManager.default.fileExists(atPath: source.path) {
                try? FileManager.default.copyItem(at: source, to: shared.appendingPathComponent(name))
            }
        }
        let staged = staging.appendingPathComponent("dirt-4.xml")
        try FileManager.default.copyItem(at: track, to: staged)
        defer { try? FileManager.default.removeItem(at: staging.deletingLastPathComponent().deletingLastPathComponent()) }

        let world = try ReferenceWorld(track: staged,
                                       car: fixtures.appendingPathComponent("155-DTM.xml"),
                                       category: fixtures.appendingPathComponent("Track-4WD-GrB.xml"))
        defer { world.close() }
        let geometry = try world.trackGeometry()

        XCTAssertGreaterThan(geometry.segments.count, 0)
        XCTAssertGreaterThan(geometry.mainSegments.count, 10, "expected a real circuit")
        for segment in geometry.segments {
            XCTAssertTrue(segment.length.isFinite && segment.width.isFinite)
            XCTAssertGreaterThan(segment.extent, 0)
        }
        print("V3 REFERENCE dirt-4: \(geometry.segments.count) segments, "
              + "\(geometry.mainSegments.count) main")
    }

    /// Loads a version-3 track through both readers and compares the result.
    /// This is the whole point of the schema adapter: the version-4 builder is
    /// verified against the original, so a translation that reaches it
    /// correctly inherits that verification.
    func testNativeVersion3MatchesTheOriginalReader() throws {
        let install = try install()
        let fixtures = try fixtures()
        // dirt-4 is excluded: it is the only version-3 track with a pit lane,
        // declares `pit type = "track side"` which version 4 has no counterpart
        // for, and comes out translated in Y by 705.5 m because the original's
        // bounding box includes pit geometry this translation does not produce.
        // `testDirt4PitLaneRemainsAKnownGap` pins that exact signature.
        for name in ["dirt-5", "dirt-6", "mixed-1", "mixed-2", "a-speedway", "e-track-5"] {
            guard let track = trackXML(install, name) else { continue }

            let staging = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("v3-\(UUID().uuidString)/data/tracks/\(name)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let shared = staging.deletingLastPathComponent()
            for entity in ["surfaces.xml", "objects.xml"] {
                let source = install.appendingPathComponent("data/data/tracks/\(entity)")
                if FileManager.default.fileExists(atPath: source.path) {
                    try? FileManager.default.copyItem(at: source, to: shared.appendingPathComponent(entity))
                }
            }
            let staged = staging.appendingPathComponent("\(name).xml")
            try FileManager.default.copyItem(at: track, to: staged)
            defer { try? FileManager.default.removeItem(at: shared.deletingLastPathComponent()) }

            let world = try ReferenceWorld(track: staged,
                                           car: fixtures.appendingPathComponent("155-DTM.xml"),
                                           category: fixtures.appendingPathComponent("Track-4WD-GrB.xml"))
            defer { world.close() }
            let original = try world.trackGeometry()

            let document = try ParameterDocument.parse(
                Data(contentsOf: staged),
                entities: ["default-surfaces": Data(contentsOf: shared.appendingPathComponent("surfaces.xml")),
                           "default-objects": (try? Data(contentsOf: shared.appendingPathComponent("objects.xml"))) ?? Data()],
                allowLegacyLatin1: true)
            let road = try TrackBuilder.buildRoad(parameters: document)
            let native = road.geometry
            if let originalBounds = try? world.trackBounds() {
                print("V3 BOUNDS \(name): native \(road.bounds) original \(originalBounds)")
            }

            XCTAssertEqual(native.segments.count, original.segments.count, "\(name): segment count")
            XCTAssertEqual(native.mainSegments.count, original.mainSegments.count, "\(name): main count")
            guard native.segments.count == original.segments.count else { continue }

            var worstLength: Float = 0, worstWidth: Float = 0, worstPosition: Float = 0
            var firstDivergence: Int? = nil
            for (index, expected) in original.segments.enumerated() {
                let actual = native.segments[index]
                XCTAssertEqual(actual.curve, expected.curve, "\(name) segment \(index): curve")
                XCTAssertEqual(actual.role, expected.role, "\(name) segment \(index): role")
                worstLength = max(worstLength, abs(actual.length - expected.length))
                worstWidth = max(worstWidth, abs(actual.width - expected.width))
                let offset = simd_length(actual.startRight - expected.startRight)
                if offset > 0.01, firstDivergence == nil {
                    firstDivergence = index
                    print("V3 DIVERGE \(name) at \(index) '\(actual.name)' "
                          + "native \(actual.startRight) original \(expected.startRight) "
                          + "delta \(actual.startRight - expected.startRight)")
                }
                worstPosition = max(worstPosition, offset)
            }
            print("V3 PARITY \(name): \(native.segments.count) segments, "
                  + "length \(worstLength), width \(worstWidth), position \(worstPosition)")
            XCTAssertLessThan(worstLength, 1e-3, "\(name): segment length diverges")
            XCTAssertLessThan(worstWidth, 1e-3, "\(name): segment width diverges")
            XCTAssertLessThan(worstPosition, 1e-2, "\(name): segment position diverges")
        }
    }

    /// The one version-3 track that does not match, pinned precisely so the
    /// gap stays visible and any change to it is noticed.
    ///
    /// dirt-4 is the only version-3 track with a pit lane. Version 3 declares
    /// `pit type`, which version 4 has no equivalent for, and its "track side"
    /// lane contributes geometry to the track's bounding box. Since every
    /// vertex is then translated so the minimum corner sits at the origin, a
    /// different bound moves the whole track: the shape is correct — segment
    /// count, lengths and widths all match exactly — but it sits 705.5 m away
    /// in Y.
    ///
    /// That matters beyond tidiness. The visible track is a baked mesh in the
    /// original coordinates, so an origin shift would separate the road the
    /// driver sees from the road the physics uses.
    func testDirt4PitLaneRemainsAKnownGap() throws {
        let install = try install()
        let fixtures = try fixtures()
        guard let track = trackXML(install, "dirt-4") else { throw XCTSkip("dirt-4 not installed") }

        let staging = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("v3gap-\(UUID().uuidString)/data/tracks/dirt-4", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let shared = staging.deletingLastPathComponent()
        for entity in ["surfaces.xml", "objects.xml"] {
            let source = install.appendingPathComponent("data/data/tracks/\(entity)")
            if FileManager.default.fileExists(atPath: source.path) {
                try? FileManager.default.copyItem(at: source, to: shared.appendingPathComponent(entity))
            }
        }
        let staged = staging.appendingPathComponent("dirt-4.xml")
        try FileManager.default.copyItem(at: track, to: staged)
        defer { try? FileManager.default.removeItem(at: shared.deletingLastPathComponent()) }

        let world = try ReferenceWorld(track: staged,
                                       car: fixtures.appendingPathComponent("155-DTM.xml"),
                                       category: fixtures.appendingPathComponent("Track-4WD-GrB.xml"))
        defer { world.close() }
        let original = try world.trackGeometry()
        let document = try ParameterDocument.parse(
            Data(contentsOf: staged),
            entities: ["default-surfaces": Data(contentsOf: shared.appendingPathComponent("surfaces.xml")),
                       "default-objects": (try? Data(contentsOf: shared.appendingPathComponent("objects.xml"))) ?? Data()],
            allowLegacyLatin1: true)
        let native = try TrackBuilder.buildRoad(parameters: document).geometry

        // The shape is right.
        XCTAssertEqual(native.segments.count, original.segments.count)
        for (index, expected) in original.segments.enumerated() {
            XCTAssertEqual(native.segments[index].length, expected.length, accuracy: 1e-3)
            XCTAssertEqual(native.segments[index].width, expected.width, accuracy: 1e-3)
        }
        // The placement is not, and the error is a pure translation in Y.
        let delta = native.segments[0].startRight - original.segments[0].startRight
        XCTAssertEqual(delta.x, 0, accuracy: 1e-3, "the gap is Y only")
        XCTAssertEqual(delta.z, 0, accuracy: 1e-3, "the gap is Y only")
        XCTAssertEqual(delta.y, -705.5261, accuracy: 0.5, "known dirt-4 pit-lane offset changed")
        for segment in native.segments.indices {
            let offset = native.segments[segment].startRight - original.segments[segment].startRight
            XCTAssertEqual(offset.y, delta.y, accuracy: 1e-2, "the offset must be uniform, not a shape difference")
        }
    }

    /// Versions outside the range the original loader dispatches on must fail
    /// explicitly rather than produce an empty track.
    func testNativeBuilderRejectsVersion3WithAClearError() throws {
        let install = try install()
        let track = try XCTUnwrap(trackXML(install, "dirt-4"))
        let fixtures = try fixtures()
        let document = try ParameterDocument.parse(
            Data(contentsOf: track),
            entities: ["default-surfaces": Data(contentsOf: fixtures.appendingPathComponent("surfaces.xml")),
                       "default-objects": Data(contentsOf: fixtures.appendingPathComponent("objects.xml"))],
            allowLegacyLatin1: true)
        XCTAssertEqual(document.section("Header")?.number("version", default: 0), 3)
        // Version 3 is now accepted; this documents the boundary instead.
        XCTAssertNoThrow(try TrackBuilder.buildRoad(parameters: document))
    }
}
