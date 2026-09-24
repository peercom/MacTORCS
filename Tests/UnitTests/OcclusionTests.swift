// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
import TORCSRender
import TORCSAssets

final class OcclusionTests: XCTestCase {
    func fixtureScene(_ name: String, car: Bool) throws -> RenderScene {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/Artwork/\(name)")
        return try RenderScene(ACScene.parse(Data(contentsOf: url), car: car))
    }

    func makeRenderer(_ configure: (inout RenderSettings) -> Void = { _ in }) throws -> ForwardRenderer {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        var settings = RenderSettings()
        settings.bloom = false
        // Every renderer here runs the prepass, so an "off" baseline differs
        // from "on" only by the occlusion itself and not by the depth test —
        // the prepass path tests for equality where the plain path tests for
        // greater, and the two disagree exactly where surfaces z-fight.
        settings.depthPrepass = true
        configure(&settings)
        return try ForwardRenderer(settings: settings)
    }

    /// Low camera close to the car, so wheel arches and the underside — where
    /// occlusion is strongest — cover a useful fraction of the frame.
    let camera = RenderCamera(eye: SIMD3(3.5, -3, 0.9), target: SIMD3(0, 0, 0.4))

    func render(_ renderer: ForwardRenderer, lighting: SunLighting = SunLighting(),
                width: Int = 320, height: Int = 200) throws -> [UInt8] {
        let scene = try SceneResources(device: renderer.device, scene: fixtureScene("155-DTM/155-DTM.acc", car: true))
        return try renderer.render(scene: scene, camera: camera, lighting: lighting, width: width, height: height)
    }

    func mean(_ pixels: [UInt8]) -> Double {
        Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count)
    }

    /// Occlusion only ever removes light. No pixel may brighten, and the frame
    /// as a whole must darken by a small but real amount — a large drop would
    /// mean the radius or the normal reconstruction is wrong and the whole car
    /// is being treated as a cave.
    func testAmbientOcclusionDarkensWithoutBrightening() throws {
        let off = try render(try makeRenderer { $0.ambientOcclusion = .off })
        let on = try render(try makeRenderer { $0.ambientOcclusion = .full })
        var brighter = 0
        var examples: [String] = []
        for i in stride(from: 0, to: off.count, by: 4) {
            for channel in 0 ..< 3 where Int(on[i + channel]) > Int(off[i + channel]) + 2 {
                brighter += 1
                if examples.count < 8 {
                    let pixel = i / 4
                    examples.append("(\(pixel % 320),\(pixel / 320)) c\(channel) \(off[i + channel])->\(on[i + channel])")
                }
            }
        }
        XCTAssertEqual(brighter, 0, "\(brighter) channel samples brightened with occlusion on: \(examples)")
        // Most of this frame is open ground and sky, where there is nothing
        // to occlude; the car's cavities are a small fraction of the pixels.
        let drop = 1 - mean(on) / mean(off)
        XCTAssertGreaterThan(drop, 0.002, "occlusion had no measurable effect")
        XCTAssertLessThan(drop, 0.15, "occlusion darkened the frame by \(drop * 100)%, far too much")
    }

    /// Contact shadows sit where the cascades already put shadow, so their
    /// effect is small — but it must exist, and it must not lighten anything.
    func testContactShadowsOnlyRemoveSunlight() throws {
        // Sun low and from the side, so the underside gap is lit at grazing
        // incidence and the contact ray has something to find.
        let lighting = SunLighting(direction: simd_normalize(SIMD3(0.8, 0.3, 0.35)))
        let off = try render(try makeRenderer { $0.contactShadows = false }, lighting: lighting)
        let on = try render(try makeRenderer { $0.contactShadows = true }, lighting: lighting)
        var brighter = 0
        for i in stride(from: 0, to: off.count, by: 4) {
            for channel in 0 ..< 3 where Int(on[i + channel]) > Int(off[i + channel]) + 2 { brighter += 1 }
        }
        XCTAssertEqual(brighter, 0)
        XCTAssertNotEqual(off, on, "contact shadows changed nothing")
        XCTAssertLessThan(1 - mean(on) / mean(off), 0.05)
    }

    /// The sky is not a surface. It must come out of the pass untouched, or
    /// the horizon acquires a dark band where the ground meets it.
    func testSkyIsNeverOccluded() throws {
        let off = try render(try makeRenderer { $0.ambientOcclusion = .off; $0.contactShadows = false })
        let on = try render(try makeRenderer { $0.ambientOcclusion = .full; $0.contactShadows = true })
        // Top rows are sky at this camera.
        let width = 320
        for row in 0 ..< 8 {
            for x in 0 ..< width {
                let i = (row * width + x) * 4
                for c in 0 ..< 3 {
                    XCTAssertEqual(Int(on[i + c]), Int(off[i + c]), accuracy: 1, "sky pixel (\(x),\(row)) changed")
                }
            }
        }
    }

    /// Both effects need the depth prepass; asking for them must turn it on
    /// rather than silently producing nothing.
    func testOcclusionForcesTheDepthPrepass() throws {
        let renderer = try makeRenderer { $0.ambientOcclusion = .full; $0.depthPrepass = false }
        _ = try render(renderer)
        XCTAssertNotNil(renderer.occlusion.result)
        XCTAssertTrue(renderer.lastFrameUsedDepthPrepass)
        renderer.settings.ambientOcclusion = .off
        renderer.settings.contactShadows = false
        _ = try render(renderer)
        XCTAssertNil(renderer.occlusion.result)
        XCTAssertFalse(renderer.lastFrameUsedDepthPrepass, "prepass should follow the setting again")
    }

    /// Noise rotates per frame, which is right for a temporal history and
    /// wrong for a golden image. The offscreen verification path therefore
    /// starts every render from a cold phase, and two renders are identical.
    func testRepeatedOffscreenRendersAreIdentical() throws {
        let renderer = try makeRenderer { $0.ambientOcclusion = .full; $0.contactShadows = true }
        let first = try render(renderer)
        let second = try render(renderer)
        XCTAssertEqual(first, second)
        // The phase did advance during the frame; the next render resets it.
        XCTAssertEqual(renderer.occlusion.noisePhase, 1)
    }
}
