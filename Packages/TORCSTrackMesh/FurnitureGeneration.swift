// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd
import TORCSTrack

/// Trackside furniture placed from the segment model: tyre walls along the
/// outside of corners, in front of whatever barrier is there.
///
/// A circuit's corners are where cars leave the road, and where every real
/// circuit stacks tyres. The segment model says where the corners are and
/// which side is outside; the rows go against the outer strip's edge for the
/// length of the corner, two tyres high, one tyre deep. Nothing here is
/// collidable — the physics keeps the original barrier — it is dressing.
public enum FurnitureGeneration {
    public struct Parameters: Sendable, Equatable {
        /// Corners tighter than this radius get a tyre wall.
        public var maximumRadius: Float = 120
        /// Corners shorter than this, in metres, are kinks and get none.
        public var minimumLength: Float = 12
        /// Stack height and depth, in metres: two tyres high, one deep.
        public var height: Float = 1.3
        public var depth: Float = 0.65
        /// Longitudinal step of the strip, in metres.
        public var step: Float = 2
        public init() {}
    }

    /// One continuous run of tyre wall.
    public struct Run: Sendable, Equatable {
        public var side: TrackSide
        public var segments: [Int]
    }

    /// The corners that get a wall: runs of same-hand arcs tighter than the
    /// radius limit and longer than the length limit, with the outside side.
    public static func runs(_ geometry: TrackGeometry, parameters: Parameters = .init()) -> [Run] {
        var result: [Run] = []
        var current: [Int] = []
        var hand: TrackCurve = .straight
        func flush() {
            defer { current = []; hand = .straight }
            guard !current.isEmpty else { return }
            let length = current.reduce(Float(0)) { $0 + geometry.segments[$1].length }
            guard length >= parameters.minimumLength else { return }
            // Outside of a right-hander is the left.
            result.append(Run(side: hand == .right ? .left : .right, segments: current))
        }
        for index in geometry.mainSegments {
            let segment = geometry.segments[index]
            let tight = segment.curve != .straight && segment.radius > 0 && segment.radius <= parameters.maximumRadius
            if tight, segment.curve == hand || current.isEmpty {
                hand = segment.curve
                current.append(index)
            } else {
                flush()
                if tight { hand = segment.curve; current = [index] }
            }
        }
        flush()
        return result
    }

    /// The tyre walls as one geometry group for the `tyre-wall` material.
    public static func tyreWalls(_ geometry: TrackGeometry, parameters: Parameters = .init()) -> GeneratedGeometry {
        var out = GeneratedGeometry()
        for run in runs(geometry, parameters: parameters) {
            appendRun(geometry, run: run, parameters: parameters, into: &out)
        }
        return out
    }

    /// The strip along one run: a front face, a top and a back, stepped
    /// along the outer edge like the road generator's barriers.
    static func appendRun(_ geometry: TrackGeometry, run: Run, parameters p: Parameters, into out: inout GeneratedGeometry) {
        let base = UInt32(out.positions.count)
        var rows = 0
        var along: Float = 0
        for (i, main) in run.segments.enumerated() {
            let (outer, outerIsZero) = RoadGeneration.outerEdge(geometry, main: main, side: run.side)
            let segment = geometry.segments[outer]
            let mainSegment = geometry.segments[main]
            let count = max(1, Int((mainSegment.length / p.step).rounded(.up)))
            // Share the row at a join: skip the first row of every segment
            // after the first.
            for row in (i == 0 ? 0 : 1) ... count {
                let fraction = Float(row) / Float(count)
                let s = segment.extent * fraction
                let width = geometry.width(segment: outer, toStart: s)
                let edge = TrackLocalPosition(segment: outer, toStart: s, toRight: outerIsZero ? 0 : width)
                let inward = TrackLocalPosition(segment: outer, toStart: s,
                                                toRight: outerIsZero ? min(width, 0.5) : max(0, width - 0.5))
                let xy = geometry.localToGlobal(edge)
                // Outward from the main road's own lateral axis: the outer
                // strip can be too narrow to take a direction from.
                let mainFraction = min(max(fraction, 0), 1)
                let mainS = mainSegment.extent * mainFraction
                let rightPoint = geometry.localToGlobal(TrackLocalPosition(segment: main, toStart: mainS, toRight: 0))
                let leftPoint = geometry.localToGlobal(TrackLocalPosition(segment: main, toStart: mainS, toRight: 1))
                var outward = run.side == .right ? rightPoint - leftPoint : leftPoint - rightPoint
                let l = simd_length(outward)
                outward = l > 1e-5 ? outward / l : SIMD2(0, 0)
                _ = inward
                let z = geometry.height(edge)
                // Stand just inside the edge so the barrier behind stays visible above.
                let front = SIMD3(xy.x - outward.x * p.depth, xy.y - outward.y * p.depth, z)
                let back = SIMD3(xy.x, xy.y, z)
                let up = SIMD3<Float>(0, 0, p.height)
                let inwardNormal = SIMD3(-outward.x, -outward.y, 0)
                out.positions += [front, front + up, back + up, back]
                out.normals += [inwardNormal, inwardNormal, SIMD3(0, 0, 1), SIMD3(outward.x, outward.y, 0)]
                // Metres along for the tyres to repeat; v up the stack.
                out.uv0 += [SIMD2(along, 0), SIMD2(along, p.height), SIMD2(along, p.height + p.depth), SIMD2(along, 0)]
                out.attributes += Array(repeating: SIMD4<UInt8>(0, 0, 3, 0), count: 4)
                rows += 1
                along += mainSegment.length / Float(count)
            }
        }
        for row in 0 ..< UInt32(max(rows - 1, 0)) {
            let a = base + row * 4, n = a + 4
            for (q, r) in [(0 as UInt32, 1 as UInt32), (1, 2), (2, 3)] {
                out.indices += [a + q, n + q, a + r, a + r, n + q, n + r]
            }
        }
        RoadGeneration.orient(&out, from: base)
    }
}
