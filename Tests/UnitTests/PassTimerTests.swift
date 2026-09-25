// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
import TORCSRender
import TORCSAssets

final class PassTimerTests: XCTestCase {
    /// Every pass of a frame reports a duration, the durations are
    /// positive, and their sum is of the order of the frame.
    func testEveryPassIsTimedWithinTheFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice(), PassTimer.isSupported(device) else {
            throw XCTSkip("Timestamp sampling unavailable")
        }
        var settings = RenderSettings()
        settings.bloom = true; settings.motionBlur = true; settings.screenSpaceReflections = .half
        settings.ambientOcclusion = .half; settings.contactShadows = true
        let renderer = try ForwardRenderer(settings: settings)
        renderer.passTimer = try PassTimer(device: device)
        let scene = try SceneResources(device: device, scene: MotionBlurTests().fixtureScene())
        // Twice: the first frame's GPU time carries first-use costs that no
        // pass accounts for.
        _ = try renderer.render(scene: scene, camera: RenderCamera(eye: SIMD3(6, -5, 2), target: SIMD3(0, 0, 0.5)),
                                lighting: SunLighting(), width: 512, height: 320)
        // The atmosphere tables are built on the first frame only.
        XCTAssertTrue(renderer.lastPassTimes.contains { $0.name == "Atmosphere tables" && $0.seconds.isFinite })
        _ = try renderer.render(scene: scene, camera: RenderCamera(eye: SIMD3(6, -5, 2), target: SIMD3(0, 0, 0.5)),
                                lighting: SunLighting(), width: 512, height: 320)
        let passes = renderer.lastPassTimes
        let names = passes.map(\.name)
        for expected in ["Shadow cascade 0", "Depth prepass", "Sky and forward opaque",
                         "Reflection trace", "Reflection composite", "Motion blur", "Tonemap resolve"] {
            XCTAssertTrue(names.contains(expected), "no timing for \(expected): \(names)")
        }
        XCTAssertTrue(names.contains { $0.hasPrefix("Bloom") })
        XCTAssertTrue(passes.allSatisfy { $0.seconds.isFinite && $0.seconds >= 0 }, "\(passes)")
        let sum = passes.map(\.seconds).reduce(0, +)
        XCTAssertGreaterThan(sum, 0)
        // Passes can overlap on a tile-based GPU, so the sum may exceed the
        // frame; it cannot exceed it by a lot, and cannot be a small fraction.
        XCTAssertLessThan(sum, renderer.lastGPUTime * 2.5, "sum \(sum) vs frame \(renderer.lastGPUTime)")
        XCTAssertGreaterThan(sum, renderer.lastGPUTime * 0.3, "sum \(sum) vs frame \(renderer.lastGPUTime)")
    }
}
