// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
import TORCSRender
import TORCSAssets

/// A swaying tree's shadow must sway with it.
final class WindShadowTests: XCTestCase {
    func state() -> ACRenderState {
        ACRenderState(material: [0, 0, 0, 1, 0, 0, 0, 1, 0.2, 0.2, 0.2, 1, 0], texture: nil, flags: 8, alphaClamp: 0)
    }

    /// A tall vertical card at x = −6, swaying, out of the camera's view; a
    /// ground square at the origin catching its shadow.
    func scene(treeCastsShadow: Bool) throws -> RenderScene {
        let ground = try RenderMesh.build(
            positions: [SIMD3(-20, -20, 0), SIMD3(20, -20, 0), SIMD3(20, 20, 0), SIMD3(-20, 20, 0)],
            normals: Array(repeating: SIMD3(0, 0, 1), count: 4),
            uv0: [SIMD2(0, 0), SIMD2(20, 0), SIMD2(20, 20), SIMD2(0, 20)], indices: [0, 1, 2, 0, 2, 3], uvInMetres: true)
        // blend.x height 0 at the foot, 255 at the top; blend.y the amplitude.
        let tree = try RenderMesh.build(
            positions: [SIMD3(-6, -1.5, 0), SIMD3(-6, 1.5, 0), SIMD3(-6, 1.5, 7), SIMD3(-6, -1.5, 7)],
            normals: Array(repeating: SIMD3(1, 0, 0), count: 4),
            uv0: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)],
            blend: [SIMD4(0, 255, 0, 0), SIMD4(0, 255, 0, 0), SIMD4(255, 255, 0, 0), SIMD4(255, 255, 0, 0)],
            indices: [0, 1, 2, 0, 2, 3])
        let material = ResolvedMaterial(baseColour: SIMD4(0.6, 0.6, 0.6, 1), roughness: 0.9, metallic: 0)
        let batches = [
            RenderBatch(mesh: ground, baseTexture: nil, blends: false, isDeferred: false, alphaTestThreshold: nil,
                        culls: false, isDriver: false, sourceMaterial: state(), material: material, castsShadow: false),
            RenderBatch(mesh: tree, baseTexture: nil, blends: false, isDeferred: false, alphaTestThreshold: nil,
                        culls: false, isDriver: false, sourceMaterial: state(), material: material,
                        swaysInWind: true, castsShadow: treeCastsShadow)]
        return RenderScene(batches: batches, minimum: SIMD3(-20, -20, 0), maximum: SIMD3(20, 20, 7))
    }

    func render(_ renderer: ForwardRenderer, _ scene: RenderScene, time: Double) throws -> [UInt8] {
        renderer.animationTime = time
        let resources = try SceneResources(device: renderer.device, scene: scene)
        // The sun low in the −x, casting the tree's shadow across the origin.
        let lighting = SunLighting(direction: simd_normalize(SIMD3(-1, 0, 0.35)))
        return try renderer.render(scene: resources, camera: RenderCamera(eye: SIMD3(2, -8, 5), target: SIMD3(3, 0, 0)),
                                   lighting: lighting, width: 256, height: 160)
    }

    func testTreeShadowMovesWithTheWind() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        var settings = RenderSettings()
        settings.bloom = false; settings.motionBlur = false; settings.screenSpaceReflections = .off
        settings.ambientOcclusion = .off; settings.contactShadows = false
        let renderer = try ForwardRenderer(settings: settings)
        let still = try render(renderer, scene(treeCastsShadow: true), time: 0)
        let later = try render(renderer, scene(treeCastsShadow: true), time: 2.5)
        let moved = zip(still, later).filter { $0 != $1 }.count
        XCTAssertGreaterThan(moved, 200, "the shadow did not move: \(moved) pixels changed")
        // Nothing in view but the shadow depends on time.
        let a = try render(renderer, scene(treeCastsShadow: false), time: 0)
        let b = try render(renderer, scene(treeCastsShadow: false), time: 2.5)
        XCTAssertEqual(a, b, "without the tree's shadow the view must not change with time")
        XCTAssertNotEqual(a, still, "the shadow must fall in view")
    }
}
