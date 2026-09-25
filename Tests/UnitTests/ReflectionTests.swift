// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
import TORCSRender
import TORCSAssets

final class ReflectionTests: XCTestCase {
    func fixtureScene() throws -> RenderScene {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Artwork/155-DTM/155-DTM.acc")
        return try RenderScene(ACScene.parse(Data(contentsOf: url), car: true), car: true)
    }

    func makeRenderer(_ configure: (inout RenderSettings) -> Void = { _ in }) throws -> ForwardRenderer {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        var settings = RenderSettings()
        settings.bloom = false
        settings.depthPrepass = true
        configure(&settings)
        return try ForwardRenderer(settings: settings)
    }

    // Low and to the side, so paint reflects the ground and glass the sky.
    let camera = RenderCamera(eye: SIMD3(4, -3.5, 1.0), target: SIMD3(0, 0, 0.5))
    let width = 256, height = 160

    func render(_ renderer: ForwardRenderer) throws -> [UInt8] {
        let scene = try SceneResources(device: renderer.device, scene: fixtureScene())
        return try renderer.render(scene: scene, camera: camera, lighting: SunLighting(), width: width, height: height)
    }

    func mean(_ pixels: [UInt8]) -> Double { Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count) }

    /// The reflection surface must carry what the forward pass wrote for the
    /// sharp lobe. The first version received the motion vectors instead: with
    /// upscaling off the pass bound no velocity attachment while every
    /// pipeline declared one, and the later attachment shifted down a slot.
    /// Roughness outside [0, 1] or a weight below zero is that bug.
    func testReflectionSurfaceHoldsRoughnessAndWeightNotVelocity() throws {
        let renderer = try makeRenderer { $0.screenSpaceReflections = .full }
        _ = try render(renderer)
        let targets = try renderer.targets(outputWidth: width, outputHeight: height)
        XCTAssertNil(targets.upscaled, "upscaling is off")
        XCTAssertTrue(targets.reflections)
        let raw = try renderer.readback(targets.reflectionSurface, bytesPerPixel: 8)
        var covered = 0, coated = 0, badRange = 0, maxWeight: Float = 0
        raw.withUnsafeBytes { bytes in
            let halves = bytes.bindMemory(to: UInt16.self)
            for i in 0 ..< width * height {
                let roughness = Float(Float16(bitPattern: halves[i * 4 + 2]))
                let weight = Float(Float16(bitPattern: halves[i * 4 + 3]))
                if roughness < 0 || roughness > 1 || weight < 0 || weight > 1.5 { badRange += 1 }
                if weight > 0.001 { covered += 1 }
                if roughness > 0 && roughness < 0.1 { coated += 1 }
                maxWeight = max(maxWeight, weight)
            }
        }
        XCTAssertEqual(badRange, 0, "\(badRange) texels outside the encodable range")
        XCTAssertGreaterThan(covered, width * height / 10, "paint and ground should have a specular weight")
        XCTAssertGreaterThan(coated, 100, "the car's clear coat is roughness 0.05")
        XCTAssertGreaterThan(maxWeight, 0.02)
    }

    func testReflectionsChangeTheFrameWithoutBreakingIt() throws {
        let off = try render(try makeRenderer { $0.screenSpaceReflections = .off })
        let on = try render(try makeRenderer { $0.screenSpaceReflections = .full })
        XCTAssertNotEqual(off, on, "reflections had no effect")
        // A broken composite — NaN, a wrong sign, a wrong weight — moves the
        // mean far more than a reflection swap does.
        let ratio = mean(on) / mean(off)
        XCTAssertGreaterThan(ratio, 0.9, "frame darkened by \((1 - ratio) * 100)%")
        XCTAssertLessThan(ratio, 1.1, "frame brightened by \((ratio - 1) * 100)%")
    }

    /// The sky is not a surface and must never be composited onto.
    func testSkyIsUntouched() throws {
        let off = try render(try makeRenderer { $0.screenSpaceReflections = .off })
        let on = try render(try makeRenderer { $0.screenSpaceReflections = .full })
        for row in 0 ..< 6 {
            for x in 0 ..< width {
                let i = (row * width + x) * 4
                for c in 0 ..< 3 {
                    XCTAssertEqual(Int(on[i + c]), Int(off[i + c]), accuracy: 1, "sky pixel (\(x),\(row))")
                }
            }
        }
    }

    func testRepeatedOffscreenRendersAreIdentical() throws {
        let renderer = try makeRenderer { $0.screenSpaceReflections = .full }
        XCTAssertEqual(try render(renderer), try render(renderer))
    }

    func testQuarterResolutionTargetIsAQuarter() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        var settings = RenderSettings()
        settings.bloom = false; settings.motionBlur = false; settings.screenSpaceReflections = .quarter
        let renderer = try ForwardRenderer(settings: settings)
        let scene = try SceneResources(device: renderer.device, scene: MotionBlurTests().fixtureScene())
        _ = try renderer.render(scene: scene, camera: RenderCamera(eye: SIMD3(6, -5, 2), target: SIMD3(0, 0, 0.5)),
                                lighting: SunLighting(), width: 256, height: 160)
        let result = try XCTUnwrap(renderer.reflections.result)
        XCTAssertEqual(result.width, 64); XCTAssertEqual(result.height, 40)
        XCTAssertEqual(RenderSettings.Quality.quarter.divisor, 4)
        XCTAssertTrue(RenderSettings.Quality.quarter < .half && .half < .full && .off < .quarter)
    }

    func testHalfResolutionTargetIsHalf() throws {
        let renderer = try makeRenderer { $0.screenSpaceReflections = .half }
        _ = try render(renderer)
        let traced = try XCTUnwrap(renderer.reflections.result)
        XCTAssertEqual(traced.width, width / 2)
        XCTAssertEqual(traced.height, height / 2)
        renderer.settings.screenSpaceReflections = .off
        _ = try render(renderer)
        XCTAssertNil(renderer.reflections.result)
    }
}

