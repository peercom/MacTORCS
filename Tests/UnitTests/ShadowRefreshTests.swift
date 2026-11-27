// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
import TORCSRender
import TORCSAssets

final class ShadowRefreshTests: XCTestCase {
    func testCadenceRefreshesNearEveryFrameAndFarOnesStaggered() {
        // Interval 3: slice 0 always, slice 1 every other frame, 2 and 3 every
        // third, offset so no frame carries them all.
        var perFrame: [[Int]] = []
        for frame in 0 ..< 6 {
            perFrame.append((0 ..< 4).filter { ShadowRenderer.refreshes(slice: $0, frame: frame, interval: 3) })
        }
        XCTAssertTrue(perFrame.allSatisfy { $0.contains(0) })
        XCTAssertEqual(perFrame.filter { $0.contains(1) }.count, 3)
        XCTAssertEqual(perFrame.filter { $0.contains(2) }.count, 2)
        XCTAssertEqual(perFrame.filter { $0.contains(3) }.count, 2)
        XCTAssertFalse(perFrame.contains { $0.count == 4 }, "no frame refreshes every slice")
        // Interval 1 is every slice every frame.
        XCTAssertTrue((0 ..< 6).allSatisfy { f in (0 ..< 4).allSatisfy { ShadowRenderer.refreshes(slice: $0, frame: f, interval: 1) } })
    }

    /// Through the renderer: a cold frame renders every slice; the next
    /// frames render fewer, and the stale slices are sampled with the
    /// matrices they were rendered with. Offscreen verification renders stay
    /// cold and identical.
    func testStaleSlicesKeepTheirMatricesAndColdRendersRepeat() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        var settings = RenderSettings()
        settings.bloom = false; settings.motionBlur = false; settings.screenSpaceReflections = .off
        settings.shadowCascades = 4; settings.staticShadowRefreshInterval = 3
        let renderer = try ForwardRenderer(settings: settings)
        let scene = try SceneResources(device: renderer.device, scene: MotionBlurTests().fixtureScene())
        func frame(_ eye: SIMD3<Float>) throws -> [UInt8] {
            try renderer.render(scene: scene, camera: RenderCamera(eye: eye, target: SIMD3(0, 0, 0.5)),
                                lighting: SunLighting(), width: 192, height: 120)
        }
        let a = try frame(SIMD3(6, -5, 2)), b = try frame(SIMD3(6, -5, 2))
        XCTAssertEqual(a, b, "cold renders must repeat")
        XCTAssertEqual(renderer.shadows.lastRefreshedSlices, [0, 1, 2, 3])

