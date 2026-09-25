// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
import TORCSRender
import TORCSAssets

final class HeatHazeTests: XCTestCase {
    /// A long ground strip seen down its length: near pixels must be still,
    /// far pixels shimmer with time under a high sun, and nothing moves
    /// with the haze off or a low sun.
    func testFarGroundShimmersNearGroundHolds() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        let state = ACRenderState(material: [0, 0, 0, 1, 0, 0, 0, 1, 0.2, 0.2, 0.2, 1, 0], texture: nil, flags: 8, alphaClamp: 0)
        // A checkered strip so a displaced sample changes the pixel.
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uv: [SIMD2<Float>] = [], indices: [UInt32] = []
        var batches: [RenderBatch] = []
        for tile in 0 ..< 60 {
            let y0 = Float(tile) * 8, y1 = y0 + 8
            positions = [SIMD3(-8, y0, 0), SIMD3(8, y0, 0), SIMD3(8, y1, 0), SIMD3(-8, y1, 0)]
            normals = Array(repeating: SIMD3(0, 0, 1), count: 4)
            uv = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
            indices = [0, 1, 2, 0, 2, 3]
            let mesh = try RenderMesh.build(positions: positions, normals: normals, uv0: uv, indices: indices)
            let shade: Float = tile % 2 == 0 ? 0.15 : 0.7
            batches.append(RenderBatch(mesh: mesh, baseTexture: nil, blends: false, isDeferred: false, alphaTestThreshold: nil,
                                       culls: false, isDriver: false, sourceMaterial: state,
                                       material: ResolvedMaterial(baseColour: SIMD4(shade, shade, shade, 1), roughness: 0.9, metallic: 0)))
        }
        let scene = RenderScene(batches: batches, minimum: SIMD3(-8, 0, 0), maximum: SIMD3(8, 480, 0))
        func settings(haze: Bool) -> RenderSettings {
            var s = RenderSettings()
            s.autoExposure = false   // fixed exposure: the shimmer is measured, not the meter
            s.bloom = false; s.motionBlur = false; s.screenSpaceReflections = .off; s.sunGlare = false
            s.ambientOcclusion = .off; s.contactShadows = false; s.heatHaze = haze
            return s
        }
        let camera = RenderCamera(eye: SIMD3(0, 0, 1.5), target: SIMD3(0, 100, 0.5), verticalFieldOfView: 30 * .pi / 180)
        func render(_ renderer: ForwardRenderer, elevation: Float, time: Double) throws -> [UInt8] {
            renderer.animationTime = time
            let resources = try SceneResources(device: renderer.device, scene: scene)
            let sun = SunLighting(direction: simd_normalize(SIMD3(0.2, 0.3, sin(elevation * .pi / 180) / cos(elevation * .pi / 180) * 0.36)))
            return try renderer.render(scene: resources, camera: camera, lighting: sun, width: 256, height: 160)
        }
        let hazy = try ForwardRenderer(settings: settings(haze: true))
        let a = try render(hazy, elevation: 60, time: 0), b = try render(hazy, elevation: 60, time: 1.7)
        func differing(_ x: [UInt8], _ y: [UInt8], rows: Range<Int>) -> Int {
            var n = 0
            for row in rows { for col in 0 ..< 256 { let i = (row * 256 + col) * 4; if x[i] != y[i] { n += 1 } } }
            return n
        }
        // The far strip sits just under the horizon, the near strip fills the bottom.
        XCTAssertGreaterThan(differing(a, b, rows: 78 ..< 90), 20, "the far road did not shimmer")
        XCTAssertEqual(differing(a, b, rows: 130 ..< 160), 0, "the near road must hold still")
        let still = try ForwardRenderer(settings: settings(haze: false))
        XCTAssertEqual(try render(still, elevation: 60, time: 0), try render(still, elevation: 60, time: 1.7))
        // A low sun heats nothing.
        XCTAssertEqual(try render(hazy, elevation: 10, time: 0), try render(hazy, elevation: 10, time: 1.7))
    }
}
