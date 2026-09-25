// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import Metal
@testable import TORCSRender

final class ViewFrustumTests: XCTestCase {
    /// Looking down +x from the origin with the renderer's own projection.
    private func frustum(aspect: Float = 1.5) -> ViewFrustum {
        let camera = RenderCamera(eye: SIMD3(0, 0, 2), target: SIMD3(10, 0, 2))
        return ViewFrustum(viewProjection: camera.projection(aspect: aspect) * camera.view())
    }

    func testReversedInfiniteProjectionHasNoFarPlane() {
        XCTAssertEqual(frustum().planes.count, 5, "left, right, bottom, top, near")
        for plane in frustum().planes {
            XCTAssertEqual(simd_length(SIMD3(plane.x, plane.y, plane.z)), 1, accuracy: 1e-5)
        }
    }

    func testSpheresAheadAreInsideAndBehindAreOut() {
        let f = frustum()
        XCTAssertTrue(f.mayContain(sphereAt: SIMD3(5, 0, 2), radius: 1))
        XCTAssertTrue(f.mayContain(sphereAt: SIMD3(5000, 0, 2), radius: 1), "no far plane")
        XCTAssertFalse(f.mayContain(sphereAt: SIMD3(-5, 0, 2), radius: 1), "behind the camera")
        XCTAssertFalse(f.mayContain(sphereAt: SIMD3(5, 100, 2), radius: 1), "far off to the side")
        XCTAssertFalse(f.mayContain(sphereAt: SIMD3(5, 0, 200), radius: 1), "far above")
    }

    func testSphereRadiusIsHonoured() {
        let f = frustum()
        // Off to the side but large enough to reach into the view.
        XCTAssertTrue(f.mayContain(sphereAt: SIMD3(5, 100, 2), radius: 200))
        // Behind, but enclosing the camera.
        XCTAssertTrue(f.mayContain(sphereAt: SIMD3(-5, 0, 2), radius: 10))
        // Just outside the side plane: at 5 m ahead the half-width is
        // tan(fov/2) * 5 * aspect; a sphere well past it is out, one straddling it is in.
        XCTAssertFalse(f.mayContain(sphereAt: SIMD3(5, 30, 2), radius: 1))
        XCTAssertTrue(f.mayContain(sphereAt: SIMD3(5, 30, 2), radius: 40))
    }

    func testAgreesWithClipSpaceForPoints() {
        // A zero-radius sphere is inside exactly when its clip coordinates are.
        let camera = RenderCamera(eye: SIMD3(3, -7, 1.5), target: SIMD3(-20, 40, 3))
        let vp = camera.projection(aspect: 1.54) * camera.view()
        let f = ViewFrustum(viewProjection: vp)
        var generator = SystemRandomNumberGenerator()
        var inside = 0
        for _ in 0 ..< 2000 {
            let p = SIMD3(Float.random(in: -300 ... 300, using: &generator),
                          Float.random(in: -300 ... 300, using: &generator),
                          Float.random(in: -50 ... 50, using: &generator))
            let clip = vp * SIMD4(p, 1)
            let expected = clip.w > 0 && abs(clip.x) <= clip.w && abs(clip.y) <= clip.w && clip.z >= 0 && clip.z <= clip.w
            XCTAssertEqual(f.mayContain(sphereAt: p, radius: 0), expected, "\(p)")
            if expected { inside += 1 }
        }
        XCTAssertGreaterThan(inside, 50, "the sample should land some points in view")
    }

    /// Culling changes what is submitted, never what is drawn: a view of the
    /// fixture renders the same bytes with and without it, and a view away
    /// from it submits nothing.
    func testCullingLeavesTheImageUnchangedAndSkipsWhatIsBehind() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        var settings = RenderSettings()
        settings.bloom = false; settings.motionBlur = false; settings.upscaling = false
        let renderer = try ForwardRenderer(settings: settings)
        let scene = try SceneResources(device: renderer.device, scene: MotionBlurTests().fixtureScene())
        let toward = RenderCamera(eye: SIMD3(6, -5, 2), target: SIMD3(0, 0, 0.5))
        let away = RenderCamera(eye: SIMD3(6, -5, 2), target: SIMD3(12, -10, 3.5))
        func frame(_ camera: RenderCamera) throws -> [UInt8] {
            try renderer.render(scene: scene, camera: camera, lighting: SunLighting(), width: 256, height: 160)
        }
        renderer.frustumCulling = false
        let reference = try frame(toward)
        let allDraws = renderer.lastDrawCount
        XCTAssertEqual(renderer.lastCulledCount, 0)
        XCTAssertGreaterThan(allDraws, 0)
        renderer.frustumCulling = true
        let culled = try frame(toward)
        XCTAssertEqual(culled, reference, "culling must not change a pixel")
        XCTAssertEqual(renderer.lastDrawCount, allDraws, "everything in view is still drawn")

        _ = try frame(away)
        XCTAssertGreaterThan(renderer.lastCulledCount, 0, "looking away from the fixture rejects its batches")
        XCTAssertLessThan(renderer.lastDrawCount, allDraws)
        renderer.frustumCulling = false
        _ = try frame(away)
        XCTAssertEqual(renderer.lastDrawCount, allDraws, "without the cull everything is submitted again")
    }
}
