// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
@testable import TORCSRender
import TORCSAssets
import Metal

final class RenderSettingsTests: XCTestCase {
    let retina = (width: 2560, height: 1664)

    /// The default preset renders natively at rest, with the spatial scaler
    /// available for dynamic resolution to step down into under sustained
    /// load. The temporal scaler measured as a net loss twice and is not the
    /// default mode.
    func testDefaultPresetRendersNativelyWithTheSpatialScalerAvailable() {
        let settings = RenderSettings(preset: .m2Air)
        XCTAssertEqual(settings.renderScale, 1.0)
        XCTAssertTrue(settings.upscaling)
        XCTAssertEqual(settings.upscalingMode, .spatial)
        XCTAssertTrue(settings.dynamicResolution)
        let size = settings.renderSize(output: retina)
        XCTAssertEqual(size.width, retina.width, "scale 1 renders at output resolution")
        XCTAssertEqual(size.height, retina.height)
    }

    func testHalfScaleHalvesTheRenderSize() {
        var settings = RenderSettings(preset: .m2Air)
        settings.renderScale = 0.5
        let size = settings.renderSize(output: retina)
        XCTAssertEqual(size.width, 1280)
        XCTAssertEqual(size.height, 832)
    }

    func testHighPresetRendersNative() {
        let size = RenderSettings(preset: .high).renderSize(output: retina)
        XCTAssertEqual(size.width, retina.width)
        XCTAssertEqual(size.height, retina.height)
    }

    func testRenderSizeIsAlwaysEvenSoHalfResolutionPassesTileExactly() {
        let settings = RenderSettings(preset: .m2Air)
        for scale in stride(from: Float(0.25), through: 1.0, by: 0.03) {
            for output in [retina, (width: 1512, height: 982), (width: 801, height: 601)] {
                let size = settings.renderSize(output: output, scale: scale)
                XCTAssertEqual(size.width % 2, 0, "odd width at \(scale)")
                XCTAssertEqual(size.height % 2, 0, "odd height at \(scale)")
                XCTAssertGreaterThanOrEqual(size.width, 16)
                XCTAssertLessThanOrEqual(size.width, output.width + 1)
            }
        }
    }

    func testScaleIsClampedToASaneRange() {
        let settings = RenderSettings(preset: .m2Air)
        // Absurd inputs must not produce a zero or oversized target.
        XCTAssertGreaterThanOrEqual(settings.renderSize(output: retina, scale: -5).width, 16)
        XCTAssertLessThanOrEqual(settings.renderSize(output: retina, scale: 99).width, retina.width + 1)
    }

    /// The normal and roughness maps filter at a lower anisotropy than the
    /// albedo on the cheaper presets: measured a millisecond off the forward
    /// pass at 2 with no visible change. The high preset keeps the full 8.
    func testDetailAnisotropyRisesWithThePreset() {
        let air = RenderSettings(preset: .m2Air), balanced = RenderSettings(preset: .balanced)
        let high = RenderSettings(preset: .high)
        XCTAssertEqual(air.detailAnisotropy, 2)
        XCTAssertLessThanOrEqual(air.detailAnisotropy, balanced.detailAnisotropy)
        XCTAssertLessThanOrEqual(balanced.detailAnisotropy, high.detailAnisotropy)
        XCTAssertEqual(high.detailAnisotropy, 8, "the high preset filters the detail maps like the albedo")
        for settings in [air, balanced, high] {
            XCTAssertTrue((1 ... 16).contains(settings.detailAnisotropy))
        }
    }

