// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
import TORCSRender
import TORCSAssets

final class SunGlareTests: XCTestCase {
    func fixtureScene() throws -> RenderScene { try MotionBlurTests().fixtureScene() }

    func makeRenderer(glare: Bool) throws -> ForwardRenderer {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        var settings = RenderSettings()
        settings.bloom = false; settings.motionBlur = false; settings.screenSpaceReflections = .off
        settings.sunGlare = glare
        return try ForwardRenderer(settings: settings)
    }

    /// Camera at the origin looking along +y; the sun low ahead or behind.
    func render(_ renderer: ForwardRenderer, sunAhead: Bool, scene: RenderScene? = nil) throws -> [UInt8] {
        let resources = try SceneResources(device: renderer.device, scene: scene ?? fixtureScene())
        let sun = simd_normalize(SIMD3<Float>(0, sunAhead ? 1 : -1, 0.3))
        let camera = RenderCamera(eye: SIMD3(0, -12, 2), target: SIMD3(0, 0, 3))
        return try renderer.render(scene: resources, camera: camera, lighting: SunLighting(direction: sun), width: 256, height: 160)
    }

    func testGlareAppearsOnlyWithTheSunInFrame() throws {
        let with = try makeRenderer(glare: true), without = try makeRenderer(glare: false)
        // Sun behind the camera: nothing to draw, and the images are identical.
        XCTAssertEqual(try render(with, sunAhead: false), try render(without, sunAhead: false))
        XCTAssertNil(with.sunScreenPosition)
        // Sun ahead and in the sky: the glare adds light.
        let a = try render(with, sunAhead: true), b = try render(without, sunAhead: true)
        let sun = try XCTUnwrap(with.sunScreenPosition)
        XCTAssertGreaterThan(sun.x, 0.3); XCTAssertLessThan(sun.x, 0.7); XCTAssertGreaterThan(sun.y, 0); XCTAssertLessThan(sun.y, 0.5)
        XCTAssertNotEqual(a, b)
        let sum = { (p: [UInt8]) in p.reduce(0) { $0 + Int($1) } }
        XCTAssertGreaterThan(sum(a), sum(b), "glare only adds light")
        for (x, y) in zip(a, b) where Int(x) + 1 < Int(y) { XCTFail("glare darkened a pixel"); break }
    }

    /// A wall across the sun hides it: no glare through geometry.
    func testGlareIsOccludedByGeometry() throws {
        let with = try makeRenderer(glare: true), without = try makeRenderer(glare: false)
        let wall = try RenderMesh.build(
            positions: [SIMD3(-30, 20, 0), SIMD3(30, 20, 0), SIMD3(30, 20, 40), SIMD3(-30, 20, 40)],
            normals: Array(repeating: SIMD3(0, -1, 0), count: 4),
            uv0: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)], indices: [0, 1, 2, 0, 2, 3])
        let state = ACRenderState(material: [0, 0, 0, 1, 0, 0, 0, 1, 0.2, 0.2, 0.2, 1, 0], texture: nil, flags: 8, alphaClamp: 0)
        let batch = RenderBatch(mesh: wall, baseTexture: nil, blends: false, isDeferred: false, alphaTestThreshold: nil,
                                culls: false, isDriver: false, sourceMaterial: state,
                                material: ResolvedMaterial(baseColour: SIMD4(0.3, 0.3, 0.3, 1), roughness: 0.9, metallic: 0))
        let scene = try fixtureScene().adding([batch])
        XCTAssertEqual(try render(with, sunAhead: true, scene: scene), try render(without, sunAhead: true, scene: scene))
        XCTAssertNotNil(with.sunScreenPosition, "the sun is in frame, just hidden")
    }
}
