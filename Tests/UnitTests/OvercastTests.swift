// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
import TORCSRender

final class OvercastTests: XCTestCase {
    func testFrameUniformsCarryTheCoverageAndClampIt() {
        let frame = FrameUniforms(viewProjection: matrix_identity_float4x4, view: matrix_identity_float4x4,
                                  cameraPosition: .zero, sunDirection: SIMD3(0, 0, 1),
                                  sunIlluminance: SIMD3(repeating: 1), exposureScale: 1,
                                  ambientIrradiance: .zero, overcast: 0.6)
        XCTAssertEqual(frame.overcast, 0.6)
        XCTAssertEqual(simd_length(SIMD3(frame.sunDirection.x, frame.sunDirection.y, frame.sunDirection.z)), 1, accuracy: 1e-6)
        XCTAssertEqual(FrameUniforms(viewProjection: matrix_identity_float4x4, view: matrix_identity_float4x4,
                                     cameraPosition: .zero, sunDirection: SIMD3(0, 0, 1),
                                     sunIlluminance: .zero, exposureScale: 1, ambientIrradiance: .zero, overcast: 3).overcast, 1)
    }

    /// An overcast day is short of sun, not of light.
    func testOvercastLightingDimsTheSunAndKeepsTheSkylight() {
        let clear = SunLighting()
        let covered = clear.overcast(1)
        XCTAssertEqual(covered.intensity, clear.intensity * 0.2, accuracy: 1e-6)
        XCTAssertGreaterThan(covered.ambient.x, clear.ambient.x)
        XCTAssertLessThan(covered.exposureEV100, clear.exposureEV100, "opened up, as an eye would")
        XCTAssertEqual(clear.overcast(0), clear)
        XCTAssertEqual(clear.overcast(0.5).intensity, clear.intensity * 0.6, accuracy: 1e-6)
    }

    /// With the sky covered, the blue goes grey: the mean colour difference
    /// between the blue and red channels over the sky falls. And the frame
    /// is deterministic, like every verification render.
    func testCloudsGreyTheSkyDeterministically() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        var settings = RenderSettings()
        settings.bloom = false; settings.motionBlur = false; settings.upscaling = false
        settings.ambientOcclusion = .off; settings.contactShadows = false
        let renderer = try ForwardRenderer(settings: settings)
        let scene = try SceneResources(device: renderer.device, scene: MotionBlurTests().fixtureScene())
        // Looking up over the fixture so the top half of the frame is sky.
        let camera = RenderCamera(eye: SIMD3(6, -5, 1), target: SIMD3(0, 0, 4))
        let width = 256, height = 160
        // The same lighting for every coverage: the exposure an overcast
        // day opens up would brighten the blue that remains at half cover
        // and mask what the clouds themselves do.
        func frame(_ coverage: Float, lighting: SunLighting = SunLighting()) throws -> [UInt8] {
            renderer.overcast = coverage
            return try renderer.render(scene: scene, camera: camera, lighting: lighting, width: width, height: height)
        }
        func blueness(_ image: [UInt8]) -> Double {
            var total = 0
            for y in 0 ..< height / 3 {
                for x in 0 ..< width {
                    let i = (y * width + x) * 4
                    total += Int(image[i + 2]) - Int(image[i])
                }
            }
            return Double(total) / Double(width * height / 3)
        }
        let clear = try frame(0), covered = try frame(1), half = try frame(0.5)
        XCTAssertEqual(covered, try frame(1), "cold renders must repeat exactly")
        let lit = try frame(1, lighting: SunLighting().overcast(1))
        XCTAssertEqual(lit, try frame(1, lighting: SunLighting().overcast(1)), "with the overcast lighting too")
        XCTAssertNotEqual(lit, covered)
        XCTAssertNotEqual(clear, covered)
        let clearBlue = blueness(clear), coveredBlue = blueness(covered), halfBlue = blueness(half)
        XCTAssertGreaterThan(clearBlue, 20, "a clear sky is blue: \(clearBlue)")
        XCTAssertLessThan(coveredBlue, clearBlue * 0.5, "an overcast sky is grey: \(coveredBlue) vs \(clearBlue)")
        XCTAssertLessThan(halfBlue, clearBlue, "half cover is between: \(halfBlue)")
        XCTAssertGreaterThan(halfBlue, coveredBlue)
    }
}
