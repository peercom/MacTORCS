// SPDX-License-Identifier: GPL-2.0-only
import Metal
import XCTest
@testable import TORCSRender

/// `submit` returns before the GPU finishes and reports each frame's time on
/// completion, so a harness can keep frames in flight; the synchronous path
/// is unchanged by frames that went through it.
final class PipelinedRenderTests: XCTestCase {
    func testSubmittedFramesCompleteWithTimesAndLeaveTheSynchronousPathAlone() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        var settings = RenderSettings()
        settings.bloom = false; settings.motionBlur = false; settings.upscaling = false
        let renderer = try ForwardRenderer(settings: settings)
        let scene = try SceneResources(device: renderer.device, scene: MotionBlurTests().fixtureScene())
        let camera = RenderCamera(eye: SIMD3(6, -5, 2), target: SIMD3(0, 0, 0.5))
        let reference = try renderer.render(scene: scene, camera: camera, lighting: SunLighting(), width: 256, height: 160)

        let inFlight = DispatchSemaphore(value: ForwardRenderer.maximumFramesInFlight)
        let done = DispatchSemaphore(value: 0)
        final class Times: @unchecked Sendable {
            let lock = NSLock(); var values: [Double] = []
            func add(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
            var all: [Double] { lock.lock(); defer { lock.unlock() }; return values }
        }
        let times = Times()
        let count = 12
        for _ in 0 ..< count {
            inFlight.wait()
            try renderer.submit(resources: [scene], instances: [RenderInstance(resource: 0)],
                                camera: camera, lighting: SunLighting(), width: 256, height: 160) { seconds in
                times.add(seconds)
                inFlight.signal()
                done.signal()
            }
        }
        for _ in 0 ..< count {
            XCTAssertEqual(done.wait(timeout: .now() + 10), .success, "a submitted frame never completed")
        }
        let recorded = times.all
        XCTAssertEqual(recorded.count, count)
        for time in recorded { XCTAssertGreaterThan(time, 0); XCTAssertLessThan(time, 1) }
        XCTAssertGreaterThan(renderer.gpuTime, 0, "the last completion recorded the frame time")

        let after = try renderer.render(scene: scene, camera: camera, lighting: SunLighting(), width: 256, height: 160)
        XCTAssertEqual(after, reference, "a verification render after submitted frames is the cold render")
    }
}