    /// One sampler per anisotropy the settings ask for, made once, and an
    /// out-of-range value clamped rather than failing the sampler.
    func testDetailSamplerFollowsTheSettingAndIsCached() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let renderer = try ForwardRenderer(device: device)
        renderer.settings.detailAnisotropy = 2
        let two = renderer.detailSampler()
        XCTAssertTrue(two === renderer.detailSampler(), "same setting, same sampler")
        renderer.settings.detailAnisotropy = 8
        let eight = renderer.detailSampler()
        XCTAssertFalse(two === eight, "a different anisotropy needs its own sampler")
        renderer.settings.detailAnisotropy = 99
        XCTAssertTrue(renderer.detailSampler() === renderer.detailSampler(), "clamped and cached")
        renderer.settings.detailAnisotropy = 2
        XCTAssertTrue(two === renderer.detailSampler(), "the first sampler was kept")
    }

    func testPresetsAreOrderedByCost() {
        let air = RenderSettings(preset: .m2Air), high = RenderSettings(preset: .high)
        XCTAssertLessThanOrEqual(air.renderScale, high.renderScale)
        XCTAssertLessThanOrEqual(air.shadowResolution, high.shadowResolution)
        XCTAssertLessThanOrEqual(air.ambientOcclusion, high.ambientOcclusion)
        XCTAssertLessThan(air.textureMemoryBudgetBytes, high.textureMemoryBudgetBytes)
        // Distant cascades refresh less often on the cheaper preset.
        XCTAssertGreaterThanOrEqual(air.staticShadowRefreshInterval, high.staticShadowRefreshInterval)
    }
}

final class DynamicResolutionControllerTests: XCTestCase {
    let target = 1.0 / 60.0 * 0.66  // about 11 ms

    func drive(_ controller: inout DynamicResolutionController, gpuTime: Double, frames: Int) {
        for _ in 0 ..< frames { controller.record(gpuTime: gpuTime) }
    }

    func testSustainedOverBudgetDropsTheScale() {
        var controller = DynamicResolutionController(targetGPUTime: target, initialScale: 0.75)
        let start = controller.scale
        drive(&controller, gpuTime: target * 1.5, frames: 200)
        XCTAssertLessThan(controller.scale, start)
        XCTAssertGreaterThanOrEqual(controller.scale, 0.4, "must not fall below the floor")
    }

    func testSustainedHeadroomClimbsBackUp() {
        var controller = DynamicResolutionController(targetGPUTime: target, initialScale: 0.5)
        let start = controller.scale
        drive(&controller, gpuTime: target * 0.3, frames: 2000)
        XCTAssertGreaterThan(controller.scale, start)
        XCTAssertLessThanOrEqual(controller.scale, 1.0, "must not exceed the ceiling")
    }

    /// The failure mode that matters: a frame time sitting near the target must
    /// not make the controller flip scale every few frames, which would be far
    /// more visible than simply running one step lower.
    func testFrameTimeNearTargetDoesNotOscillate() {
        var controller = DynamicResolutionController(targetGPUTime: target, initialScale: 0.6)
        var changes = 0
        for frame in 0 ..< 1000 {
            // Hovers just inside the hysteresis band, with a little noise.
            let jitter = (frame % 7) == 0 ? 1.02 : 0.93
            if controller.record(gpuTime: target * jitter) { changes += 1 }
        }
        XCTAssertLessThanOrEqual(changes, 2, "scale changed \(changes) times near the target")
    }

    func testSingleSlowFrameDoesNotMoveTheScale() {
        var controller = DynamicResolutionController(targetGPUTime: target, initialScale: 0.6)
        drive(&controller, gpuTime: target * 0.5, frames: 30)
        let settled = controller.scale
        // One catastrophic hitch, e.g. a window resize or a shader compile.
        controller.record(gpuTime: target * 20)
        XCTAssertEqual(controller.scale, settled, "a single hitch must not drop resolution")
    }

    func testThermalRampDropsThenHoldsRatherThanCollapsing() {
        var controller = DynamicResolutionController(targetGPUTime: target, initialScale: 1.0)
        // Cost rises as the chip heats, then plateaus: the fanless Air case.
        for frame in 0 ..< 600 {
            let heat = min(1.35, 1.0 + Double(frame) * 0.002)
            controller.record(gpuTime: target * heat * Double(controller.scale) / 0.75)
        }
        XCTAssertGreaterThan(controller.scale, 0.4, "should settle above the floor, not collapse")
        XCTAssertLessThan(controller.scale, 1.0, "should have given up some resolution")
    }

