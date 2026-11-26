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

    /// A shutter is a time, not a frame: the same motion over a frame that
    /// took three times as long is blurred a third as much, so a slow machine
    /// does not smear more the slower it gets.
    func testBlurExposesForAFixedTimeWhateverTheFrameTook() throws {
        let plain = try makeRenderer { $0.motionBlur = false }
        _ = try render(plain, still)
        let sharp = try render(plain, moved)
        func blurEnergy(interval: Double) throws -> Double {
            let blurred = try makeRenderer { $0.motionBlur = true }
            blurred.presentedFrameInterval = interval
            _ = try render(blurred, still)
            let frame = try render(blurred, moved)
            return Double(zip(frame, sharp).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) })
        }
        let nominal = try blurEnergy(interval: 1.0 / 60.0)
        let slow = try blurEnergy(interval: 3.0 / 60.0)
        let fast = try blurEnergy(interval: 1.0 / 120.0)
        XCTAssertGreaterThan(nominal, 0)
        XCTAssertLessThan(slow, nominal * 0.8, "a frame three times as long blurs less: \(slow) vs \(nominal)")
        XCTAssertEqual(fast, nominal, accuracy: nominal * 0.05, "never more than a frame's worth")
    }

    /// Long streaks are gathered from a half-resolution copy of the scene.
    /// That is a cheaper way to the same picture, not another picture: the
    /// copy exists only while the blur is on, a still frame never reads it,
    /// and a moving frame with it is the moving frame without it to within
    /// the softness of a texel.
    func testLongStreaksComeFromAHalfResolutionCopy() throws {
        let fast = RenderCamera(eye: SIMD3(4.6, -6.2, 2), target: SIMD3(0, 0, 0.5))
        func frames(half: Bool) throws -> (still: [UInt8], moving: [UInt8], renderer: ForwardRenderer) {
            let renderer = try makeRenderer { $0.motionBlur = true }
            renderer.motionBlur.usesHalfResolution = half
            // Short enough streaks at this size that the copy would never
            // be asked for otherwise.
            renderer.motionBlur.halfResolutionStreak = 1 ... 2
            let first = try render(renderer, still)
            return (first, try render(renderer, fast), renderer)
        }
        let with = try frames(half: true), without = try frames(half: false)
        let copy = try XCTUnwrap(with.renderer.motionBlur.halfScene)
        XCTAssertEqual(copy.width, 128); XCTAssertEqual(copy.height, 80)
        XCTAssertNil(without.renderer.motionBlur.halfScene)
        XCTAssertEqual(with.still, without.still, "a still frame has no streaks to take from the copy")
        XCTAssertNotEqual(with.moving, without.moving, "the copy was not used")
        let difference = zip(with.moving, without.moving).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) }
            / Double(with.moving.count)
        XCTAssertLessThan(difference, 3, "the two gathers differ by \(difference) steps of 255 on average")
        // Blur off: no copy is made.
        with.renderer.settings.motionBlur = false
        _ = try render(with.renderer, still)
        XCTAssertNil(with.renderer.motionBlur.halfScene)
    }

    func testTargetsFollowTheSetting() throws {
        let renderer = try makeRenderer { $0.motionBlur = true }
        _ = try render(renderer, still)
        let on = try renderer.targets(outputWidth: 256, outputHeight: 160)
        XCTAssertNotNil(on.velocity, "motion blur needs the velocity stored even without upscaling")
        renderer.settings.motionBlur = false
        _ = try render(renderer, still)
        let off = try renderer.targets(outputWidth: 256, outputHeight: 160)
        XCTAssertNil(off.velocity)
    }
}
