// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import TORCSAssets
@testable import TORCSRender

/// The original artwork goes up block-compressed too: BC3 wherever the
/// image has any alpha — a cutout's coverage or a pane of glass that is
/// blended, not tested — and BC1 where it has none; the encode kept in the
/// block cache by the source's hash.
final class TextureStoreCompressionTests: XCTestCase {
    func testOriginalArtUploadsCompressedThroughTheBlockCache() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/Artwork")
        let atlas = fixtures.appendingPathComponent("aalborg/allborg-trees_n.rgb")
        let wallURL = fixtures.appendingPathComponent("aalborg/tarmac-wall-1-g2.rgb")
        guard FileManager.default.fileExists(atPath: atlas.path), FileManager.default.fileExists(atPath: wallURL.path) else {
            throw XCTSkip("fixture textures not present")
        }
        let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("torcs-blocks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let was = TextureStore.compressesUploads
        defer { TextureStore.compressesUploads = was }
        let wallHasAlpha = TextureStore.hasTransparency(try TextureLoading.decode(try Data(contentsOf: wallURL)).rgba8)
        let wallFormat: MTLPixelFormat = wallHasAlpha ? .bc3_rgba_srgb : .bc1_rgba_srgb

        TextureStore.compressesUploads = true
        let first = TextureStore(device: device, roots: [], blockCache: cacheDirectory)
        let cutout = try XCTUnwrap(first.albedo(at: atlas, key: "tree", isCutout: true))
        XCTAssertEqual(cutout.pixelFormat, .bc3_rgba_srgb, "a cutout keeps its alpha")
        let wall = try XCTUnwrap(first.albedo(at: wallURL, key: "wall", isCutout: false))
        XCTAssertEqual(wall.pixelFormat, wallFormat, "the format follows the image")
        XCTAssertEqual(first.sidecarHits, 0, "nothing to serve the first time")
        // Glass: the same kind of image drawn blended rather than tested. It
        // lost its pane to BC1 once; any alpha at all now means BC3.
        let glass = try XCTUnwrap(first.albedo(at: atlas, key: "glass", isCutout: false))
        XCTAssertEqual(glass.pixelFormat, .bc3_rgba_srgb, "an image with alpha is never BC1")
        XCTAssertEqual(first.sidecarHits, 1, "the same source in the same format is served from its sidecar")
        let kept = try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)
        XCTAssertEqual(kept.count, 2, "one encode per source and format: \(kept)")
        XCTAssertTrue(kept.allSatisfy { $0.hasSuffix(".torcsbc") && $0.count > 64 }, "named by the source hash: \(kept)")

        let second = TextureStore(device: device, roots: [], blockCache: cacheDirectory)
        _ = try XCTUnwrap(second.albedo(at: atlas, key: "tree", isCutout: true))
        _ = try XCTUnwrap(second.albedo(at: wallURL, key: "wall", isCutout: false))
        XCTAssertEqual(second.sidecarHits, 2)
        let compressedBytes = second.uploadedBytes

        // The compiled-texture path keys by the cache's own source hash.
        let data = try Data(contentsOf: wallURL)
        let compiled = try TextureCache.decode(try TextureCache.compileSGI(data, filename: "tarmac-wall-1-g2.rgb"))
        let third = TextureStore(device: device, roots: [], blockCache: cacheDirectory)
        let fromCompiled = try XCTUnwrap(third.albedo(compiled: compiled, key: "wall", isCutout: false))
        XCTAssertEqual(fromCompiled.pixelFormat, wallFormat)
        XCTAssertEqual(third.sidecarHits, 1, "the same source, whichever way it arrives, is one encode")

        TextureStore.compressesUploads = false
        let plain = TextureStore(device: device, roots: [], blockCache: cacheDirectory)
        _ = try XCTUnwrap(plain.albedo(at: wallURL, key: "wall", isCutout: false))
        XCTAssertEqual(try XCTUnwrap(plain.albedo(at: atlas, key: "tree", isCutout: true)).pixelFormat, .rgba8Unorm_srgb)
        XCTAssertGreaterThan(plain.uploadedBytes, compressedBytes * 2,
                             "RGBA8 is several times the bytes: \(plain.uploadedBytes) vs \(compressedBytes)")
    }
}
