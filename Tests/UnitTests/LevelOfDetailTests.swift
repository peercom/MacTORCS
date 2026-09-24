// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import TORCSRender

final class LevelOfDetailTests: XCTestCase {
    /// The two builds of one switch are complementary at every distance
    /// through the band: their coverages sum to one and they keep opposite
    /// halves of the noise.
    func testPairIsComplementaryThroughTheBand() {
        let near: ClosedRange<Float> = 0 ... 70, middle: ClosedRange<Float> = 70 ... .infinity
        for d: Float in stride(from: 60, through: 80, by: 0.5) {
            let a = LevelOfDetail.fade(distance: d, range: near), b = LevelOfDetail.fade(distance: d, range: middle)
            if d <= 64 { XCTAssertEqual(a, .full); XCTAssertFalse(b.visible) }
            else if d >= 76 { XCTAssertFalse(a.visible); XCTAssertEqual(b, .full) }
            else {
                XCTAssertTrue(a.visible && b.visible, "\(d)")
                XCTAssertEqual(a.coverage + b.coverage, 1, accuracy: 1e-5, "\(d)")
                XCTAssertEqual(a.side, .leaving); XCTAssertEqual(b.side, .arriving)
                // The noise halves: near keeps n < a, middle keeps n >= 1 − b = a.
                XCTAssertEqual(1 - b.coverage, a.coverage, accuracy: 1e-5)
            }
        }
        XCTAssertEqual(LevelOfDetail.fade(distance: 70, range: near).coverage, 0.5, accuracy: 1e-5)
    }

    func testNoRangeIsAlwaysFullAndAnUnpartneredRangeFadesToNothing() {
        XCTAssertEqual(LevelOfDetail.fade(distance: 1e6, range: nil), .full)
        let grass: ClosedRange<Float> = 0 ... 60
        XCTAssertEqual(LevelOfDetail.fade(distance: 10, range: grass), .full)
        XCTAssertEqual(LevelOfDetail.fade(distance: 60, range: grass).coverage, 0.5, accuracy: 1e-5)
        XCTAssertFalse(LevelOfDetail.fade(distance: 67, range: grass).visible)
    }

    /// A build with both bounds arrives at one and leaves at the other.
    func testThreeLevelChainPicksTheActiveEnd() {
        let mid: ClosedRange<Float> = 70 ... 300
        XCTAssertEqual(LevelOfDetail.fade(distance: 70, range: mid).side, .arriving)
        XCTAssertEqual(LevelOfDetail.fade(distance: 150, range: mid), .full)
        XCTAssertEqual(LevelOfDetail.fade(distance: 300, range: mid).side, .leaving)
        XCTAssertEqual(LevelOfDetail.fade(distance: 300, range: mid).coverage, 0.5, accuracy: 1e-5)
    }
}
