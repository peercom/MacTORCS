// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
import TORCSRender
import TORCSAssets

final class BloomTests: XCTestCase {
    func fixtureScene(_ name: String, car: Bool) throws -> RenderScene {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/Artwork/\(name)")
        return try RenderScene(ACScene.parse(Data(contentsOf: url), car: car))
    }

    func makeRenderer(_ configure: (inout RenderSettings) -> Void = { _ in }) throws -> ForwardRenderer {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        var settings = RenderSettings()
        configure(&settings)
        return try ForwardRenderer(settings: settings)
    }

    let camera = RenderCamera(eye: SIMD3(6, -5, 2), target: SIMD3(0, 0, 0.5))

    func render(_ renderer: ForwardRenderer, width: Int = 256, height: Int = 160) throws -> [UInt8] {
        let scene = try SceneResources(device: renderer.device, scene: fixtureScene("155-DTM/155-DTM.acc", car: true))
        return try renderer.render(scene: scene, camera: camera, lighting: SunLighting(), width: width, height: height)
    }

    func mean(_ pixels: [UInt8]) -> Double {
        Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count)
    }

    /// Bloom is added, never mixed: no pixel may come out darker than it would
    /// have without it. Mixing with a thresholded pyramid would fail this
    /// across the whole frame, which is the bug the design note in
    /// Resolve.metal describes.
    func testBloomNeverDarkensAPixel() throws {
        let off = try render(try makeRenderer { $0.bloom = false })
        let on = try render(try makeRenderer { $0.bloom = true; $0.bloomStrength = 0.3; $0.bloomThreshold = 0.5 })
        XCTAssertEqual(off.count, on.count)
        var darker = 0
        for i in stride(from: 0, to: off.count, by: 4) {
            for channel in 0 ..< 3 where Int(on[i + channel]) < Int(off[i + channel]) - 2 {
                darker += 1  // two levels of tolerance for output dither
            }
        }
        XCTAssertEqual(darker, 0, "\(darker) channel samples got darker with bloom on")
        XCTAssertGreaterThan(mean(on), mean(off), "bloom at threshold 0.5 should have lifted something")
    }

    /// A threshold nothing crosses must produce a frame identical to bloom off,
    /// not merely similar: it pins that the resolve adds exactly zero rather
    /// than sampling an unwritten or stale target.
    func testBloomAboveEveryHighlightIsExactlyInert() throws {
        let off = try render(try makeRenderer { $0.bloom = false })
        let on = try render(try makeRenderer { $0.bloom = true; $0.bloomThreshold = 1_000 })
        XCTAssertEqual(off, on)
    }

    /// The pyramid must not keep halving into meaningless single-digit levels,
    /// nor stop early on a normal frame.
    func testPyramidDepthFollowsResolution() throws {
        let renderer = try makeRenderer { $0.bloom = true }
        _ = try render(renderer, width: 256, height: 160)
        // A quarter of 160 is 40, then 20, 10; the next, 5, is below the 8 px floor.
        XCTAssertEqual(renderer.bloom.levelCount, 3)
        _ = try render(renderer, width: 2560, height: 1664)
        XCTAssertEqual(renderer.bloom.levelCount, 6, "capped at the maximum, not 7")
        _ = try render(renderer, width: 256, height: 160)
        XCTAssertEqual(renderer.bloom.levelCount, 3, "chain must rebuild when the source shrinks")
    }

    /// A source too small to halve twice has no pyramid to composite. The frame
    /// must then match bloom off exactly rather than adding a single blurred
    /// copy of itself.
    func testTinySourceSkipsBloomCleanly() throws {
        let renderer = try makeRenderer { $0.bloom = true; $0.bloomThreshold = 0; $0.bloomStrength = 1 }
        let on = try render(renderer, width: 16, height: 16)
        XCTAssertLessThan(renderer.bloom.levelCount, 2)
        XCTAssertNil(renderer.bloom.result)
        let off = try render(try makeRenderer { $0.bloom = false }, width: 16, height: 16)
        XCTAssertEqual(on, off)
    }

    /// Repeat-render identity, the discipline that found RASTER_STABILITY.md's
    /// bug, must survive the extra passes: every level is fully written before
    /// it is read, so nothing depends on stale contents.
    func testRepeatedRendersWithBloomAreIdentical() throws {
        let renderer = try makeRenderer { $0.bloom = true; $0.bloomThreshold = 0.2; $0.bloomStrength = 0.5 }
        let first = try render(renderer)
        let second = try render(renderer)
        XCTAssertEqual(first, second)
    }

    /// Disabling bloom after it has run must not leave last frame's pyramid
    /// composited in.
    func testTogglingBloomOffDropsThePyramid() throws {
        let renderer = try makeRenderer { $0.bloom = true; $0.bloomThreshold = 0; $0.bloomStrength = 1 }
        let glowing = try render(renderer)
        renderer.settings.bloom = false
        let plain = try render(renderer)
        XCTAssertNil(renderer.bloom.result)
        XCTAssertNotEqual(glowing, plain)
        XCTAssertEqual(plain, try render(try makeRenderer { $0.bloom = false }))
    }
}
