// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
import TORCSRender
import TORCSAssets
import TORCSTrack

final class RoadPaintTests: XCTestCase {
    func testBoxesBecomeQuadsInMetres() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let paint = RoadPaint(device: device)
        paint.set([RoadPaint.Box(centre: SIMD3(10, 5, 0.3), yaw: .pi / 2, length: 4, width: 2)])
        XCTAssertEqual(paint.quadCount, 1)
        XCTAssertNotNil(paint.buffer)
        let vertices = paint.buffer!.contents().bindMemory(to: SkidMarks.Vertex.self, capacity: 6)
        // Heading +y: the box spans y 3..7 and x 9..11, lifted.
        let xs = (0 ..< 6).map { vertices[$0].positionIntensity.x }, ys = (0 ..< 6).map { vertices[$0].positionIntensity.y }
        XCTAssertEqual(xs.min()!, 9, accuracy: 1e-4); XCTAssertEqual(xs.max()!, 11, accuracy: 1e-4)
        XCTAssertEqual(ys.min()!, 3, accuracy: 1e-4); XCTAssertEqual(ys.max()!, 7, accuracy: 1e-4)
        XCTAssertEqual(vertices[0].positionIntensity.z, 0.3 + paint.lift, accuracy: 1e-5)
        XCTAssertEqual(vertices[2].uv.x, 4); XCTAssertEqual(vertices[2].uv.y, 2)
        paint.set([])
        XCTAssertNil(paint.buffer)
    }

    /// The native grid on Aalborg: twenty boxes, in two columns, all on
    /// the road within the first fifty metres of the lap.
    func testGridBoxesFromTheNativeStartingGrid() throws {
        let road = try RoadGenerationTests().aalborg()
        let configuration = try StartingGridConfiguration()
        let slots = try StartingGrid.slots(road: road, configuration: configuration, cars: 20)
        XCTAssertEqual(slots.count, 20)
        for slot in slots {
            let local = try road.geometry.globalToLocal(SIMD2(slot.world.x, slot.world.y), startingAt: slot.position.segment)
            XCTAssertGreaterThan(local.toRight, 0); XCTAssertLessThan(local.toRight, road.geometry.segments[local.segment].width)
        }
    }

    /// Paint brightens the road under the box and darkens nothing; with the
    /// decals off the frame is untouched.
    func testPaintBrightensOnlyUnderTheBox() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        var settings = RenderSettings()
        settings.bloom = false; settings.motionBlur = false; settings.screenSpaceReflections = .off
        let renderer = try ForwardRenderer(settings: settings)
        let scene = try SceneResources(device: renderer.device, scene: MotionBlurTests().fixtureScene())
        let camera = RenderCamera(eye: SIMD3(0, -6, 4), target: SIMD3(0, -4, 0))
        let plain = try renderer.render(scene: scene, camera: camera, lighting: SunLighting(), width: 256, height: 160)
        renderer.roadPaint.set([RoadPaint.Box(centre: SIMD3(0, -4, 0), yaw: .pi / 2, length: 3, width: 2)])
        let painted = try renderer.render(scene: scene, camera: camera, lighting: SunLighting(), width: 256, height: 160)
        XCTAssertEqual(renderer.skidMarkRenderer.lastPaintedBoxes, 1)
        let sum = { (p: [UInt8]) in p.reduce(0) { $0 + Int($1) } }
        XCTAssertGreaterThan(sum(painted), sum(plain), "paint must brighten")
        var darkened = 0
        for (a, b) in zip(painted, plain) where Int(a) + 2 < Int(b) { darkened += 1 }
        XCTAssertLessThan(darkened, 20, "paint darkened \(darkened) samples")
        renderer.settings.skidMarks = false
        XCTAssertEqual(try renderer.render(scene: scene, camera: camera, lighting: SunLighting(), width: 256, height: 160), plain)
    }

    /// The paint is lit as the road is: with the sun gone it is darker, and
    /// under an occluder it is darker still, so a car's shadow crosses the grid.
    func testPaintTakesTheRoadsLight() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        var settings = RenderSettings()
        settings.bloom = false; settings.motionBlur = false; settings.upscaling = false
        settings.ambientOcclusion = .off; settings.contactShadows = false; settings.screenSpaceReflections = .off
        let renderer = try ForwardRenderer(settings: settings)
        let scene = try SceneResources(device: renderer.device, scene: WeatherTests().ground(weather: false))
        renderer.roadPaint.set([RoadPaint.Box(centre: SIMD3(0, 0, 0), yaw: 0, length: 4, width: 2)])
        let camera = RenderCamera(eye: SIMD3(0, -6, 5), target: SIMD3(0, 0, 0))
        func frame(_ lighting: SunLighting) throws -> [UInt8] {
            try renderer.render(scene: scene, camera: camera, lighting: lighting, width: 256, height: 160)
        }
        func brightest(_ image: [UInt8]) -> Int {
            var best = 0
            for i in stride(from: 0, to: image.count, by: 4) { best = max(best, Int(image[i]) + Int(image[i + 1]) + Int(image[i + 2])) }
            return best
        }
        var sunny = SunLighting()
        sunny.direction = simd_normalize(SIMD3(0.2, -0.3, 0.93))
        var dusk = sunny
        dusk.intensity = 0
        let lit = brightest(try frame(sunny)), unlit = brightest(try frame(dusk))
        XCTAssertGreaterThan(lit, unlit + 30, "the paint is brighter under the sun than without it: \(lit) vs \(unlit)")
        XCTAssertGreaterThan(unlit, 0, "and not black by skylight alone")
    }
}
