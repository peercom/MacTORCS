// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import TORCSRender

final class RenderSettingsTests: XCTestCase {
    let retina = (width: 2560, height: 1664)

    /// The default preset renders natively. Upscaling is implemented but off:
    /// the renderer is submission-bound, so a lower render resolution saves
    /// nothing while the upscaler costs a fixed amount. The half-resolution
    /// scale is retained for when that ceases to be true.
    func testDefaultPresetRendersNativelyWithUpscalingAvailable() {
        let settings = RenderSettings(preset: .m2Air)
        XCTAssertEqual(settings.renderScale, 0.5, "the scale to use once upscaling pays for itself")
        XCTAssertFalse(settings.temporalUpscaling)
        let size = settings.renderSize(output: retina)
        XCTAssertEqual(size.width, retina.width, "upscaling off means rendering at output resolution")
        XCTAssertEqual(size.height, retina.height)
    }

    func testEnablingUpscalingHalvesTheRenderSize() {
        var settings = RenderSettings(preset: .m2Air)
        settings.temporalUpscaling = true
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

    func testPresetsAreOrderedByCost() {
        let air = RenderSettings(preset: .m2Air), high = RenderSettings(preset: .high)
        XCTAssertLessThanOrEqual(air.renderScale, high.renderScale)
        XCTAssertLessThanOrEqual(air.shadowResolution, high.shadowResolution)
        XCTAssertLessThanOrEqual(air.ambientOcclusion, high.ambientOcclusion)
        XCTAssertLessThan(air.textureMemoryBudgetBytes, high.textureMemoryBudgetBytes)
        // Distant cascades refresh less often on the cheaper preset.
        XCTAssertGreaterThan(air.staticShadowRefreshInterval, high.staticShadowRefreshInterval)
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

    /// Off by default because it measured as a net loss: the renderer is
    /// submission-bound, not pixel-bound.
    func testUpscalingIsOffInEveryPreset() {
        for preset in RenderSettings.Preset.allCases {
            XCTAssertFalse(RenderSettings(preset: preset).temporalUpscaling,
                           "\(preset) enables upscaling; measurement says it costs more than it saves")
        }
    }
}

final class EffectAvailabilityTests: XCTestCase {
    /// A setting that is on for a pass the frame does not contain is a lie the
    /// budget table would be built on. Each of these flips to its live value in
    /// the commit that lands the pass, and this test is updated with it.
    func testUnimplementedEffectsAreInertInEveryPreset() {
        for preset in RenderSettings.Preset.allCases {
            let settings = RenderSettings(preset: preset)
            XCTAssertFalse(settings.contactShadows, "\(preset): contact shadows are not implemented")
            XCTAssertEqual(settings.ambientOcclusion, .off, "\(preset): GTAO is not implemented")
            XCTAssertEqual(settings.screenSpaceReflections, .off, "\(preset): SSR is not implemented")
            XCTAssertFalse(settings.motionBlur, "\(preset): motion blur is not implemented")
        }
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
