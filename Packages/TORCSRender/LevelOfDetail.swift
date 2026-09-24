// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// The cross-fade between two builds of the same object at a detail switch.
///
/// A hard switch at a distance is a pop: the tree changes shape on one frame
/// as the car passes 70 m from it. Instead, for a band either side of the
/// switch both builds draw, screen-door dithered with complementary
/// patterns — every pixel shows exactly one of them — and the mix slides
/// from one to the other across the band. The dither is per pixel from a
/// fixed noise, so it is stable frame to frame and costs one compare.
public enum LevelOfDetail {
    /// Half-width of the band, in metres: the switch is spread over twice this.
    public static let band: Float = 6

    public struct Fade: Equatable, Sendable {
        public var visible: Bool
        /// Coverage 0–1: the fraction of pixels this build keeps.
        public var coverage: Float
        /// Which half of the noise this build keeps: `.leaving` keeps
        /// `noise < coverage`, `.arriving` keeps `noise >= 1 − coverage`, so
        /// the two builds of one switch never overlap and never leave a gap.
        public var side: Side
        public enum Side: Sendable { case leaving, arriving }
        public static let full = Fade(visible: true, coverage: 1, side: .leaving)
        public static let hidden = Fade(visible: false, coverage: 0, side: .leaving)
    }

    /// The fade for a build whose range is `range`, seen from `distance`.
    ///
    /// Crossing the lower bound outward the build arrives; crossing the
    /// upper bound outward it leaves. A range starting at zero has no lower
    /// switch, and one with no partner beyond its upper bound simply fades
    /// to nothing, which also removes the pop of grass at its distance.
    public static func fade(distance: Float, range: ClosedRange<Float>?, band: Float = band) -> Fade {
        guard let range else { return .full }
        let lower = range.lowerBound, upper = range.upperBound
        if distance < lower - band || distance > upper + band { return .hidden }
        var coverage: Float = 1
        var side = Fade.Side.leaving
        if lower > 0, distance < lower + band {
            coverage = min(coverage, (distance - (lower - band)) / (2 * band))
            side = .arriving
        }
        if upper.isFinite, distance > upper - band {
            let leaving = ((upper + band) - distance) / (2 * band)
            if leaving < coverage { coverage = leaving; side = .leaving }
        }
        coverage = min(max(coverage, 0), 1)
        if coverage <= 0 { return .hidden }
        return Fade(visible: true, coverage: coverage, side: side)
    }
}
