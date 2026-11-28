// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd
import TORCSTrack

/// Pit garages along the pit lane, from the track's pit model.
///
/// The physics model already places every stall — `TrackPits.positions` is
/// parity-verified against the original — so the buildings go where the
/// cars stop. Each stall gets one garage, a stall long, against the pit
/// lane's outer edge. The original circuits have no pit buildings at all.
///
/// A garage was a box: one door the whole length of the stall, fifteen
/// metres of it, brick above and round it. It is now built as one is: its
/// front divided into bays about five metres wide, a blockwork pier between
/// each, a roller door set back between the piers, a band over the doors
/// with the garage's number on a plate, and a roof that comes out over the
/// lane and shades them.
public enum PitGeneration {
    public struct Parameters: Sendable, Equatable {
        /// Metres the garage extends away from the lane.
        public var depth: Float = 7
        public var height: Float = 4.2
        /// Height of the roller doors; the band over them is the rest.
        public var doorHeight: Float = 3.2
        /// Gap between neighbouring garages' footprints, in metres. The
        /// front's end piers, its band and its roof run on across it.
        public var gap: Float = 0.3
        /// The width a bay is made as near to as divides the front evenly.
        public var bay: Float = 5
        /// Width of the pier between two doors.
        public var pier: Float = 0.6
        /// How far the doors stand back from the face of the piers.
        public var recess: Float = 0.25
        /// How far the roof comes out over the lane, and how thick it is.
        public var overhang: Float = 1.2
        public var roofThickness: Float = 0.2
        /// A number plate's width and height: one figure to a plate.
        public var plate: SIMD2<Float> = SIMD2(0.45, 0.6)
        /// One garage in this many has a door part raised; none if zero.
        public var openEvery: Int = 3
        /// How far up its opening a raised door's foot is, 0 to 1.
        public var raised: Float = 0.6
        /// How deep the room behind a raised door is drawn, and how much
        /// its floor rises to the back, as a slope.
        /// How far below its floor a garage's walls go on down.
        public var footing: Float = 0.6
        public var room: Float = 4.5
        public var floorRise: Float = 0.08
        public init() {}
    }

    /// The groups a garage's geometry is made in, in the order `garages`
    /// returns them: the renderer binds a generated set to each by name.
    public static let materials = ["blockwork", "roller-door", "fascia", "numbers", "roofing", "interior"]

    /// The bay of a garage whose door is part raised, or nil if all its
    /// doors are down: every `openEvery`th garage, and not the same bay
    /// each time.
    public static func raisedBay(number: Int, bays: Int, parameters: Parameters = .init()) -> Int? {
        guard parameters.openEvery > 0, bays > 0, number % parameters.openEvery == 1 % parameters.openEvery else { return nil }
        return (number / parameters.openEvery) % bays
    }

    /// How many bays a front this long is divided into.
    public static func bays(length: Float, parameters: Parameters = .init()) -> Int {
        max(1, Int((length / max(parameters.bay, 0.5)).rounded()))
    }

    public struct Garage: Sendable, Equatable {
        /// The four floor corners: lane-side left, lane-side right, back
        /// right, back left, in world space.
        public var floor: [SIMD3<Float>]
        public init(floor: [SIMD3<Float>]) { self.floor = floor }
    }