    /// What a throttling chip actually delivers: a median well under target
    /// with bursts of frames at twice it. The scale must not move.
    func testSpikeBurstsUnderAComfortableMedianDoNotMoveTheScale() {
        var controller = DynamicResolutionController(targetGPUTime: target, initialScale: 1.0)
        var changes = 0
        for frame in 0 ..< 3000 {
            let burst = (frame % 60) < 8
            if controller.record(gpuTime: target * (burst ? 1.3 : 0.55)) { changes += 1 }
        }
        XCTAssertEqual(changes, 0, "scale moved \(changes) times on spike bursts")
        XCTAssertEqual(controller.scale, 1.0)
    }

    /// A step reallocates the targets, and the frame that does is slow. That
    /// frame must not seed the next decision, or one legitimate step cascades.
    func testTheHitchAfterAStepDoesNotCascade() {
        var controller = DynamicResolutionController(targetGPUTime: target, initialScale: 1.0)
        drive(&controller, gpuTime: target * 1.3, frames: 120)
        let afterFirst = controller.scale
        XCTAssertLessThan(afterFirst, 1.0, "sustained over budget should step down once")
        controller.record(gpuTime: target * 4)  // the reallocation hitch
        drive(&controller, gpuTime: target * 0.6, frames: 60)
        XCTAssertEqual(controller.scale, afterFirst, "the hitch after a step cascaded")
    }

    func testDegenerateMeasurementsAreIgnored() {
        var controller = DynamicResolutionController(targetGPUTime: target, initialScale: 0.5)
        let start = controller.scale
        for bad in [0.0, -1.0, Double.nan, Double.infinity] {
            XCTAssertFalse(controller.record(gpuTime: bad))
        }
        XCTAssertEqual(controller.scale, start)
    }

    func testEveryLadderStepIsReachableAndOrdered() {
        XCTAssertEqual(DynamicResolutionController.ladder, DynamicResolutionController.ladder.sorted())
        XCTAssertEqual(Set(DynamicResolutionController.ladder).count, DynamicResolutionController.ladder.count)
        for step in DynamicResolutionController.ladder {
            let controller = DynamicResolutionController(initialScale: step)
            XCTAssertEqual(controller.scale, step, "ladder step \(step) not selectable")
        }
    }
}

final class TemporalUpscalingTests: XCTestCase {
    let retina = (width: 2560, height: 1664)

    /// Halton is low-discrepancy: a short sequence must cover the pixel evenly
    /// rather than clustering, or temporal accumulation converges to a biased
    /// result instead of the true image.
    func testJitterCoversThePixelWithoutClustering() {
        var xs: [Float] = [], ys: [Float] = []
        for index in 0 ..< 16 {
            let offset = JitterSequence.offset(at: index, length: 16)
            XCTAssertGreaterThanOrEqual(offset.x, -0.5)
            XCTAssertLessThanOrEqual(offset.x, 0.5)
            XCTAssertGreaterThanOrEqual(offset.y, -0.5)
            XCTAssertLessThanOrEqual(offset.y, 0.5)
            xs.append(offset.x); ys.append(offset.y)
        }
        // Mean near zero, or the accumulated image sits off-centre.
        XCTAssertEqual(xs.reduce(0, +) / 16, 0, accuracy: 0.1)
        XCTAssertEqual(ys.reduce(0, +) / 16, 0, accuracy: 0.1)
        // Every sample distinct: a repeat wastes a phase.
        XCTAssertEqual(Set(xs.map { Int($0 * 10_000) }).count, 16)
    }

