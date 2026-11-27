// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
import TORCSRender
import TORCSAssets

/// A swaying tree's shadow must sway with it.
final class WindShadowTests: XCTestCase {
    /// Read the actual shadow map, independently of exposure, shading and the
    /// camera. Both static cards and wind-deformed cards must respect holes.
    func testCutoutShadowCoverageForStaticAndSwayingCards() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let shadow = try ShadowRenderer(device: device, library: ShaderLibrary(device: device).library,
                                        resolution: 256, cascadeCount: 1)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let mesh = try RenderMesh.build(
            positions: [SIMD3(-5, -5, 0), SIMD3(5, -5, 0), SIMD3(5, 5, 0), SIMD3(-5, 5, 0)],
            normals: Array(repeating: SIMD3(0, 0, 1), count: 4),
            uv0: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)],
            blend: Array(repeating: SIMD4(255, 184, 0, 255), count: 4),
            indices: [0, 1, 2, 0, 2, 3])
        let cascades = ShadowCascades(camera: RenderCamera(eye: SIMD3(0, -12, 10), target: .zero),
                                     sunDirection: SIMD3(0, 0, 1), aspect: 1, count: 1,
                                     resolution: 256, shadowDistance: 30).cascades
        func coverage(sways: Bool, textureAlpha: UInt8?, halfCutout: Bool = false,
                      baseAlpha: Float = 1) throws -> Int {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                width: 16, height: 16, mipmapped: false)
            descriptor.storageMode = .shared
            let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
            var pixels = Array(repeating: UInt8(255), count: 16 * 16 * 4)
            for y in 0 ..< 16 { for x in 0 ..< 16 {
                pixels[(y * 16 + x) * 4 + 3] = halfCutout && x < 8 ? 0 : (textureAlpha ?? 255)
            } }
            pixels.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0,
                                withBytes: $0.baseAddress!, bytesPerRow: 64)
            }
            let batch = RenderBatch(mesh: mesh, baseTexture: textureAlpha == nil ? nil : "leaves",
                blends: false, isDeferred: false, alphaTestThreshold: 0.5, culls: false, isDriver: false,
                sourceMaterial: state(), material: ResolvedMaterial(baseColour: SIMD4(1, 1, 1, baseAlpha),
                roughness: 0.9, metallic: 0), swaysInWind: sways)
            let scene = RenderScene(batches: [batch], minimum: SIMD3(-5, -5, 0), maximum: SIMD3(5, 5, 0))
            let resources = try SceneResources(device: device, scene: scene, resolveTexture: { _, _ in texture })
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            shadow.encode(into: commands, resources: [resources], instances: [RenderInstance(resource: 0)],
                          cascades: cascades, animationTime: 2.5)
            let buffer = try XCTUnwrap(device.makeBuffer(length: 256 * 256 * 2, options: .storageModeShared))
            let blit = try XCTUnwrap(commands.makeBlitCommandEncoder())
            blit.copy(from: shadow.map, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                      sourceSize: MTLSize(width: 256, height: 256, depth: 1), to: buffer,
                      destinationOffset: 0, destinationBytesPerRow: 512, destinationBytesPerImage: 256 * 512)
            blit.endEncoding()
            commands.commit(); commands.waitUntilCompleted()
            XCTAssertNil(commands.error)
            let depths = buffer.contents().bindMemory(to: UInt16.self, capacity: 256 * 256)
            return (0 ..< 256 * 256).filter { depths[$0] < UInt16.max }.count
        }
        for sways in [false, true] {
            let solid = try coverage(sways: sways, textureAlpha: 255)
            XCTAssertGreaterThan(solid, 100)
            XCTAssertEqual(try coverage(sways: sways, textureAlpha: 0), 0, "transparent texels must not cast")
            let cutout = try coverage(sways: sways, textureAlpha: 255, halfCutout: true)
            XCTAssertGreaterThan(cutout, solid / 3)
            XCTAssertLessThan(cutout, solid * 2 / 3, "holes must survive in the depth map")
            XCTAssertEqual(try coverage(sways: sways, textureAlpha: 255, baseAlpha: 0.25), 0)
            XCTAssertEqual(try coverage(sways: sways, textureAlpha: nil), solid, "untextured cutouts use base alpha")
        }
    }

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
