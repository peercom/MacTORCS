// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
import TORCSRender
import TORCSAssets

final class RainTests: XCTestCase {
    func device() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        return device
    }

    /// Drops spawn in the box above the source, fall at their terminal
    /// speed, and the count settles at rate × life.
    func testRainSpawnsAboveAndFalls() throws {
        let system = try ParticleSystem(device: device())
        let source = ParticleSystem.Source(kind: .rain, position: SIMD3(0, 0, 2), velocity: .zero, intensity: 1)
        system.sources = [source]; system.advance(by: 1 / 60)
        let first = system.packed
        XCTAssertGreaterThan(first.count, 10)
        XCTAssertTrue(first.allSatisfy { $0.attributes.z == 3 })
        XCTAssertTrue(first.allSatisfy { $0.positionSize.z > 2 }, "rain starts above the source")
        let p = system.parameters
        XCTAssertTrue(first.allSatisfy { abs($0.positionSize.x) <= p.rainSpread && abs($0.positionSize.y) <= p.rainSpread })
        let before = first.map(\.positionSize.z).reduce(0, +) / Float(first.count)
        for _ in 0 ..< 30 { system.advance(by: 1 / 60) }
        let after = system.packed.map(\.positionSize.z).reduce(0, +) / Float(max(system.count, 1))
        XCTAssertLessThan(after, before - 3, "half a second of fall at \(p.rainFall) m/s")
        for _ in 0 ..< 120 { system.sources = [source]; system.advance(by: 1 / 60) }
        XCTAssertEqual(Double(system.count), Double(p.rainRate * p.rainLife), accuracy: Double(p.rainRate) * 0.1)
    }

    /// Streaks in the frame, and the dimmed lighting of a rainy sky.
    func testRainDrawsStreaksAndDimsTheSun() throws {
        _ = try device()
        var settings = RenderSettings()
        settings.bloom = false; settings.motionBlur = false; settings.screenSpaceReflections = .off
        let renderer = try ForwardRenderer(settings: settings)
        let scene = try SceneResources(device: renderer.device, scene: MotionBlurTests().fixtureScene())
        let camera = RenderCamera(eye: SIMD3(6, -5, 2), target: SIMD3(0, 0, 0.5))
        let dry = try renderer.render(scene: scene, camera: camera, lighting: SunLighting(), width: 256, height: 160)
        for _ in 0 ..< 40 {
            renderer.particles.sources = [.init(kind: .rain, position: camera.eye, velocity: .zero, intensity: 1)]
            renderer.particles.advance(by: 1 / 60)
        }
        let raining = try renderer.render(scene: scene, camera: camera, lighting: SunLighting(), width: 256, height: 160)
        XCTAssertGreaterThan(renderer.particleRenderer.lastDrawnCount, 100)
        XCTAssertNotEqual(raining, dry)
        var base = SunLighting()
        base.intensity = 100_000; base.ambient = SIMD3(repeating: 5)
        let dim = ModernDrivingLightingProbe.lighting(base, rain: 1)
        XCTAssertEqual(dim.intensity, 30_000, accuracy: 1)
        XCTAssertEqual(dim.ambient.x, 5.5, accuracy: 1e-3)
        XCTAssertEqual(dim.exposureEV100, base.exposureEV100 - 1.2, accuracy: 1e-4)
    }
}

/// The app's rain dimming, mirrored here so the rule is pinned without the
/// app target: the sun to thirty percent, the skylight kept.
enum ModernDrivingLightingProbe {
    static func lighting(_ base: SunLighting, rain: Float) -> SunLighting {
        var lighting = base
        let r = min(max(rain, 0), 1)
        lighting.intensity *= 1 - 0.7 * r
        lighting.ambient *= 1 + 0.1 * r
        lighting.exposureEV100 -= 1.2 * r
        return lighting
    }
}