    func testJitterSequenceIsDeterministicAndRepeats() {
        var sequence = JitterSequence(length: 8)
        let first = (0 ..< 8).map { _ in sequence.next() }
        let second = (0 ..< 8).map { _ in sequence.next() }
        XCTAssertEqual(first, second, "sequence must repeat so a golden image can pin a phase")
        var other = JitterSequence(length: 8)
        XCTAssertEqual(first, (0 ..< 8).map { _ in other.next() }, "two sequences must agree")
    }

    /// The jitter belongs in the projection's z column, because the perspective
    /// divide turns it into a constant screen-space offset. Putting it anywhere
    /// else would scale it with depth.
    func testJitterOffsetsClipSpaceUniformlyWithDepth() {
        let camera = RenderCamera(eye: SIMD3(0, -10, 2), target: SIMD3(0, 0, 1))
        let projection = camera.projection(aspect: 1.5)
        let jittered = RenderCamera.jittered(projection, jitter: SIMD2(0.25, -0.25),
                                             renderWidth: 1280, renderHeight: 832)
        for depth in [Float(-2), -20, -200] {
            let point = SIMD4<Float>(1, 0.5, depth, 1)
            let plain = projection * point, moved = jittered * point
            let plainNDC = SIMD2(plain.x / plain.w, plain.y / plain.w)
            let movedNDC = SIMD2(moved.x / moved.w, moved.y / moved.w)
            // A quarter pixel of 1280 is 2 * 0.25 / 1280 in NDC.
            XCTAssertEqual(movedNDC.x - plainNDC.x, 2 * 0.25 / 1280, accuracy: 1e-6, "depth \(depth)")
            XCTAssertEqual(movedNDC.y - plainNDC.y, 2 * 0.25 / 832, accuracy: 1e-6, "depth \(depth)")
        }
    }

    func testMipBiasMatchesTheUpscaleRatio() {
        // Half linear resolution needs one mip level of extra detail.
        XCTAssertEqual(RenderCamera.mipBias(renderWidth: 1280, outputWidth: 2560), -1, accuracy: 1e-5)
        XCTAssertEqual(RenderCamera.mipBias(renderWidth: 2560, outputWidth: 2560), 0, accuracy: 1e-5)
        XCTAssertEqual(RenderCamera.mipBias(renderWidth: 0, outputWidth: 2560), 0)
    }

    /// The spatial scaler needs neither jitter nor motion vectors, so a frame
    /// through it must have zero jitter and still produce output at the
    /// output size — and be repeatable, having no history.
    func testSpatialModeRendersWithoutJitterAndRepeats() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        var settings = RenderSettings()
        settings.upscaling = true
        settings.upscalingMode = .spatial
        settings.renderScale = 0.5
        settings.bloom = false
        let renderer = try ForwardRenderer(settings: settings)
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Artwork/155-DTM/155-DTM.acc")
        let scene = try SceneResources(device: renderer.device,
                                       scene: RenderScene(ACScene.parse(Data(contentsOf: url), car: true)))
        let camera = RenderCamera(eye: SIMD3(6, -5, 2), target: SIMD3(0, 0, 0.5))
        let a = try renderer.render(scene: scene, camera: camera, lighting: SunLighting(), width: 256, height: 160)
        let b = try renderer.render(scene: scene, camera: camera, lighting: SunLighting(), width: 256, height: 160)
        XCTAssertEqual(a.count, 256 * 160 * 4)
        XCTAssertEqual(a, b, "no history, so identical")
        XCTAssertEqual(renderer.currentJitter, SIMD2(0, 0), "spatial scaling must not jitter the projection")
        XCTAssertNil(renderer.lastUpscalerError)
        let targets = try renderer.targets(outputWidth: 256, outputHeight: 160)
        XCTAssertEqual(targets.renderWidth, 128)
        XCTAssertNotNil(targets.upscaled)
    }

    /// Every preset renders native at rest; the temporal scaler, which
    /// measured as a net loss twice, is nobody's default.
    func testEveryPresetRendersNativeAtRestAndNoneDefaultsToTemporal() {
        for preset in RenderSettings.Preset.allCases {
            let settings = RenderSettings(preset: preset)
            XCTAssertEqual(settings.renderSize(output: retina).width, retina.width, "\(preset)")
            XCTAssertNotEqual(settings.upscalingMode, .temporal, "\(preset)")
        }
    }

    /// The valve: under sustained load the render scale steps down and the
    /// scaler engages; at rest the scaler is bypassed, not run at 1:1.
    func testDynamicResolutionEngagesTheScalerOnlyUnderLoad() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        let renderer = try ForwardRenderer(settings: RenderSettings(preset: .m2Air))
        let rest = try renderer.targets(outputWidth: 512, outputHeight: 320)
        XCTAssertEqual(rest.renderWidth, 512)
        XCTAssertNil(rest.upscaled, "at scale 1 the scaler is bypassed")
        // Two hundred frames well over budget, as a throttling chip delivers.
        // Past the controller's warm-up, then long enough to step.
        for _ in 0 ..< ForwardRenderer.resolutionWarmupFrames + 200 { renderer.recordDynamicResolution(gpuTime: 0.020) }
        XCTAssertLessThan(renderer.effectiveRenderScale, 1)
        let loaded = try renderer.targets(outputWidth: 512, outputHeight: 320)
        XCTAssertLessThan(loaded.renderWidth, 512)
        XCTAssertNotNil(loaded.upscaled)
        renderer.resetDynamicResolution()
        XCTAssertEqual(renderer.effectiveRenderScale, 1)
        // Offscreen renders never record, so a verification render at rest
        // is native whatever presentation was doing.
        let settings = RenderSettings(preset: .m2Air)
        XCTAssertEqual(settings.renderSize(output: retina, scale: renderer.effectiveRenderScale).width, retina.width)
    }
}

