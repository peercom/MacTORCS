// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd
import TORCSTrack

/// Pit garages along the pit lane, from the track's pit model.
///
/// The physics model already places every stall — `TrackPits.positions` is
/// parity-verified against the original — so the buildings go where the
/// cars stop. Each stall gets one garage: a box against the pit lane's
/// outer edge, one stall long, with a roller door on the lane side, brick
/// walls and a concrete roof. It is deliberately plain: the original
/// circuits have no pit buildings at all, and a row of garages that reads
/// as a pit complex is the whole of the ambition here.
public enum PitGeneration {
    public struct Parameters: Sendable, Equatable {
        /// Metres the garage extends away from the lane.
        public var depth: Float = 7
        public var height: Float = 4.2
        /// Height of the roller door on the lane side; brick above it.
        public var doorHeight: Float = 3.2
        /// Gap between neighbouring garages, in metres.
        public var gap: Float = 0.3
        public init() {}
    }

    public struct Garage: Sendable, Equatable {
        /// The four floor corners: lane-side left, lane-side right, back
        /// right, back left, in world space.
        public var floor: [SIMD3<Float>]
    }

    /// Material name → geometry, as the road generator groups its output.
    public static func garages(_ geometry: TrackGeometry, pits: TrackPits,
                               parameters: Parameters = .init()) -> [(material: String, geometry: GeneratedGeometry)] {
        guard pits.type != .none, let side = pits.side, pits.stallLength > 0 else { return [] }
        var brick = GeneratedGeometry(), door = GeneratedGeometry(), roof = GeneratedGeometry()
        for garage in footprints(geometry, pits: pits, parameters: parameters) {
            build(garage, parameters: parameters, brick: &brick, door: &door, roof: &roof)
        }
        _ = side
        return [("brick", brick), ("painted-steel", door), ("concrete", roof)].filter { !$0.1.isEmpty }
    }

    /// Where each garage stands: against the outer edge of the pit side.
    ///
    /// Built in world space from the stall's centre: the outer edge point
    /// beside it, the track tangent there, and the outward direction across
    /// the strip. Working from one centre rather than two ends keeps a stall
    /// that straddles a segment join at its full length.
    public static func footprints(_ geometry: TrackGeometry, pits: TrackPits,
                                  parameters: Parameters = .init()) -> [Garage] {
        guard let side = pits.side else { return [] }
        var garages: [Garage] = []
        let half = (pits.stallLength - parameters.gap) / 2
        for stall in pits.positions where geometry.segments.indices.contains(stall.segment) {
            let main = geometry.segments[stall.segment]
            let (outer, outerIsZero) = RoadGeneration.outerEdge(geometry, main: stall.segment, side: side)
            // The pit model stores toStart in metres even on curves; the
            // geometry queries take the segment parameter.
            let metres = min(max(stall.toStart, 0), max(main.length, 0.01))
            let s = main.curve == .straight || main.radius <= 0 ? metres : metres / main.radius
            let width = geometry.width(segment: outer, toStart: s)
            let edgeLocal = TrackLocalPosition(segment: outer, toStart: s, toRight: outerIsZero ? 0 : width)
            let innerLocal = TrackLocalPosition(segment: outer, toStart: s,
                                                toRight: outerIsZero ? min(width, 0.5) : max(0, width - 0.5))
            let edge = geometry.localToGlobal(edgeLocal), inner = geometry.localToGlobal(innerLocal)
            var outward = edge - inner
            let outwardLength = simd_length(outward)
            let z = geometry.height(edgeLocal)
            guard outwardLength > 1e-5, z.isFinite else { continue }
            outward /= outwardLength
            // Tangent along the lane: perpendicular to outward, oriented with
            // the track's direction of travel.
            let heading = geometry.tangent(TrackLocalPosition(segment: stall.segment, toStart: s, toRight: 0))
            var tangent = SIMD2(cos(heading), sin(heading))
            tangent -= outward * simd_dot(tangent, outward)
            let tangentLength = simd_length(tangent)
            guard tangentLength > 1e-5 else { continue }
            tangent /= tangentLength
            let laneA = SIMD3(edge.x - tangent.x * half, edge.y - tangent.y * half, z)
            let laneB = SIMD3(edge.x + tangent.x * half, edge.y + tangent.y * half, z)
            let back = SIMD3(outward.x, outward.y, 0) * parameters.depth
            garages.append(Garage(floor: [laneA, laneB, laneB + back, laneA + back]))
        }
        return garages
    }

    /// One box: four walls, a door band on the lane side, a flat roof.
    static func build(_ garage: Garage, parameters p: Parameters,
                      brick: inout GeneratedGeometry, door: inout GeneratedGeometry, roof: inout GeneratedGeometry) {
        let f = garage.floor
        let up = SIMD3<Float>(0, 0, 1)
        // Walls, each as a quad with metre UVs; the lane wall is split into
        // the door and the brick lintel above it.
        func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>,
                  normal: SIMD3<Float>, into out: inout GeneratedGeometry) {
            let base = UInt32(out.positions.count)
            let u = simd_length(b - a), v = simd_length(d - a)
            out.positions += [a, b, c, d]
            out.normals += [normal, normal, normal, normal]
            out.uv0 += [SIMD2(0, 0), SIMD2(u, 0), SIMD2(u, v), SIMD2(0, v)]
            out.indices += [base, base + 1, base + 2, base, base + 2, base + 3]
            RoadGeneration.orient(&out, from: base)
        }
        // Every wall faces away from the box's centre; the orient pass then
        // winds it to match, so no wall can face inward whichever side of
        // the track the pits are on.
        let centre = (f[0] + f[1] + f[2] + f[3]) / 4
        func wall(_ a: SIMD3<Float>, _ b: SIMD3<Float>, from z0: Float, to z1: Float, into out: inout GeneratedGeometry) {
            let middle = (a + b) / 2
            var normal = SIMD3(middle.x - centre.x, middle.y - centre.y, 0)
            let l = simd_length(normal)
            normal = l > 1e-6 ? normal / l : SIMD3(1, 0, 0)
            quad(a + up * z0, b + up * z0, b + up * z1, a + up * z1, normal: normal, into: &out)
        }
        // Lane side: door then lintel.
        wall(f[0], f[1], from: 0, to: p.doorHeight, into: &door)
        wall(f[0], f[1], from: p.doorHeight, to: p.height, into: &brick)
        // Sides and back.
        wall(f[1], f[2], from: 0, to: p.height, into: &brick)
        wall(f[2], f[3], from: 0, to: p.height, into: &brick)
        wall(f[3], f[0], from: 0, to: p.height, into: &brick)
        // Roof.
        quad(f[0] + up * p.height, f[1] + up * p.height, f[2] + up * p.height, f[3] + up * p.height, normal: up, into: &roof)
    }
}
