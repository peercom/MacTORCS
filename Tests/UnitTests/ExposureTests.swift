// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
@testable import TORCSRender

/// Auto-exposure: a dark scene is opened up and a bright one closed down,
/// a cold render snaps and repeats, an interactive sequence adapts at the
/// eye's two speeds, and manual exposure is what it was.
final class ExposureTests: XCTestCase {
    func makeRenderer(automatic: Bool) throws -> ForwardRenderer {
        var settings = RenderSettings()
        settings.bloom = false; settings.motionBlur = false; settings.upscaling = false
        settings.ambientOcclusion = .off; settings.contactShadows = false; settings.heatHaze = false
        settings.autoExposure = automatic
        return try ForwardRenderer(settings: settings)
    }
    // The weather tests' ground square: a lit surface filling the lower
    // frame with sky above, the kind of picture a meter is for.
    let camera = RenderCamera(eye: SIMD3(0, -8, 6), target: SIMD3(0, 2, 0))
    func mean(_ image: [UInt8]) -> Double {
        var total = 0
        for i in stride(from: 0, to: image.count, by: 4) { total += Int(image[i]) + Int(image[i + 1]) + Int(image[i + 2]) }
        return Double(total) / Double(image.count / 4 * 3)
    }
    func frame(_ renderer: ForwardRenderer, intensity: Float) throws -> [UInt8] {
        let scene = try SceneResources(device: renderer.device, scene: try WeatherTests().ground(weather: false))
        var lighting = SunLighting()
        lighting.intensity = intensity
        return try renderer.render(scene: scene, camera: camera, lighting: lighting, width: 256, height: 160)
    }

    func testMeteringOpensUpTheDarkAndClosesDownTheBright() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        let manual = try makeRenderer(automatic: false), automatic = try makeRenderer(automatic: true)
        let dimManual = mean(try frame(manual, intensity: 0.5)), dimAuto = mean(try frame(automatic, intensity: 0.5))
        let brightManual = mean(try frame(manual, intensity: 32)), brightAuto = mean(try frame(automatic, intensity: 32))
        XCTAssertGreaterThan(dimAuto, dimManual * 1.25, "a dim scene is opened up: \(dimAuto) vs \(dimManual)")
        XCTAssertLessThan(brightAuto, brightManual * 0.8, "a bright scene is closed down: \(brightAuto) vs \(brightManual)")
        // Metered, the two land near each other: that is what a meter is for.
        XCTAssertEqual(dimAuto, brightAuto, accuracy: max(dimAuto, brightAuto) * 0.35, "\(dimAuto) vs \(brightAuto)")
        XCTAssertGreaterThan(automatic.lastExposureEV, -10); XCTAssertLessThan(automatic.lastExposureEV, 20)
    }

    func testColdRendersSnapAndRepeatAndManualIsUnchanged() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        let automatic = try makeRenderer(automatic: true)
        let a = try frame(automatic, intensity: 4), b = try frame(automatic, intensity: 4)
        XCTAssertEqual(a, b, "cold renders must repeat exactly")
        let manual = try makeRenderer(automatic: false)
        let m = try frame(manual, intensity: 4)
        XCTAssertEqual(m, try frame(manual, intensity: 4))
        XCTAssertEqual(manual.lastExposureEV, 0, accuracy: 1e-6, "manual carries the lighting's EV100")
        XCTAssertNotEqual(a, m, "the meter chose something other than EV 0 for the fixture")
    }

    /// Bright to dark: the exposure opens up over frames, slowly; dark to
    /// bright: it closes down faster. Both settle at the cold-render value.
    func testAdaptationIsSlowToOpenAndFastToClose() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        let renderer = try makeRenderer(automatic: true)
        renderer.presentedFrameInterval = 1.0 / 60.0
        // Settled in the bright.
        _ = try frame(renderer, intensity: 32)
        let brightEV = renderer.lastExposureEV
        renderer.resetsHistoryPerRender = false
        var opening: [Float] = []
        for _ in 0 ..< 30 { _ = try frame(renderer, intensity: 0.5); opening.append(renderer.lastExposureEV) }
        let dimTarget = renderer.exposureMeter.lastState.targetEV
        XCTAssertLessThan(opening[0], brightEV, "the exposure starts opening")
        XCTAssertGreaterThan(opening[0], opening[29], "and keeps opening")
        // Fractions of each gap closed in half a second, since the gaps differ:
        // the opening at 1.5 s covers about a quarter, the closing at 0.4 s
        // about two thirds.
        let openedFraction = (brightEV - opening[29]) / (brightEV - dimTarget)
        var closing: [Float] = []
        for _ in 0 ..< 30 { _ = try frame(renderer, intensity: 32); closing.append(renderer.lastExposureEV) }
        let brightTarget = renderer.exposureMeter.lastState.targetEV
        let closedFraction = (closing[29] - opening[29]) / (brightTarget - opening[29])
        XCTAssertGreaterThan(closedFraction, openedFraction * 2, "closing is faster: \(closedFraction) vs \(openedFraction) of the gap in half a second")
        XCTAssertEqual(openedFraction, 1 - exp(-0.5 / renderer.exposureMeter.openingTime), accuracy: 0.08)
        XCTAssertEqual(closedFraction, 1 - exp(-0.5 / renderer.exposureMeter.closingTime), accuracy: 0.1)
        for i in 1 ..< 30 { XCTAssertLessThanOrEqual(opening[i], opening[i - 1] + 1e-4); XCTAssertGreaterThanOrEqual(closing[i], closing[i - 1] - 1e-4) }
    }
}
