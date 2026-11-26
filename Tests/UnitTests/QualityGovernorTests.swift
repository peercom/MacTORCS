// SPDX-License-Identifier: GPL-2.0-only
// The frame-rate governor: when it moves the quality down, when it climbs
// back, and when it does neither.
import XCTest
import TORCSRender

final class QualityGovernorTests: XCTestCase {
    private let top=QualityGovernor.ladder.count-1
    private func settle(_ governor: inout QualityGovernor,rate: Double = 60) {
        for _ in 0..<QualityGovernor.settleSeconds { XCTAssertNil(governor.record(frameRate:rate)) }
    }
    func testStepsDownOnlyAfterSettlingAndSustainedSlowSeconds() {
        var governor=QualityGovernor(index:top)
        XCTAssertEqual(governor.level.preset,.high)
        // The first seconds are ignored, however slow.
        settle(&governor,rate:10)
        // Two slow seconds are not enough; a good one in between starts the count again.
        XCTAssertNil(governor.record(frameRate:33));XCTAssertNil(governor.record(frameRate:33))
        XCTAssertNil(governor.record(frameRate:60))
        XCTAssertNil(governor.record(frameRate:33));XCTAssertNil(governor.record(frameRate:33))
        XCTAssertEqual(governor.record(frameRate:33)?.preset,.balanced,"the third slow second in a row")
        // It settles again after a change, then steps on: fanless at native, then lower resolutions.
        var seen: [QualityLevel]=[]
        for _ in 0..<200 { if let level=governor.record(frameRate:33) { seen.append(level) } }
        XCTAssertEqual(seen.map(\.preset),[.m2Air,.m2Air,.m2Air,.m2Air])
        XCTAssertEqual(seen.map(\.renderScale),[1,0.85,0.67,0.5])
        // At the bottom there is nowhere to go.
        XCTAssertEqual(governor.index,0)
        for _ in 0..<20 { XCTAssertNil(governor.record(frameRate:20)) }
    }
    func testHoldsWhenTheRateIsMetAndIgnoresNonsense() {
        var governor=QualityGovernor(index:QualityGovernor.index(of:.balanced))
        for _ in 0..<60 { XCTAssertNil(governor.record(frameRate:58,gpuSeconds:0.012)) }   // within tolerance, no headroom
        for value in [Double.nan,.infinity,0,-5] { XCTAssertNil(governor.record(frameRate:value)) }
        XCTAssertEqual(governor.level.preset,.balanced)
        // A reset forgets a run of slow seconds.
        XCTAssertNil(governor.record(frameRate:30));XCTAssertNil(governor.record(frameRate:30))
        governor.reset()
        for _ in 0..<QualityGovernor.settleSeconds+2 { XCTAssertNil(governor.record(frameRate:30)) }
        XCTAssertEqual(governor.record(frameRate:30),QualityLevel(preset:.m2Air,renderScale:1))
        // A 120 Hz target is held to its own tolerance.
        var fast=QualityGovernor(index:top,targetRate:120)
        settle(&fast,rate:120)
        XCTAssertNil(fast.record(frameRate:110))
        for _ in 0..<2 { XCTAssertNil(fast.record(frameRate:60)) }
        XCTAssertEqual(fast.record(frameRate:60)?.preset,.balanced)
    }
    func testClimbsOnlyWithHeadroomUpToTheCeilingAndRemembersAFailedRung() {
        let fanless=QualityGovernor.index(of:.m2Air)
        var governor=QualityGovernor(index:1,ceiling:fanless)
        settle(&governor)
        // Steady at the target but the GPU busy: no climb.
        for _ in 0..<60 { XCTAssertNil(governor.record(frameRate:60,gpuSeconds:0.012)) }
        // Steady with the GPU under half its interval: one rung after the steady stretch.
        for _ in 0..<QualityGovernor.steadySeconds-1 { XCTAssertNil(governor.record(frameRate:60,gpuSeconds:0.006)) }
        XCTAssertEqual(governor.record(frameRate:60,gpuSeconds:0.006),QualityLevel(preset:.m2Air,renderScale:0.85))
        // The new rung drops frames: back down, and that rung is not tried again.
        settle(&governor,rate:40)
        for _ in 0..<QualityGovernor.slowSeconds-1 { XCTAssertNil(governor.record(frameRate:40,gpuSeconds:0.02)) }
        XCTAssertEqual(governor.record(frameRate:40,gpuSeconds:0.02)?.renderScale,0.67)
        XCTAssertEqual(governor.ceiling,1)
        settle(&governor)
        for _ in 0..<200 { XCTAssertNil(governor.record(frameRate:60,gpuSeconds:0.004)) }
        XCTAssertEqual(governor.index,1)
        // A climb that holds past its trial keeps the ceiling, and stops at it.
        var steady=QualityGovernor(index:fanless-1,ceiling:fanless)
        var changes=0
        for _ in 0..<400 { if steady.record(frameRate:60,gpuSeconds:0.005) != nil { changes += 1 } }
        XCTAssertEqual(changes,1);XCTAssertEqual(steady.index,fanless);XCTAssertEqual(steady.ceiling,fanless)
    }
    func testLevelsAndRecommendationFollowTheChip() {
        let fanless=QualityGovernor.index(of:.m2Air)
        XCTAssertEqual(QualityGovernor.recommended(deviceName:"Apple M2"),fanless)
        XCTAssertEqual(QualityGovernor.recommended(deviceName:"Apple M3 Pro"),QualityGovernor.index(of:.balanced))
        XCTAssertEqual(QualityGovernor.recommended(deviceName:"Apple M2 Max"),top)
        XCTAssertEqual(QualityGovernor.recommended(deviceName:"Apple M1 Ultra"),top)
        XCTAssertEqual(QualityGovernor.recommended(deviceName:""),fanless)
        // A starting rung is kept inside the ladder and under its ceiling.
        XCTAssertEqual(QualityGovernor(index:99).index,top);XCTAssertEqual(QualityGovernor(index:-3).index,0)
        XCTAssertEqual(QualityGovernor(index:5,ceiling:2).index,2)
        // A fanless rung fixes the resolution itself; the heavier presets are untouched.
        let low=QualityGovernor.ladder[1].settings()
        XCTAssertEqual(low.renderScale,0.67);XCTAssertTrue(low.upscaling);XCTAssertFalse(low.dynamicResolution)
        // Dry, a fanless rung leaves reflections out; wet, it keeps them.
        XCTAssertEqual(low.screenSpaceReflections,.off)
        XCTAssertEqual(QualityGovernor.ladder[1].settings(wetRoad:true).screenSpaceReflections,RenderSettings(preset:.m2Air).screenSpaceReflections)
        XCTAssertEqual(QualityGovernor.ladder[top].settings(),RenderSettings(preset:.high))
        // A base chip starts a rung under its ceiling; the others at it.
        XCTAssertEqual(QualityGovernor.start(deviceName:"Apple M2"),fanless-1)
        XCTAssertEqual(QualityGovernor.start(deviceName:"Apple M3 Pro"),QualityGovernor.index(of:.balanced))
        // Every scale is a rung of the renderer's resolution ladder.
        for level in QualityGovernor.ladder { XCTAssertTrue(DynamicResolutionController.ladder.contains(level.renderScale)) }
    }
}
