// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import TORCSTrack

/// A plausible racing line from the segment model, for the rubber the
/// renderer lays on the road.
///
/// This is not the AI's line and makes no claim to be fast. It is the shape
/// every driver's line has — outside on the approach, inside at the apex,
/// outside again on the exit — derived from curvature alone, so that the
/// darkened band on the road follows the corners instead of the centre line.
/// The robot's actual line is computed in the robot and the renderer never
/// sees it; when it does, it replaces this by writing the same per-metre
/// table.
public struct RacingLine: Sendable, Equatable {
    /// Lateral position per metre of lap distance, as a fraction of the road
    /// width from the right edge: 0.5 is the centre. Wraps at the lap length.
    public let lateral: [Float]
    public let lapLength: Float

    public struct Parameters: Sendable, Equatable {
        /// Radius at which a corner pulls the line fully to its inside.
        public var fullInsideRadius: Float = 70
        /// How far along the road the outside positioning before and after a
        /// corner reaches, in metres. Aalborg's corners are 17–50 m long and
        /// 50–100 m apart; a wider window than this blends neighbouring
        /// corners of opposite hand into nothing.
        public var approach: Float = 60
        /// Final smoothing so the band has no kinks at segment joins. Kept
        /// short: a corner's inside plateau is only as long as the corner.
        public var smoothing: Float = 8
        /// Margin from the edge the line never crosses, as a fraction of width.
        public var edgeMargin: Float = 0.12
        public init() {}
    }

    public init(_ geometry: TrackGeometry, parameters: Parameters = .init()) {
        guard let last = geometry.mainSegments.last else { lateral = []; lapLength = 0; return }
        let length = geometry.segments[last].distanceFromStart + geometry.segments[last].length
        let count = max(Int(length.rounded(.up)), 1)
        lapLength = length

        // Target: how far inside each metre wants to be. Lateral 0 is the
        // right edge, so a right-hander's inside is negative.
        var target = [Float](repeating: 0, count: count)
        for index in geometry.mainSegments {
            let segment = geometry.segments[index]
            guard segment.curve != .straight, segment.radius > 0 else { continue }
            let pull = min(parameters.fullInsideRadius / segment.radius, 1)
            let value: Float = segment.curve == .right ? -pull : pull
            let start = Int(segment.distanceFromStart), end = Int(segment.distanceFromStart + segment.length)
            for metre in start ..< max(end, start + 1) where metre < count { target[metre] = value }
        }

        // Outside on approach and exit: the wide blur of the target says
        // where the corners are, and the line sits opposite to it. Inside the
        // corner itself the unblurred target wins.
        let wide = Self.blur(target, radius: Int(parameters.approach))
        var line = zip(target, wide).map { t, w in max(min(1.6 * t - 1.4 * w, 1), -1) }
        line = Self.blur(line, radius: Int(parameters.smoothing))

        let half = 0.5 - parameters.edgeMargin
        lateral = line.map { 0.5 + $0 * half }
    }

    /// Fraction across the width at a lap distance, wrapping.
    public func lateral(at distance: Float) -> Float {
        guard !lateral.isEmpty else { return 0.5 }
        var d = distance.truncatingRemainder(dividingBy: lapLength)
        if d < 0 { d += lapLength }
        let i = Int(d), a = lateral[i % lateral.count], b = lateral[(i + 1) % lateral.count]
        return a + (b - a) * (d - Float(i))
    }

    /// Circular box blur, applied twice so it is close to a Gaussian.
    static func blur(_ values: [Float], radius: Int) -> [Float] {
        guard radius > 0, values.count > 1 else { return values }
        func pass(_ v: [Float]) -> [Float] {
            let n = v.count
            var out = [Float](repeating: 0, count: n)
            let window = Float(2 * radius + 1)
            var sum: Float = 0
            for k in -radius ... radius { sum += v[((k % n) + n) % n] }
            for i in 0 ..< n {
                out[i] = sum / window
                sum += v[(i + radius + 1) % n] - v[((i - radius) % n + n) % n]
            }
            return out
        }
        return pass(pass(values))
    }
}