        // A sequence: the reset that a verification render makes at its
        // start is now ours to make, once, so the first frame is cold.
        renderer.resetsHistoryPerRender = false
        renderer.resetHistory()
        _ = try frame(SIMD3(6, -5, 2))
        let cold = renderer.shadows.renderedCascades
        XCTAssertEqual(renderer.shadows.lastRefreshedSlices.count, 4)
        _ = try frame(SIMD3(5, -6, 2))
        let second = renderer.shadows.lastRefreshedSlices
        XCTAssertLessThan(second.count, 4)
        XCTAssertTrue(second.contains(0))
        let after = renderer.shadows.renderedCascades
        for slice in 0 ..< 4 where !second.contains(slice) {
            XCTAssertEqual(after[slice], cold[slice], "stale slice \(slice) must keep its matrix")
        }
        for slice in second { XCTAssertNotEqual(after[slice], cold[slice], "refreshed slice \(slice) must follow the camera") }
        renderer.resetHistory()
        _ = try frame(SIMD3(5, -6, 2))
        XCTAssertEqual(renderer.shadows.lastRefreshedSlices, [0, 1, 2, 3], "a history reset refreshes everything")
    }

    /// A slice kept from an earlier frame looks along that frame's light.
    /// The shader takes all four to share one orientation, so when the sun
    /// moves none may be kept.
    func testAMovedSunRefreshesEverySlice() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        var settings = RenderSettings()
        settings.bloom = false; settings.motionBlur = false; settings.screenSpaceReflections = .off
        settings.shadowCascades = 4; settings.staticShadowRefreshInterval = 3
        let renderer = try ForwardRenderer(settings: settings)
        let scene = try SceneResources(device: renderer.device, scene: MotionBlurTests().fixtureScene())
        func frame(sun: SIMD3<Float>) throws {
            _ = try renderer.render(scene: scene, camera: RenderCamera(eye: SIMD3(6, -5, 2), target: SIMD3(0, 0, 0.5)),
                                    lighting: SunLighting(direction: simd_normalize(sun)), width: 192, height: 120)
        }
        renderer.resetsHistoryPerRender = false
        renderer.resetHistory()
        let noon = SIMD3<Float>(0.35, -0.45, 0.82), later = SIMD3<Float>(0.5, -0.3, 0.8)
        try frame(sun: noon)
        try frame(sun: noon)
        XCTAssertLessThan(renderer.shadows.lastRefreshedSlices.count, 4, "the same sun keeps its far slices")
        try frame(sun: later)
        XCTAssertEqual(renderer.shadows.lastRefreshedSlices, [0, 1, 2, 3])
        XCTAssertTrue(ShadowCascades.shareOrientation(renderer.shadows.renderedCascades))
        try frame(sun: later)
        XCTAssertLessThan(renderer.shadows.lastRefreshedSlices.count, 4, "and the cadence resumes")
    }

    /// The lookup no longer asks whether a point is on the map: the
    /// sampler answers. Off the map is the far plane, where nothing casts,
    /// so a point a cascade does not reach comes out lit.
    func testOffTheMapIsLitByTheSamplerItself() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable")
        }
        let probe = """
        kernel void probeShadowBorder(depth2d_array<float> map [[texture(0)]],
                                      sampler compare [[sampler(0)]],
                                      device float *out [[buffer(0)]],
                                      uint i [[thread_position_in_grid]]) {
            constexpr float2 places[4] = { float2(0.5f, 0.5f), float2(-0.5f, 0.5f), float2(0.5f, 1.5f), float2(2.0f, -1.0f) };
            out[i] = map.sample_compare(compare, places[i], 0, 0.5f, level(0.0f));
        }
        """
        let shaders = try ShaderLibrary(device: device, source: try ShaderLibrary.combinedSource() + probe)
        let renderer = try ShadowRenderer(device: device, library: shaders.library, resolution: 256, cascadeCount: 1)
        // A map with a caster everywhere: cleared to the nearest depth.
        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.depthAttachment.texture = renderer.map
        pass.depthAttachment.slice = 0
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 0
        pass.depthAttachment.storeAction = .store
        try XCTUnwrap(commands.makeRenderCommandEncoder(descriptor: pass)).endEncoding()
        let output = try XCTUnwrap(device.makeBuffer(length: 4 * MemoryLayout<Float>.stride, options: .storageModeShared))
        let pipeline = try device.makeComputePipelineState(
            function: XCTUnwrap(shaders.library.makeFunction(name: "probeShadowBorder")))
        let encoder = try XCTUnwrap(commands.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(renderer.map, index: 0)
        encoder.setSamplerState(renderer.comparisonSampler, index: 0)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: 4, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 4, height: 1, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertNil(commands.error)
        let lit = output.contents().bindMemory(to: Float.self, capacity: 4)
        XCTAssertEqual(lit[0], 0, "on the map, behind the caster: dark")
        XCTAssertEqual(lit[1], 1, "off its left edge: lit")
        XCTAssertEqual(lit[2], 1, "off its lower edge: lit")
        XCTAssertEqual(lit[3], 1, "off a corner: lit")
    }

    func testControllerIgnoresTheWarmup() {
        var controller = DynamicResolutionController(targetGPUTime: 0.010, initialScale: 1.0, warmupFrames: 50)
        for _ in 0 ..< 50 { XCTAssertFalse(controller.record(gpuTime: 0.030)) }
        XCTAssertEqual(controller.scale, 1.0, "nothing may happen during the warm-up")
        var stepped = false
        for _ in 0 ..< 60 { if controller.record(gpuTime: 0.030) { stepped = true } }
        XCTAssertTrue(stepped, "after the warm-up an over-budget run steps down")
    }
}
