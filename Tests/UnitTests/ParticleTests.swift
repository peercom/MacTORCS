// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
import TORCSRender
import TORCSAssets

final class ParticleTests: XCTestCase {
    func device() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        return device
    }

    let source = ParticleSystem.Source(kind: .smoke, position: SIMD3(0, 0, 0.1), velocity: SIMD3(10, 0, 0), intensity: 1)

    /// A source emits at its rate, particles age out, and a vanished source
    /// emits nothing more.
    func testEmissionAndRetirement() throws {
        let system = try ParticleSystem(device: device(), capacity: 512)
        for _ in 0 ..< 30 {
            system.sources = [source]
            system.advance(by: 1 / 60)
        }
        // 48/s × 0.5 s, less nothing: nobody has aged out yet.
        XCTAssertEqual(system.count, 24, accuracy: 2)
        XCTAssertLessThanOrEqual(system.count, system.capacity)
        for _ in 0 ..< 240 { system.advance(by: 1 / 60) }
        XCTAssertEqual(system.count, 0, "everything has outlived the longest smoke life")
    }

    /// The capacity is a hard cap, whatever the sources ask for.
    func testCapacityIsRespected() throws {
        let system = try ParticleSystem(device: device(), capacity: 64)
        for _ in 0 ..< 120 {
            system.sources = Array(repeating: source, count: 8)
            system.advance(by: 1 / 30)
        }
        XCTAssertEqual(system.count, 64)
    }

    /// Same seed, same steps, same particles: a diagnostic render repeats.
    func testDeterministicForASeed() throws {
        let a = try ParticleSystem(device: device(), seed: 7), b = try ParticleSystem(device: device(), seed: 7)
        for system in [a, b] {
            for _ in 0 ..< 20 { system.sources = [source]; system.advance(by: 1 / 60) }
        }
        XCTAssertEqual(a.packed, b.packed)
        XCTAssertGreaterThan(a.packed.count, 10)
        // Smoke rises and thins: later particles are smaller and more opaque
        // than the first, which has grown and faded.
        let first = a.packed.first!, last = a.packed.last!
        XCTAssertGreaterThan(first.positionSize.w, last.positionSize.w)
        XCTAssertGreaterThan(first.positionSize.z, last.positionSize.z)
    }

    // MARK: rendering

    func fixtureScene() throws -> RenderScene {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Artwork/155-DTM/155-DTM.acc")
        return try RenderScene(ACScene.parse(Data(contentsOf: url), car: true), car: true)
    }

    func makeRenderer(_ configure: (inout RenderSettings) -> Void = { _ in }) throws -> ForwardRenderer {
        _ = try device()
        var settings = RenderSettings()
        settings.bloom = false
        settings.screenSpaceReflections = .off
        settings.motionBlur = false
        configure(&settings)
        return try ForwardRenderer(settings: settings)
    }

    let camera = RenderCamera(eye: SIMD3(6, -5, 2), target: SIMD3(0, 0, 0.5))

    func render(_ renderer: ForwardRenderer) throws -> [UInt8] {
        let scene = try SceneResources(device: renderer.device, scene: fixtureScene())
        return try renderer.render(scene: scene, camera: camera, lighting: SunLighting(), width: 256, height: 160)
    }

    /// A puff above the car is drawn; one behind the body, on the ray through
    /// it, is not: the manual depth test against the opaque depth works.
    func testPuffIsDrawnWhereVisibleAndHiddenBehindGeometry() throws {
        let renderer = try makeRenderer()
        let plain = try render(renderer)
        XCTAssertEqual(renderer.particleRenderer.lastDrawnCount, 0)

        renderer.particles.place(.smoke, at: SIMD3(0, 0, 1.6), size: 0.5, opacity: 0.9)
        renderer.particles.advance(by: 0)
        let visible = try render(renderer)
        XCTAssertEqual(renderer.particleRenderer.lastDrawnCount, 1)
        XCTAssertNotEqual(visible, plain, "a puff in clear view changed nothing")
        // Only near the puff: the bottom-left corner is car-free and untouched.
        let corner = { (p: [UInt8]) in Array(p[(159 * 256) * 4 ..< (159 * 256 + 40) * 4]) }
        XCTAssertEqual(corner(visible), corner(plain))

        // On the view ray past the car's centre, inside the shadow of the body.
        renderer.particles.reset()
        let direction = simd_normalize(camera.target - camera.eye)
        renderer.particles.place(.smoke, at: camera.eye + direction * 10, size: 0.15, opacity: 0.9)
        renderer.particles.advance(by: 0)
        let hidden = try render(renderer)
        XCTAssertEqual(renderer.particleRenderer.lastDrawnCount, 1, "the draw ran; the depth test rejected it")
        XCTAssertEqual(hidden, plain, "a puff behind the body must not show through it")
    }

    /// The setting removes the pass entirely.
    func testSettingOffDrawsNothing() throws {
        let renderer = try makeRenderer { $0.particles = false }
        let plain = try render(renderer)
        renderer.particles.place(.dust, at: SIMD3(0, 0, 1.6), size: 0.5, opacity: 0.9)
        renderer.particles.advance(by: 0)
        XCTAssertEqual(try render(renderer), plain)
        XCTAssertEqual(renderer.particleRenderer.lastDrawnCount, 0)
    }

    /// Two renders of the same system are identical: nothing in the pass
    /// depends on wall-clock time.
    func testRepeatable() throws {
        let renderer = try makeRenderer()
        for _ in 0 ..< 10 { renderer.particles.sources = [source]; renderer.particles.advance(by: 1 / 60) }
        XCTAssertEqual(try render(renderer), try render(renderer))
    }
}
