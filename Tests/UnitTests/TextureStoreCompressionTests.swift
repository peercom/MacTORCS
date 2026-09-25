// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import TORCSAssets
@testable import TORCSRender

/// The original artwork goes up block-compressed too: BC1, or BC3 for a
/// cutout, with the encode kept in the block cache by the source's hash.
final class TextureStoreCompressionTests: XCTestCase {
    func testOriginalArtUploadsCompressedThroughTheBlockCache() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/Artwork")
        let atlas = fixtures.appendingPathComponent("aalborg/allborg-trees_n.rgb")
        let opaque = fixtures.appendingPathComponent("aalborg/tarmac-wall-1-g2.rgb")
        guard FileManager.default.fileExists(atPath: atlas.path), FileManager.default.fileExists(atPath: opaque.path) else {
            throw XCTSkip("fixture textures not present")
        }
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("torcs-blocks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let was = TextureStore.compressesUploads
        defer { TextureStore.compressesUploads = was }

        TextureStore.compressesUploads = true
        let first = TextureStore(device: device, roots: [], blockCache: cacheDirectory)
        let cutout = try XCTUnwrap(first.albedo(at: atlas, key: "tree", isCutout: true))
        let wall = try XCTUnwrap(first.albedo(at: opaque, key: "wall", isCutout: false))
        XCTAssertEqual(cutout.pixelFormat, .bc3_rgba_srgb, "a cutout keeps its alpha")
        XCTAssertEqual(wall.pixelFormat, .bc1_rgba_srgb)
        XCTAssertEqual(first.sidecarHits, 0)
        let kept = try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)
        XCTAssertEqual(kept.count, 2, "one encode per source: \(kept)")
        XCTAssertTrue(kept.allSatisfy { $0.hasSuffix(".torcsbc") && $0.count > 64 }, "named by the source hash: \(kept)")

        let second = TextureStore(device: device, roots: [], blockCache: cacheDirectory)
        _ = try XCTUnwrap(second.albedo(at: atlas, key: "tree", isCutout: true))
        _ = try XCTUnwrap(second.albedo(at: opaque, key: "wall", isCutout: false))
        XCTAssertEqual(second.sidecarHits, 2)
        XCTAssertEqual(second.uploadedBytes, first.uploadedBytes)

        // The compiled-texture path keys by the cache's own source hash.
        let data = try Data(contentsOf: opaque)
        let compiled = try TextureCache.decode(try TextureCache.compileSGI(data, filename: "tarmac-wall-1-g2.rgb"))
        let third = TextureStore(device: device, roots: [], blockCache: cacheDirectory)
        let fromCompiled = try XCTUnwrap(third.albedo(compiled: compiled, key: "wall", isCutout: false))
        XCTAssertEqual(fromCompiled.pixelFormat, .bc1_rgba_srgb)
        XCTAssertEqual(third.sidecarHits, 1, "the same source, whichever way it arrives, is one encode")

        TextureStore.compressesUploads = false
        let plain = TextureStore(device: device, roots: [], blockCache: cacheDirectory)
        _ = try XCTUnwrap(plain.albedo(at: opaque, key: "wall", isCutout: false))
        XCTAssertEqual(try XCTUnwrap(plain.albedo(at: atlas, key: "tree", isCutout: true)).pixelFormat, .rgba8Unorm_srgb)
        XCTAssertGreaterThan(plain.uploadedBytes, first.uploadedBytes * 3, "RGBA8 is several times the bytes")
    }
}
