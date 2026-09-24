// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
import TORCSRender
import TORCSAssets

final class MotionBlurTests: XCTestCase {
    func fixtureScene() throws -> RenderScene {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Artwork/155-DTM/155-DTM.acc")
        return try RenderScene(ACScene.parse(Data(contentsOf: url), car: true), car: true)
    }

    func makeRenderer(_ configure: (inout RenderSettings) -> Void = { _ in }) throws -> ForwardRenderer {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        var settings = RenderSettings()
        settings.bloom = false
        settings.screenSpaceReflections = .off
        configure(&settings)
        return try ForwardRenderer(settings: settings)
    }

    let still = RenderCamera(eye: SIMD3(6, -5, 2), target: SIMD3(0, 0, 0.5))
    let moved = RenderCamera(eye: SIMD3(5.7, -5.3, 2), target: SIMD3(0, 0, 0.5))

    func render(_ renderer: ForwardRenderer, _ camera: RenderCamera) throws -> [UInt8] {
        let scene = try SceneResources(device: renderer.device, scene: fixtureScene())
        return try renderer.render(scene: scene, camera: camera, lighting: SunLighting(), width: 256, height: 160)
    }

    /// A still camera has zero velocity everywhere; the blur must be a no-op
    /// and repeat renders identical, or it will smear frames at rest.
    func testStillFramesAreUnblurredAndRepeatable() throws {
        let blurred = try makeRenderer { $0.motionBlur = true }
        let plain = try makeRenderer { $0.motionBlur = false }
        let a = try render(blurred, still), b = try render(blurred, still)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, try render(plain, still), "a still frame must not change with motion blur on")
        XCTAssertNotNil(blurred.motionBlur.result, "the pass ran, even if it changed nothing")
    }

    /// Camera motion between two frames gives every static pixel a velocity,
    /// and the second frame must blur.
    func testCameraMotionBlursTheSecondFrame() throws {
        let blurred = try makeRenderer { $0.motionBlur = true }
        let plain = try makeRenderer { $0.motionBlur = false }
        _ = try render(blurred, still); _ = try render(plain, still)
        let withBlur = try render(blurred, moved), without = try render(plain, moved)
        XCTAssertNotEqual(withBlur, without, "motion produced no blur")
        // Blur redistributes, it does not add or remove light.
        let sum = { (p: [UInt8]) in Double(p.reduce(0) { $0 + Int($1) }) }
        XCTAssertEqual(sum(withBlur) / sum(without), 1, accuracy: 0.03)
    }

    func testTargetsFollowTheSetting() throws {
        let renderer = try makeRenderer { $0.motionBlur = true }
        _ = try render(renderer, still)
        let on = try renderer.targets(outputWidth: 256, outputHeight: 160)
        XCTAssertNotNil(on.velocity, "motion blur needs the velocity stored even without upscaling")
        XCTAssertNotNil(on.postColour)
        renderer.settings.motionBlur = false
        _ = try render(renderer, still)
        let off = try renderer.targets(outputWidth: 256, outputHeight: 160)
        XCTAssertNil(off.velocity)
        XCTAssertNil(off.postColour)
        XCTAssertNil(renderer.motionBlur.result)
    }
}
