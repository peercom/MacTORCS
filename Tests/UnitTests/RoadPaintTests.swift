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
}
