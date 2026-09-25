// SPDX-License-Identifier: GPL-2.0-only
import Metal
import simd
import XCTest
@testable import TORCSRender

final class DepthOfFieldTests: XCTestCase {
    /// The thin-lens circle: zero at the focus, signed either side, capped,
    /// and in the pixels of the image it is asked about.
    func testCircleOfConfusionFollowsTheThinLens() {
        let lens = DepthOfField(focusDistance: 20, fNumber: 2.8, focalLength: 85, maximumCircle: 12)
        // f² / (N (F − f)) = 7225 / (2.8 × 19915) mm = 0.1296 mm on a 36 mm sensor.
        XCTAssertEqual(lens.circleScale(imageWidth: 1280), 0.1296 / 36 * 1280, accuracy: 0.02)
        XCTAssertEqual(lens.circle(at: 20, imageWidth: 1280), 0, accuracy: 1e-5)
        XCTAssertLessThan(lens.circle(at: 5, imageWidth: 1280), 0, "in front of the focus")
        XCTAssertGreaterThan(lens.circle(at: 100, imageWidth: 1280), 0, "behind it")
        XCTAssertEqual(lens.circle(at: 1e6, imageWidth: 1280), lens.circleScale(imageWidth: 1280), accuracy: 0.01,
                       "infinity has the full circle")
        XCTAssertEqual(lens.circle(at: 0.2, imageWidth: 1280), -12, "capped in front")
        let wide = DepthOfField(focusDistance: 20, fNumber: 1.4, focalLength: 85)
        XCTAssertGreaterThan(wide.circleScale(imageWidth: 1280), lens.circleScale(imageWidth: 1280), "a faster lens is shallower")
        let short = DepthOfField(focusDistance: 20, fNumber: 2.8, focalLength: 35)
        XCTAssertLessThan(short.circleScale(imageWidth: 1280), lens.circleScale(imageWidth: 1280), "a shorter lens is deeper")
        // Focus inside the focal length is nonsense; it caps rather than divides by zero.
        XCTAssertEqual(DepthOfField(focusDistance: 0.01, focalLength: 85).circleScale(imageWidth: 100), 12)
    }

    /// Focused on the fixture the picture is sharp; focused far in front of
    /// it the fixture blurs, which shows as less high-frequency energy.
    func testFocusOnTheSubjectKeepsItSharpAndFocusElsewhereBlursIt() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        var settings = RenderSettings()
        settings.bloom = false; settings.motionBlur = false; settings.upscaling = false
        settings.ambientOcclusion = .off; settings.contactShadows = false; settings.heatHaze = false
        let renderer = try ForwardRenderer(settings: settings)
        let scene = try SceneResources(device: renderer.device, scene: MotionBlurTests().fixtureScene())
        let eye = SIMD3<Float>(6, -5, 2), target = SIMD3<Float>(0, 0, 0.5)
        let camera = RenderCamera(eye: eye, target: target)
        func frame() throws -> [UInt8] {
            try renderer.render(scene: scene, camera: camera, lighting: SunLighting(), width: 256, height: 160)
        }
        func energy(_ image: [UInt8], width: Int = 256) -> Int {
            var total = 0
            for i in stride(from: 4, to: image.count, by: 4) where i % (width * 4) != 0 {
                total += abs(Int(image[i]) - Int(image[i - 4])) + abs(Int(image[i + 1]) - Int(image[i - 3]))
            }
            return total
        }
        let sharp = try frame()
        XCTAssertNil(renderer.depthOfFieldRenderer.result, "no lens, no pass")

        renderer.depthOfField = DepthOfField(focusDistance: simd_distance(eye, target), fNumber: 2.8, focalLength: 85)
        let focused = try frame()
        XCTAssertNotNil(renderer.depthOfFieldRenderer.result)
        renderer.depthOfField = DepthOfField(focusDistance: 0.5, fNumber: 1.4, focalLength: 85, maximumCircle: 12)
        let missed = try frame()
        renderer.depthOfField = nil
        let sharpAgain = try frame()
        XCTAssertEqual(sharp, sharpAgain, "the lens leaves nothing behind when removed")

        let sharpEnergy = energy(sharp), focusedEnergy = energy(focused), missedEnergy = energy(missed)
        XCTAssertLessThan(missedEnergy, sharpEnergy * 3 / 4, "focus far in front of the fixture blurs it: \(missedEnergy) vs \(sharpEnergy)")
        XCTAssertGreaterThan(focusedEnergy, missedEnergy, "focused on it keeps more detail than missing it")
        XCTAssertGreaterThan(focusedEnergy, sharpEnergy * 8 / 10, "focused on it stays close to sharp")

        settings.depthOfField = false
        renderer.settings = settings
        renderer.depthOfField = DepthOfField(focusDistance: 0.5, fNumber: 1.4)
        XCTAssertEqual(try frame(), sharp, "the setting off ignores the lens")
    }

    /// The pass sizes itself to half the source and the resolve composites
    /// only when a blur was produced: a nil lens binds nothing.
    func testTargetsAreHalfTheSourceAndFollowIt() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        var settings = RenderSettings()
        settings.bloom = false; settings.motionBlur = false; settings.upscaling = false
        let renderer = try ForwardRenderer(settings: settings)
        let scene = try SceneResources(device: renderer.device, scene: MotionBlurTests().fixtureScene())
        renderer.depthOfField = DepthOfField(focusDistance: 8)
        _ = try renderer.render(scene: scene, camera: RenderCamera(eye: SIMD3(6, -5, 2), target: SIMD3(0, 0, 0.5)),
                                lighting: SunLighting(), width: 256, height: 160)
        let blurred = try XCTUnwrap(renderer.depthOfFieldRenderer.result)
        XCTAssertEqual(blurred.width, 128); XCTAssertEqual(blurred.height, 80)
        _ = try renderer.render(scene: scene, camera: RenderCamera(eye: SIMD3(6, -5, 2), target: SIMD3(0, 0, 0.5)),
                                lighting: SunLighting(), width: 320, height: 200)
        let resized = try XCTUnwrap(renderer.depthOfFieldRenderer.result)
        XCTAssertEqual(resized.width, 160); XCTAssertEqual(resized.height, 100)
    }
}
