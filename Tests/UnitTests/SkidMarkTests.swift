// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
import TORCSRender
import TORCSAssets

final class SkidMarkTests: XCTestCase {
    func device() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        return device
    }

    func source(_ x: Float, key: Int = 0, intensity: Float = 1) -> SkidMarks.Source {
        SkidMarks.Source(key: key, position: SIMD3(x, 0, 0), lateral: SIMD3(0, 1, 0), width: 0.3, intensity: intensity)
    }

    /// A strip grows one quad per segment length of travel, not per frame,
    /// and ends when the tyre stops skidding.
    func testStripsGrowWithTravelAndBreakWhenSkiddingStops() throws {
        let marks = try SkidMarks(device: device())
        marks.segmentLength = 0.25
        // Creeping: 5 cm a frame lays a quad every fifth frame.
        for frame in 0 ..< 20 {
            marks.sources = [source(Float(frame) * 0.05)]
            marks.advance()
        }
        XCTAssertEqual(marks.quadCount, 3, "0.95 m of travel at 0.25 m per quad, after the first point")
        // A frame without the source ends the strip; the next skid starts
        // fresh and lays nothing until it has travelled.
        marks.advance()
        marks.sources = [source(5)]; marks.advance()
        XCTAssertEqual(marks.quadCount, 3)
        marks.sources = [source(5.3)]; marks.advance()
        XCTAssertEqual(marks.quadCount, 4)
        // The quad spans the tyre width, lifted off the surface.
        let quad = Array(marks.laid[18 ..< 24])
        XCTAssertEqual(quad[0].positionIntensity.y, -0.15, accuracy: 1e-5)
        XCTAssertEqual(quad[1].positionIntensity.y, 0.15, accuracy: 1e-5)
        XCTAssertEqual(quad[0].positionIntensity.z, marks.lift, accuracy: 1e-5)
        XCTAssertEqual(quad[2].uv.x - quad[0].uv.x, 0.3, accuracy: 1e-4, "metres along the strip")
    }

    /// Two tyres are two strips; the ring overwrites its oldest quads.
    func testPerTyreStripsAndRingWrap() throws {
        let marks = try SkidMarks(device: device(), capacity: 8)
        for frame in 0 ..< 40 {
            marks.sources = [source(Float(frame) * 0.3, key: 0), source(Float(frame) * 0.3, key: 1)]
            marks.advance()
        }
        XCTAssertEqual(marks.quadCount, 8)
        XCTAssertEqual(marks.laid.count, 48)
        // The newest quad is the last laid: frame 39, at x ≈ 11.7.
        let xs = marks.laid.map(\.positionIntensity.x)
        XCTAssertEqual(xs.max()!, 11.7, accuracy: 1e-3)
        XCTAssertGreaterThan(xs.min()!, 10, "the early quads were overwritten")
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

    /// Looking down at the ground beside the car.
    let camera = RenderCamera(eye: SIMD3(0, -6, 4), target: SIMD3(0, -4, 0))

    func render(_ renderer: ForwardRenderer) throws -> [UInt8] {
        let scene = try SceneResources(device: renderer.device, scene: fixtureScene())
        return try renderer.render(scene: scene, camera: camera, lighting: SunLighting(), width: 256, height: 160)
    }

    /// A mark on the ground darkens the pixels under it and nothing else;
    /// one under the car body is hidden by the depth test.
    func testMarkDarkensTheGroundAndHidesUnderTheBody() throws {
        let renderer = try makeRenderer()
        let plain = try render(renderer)
        for frame in 0 ..< 12 {
            renderer.skidMarks.sources = [SkidMarks.Source(key: 0, position: SIMD3(-1.5 + Float(frame) * 0.3, -4, 0),
                                                           lateral: SIMD3(0, 1, 0), width: 0.3, intensity: 1)]
            renderer.skidMarks.advance()
        }
        XCTAssertEqual(renderer.skidMarks.quadCount, 11)
        let marked = try render(renderer)
        XCTAssertEqual(renderer.skidMarkRenderer.lastDrawnQuads, 11)
        let sum = { (p: [UInt8]) in p.reduce(0) { $0 + Int($1) } }
        XCTAssertLessThan(sum(marked), sum(plain), "a mark must darken")
        // Never brighter anywhere: a multiplicative decal only takes light away.
        for (a, b) in zip(marked, plain) where Int(a) > Int(b) + 1 { XCTFail("pixel brightened from \(b) to \(a)"); break }

        // Under the car: the body is between the camera and the mark.
        renderer.skidMarks.reset()
        for frame in 0 ..< 6 {
            renderer.skidMarks.sources = [SkidMarks.Source(key: 0, position: SIMD3(-0.8 + Float(frame) * 0.3, 0.2, 0),
                                                           lateral: SIMD3(0, 1, 0), width: 0.3, intensity: 1)]
            renderer.skidMarks.advance()
        }
        let hidden = try render(renderer)
        XCTAssertEqual(renderer.skidMarkRenderer.lastDrawnQuads, 5)
        let differing = zip(hidden, plain).filter { $0 != $1 }.count
        XCTAssertLessThan(differing, plain.count / 200, "a mark under the body leaked through it")
    }

    func testSettingOffDrawsNothing() throws {
        let renderer = try makeRenderer { $0.skidMarks = false }
        let plain = try render(renderer)
        renderer.skidMarks.sources = [source(-1.5)]; renderer.skidMarks.advance()
        renderer.skidMarks.sources = [source(-1.0)]; renderer.skidMarks.advance()
        XCTAssertEqual(try render(renderer), plain)
        XCTAssertEqual(renderer.skidMarkRenderer.lastDrawnQuads, 0)
    }
}
