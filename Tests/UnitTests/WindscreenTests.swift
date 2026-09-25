// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
import TORCSRender

/// Rain on the glass displaces the picture behind each drop; it does not
/// tint it, and it is not there unless asked for.
final class WindscreenTests: XCTestCase {
    func testDropsDisplaceWithoutTintingAndRepeat() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        var settings = RenderSettings()
        settings.bloom = false; settings.motionBlur = false; settings.upscaling = false
        settings.ambientOcclusion = .off; settings.contactShadows = false; settings.heatHaze = false
        let renderer = try ForwardRenderer(settings: settings)
        let scene = try SceneResources(device: renderer.device, scene: MotionBlurTests().fixtureScene())
        let camera = RenderCamera(eye: SIMD3(6, -5, 2), target: SIMD3(0, 0, 0.5))
        let width = 256, height = 160
        func frame() throws -> [UInt8] {
            try renderer.render(scene: scene, camera: camera, lighting: SunLighting(), width: width, height: height)
        }
        func mean(_ image: [UInt8]) -> Double {
            var total = 0
            for i in stride(from: 0, to: image.count, by: 4) { total += Int(image[i]) + Int(image[i + 1]) + Int(image[i + 2]) }
            return Double(total) / Double(image.count / 4 * 3)
        }
        let dry = try frame()
        renderer.windscreenRain = 1
        let wet = try frame()
        XCTAssertEqual(wet, try frame(), "cold renders must repeat exactly")
        XCTAssertNotEqual(wet, dry)
        var changed = 0
        for i in stride(from: 0, to: dry.count, by: 4) where abs(Int(dry[i]) - Int(wet[i])) > 4 { changed += 1 }
        let fraction = Double(changed) / Double(width * height)
        // Over the fixture's flat sky a drop refracts one colour into itself
        // and changes nothing; the count is of pixels where it bent an edge.
        XCTAssertGreaterThan(fraction, 0.005, "drops should bend some of the frame: \(fraction)")
        XCTAssertLessThan(fraction, 0.6, "and not all of it: \(fraction)")
        XCTAssertEqual(mean(wet), mean(dry), accuracy: mean(dry) * 0.05, "refraction moves light, it does not add much")
        renderer.windscreenRain = 0
        XCTAssertEqual(try frame(), dry, "gone when asked to be")
    }
}
