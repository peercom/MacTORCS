// SPDX-License-Identifier: GPL-2.0-only
import XCTest
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

    /// The native builder rejects version 3 today. Pinning that keeps the
    /// failure explicit rather than a silently empty track.
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
        XCTAssertThrowsError(try TrackBuilder.buildRoad(parameters: document)) { error in
            XCTAssertTrue("\(error)".contains("version-4"), "unexpected error: \(error)")
        }
    }
}