    /// Material name → geometry, as the road generator groups its output.
    public static func garages(_ geometry: TrackGeometry, pits: TrackPits,
                               parameters: Parameters = .init()) -> [(material: String, geometry: GeneratedGeometry)] {
        guard pits.type != .none, pits.side != nil, pits.stallLength > 0 else { return [] }
        var groups = [GeneratedGeometry](repeating: GeneratedGeometry(), count: materials.count)
        for (index, garage) in footprints(geometry, pits: pits, parameters: parameters).enumerated() {
            build(garage, number: index + 1, parameters: parameters, into: &groups)
        }
        return zip(materials, groups).filter { !$0.1.isEmpty }.map { (material: $0.0, geometry: $0.1) }
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

    /// One garage. `groups` is in the order of `materials`.
    ///
    /// The front is built in its own frame: `along` from the garage's left
    /// end as it is seen from the lane, `out` toward the lane from the
    /// face of the piers, and up. Texture coordinates are metres along and
    /// up, counted from the garage's left end and the floor, so a door's
    /// laths count up from the ground and the band's panels run on from
    /// pier to pier; the band is one tile up whatever its height, and a
    /// number plate shows its own figure's part of the sheet.
    public static func build(_ garage: Garage, number: Int, parameters p: Parameters, into groups: inout [GeneratedGeometry]) {
        let f = garage.floor
        let up = SIMD3<Float>(0, 0, 1)
        let blockwork = 0, door = 1, fascia = 2, numbers = 3, roofing = 4, interior = 5
        // Toward the lane, and to the right as the front is looked at.
        var front = SIMD3(f[0].x - f[3].x, f[0].y - f[3].y, 0)
        let frontLength = simd_length(front)
        guard frontLength > 1e-5 else { return }
        front /= frontLength
        let right = simd_cross(up, front)
        // The front's left end, seen from the lane, is whichever lane-side
        // corner lies against `right`.
        let leftEnd = simd_dot(f[1] - f[0], right) > 0 ? f[0] : f[1]
        let length = simd_length(f[1] - f[0])
        func point(_ along: Float, _ out: Float, _ z: Float) -> SIMD3<Float> { leftEnd + right * along + front * out + up * z }
        /// A quad given as four corners in order round it, with a coordinate each.
        func quad(_ group: Int, _ corners: [SIMD3<Float>], _ uvs: [SIMD2<Float>], normal: SIMD3<Float>) {
            let base = UInt32(groups[group].positions.count)
            groups[group].positions += corners
            groups[group].normals += Array(repeating: normal, count: 4)
            groups[group].uv0 += uvs
            groups[group].indices += [base, base + 1, base + 2, base, base + 2, base + 3]
            RoadGeneration.orient(&groups[group], from: base)
        }
        /// An upright face across the front, `out` from the piers' face, in metres along and up.
        func face(_ group: Int, from a: Float, to b: Float, out: Float, z0: Float, z1: Float, v: ClosedRange<Float>? = nil) {
            let v = v ?? z0 ... z1
            quad(group, [point(a, out, z0), point(b, out, z0), point(b, out, z1), point(a, out, z1)],
                 [SIMD2(a, v.lowerBound), SIMD2(b, v.lowerBound), SIMD2(b, v.upperBound), SIMD2(a, v.upperBound)], normal: front)
        }
        /// An upright face running back from the piers' face at one place along the front.
        func reveal(_ group: Int, at along: Float, from near: Float, to far: Float, z0: Float, z1: Float, facing: Float) {
            quad(group, [point(along, near, z0), point(along, far, z0), point(along, far, z1), point(along, near, z1)],
                 [SIMD2(near, z0), SIMD2(far, z0), SIMD2(far, z1), SIMD2(near, z1)], normal: right * facing)
        }
        /// A level face, looking up or down.
        func level(_ group: Int, from a: Float, to b: Float, near: Float, far: Float, z: Float, facing: Float) {
            quad(group, [point(a, near, z), point(b, near, z), point(b, far, z), point(a, far, z)],
                 [SIMD2(a, near), SIMD2(b, near), SIMD2(b, far), SIMD2(a, far)], normal: up * facing)
        }

        // The front runs on past the footprint by half the gap and a little,
        // to meet the next garage's.
        let over = p.gap / 2 + 0.02
        let count = bays(length: length, parameters: p)
        let bay = length / Float(count)
        let recess = max(p.recess, 0), pier = min(max(p.pier, 0.1), bay * 0.6)
        let open = raisedBay(number: number, bays: count, parameters: p)
        var edges: [(left: Float, right: Float)] = []
        for k in 0 ... count {
            let centre = Float(k) * bay
            edges.append((k == 0 ? -over : centre - pier / 2, k == count ? length + over : centre + pier / 2))
        }
        for (k, edge) in edges.enumerated() {
            // The pier's face, and its sides where a door is set back beside it.
            face(blockwork, from: edge.left, to: edge.right, out: 0, z0: -p.footing, z1: p.doorHeight)
            if k > 0 { reveal(blockwork, at: edge.left, from: -recess, to: 0, z0: 0, z1: p.doorHeight, facing: -1) }
            if k < count { reveal(blockwork, at: edge.right, from: -recess, to: 0, z0: 0, z1: p.doorHeight, facing: 1) }
            guard k < count else { continue }
            // The door between this pier and the next, the underside of the
            // band over it, and the sill under it: without one, the ground
            // in the doorway was whatever the terrain is there, and that
            // is grass.
            let next = edges[k + 1].left
            level(blockwork, from: edge.right, to: next, near: -recess, far: 0, z: p.doorHeight, facing: -1)
            level(blockwork, from: edge.right, to: next, near: -recess, far: 0.05, z: 0.03, facing: 1)
            face(blockwork, from: edge.right, to: next, out: 0.05, z0: -p.footing, z1: 0.03)
            guard k == open else {
                face(door, from: edge.right, to: next, out: -recess, z0: 0, z1: p.doorHeight)
                continue
            }
            // A door part raised: what is left of it hangs from the top, and
            // behind it is the garage, its floor, its walls and its ceiling.
            let foot = p.doorHeight * min(max(p.raised, 0), 0.95)
            face(door, from: edge.right, to: next, out: -recess, z0: foot, z1: p.doorHeight)
            let back = -min(max(p.depth - 0.3, recess + 0.5), recess + p.room)
            face(interior, from: edge.right, to: next, out: back, z0: 0, z1: p.doorHeight)
            reveal(interior, at: edge.right, from: back, to: -recess, z0: 0, z1: p.doorHeight, facing: 1)
            reveal(interior, at: next, from: back, to: -recess, z0: 0, z1: p.doorHeight, facing: -1)
            // The floor rises a little to the back. The ground outside is
            // not levelled for the building, and where it climbed behind
            // the lane it came up through a level floor as grass.
            let rise = (-recess - back) * p.floorRise
            quad(interior, [point(edge.right, -recess, 0.03), point(next, -recess, 0.03), point(next, back, 0.03 + rise), point(edge.right, back, 0.03 + rise)],
                 [SIMD2(edge.right, -recess), SIMD2(next, -recess), SIMD2(next, back), SIMD2(edge.right, back)],
                 normal: simd_normalize(up + front * p.floorRise))
            level(interior, from: edge.right, to: next, near: back, far: -recess, z: p.doorHeight, facing: -1)
        }
        // The band over the doors: once up it, whatever its height.
        face(fascia, from: -over, to: length + over, out: 0, z0: p.doorHeight, z1: p.height, v: 0 ... 1)
        // Its number, a figure to a plate, in the middle of the garage and
        // of the band's clear part, between the stripe and the coping.
        let figures = String(max(number, 0)).compactMap { $0.wholeNumberValue }
        let bandHeight = p.height - p.doorHeight
        let plateHeight = min(p.plate.y, bandHeight * 0.62), plateWidth = p.plate.x * plateHeight / max(p.plate.y, 1e-3)
        let foot = p.doorHeight + bandHeight * 0.565 - plateHeight / 2
        let start = length / 2 - plateWidth * Float(figures.count) / 2
        for (i, digit) in figures.enumerated() {
            let a = start + Float(i) * plateWidth, b = a + plateWidth
            let cell = (origin: SIMD2<Float>(Float(digit % 4) / 4, 1 - Float(digit / 4 + 1) / 3), size: SIMD2<Float>(0.25, 1.0 / 3))
            quad(numbers, [point(a, 0.02, foot), point(b, 0.02, foot), point(b, 0.02, foot + plateHeight), point(a, 0.02, foot + plateHeight)],
                 [cell.origin, cell.origin + SIMD2(cell.size.x, 0), cell.origin + cell.size, cell.origin + SIMD2(0, cell.size.y)],
                 normal: front)
        }
        // The roof: out over the lane, its edge and its underside.
        let top = p.height + p.roofThickness
        level(roofing, from: -over, to: length + over, near: -p.depth, far: p.overhang, z: top, facing: 1)
        face(blockwork, from: -over, to: length + over, out: p.overhang, z0: p.height, z1: top)
        level(blockwork, from: -over, to: length + over, near: 0, far: p.overhang, z: p.height, facing: -1)
        // The sides and the back, to the roof's top.
        // They start below the floor: the ground is not levelled for the
        // building, and where it fell away the garage stood in the air.
        reveal(blockwork, at: 0, from: -p.depth, to: 0, z0: -p.footing, z1: top, facing: -1)
        reveal(blockwork, at: length, from: -p.depth, to: 0, z0: -p.footing, z1: top, facing: 1)
        quad(blockwork, [point(0, -p.depth, -p.footing), point(length, -p.depth, -p.footing), point(length, -p.depth, top), point(0, -p.depth, top)],
             [SIMD2(0, -p.footing), SIMD2(length, -p.footing), SIMD2(length, top), SIMD2(0, top)], normal: -front)
    }
}
