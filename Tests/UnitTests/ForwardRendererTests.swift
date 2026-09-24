// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
import TORCSAssets
import TORCSRender

final class ForwardRendererTests: XCTestCase {
    func fixtureScene(_ relative: String, car: Bool) throws -> RenderScene {
        let root = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let url = root.appendingPathComponent("Artwork").appendingPathComponent(relative)
        return try RenderScene(ACScene.parse(Data(contentsOf: url), car: car))
    }

    func makeRenderer() throws -> ForwardRenderer {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        return try ForwardRenderer()
    }

    func meanLuminance(_ pixels: [UInt8]) -> Double {
        var total = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]), g = Double(pixels[i + 1]), b = Double(pixels[i + 2])
            total += 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        return total / Double(pixels.count / 4)
    }

    /// The classic path guarded run-to-run pixel identity closely, and
    /// RASTER_STABILITY.md documents a real M2 bug it caught. The temporal
    /// passes are not in yet, so identity must hold exactly here; once
    /// upscaling lands this becomes identity from a cold history at a fixed
    /// jitter index.
    func testRepeatedRendersAreIdentical() throws {
        let renderer = try makeRenderer()
        let scene = try SceneResources(device: renderer.device, scene: fixtureScene("155-DTM/155-DTM.acc", car: true))
        let camera = RenderCamera(eye: SIMD3(6, -5, 2), target: SIMD3(0, 0, 0.5))
        let lighting = SunLighting()

        let first = try renderer.render(scene: scene, camera: camera, lighting: lighting, width: 256, height: 160)
        let second = try renderer.render(scene: scene, camera: camera, lighting: lighting, width: 256, height: 160)
        XCTAssertEqual(first, second, "two identical renders produced different pixels")
        XCTAssertFalse(first.isEmpty)
    }

    func testSunAngleChangesTheImage() throws {
        let renderer = try makeRenderer()
        let scene = try SceneResources(device: renderer.device, scene: fixtureScene("155-DTM/155-DTM.acc", car: true))
        let camera = RenderCamera(eye: SIMD3(6, -5, 2), target: SIMD3(0, 0, 0.5))

        let noon = try renderer.render(scene: scene, camera: camera,
                                       lighting: SunLighting(direction: SIMD3(0.1, 0.1, 0.99)),
                                       width: 256, height: 160)
        let dusk = try renderer.render(scene: scene, camera: camera,
                                       lighting: SunLighting(direction: SIMD3(0.95, 0.1, 0.05)),
                                       width: 256, height: 160)
        XCTAssertNotEqual(noon, dusk, "sun direction had no effect on the frame")
        // A low sun reaches the eye through far more atmosphere.
        XCTAssertLessThan(meanLuminance(dusk), meanLuminance(noon), "dusk should be darker than noon")
    }

    /// Guards the failure this pipeline is most prone to: a frame that renders
    /// entirely to one value because a uniform, table or transform is wrong.
    func testRenderedFrameHasRealTonalRange() throws {
        let renderer = try makeRenderer()
        let scene = try SceneResources(device: renderer.device, scene: fixtureScene("155-DTM/155-DTM.acc", car: true))
        let camera = RenderCamera(eye: SIMD3(6, -5, 2), target: SIMD3(0, 0, 0.5))
        let pixels = try renderer.render(scene: scene, camera: camera, lighting: SunLighting(),
                                         width: 256, height: 160)

        var darkest = 255, brightest = 0
        var histogram = [Int](repeating: 0, count: 16)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[i]), g = Double(pixels[i + 1]), b = Double(pixels[i + 2])
            let luma = Int(0.2126 * r + 0.7152 * g + 0.0722 * b)
            darkest = min(darkest, luma); brightest = max(brightest, luma)
            histogram[min(15, luma / 16)] += 1
        }
        XCTAssertLessThan(darkest, 90, "no dark values: the frame is washed out")
        XCTAssertGreaterThan(brightest, 120, "no bright values: the frame is underexposed")
        let occupied = histogram.filter { $0 > pixels.count / 4 / 500 }.count
        XCTAssertGreaterThanOrEqual(occupied, 4, "tonal range collapsed into \(occupied) buckets")
    }

    /// Sky irradiance must never be negative: SH ringing can produce it, and a
    /// negative ambient subtracts light from shadowed surfaces.
    func testSkyIrradianceStaysNonNegativeAcrossSunAngles() throws {
        let renderer = try makeRenderer()
        let scene = try SceneResources(device: renderer.device, scene: fixtureScene("155-DTM/155-DTM.acc", car: true))
        let camera = RenderCamera(eye: SIMD3(6, -5, 2), target: SIMD3(0, 0, 0.5))
        for elevation in stride(from: Float(-0.2), through: 1.0, by: 0.2) {
            let direction = simd_normalize(SIMD3<Float>(sqrt(max(0, 1 - elevation * elevation)), 0, elevation))
            let pixels = try renderer.render(scene: scene, camera: camera,
                                             lighting: SunLighting(direction: direction),
                                             width: 128, height: 96)
            // Negative irradiance would clip to zero, so the observable symptom
            // is a frame that has gone entirely black.
            XCTAssertGreaterThan(meanLuminance(pixels), 0.5, "frame collapsed at sun elevation \(elevation)")
        }
    }

    func testDriverCanBeExcludedForCockpitViews() throws {
        let renderer = try makeRenderer()
        let scene = try SceneResources(device: renderer.device, scene: fixtureScene("155-DTM/155-DTM.acc", car: true))
        let camera = RenderCamera(eye: SIMD3(6, -5, 2), target: SIMD3(0, 0, 0.5))
        _ = try renderer.render(scene: scene, camera: camera, lighting: SunLighting(),
                                width: 128, height: 96, includeDriver: true)
        let withDriver = renderer.lastDrawCount
        _ = try renderer.render(scene: scene, camera: camera, lighting: SunLighting(),
                                width: 128, height: 96, includeDriver: false)
        XCTAssertLessThan(renderer.lastDrawCount, withDriver, "excluding the driver drew the same batches")
    }
}