extension ReflectionTests {
    /// Offscreen renders start cold, so the temporal reuse never runs in a
    /// single verification render and repeat renders stay identical; when
    /// a sequence is rendered, the history takes hold and the frames converge.
    func testTemporalReuseAccumulatesOverASequenceAndStaysColdOtherwise() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        var settings = RenderSettings()
        settings.bloom = false; settings.motionBlur = false; settings.upscaling = false
        settings.screenSpaceReflections = .full
        settings.reflectionTemporal = true
        let renderer = try ForwardRenderer(settings: settings)
        let scene = try SceneResources(device: renderer.device, scene: MotionBlurTests().fixtureScene())
        let camera = RenderCamera(eye: SIMD3(6, -5, 2), target: SIMD3(0, 0, 0.5))
        func frame() throws -> [UInt8] {
            try renderer.render(scene: scene, camera: camera, lighting: SunLighting(), width: 256, height: 160)
        }
        let a = try frame(), b = try frame()
        XCTAssertEqual(a, b, "cold renders must repeat exactly")
        XCTAssertFalse(renderer.reflections.lastFrameReusedHistory, "a cold render reuses nothing")

        renderer.resetsHistoryPerRender = false
        let first = try frame()
        XCTAssertTrue(renderer.reflections.historyValid, "the first frame of a sequence leaves a history")
        let second = try frame(), third = try frame()
        XCTAssertTrue(renderer.reflections.lastFrameReusedHistory)
        func distance(_ x: [UInt8], _ y: [UInt8]) -> Int { zip(x, y).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) } }
        // The noise phase rotates, so consecutive frames differ; with the
        // history blended in they differ less as the sequence goes on.
        XCTAssertNotEqual(first, second)
        XCTAssertLessThan(distance(second, third), distance(first, second))
    }
}