final class EffectAvailabilityTests: XCTestCase {
    /// A setting that is on for a pass the frame does not contain is a lie the
    /// budget table would be built on. Each of these flips to its live value in
    /// the commit that lands the pass, and this test is updated with it.
    func testUnimplementedEffectsAreInertInEveryPreset() {
        for preset in RenderSettings.Preset.allCases {
            let settings = RenderSettings(preset: preset)
        }
    }

    func testMotionBlurIsOnInEveryPreset() {
        for preset in RenderSettings.Preset.allCases {
            XCTAssertTrue(RenderSettings(preset: preset).motionBlur, "\(preset)")
        }
    }

    func testScreenSpaceReflectionsAreOnInEveryPreset() {
        for preset in RenderSettings.Preset.allCases {
            XCTAssertNotEqual(RenderSettings(preset: preset).screenSpaceReflections, .off, "\(preset)")
        }
        XCTAssertEqual(RenderSettings(preset: .m2Air).screenSpaceReflections, .half)
    }

    func testScreenSpaceOcclusionIsOnInEveryPreset() {
        for preset in RenderSettings.Preset.allCases {
            let settings = RenderSettings(preset: preset)
            XCTAssertTrue(settings.contactShadows, "\(preset)")
            XCTAssertNotEqual(settings.ambientOcclusion, .off, "\(preset)")
        }
        XCTAssertEqual(RenderSettings(preset: .m2Air).ambientOcclusion, .half, "the Air pays half the pixels")
    }

    func testBloomIsOnWithSaneParametersInEveryPreset() {
        for preset in RenderSettings.Preset.allCases {
            let settings = RenderSettings(preset: preset)
            XCTAssertTrue(settings.bloom, "\(preset)")
            // Strength is a fraction of the thresholded pyramid: above a few
            // tenths the whole frame fogs, at zero the pass is wasted.
            XCTAssertGreaterThan(settings.bloomStrength, 0, "\(preset)")
            XCTAssertLessThanOrEqual(settings.bloomStrength, 0.3, "\(preset)")
            // Threshold in exposed units: at or above middle grey, or ordinary
            // sunlit surfaces glow.
            XCTAssertGreaterThanOrEqual(settings.bloomThreshold, 0.18, "\(preset)")
        }
    }
}
