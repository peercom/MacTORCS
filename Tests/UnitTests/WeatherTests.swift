// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
import TORCSRender
import TORCSAssets

final class WeatherTests: XCTestCase {
    func device() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        return device
    }

    func testFrameUniformsCarryWetness() {
        let frame = FrameUniforms(viewProjection: matrix_identity_float4x4, view: matrix_identity_float4x4,
                                  cameraPosition: SIMD3(1, 2, 3), sunDirection: SIMD3(0, 0, 1),
                                  sunIlluminance: SIMD3(repeating: 1), exposureScale: 1,
                                  ambientIrradiance: .zero, wetness: 0.4)
        XCTAssertEqual(frame.wetness, 0.4)
        XCTAssertEqual(frame.cameraPosition.x, 1)
    }

    /// A flat ground square, optionally flagged as receiving weather.
    func ground(weather: Bool) throws -> RenderScene {
        let h: Float = 20
        let mesh = try RenderMesh.build(
            positions: [SIMD3(-h, -h, 0), SIMD3(h, -h, 0), SIMD3(h, h, 0), SIMD3(-h, h, 0)],
            normals: Array(repeating: SIMD3(0, 0, 1), count: 4),
            uv0: [SIMD2(0, 0), SIMD2(h, 0), SIMD2(h, h), SIMD2(0, h)],
            indices: [0, 1, 2, 0, 2, 3], uvInMetres: true)
        let state = ACRenderState(material: [0, 0, 0, 1, 0, 0, 0, 1, 0.2, 0.2, 0.2, 1, 0], texture: nil, flags: 8, alphaClamp: 0)
        let batch = RenderBatch(mesh: mesh, baseTexture: nil, blends: false, isDeferred: false,
                                alphaTestThreshold: nil, culls: false, isDriver: false, sourceMaterial: state,
                                material: ResolvedMaterial(baseColour: SIMD4(0.5, 0.5, 0.5, 1), roughness: 0.9, metallic: 0),
                                receivesWeather: weather)
        return RenderScene(batches: [batch], minimum: SIMD3(-h, -h, 0), maximum: SIMD3(h, h, 0))
    }

    func render(_ renderer: ForwardRenderer, _ scene: RenderScene, wetness: Float) throws -> [UInt8] {
        renderer.wetness = wetness
        let resources = try SceneResources(device: renderer.device, scene: scene)
        return try renderer.render(scene: resources, camera: RenderCamera(eye: SIMD3(0, -8, 6), target: SIMD3(0, 2, 0)),
                                   lighting: SunLighting(), width: 256, height: 160)
    }

    /// Wet ground is darker on average and shows puddles: the pixel spread
    /// grows because mirror-smooth patches pick up the sky. Ground that does
    /// not receive weather is untouched by the wetness.
    func testWetGroundDarkensAndPuddlesWhereFlagged() throws {
        _ = try device()
        var settings = RenderSettings()
        settings.bloom = false; settings.motionBlur = false; settings.screenSpaceReflections = .off
        let renderer = try ForwardRenderer(settings: settings)
        let dry = try render(renderer, ground(weather: true), wetness: 0)
        let wet = try render(renderer, ground(weather: true), wetness: 1)
        XCTAssertNotEqual(dry, wet)
        // Ground rows only: the bottom half of the frame.
        func rows(_ p: [UInt8]) -> [Double] {
            stride(from: 80 * 256 * 4, to: p.count, by: 4).map { Double(p[$0]) + Double(p[$0 + 1]) + Double(p[$0 + 2]) }
        }
        let a = rows(dry), b = rows(wet)
        let meanA = a.reduce(0, +) / Double(a.count), meanB = b.reduce(0, +) / Double(b.count)
        XCTAssertLessThan(meanB, meanA * 0.9, "wet ground must read darker: \(meanA) -> \(meanB)")
        func spread(_ v: [Double], _ mean: Double) -> Double { (v.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(v.count)).squareRoot() }
        XCTAssertGreaterThan(spread(b, meanB), spread(a, meanA) * 1.5, "puddles must break up the flat ground")

        let plainDry = try render(renderer, ground(weather: false), wetness: 0)
        let plainWet = try render(renderer, ground(weather: false), wetness: 1)
        XCTAssertEqual(plainDry, plainWet, "a batch that does not receive weather must not change")
    }

    /// Spray is flung and falls: it lives well under a second.
    func testSprayIsShortLivedAndFalls() throws {
        let system = try ParticleSystem(device: device())
        for _ in 0 ..< 6 {
            system.sources = [.init(kind: .spray, position: SIMD3(0, 0, 0.1), velocity: SIMD3(30, 0, 0), intensity: 1)]
            system.advance(by: 1 / 60)
        }
        XCTAssertGreaterThan(system.count, 3)
        XCTAssertTrue(system.packed.allSatisfy { $0.attributes.z == 2 })
        for _ in 0 ..< 60 { system.advance(by: 1 / 60) }
        XCTAssertEqual(system.count, 0, "spray must be gone within a second")
    }
}
