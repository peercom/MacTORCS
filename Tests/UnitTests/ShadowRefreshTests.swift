// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
import TORCSRender
import TORCSAssets

final class ShadowRefreshTests: XCTestCase {
    func testCadenceRefreshesNearEveryFrameAndFarOnesStaggered() {
        // Interval 3: slice 0 always, slice 1 every other frame, 2 and 3 every
        // third, offset so no frame carries them all.
        var perFrame: [[Int]] = []
        for frame in 0 ..< 6 {
            perFrame.append((0 ..< 4).filter { ShadowRenderer.refreshes(slice: $0, frame: frame, interval: 3) })
        }
        XCTAssertTrue(perFrame.allSatisfy { $0.contains(0) })
        XCTAssertEqual(perFrame.filter { $0.contains(1) }.count, 3)
        XCTAssertEqual(perFrame.filter { $0.contains(2) }.count, 2)
        XCTAssertEqual(perFrame.filter { $0.contains(3) }.count, 2)
        XCTAssertFalse(perFrame.contains { $0.count == 4 }, "no frame refreshes every slice")
        // Interval 1 is every slice every frame.
        XCTAssertTrue((0 ..< 6).allSatisfy { f in (0 ..< 4).allSatisfy { ShadowRenderer.refreshes(slice: $0, frame: f, interval: 1) } })
    }

    /// Through the renderer: a cold frame renders every slice; the next
    /// frames render fewer, and the stale slices are sampled with the
    /// matrices they were rendered with. Offscreen verification renders stay
    /// cold and identical.
    func testStaleSlicesKeepTheirMatricesAndColdRendersRepeat() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        var settings = RenderSettings()
        settings.bloom = false; settings.motionBlur = false; settings.screenSpaceReflections = .off
        settings.shadowCascades = 4; settings.staticShadowRefreshInterval = 3
        let renderer = try ForwardRenderer(settings: settings)
        let scene = try SceneResources(device: renderer.device, scene: MotionBlurTests().fixtureScene())
        func frame(_ eye: SIMD3<Float>) throws -> [UInt8] {
            try renderer.render(scene: scene, camera: RenderCamera(eye: eye, target: SIMD3(0, 0, 0.5)),
                                lighting: SunLighting(), width: 192, height: 120)
        }
        let a = try frame(SIMD3(6, -5, 2)), b = try frame(SIMD3(6, -5, 2))
        XCTAssertEqual(a, b, "cold renders must repeat")
        XCTAssertEqual(renderer.shadows.lastRefreshedSlices, [0, 1, 2, 3])

        // A sequence: the reset that a verification render makes at its
        // start is now ours to make, once, so the first frame is cold.
        renderer.resetsHistoryPerRender = false
        renderer.resetHistory()
        _ = try frame(SIMD3(6, -5, 2))
        let cold = renderer.shadows.renderedCascades
        XCTAssertEqual(renderer.shadows.lastRefreshedSlices.count, 4)
        _ = try frame(SIMD3(5, -6, 2))
        let second = renderer.shadows.lastRefreshedSlices
        XCTAssertLessThan(second.count, 4)
        XCTAssertTrue(second.contains(0))
        let after = renderer.shadows.renderedCascades
        for slice in 0 ..< 4 where !second.contains(slice) {
            XCTAssertEqual(after[slice], cold[slice], "stale slice \(slice) must keep its matrix")
        }
        for slice in second { XCTAssertNotEqual(after[slice], cold[slice], "refreshed slice \(slice) must follow the camera") }
        renderer.resetHistory()
        _ = try frame(SIMD3(5, -6, 2))
        XCTAssertEqual(renderer.shadows.lastRefreshedSlices, [0, 1, 2, 3], "a history reset refreshes everything")
    }

    func testControllerIgnoresTheWarmup() {
        var controller = DynamicResolutionController(targetGPUTime: 0.010, initialScale: 1.0, warmupFrames: 50)
        for _ in 0 ..< 50 { XCTAssertFalse(controller.record(gpuTime: 0.030)) }
        XCTAssertEqual(controller.scale, 1.0, "nothing may happen during the warm-up")
        var stepped = false
        for _ in 0 ..< 60 { if controller.record(gpuTime: 0.030) { stepped = true } }
        XCTAssertTrue(stepped, "after the warm-up an over-budget run steps down")
    }
}
