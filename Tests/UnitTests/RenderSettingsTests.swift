// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import TORCSRender

final class RenderSettingsTests: XCTestCase {
    let retina = (width: 2560, height: 1664)

    func testDefaultPresetTargetsHalfResolutionOnTheAir() {
        let settings = RenderSettings(preset: .m2Air)
        XCTAssertEqual(settings.renderScale, 0.5)
        XCTAssertTrue(settings.temporalUpscaling)
        XCTAssertTrue(settings.dynamicResolution)
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
        XCTAssertLessThan(air.renderScale, high.renderScale)
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
