// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd
import TORCSTrack

/// Grass clumps along the verges: crossed cutout cards scattered outward from
/// the outermost strip on each hand of the road, in chunks a hundred metres
/// long so the renderer can stop drawing them at distance.
///
/// The terrain is a textured plane; at driver height its edge against the
/// road is the flattest thing in the frame. Cards a few decimetres tall,
/// dense near the road and thinning outward, are what give the verge a
/// surface. Their height comes from the same query the terrain grid uses,
/// so they stand on it.
public enum GrassGeneration {
    public struct Parameters: Sendable, Equatable {
        /// Longitudinal spacing of the scatter rows, in metres.
        public var step: Float = 2.0
        /// How far out from the road's outer edge grass is placed.
        public var reach: Float = 8
        /// Lateral spacing at the road edge, in metres; it doubles by `reach`.
        public var spacing: Float = 2.2
        /// Chunk length along the track, in metres.
        public var chunkLength: Float = 100
        /// The terrain's own sink below the physics surface, so the cards
        /// stand on the drawn ground rather than float above it.
        public var groundOffset: Float = 0.08
        /// A side whose barrier is at least this tall gets no grass: a wall
        /// taller than the clumps hides them from the road, and Aalborg is
        /// walled for the whole lap. Infinity places grass everywhere.
        public var skipBehindBarriersTallerThan: Float = 0.3
        public init() {}
    }

    public struct Chunk: Sendable, Equatable {
        public var geometry: GeneratedGeometry
        public var clumpCount: Int
    }

    public static func chunks(_ geometry: TrackGeometry, parameters: Parameters = .init()) -> [Chunk] {
        var chunks: [Int: (GeneratedGeometry, Int)] = [:]
        var hashState: UInt32 = 0x9E37_79B9
        func random() -> Float {
            hashState = hashState &* 1_664_525 &+ 1_013_904_223
            return Float(hashState >> 8) / Float(1 << 24)
        }

        for main in geometry.mainSegments {
            let segment = geometry.segments[main]
            let rows = max(1, Int((segment.length / parameters.step).rounded(.up)))
            for row in 0 ..< rows {
                let fraction = (Float(row) + 0.5) / Float(rows)
                let along = segment.distanceFromStart + fraction * segment.length
                let chunk = Int(along / parameters.chunkLength)
                for side in [TrackSide.right, .left] {
                    let barrier = side == .right ? segment.rightBarrier : segment.leftBarrier
                    if let barrier, barrier.height >= parameters.skipBehindBarriersTallerThan { continue }
                    let (outer, outerIsZero) = RoadGeneration.outerEdge(geometry, main: main, side: side)
                    let outerSegment = geometry.segments[outer]
                    let s = outerSegment.extent * fraction
                    let width = geometry.width(segment: outer, toStart: s)
                    let edge = TrackLocalPosition(segment: outer, toStart: s, toRight: outerIsZero ? 0 : width)
                    let inward = TrackLocalPosition(segment: outer, toStart: s,
                                                    toRight: outerIsZero ? min(width, 0.5) : max(0, width - 0.5))
                    let edgeXY = geometry.localToGlobal(edge), inwardXY = geometry.localToGlobal(inward)
                    var outward = edgeXY - inwardXY
                    let length = simd_length(outward)
                    guard length > 1e-5 else { continue }
                    outward /= length
                    let edgeHeight = geometry.height(edge)

                    var d: Float = 0.6 + random() * 0.8
                    while d < parameters.reach {
                        let jitter = (random() - 0.5) * parameters.step * 0.9
                        let sideways = SIMD2(-outward.y, outward.x) * jitter
                        let xy = edgeXY + outward * d + sideways
                        // Height from the physics surface as the terrain grid
                        // does, clamped to the road's lateral extent.
                        var height = edgeHeight
                        if let local = try? geometry.globalToLocal(xy, startingAt: main, mode: .main) {
                            var clamped = local
                            let mainWidth = geometry.width(segment: local.segment, toStart: local.toStart)
                            clamped.toRight = min(max(local.toRight, 0), mainWidth)
                            let candidate = geometry.height(clamped)
                            if candidate.isFinite { height = candidate }
                        }
                        let base = SIMD3(xy.x, xy.y, height - parameters.groundOffset + 0.01)
                        var entry = chunks[chunk] ?? (GeneratedGeometry(), 0)
                        appendClump(at: base, yaw: random() * .pi, width: 0.55 + random() * 0.4,
                                    height: 0.28 + random() * 0.2, variant: Int(random() * 4) & 3,
                                    tint: 0.7 + random() * 0.3, into: &entry.0)
                        entry.1 += 1
                        chunks[chunk] = entry
                        // Thin out with distance from the road.
                        d += parameters.spacing * (1 + d / parameters.reach) * (0.7 + random() * 0.6)
                    }
                }
            }
        }
        return chunks.keys.sorted().map { Chunk(geometry: chunks[$0]!.0, clumpCount: chunks[$0]!.1) }
    }

    /// Two crossed quads. UVs pick one of the four atlas quadrants; the
    /// attribute channel carries height for the sway (x), a small sway
    /// amplitude (y), and a tint (w).
    static func appendClump(at base: SIMD3<Float>, yaw: Float, width: Float, height: Float,
                            variant: Int, tint: Float, into out: inout GeneratedGeometry) {
        let u0 = Float(variant % 2) * 0.5, v0 = Float(variant / 2) * 0.5
        for k in 0 ..< 2 {
            let angle = yaw + Float(k) * .pi / 2
            let along = SIMD3(cos(angle), sin(angle), 0) * (width * 0.5)
            let first = UInt32(out.positions.count)
            let normal = simd_normalize(SIMD3(-sin(angle), cos(angle), 0.35))
            let corners: [(SIMD3<Float>, SIMD2<Float>, Float)] = [
                (base - along, SIMD2(u0, v0 + 0.5), 0), (base + along, SIMD2(u0 + 0.5, v0 + 0.5), 0),
                (base + along + SIMD3(0, 0, height), SIMD2(u0 + 0.5, v0), 1),
                (base - along + SIMD3(0, 0, height), SIMD2(u0, v0), 1),
            ]
            for (position, uv, h) in corners {
                out.positions.append(position)
                out.normals.append(normal)
                out.uv0.append(uv)
                out.attributes.append(SIMD4(UInt8(h * 255), 30, 0, UInt8(min(max(tint, 0), 1) * 255)))
            }
            out.indices += [first, first + 1, first + 2, first, first + 2, first + 3]
        }
    }
}
