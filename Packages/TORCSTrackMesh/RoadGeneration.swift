// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd
import TORCSTrack

/// Render geometry for the road, its sides and borders, and the barriers,
/// generated from the physics segment model rather than read from the baked
/// `.acc`.
///
/// The segment model is already parity-verified against upstream — it is what
/// the cars drive on — so a surface generated from it agrees with the physics
/// by construction, at whatever density the renderer wants. The baked mesh
/// was TORCS's own `trackgen` output at 1999 density with 256² textures; this
/// replaces it, and the generated materials replace those.
///
/// Geometry is grouped by surface material name so the renderer can bind one
/// generated material set per group: an entire circuit becomes a handful of
/// draws instead of the thousand-odd batches the `.acc` carried.
public enum RoadGeneration {
    public struct Parameters: Sendable, Equatable {
        /// Longitudinal spacing in metres. Curves are stepped by the angle
        /// that gives this arc length.
        public var step: Float = 1.0
        /// Lateral spans across the main road, enough to carry crown and
        /// banking as a curve rather than a single tilt.
        public var mainSpans: Int = 8
        /// Lateral spans across side and border strips.
        public var sideSpans: Int = 2
        /// Extrude barriers the track marks as pit buildings. Off: the pit
        /// generator builds garages there instead of a solid block the
        /// height and depth of the whole pit complex.
        public var pitBuildings: Bool = false
        /// The group a barrier's surface goes into, by the surface's
        /// material name, where that is not the material name itself: the
        /// renderer names a barrier for the texture its surface declares
        /// when that says what the barrier is.
        public var barrierGroups: [String: String] = [:]
        /// Groups whose set is drawn once up the barrier whatever its
        /// height, with the span of texture coordinate that is once.
        public var fittedBarriers: [String: Float] = [:]
        /// For a fitted group that may be stacked, the height in metres one
        /// tile stands for: a taller barrier takes a whole number of them.
        public var fittedBarrierHeights: [String: Float] = [:]
        /// Groups that keep the picture their surface declares, with the
        /// metres one repeat of it runs along the wall: an advertisement
        /// painted on a pit wall. Such a wall takes the picture as trackgen
        /// laid it, a third to each of the inner face, the top and the
        /// outer face (a fence, the whole of it on its one face).
        public var picturedBarriers: [String: Float] = [:]
        public init() {}
    }

    /// One material's worth of generated surface.
    public struct Group: Sendable, Equatable {
        /// The surface's material name from the track XML, e.g. `asphalt-aa-bw1`
        /// or `curb-aa-bw-r`. The renderer maps it to a generated set the same
        /// way it maps a texture name.
        public var material: String
        public var geometry: GeneratedGeometry
    }

    public struct Road: Sendable, Equatable {
        public var groups: [Group]
        public var vertexCount: Int { groups.reduce(0) { $0 + $1.geometry.positions.count } }
        public var triangleCount: Int { groups.reduce(0) { $0 + $1.geometry.triangleCount } }
    }

    /// Builds the drivable surfaces and the barriers.
    public static func road(_ geometry: TrackGeometry, parameters: Parameters = .init()) -> Road {
        var groups: [String: GeneratedGeometry] = [:]
        let line = RacingLine(geometry)

        for index in geometry.segments.indices {
            let segment = geometry.segments[index]
            let spans = segment.role == .main ? parameters.mainSpans : parameters.sideSpans
            // A border that is a wall stands up: the cars are stopped by it
            // (`TrackWallCollision`), and drawn flat it stopped them unseen.
            if segment.style == .wall, segment.curbHeight > 0,
               segment.role == .leftBorder || segment.role == .rightBorder {
                let group = parameters.barrierGroups[segment.surface.material] ?? segment.surface.material
                appendBorderWall(geometry, segment: index, parameters: parameters,
                                 fit: fit(group, height: segment.curbHeight, parameters: parameters),
                                 picture: parameters.picturedBarriers[group],
                                 into: &groups[group, default: GeneratedGeometry()])
                continue
            }
            appendRibbon(geometry, segment: index, spans: max(1, spans), parameters: parameters, line: line,
                         into: &groups[segment.surface.material, default: GeneratedGeometry()])
        }

        for index in geometry.mainSegments {
            let segment = geometry.segments[index]
            for (side, barrier) in [(TrackSide.right, segment.rightBarrier), (.left, segment.leftBarrier)] {
                guard let barrier, barrier.height > 0 else { continue }
                if barrier.style == .pitBuilding, !parameters.pitBuildings { continue }
                let group = parameters.barrierGroups[barrier.surface.material] ?? barrier.surface.material
                appendBarrier(geometry, main: index, side: side, barrier: barrier, parameters: parameters,
                              fit: fit(group, height: barrier.height, parameters: parameters),
                              picture: parameters.picturedBarriers[group],
                              into: &groups[group, default: GeneratedGeometry()])
            }
        }

        return Road(groups: groups.keys.sorted().map { Group(material: $0, geometry: groups[$0]!) })
    }

    /// Number of longitudinal rows a segment needs at the requested step.
    static func rows(_ segment: TrackSegment, step: Float) -> Int {
        max(1, Int((segment.length / max(step, 0.05)).rounded(.up)))
    }

    /// Distance along the segment as a `toStart` parameter: metres on a
    /// straight, radians on a curve.
    static func toStart(_ segment: TrackSegment, fraction: Float) -> Float {
        segment.extent * fraction
    }

    /// Per-vertex attributes the road shader paints markings from:
    /// x lateral position across the segment (0 = right edge, 255 = left),
    /// y segment width in eighths of a metre, z role (0 main, 1 side,
    /// 2 border), w the racing line's lateral position on the same scale as
    /// x, for the rubber. Width and lateral together give metres from either
    /// edge, which is what an edge line or a centre dash is defined in.
    public static func attributes(toRight: Float, width: Float, role: TrackRole, line: Float = 0.5) -> SIMD4<UInt8> {
        let lateral = width > 0 ? toRight / width : 0
        let roleCode: UInt8 = role == .main ? 0 : (role == .leftBorder || role == .rightBorder ? 2 : 1)
        return SIMD4(UInt8(min(max(lateral, 0), 1) * 255 + 0.5),
                     UInt8(min(max(width * 8, 0), 255) + 0.5), roleCode,
                     UInt8(min(max(line, 0), 1) * 255 + 0.5))
    }

    /// One segment as a grid of `rows` × `spans` quads, welded within itself.
    static func appendRibbon(_ geometry: TrackGeometry, segment index: Int, spans: Int,
                             parameters: Parameters, line: RacingLine, into out: inout GeneratedGeometry) {
        let segment = geometry.segments[index]
        let rowCount = rows(segment, step: parameters.step)
        let base = UInt32(out.positions.count)
        for row in 0 ... rowCount {
            let fraction = Float(row) / Float(rowCount)
            let s = toStart(segment, fraction: fraction)
            let width = geometry.width(segment: index, toStart: s)
            // Metres along the circuit, for tiling.
            let along = segment.distanceFromStart + fraction * segment.length
            let lineLateral = line.lateral(at: along)
            for span in 0 ... spans {
                let toRight = width * Float(span) / Float(spans)
                let local = TrackLocalPosition(segment: index, toStart: s, toRight: toRight)
                let xy = geometry.localToGlobal(local)
                let z = geometry.height(local)
                out.positions.append(SIMD3(xy.x, xy.y, z))
                out.normals.append(geometry.surfaceNormal(local))
                out.uv0.append(SIMD2(along, toRight))
                out.attributes.append(attributes(toRight: toRight, width: width, role: segment.role, line: lineLateral))
            }
        }
        let stride = UInt32(spans + 1)
        for row in 0 ..< UInt32(rowCount) {
            for span in 0 ..< UInt32(spans) {
                let a = base + row * stride + span, b = a + 1
                let c = a + stride, d = c + 1
                out.indices.append(contentsOf: [a, b, c, b, d, c])
            }
        }
        // Winding derived from the surface normals rather than reasoned: the
        // first version reasoned "forward then left" and produced a road that
        // was culled from every camera on it. The terrain generator learned
        // the same lesson.
        orient(&out, from: base)
    }

    /// The span of texture coordinate a fitted group's set takes up a
    /// barrier of this height, or nil for a set laid in metres.
    static func fit(_ group: String, height: Float, parameters: Parameters) -> Float? {
        guard let tile = parameters.fittedBarriers[group] else { return nil }
        if let each = parameters.fittedBarrierHeights[group], each > 0 {
            return tile * max((height / each).rounded(), 1)
        }
        return tile
    }

    /// Texture coordinates for the four corners of a wall's section (inner
    /// foot, inner top, outer top, outer foot) at `along` metres round the
    /// circuit.
    ///
    /// A picture is laid as trackgen laid it, so the artwork made for it
    /// reads: a third up the inner face, a third across the top, a third
    /// down the outer face, and along the wall from right to left on the
    /// right of the track, so that lettering runs forwards seen from the road.
    public static func wallCoordinates(along: Float, height: Float, thickness: Float, side: TrackSide,
                                fit: Float?, picture: Float?, fence: Bool = false) -> [SIMD2<Float>] {
        if let picture, picture > 0 {
            let u = (side == .right ? -along : along) / picture
            return fence ? [SIMD2(u, 0), SIMD2(u, 1), SIMD2(u, 1), SIMD2(u, 0)]
                         : [SIMD2(u, 0), SIMD2(u, 1.0 / 3), SIMD2(u, 2.0 / 3), SIMD2(u, 1)]
        }
        // Metres up the wall; or, for a set drawn once up it, the whole
        // tile from foot to top, and its top edge along the top.
        let top = fit ?? height
        return [SIMD2(along, 0), SIMD2(along, top), SIMD2(along, fit ?? (height + thickness)), SIMD2(along, 0)]
    }

    /// A border that is a wall, as the three strips of a barrier: the face
    /// to the road, the top across the border's own width, and the back.
    static func appendBorderWall(_ geometry: TrackGeometry, segment index: Int, parameters: Parameters,
                                 fit: Float? = nil, picture: Float? = nil, into out: inout GeneratedGeometry) {
        let segment = geometry.segments[index]
        let main = geometry.segments[segment.mainIndex]
        let side: TrackSide = segment.role == .rightBorder ? .right : .left
        let rowCount = rows(main, step: parameters.step)
        let base = UInt32(out.positions.count)
        for row in 0 ... rowCount {
            let fraction = Float(row) / Float(rowCount)
            let s = toStart(segment, fraction: fraction)
            let width = geometry.width(segment: index, toStart: s)
            // A right-hand strip joins the road at its `toRight == width` edge.
            let inner = TrackLocalPosition(segment: index, toStart: s, toRight: side == .right ? width : 0)
            let outer = TrackLocalPosition(segment: index, toStart: s, toRight: side == .right ? 0 : width)
            let innerXY = geometry.localToGlobal(inner), outerXY = geometry.localToGlobal(outer)
            // The ground under the wall: only a curb's height is in the surface.
            let innerZ = geometry.height(inner), outerZ = geometry.height(outer)
            var outward = outerXY - innerXY
            let length = simd_length(outward)
            outward = length > 1e-5 ? outward / length : SIMD2(0, 0)
            let along = main.distanceFromStart + fraction * main.length
            out.positions.append(contentsOf: [SIMD3(innerXY.x, innerXY.y, innerZ), SIMD3(innerXY.x, innerXY.y, innerZ + segment.curbHeight),
                                              SIMD3(outerXY.x, outerXY.y, outerZ + segment.curbHeight), SIMD3(outerXY.x, outerXY.y, outerZ)])
            out.normals.append(contentsOf: [SIMD3(-outward.x, -outward.y, 0), SIMD3(-outward.x, -outward.y, 0),
                                            SIMD3(0, 0, 1), SIMD3(outward.x, outward.y, 0)])
            out.uv0.append(contentsOf: wallCoordinates(along: along, height: segment.curbHeight, thickness: width,
                                                       side: side, fit: fit, picture: picture))
            out.attributes.append(contentsOf: Array(repeating: SIMD4<UInt8>(0, 0, 3, 0), count: 4))
        }
        appendWallStrips(rows: rowCount, base: base, into: &out)
    }

    /// The triangles of a wall whose sections are four vertices each.
    static func appendWallStrips(rows rowCount: Int, base: UInt32, into out: inout GeneratedGeometry) {
        for row in 0 ..< UInt32(rowCount) {
            let a = base + row * 4, n = a + 4
            // Inner face, top, outer face. Winding is fixed up below by the
            // normals, so the order here only needs to be consistent.
            for (p, q) in [(0 as UInt32, 1 as UInt32), (1, 2), (2, 3)] {
                out.indices.append(contentsOf: [a + p, n + p, a + q, a + q, n + p, n + q])
            }
        }
        orient(&out, from: base)
    }

    /// The outermost segment on one hand of a main segment, and which of its
    /// lateral edges faces away from the road.
    static func outerEdge(_ geometry: TrackGeometry, main: Int, side: TrackSide) -> (segment: Int, outerToRightIsZero: Bool) {
        var current = main
        var guardCount = 0
        while guardCount < 8,
              let next = side == .right ? geometry.segments[current].right : geometry.segments[current].left,
              geometry.segments.indices.contains(next) {
            current = next
            guardCount += 1
        }
        // Right-hand strips attach at their toRight == width edge, so their
        // outer edge is toRight == 0; left-hand strips are the mirror.
        return (current, side == .right)
    }

    /// A wall or fence as three strips: outer face, top, inner face. The
    /// `toStart` parameter of the outer segment is walked with the main
    /// segment's row count so the barrier and the road it bounds share steps.
    static func appendBarrier(_ geometry: TrackGeometry, main: Int, side: TrackSide, barrier: TrackBarrier,
                              parameters: Parameters, fit: Float? = nil, picture: Float? = nil,
                              into out: inout GeneratedGeometry) {
        let (outer, outerIsZero) = outerEdge(geometry, main: main, side: side)
        let segment = geometry.segments[outer]
        let rowCount = rows(geometry.segments[main], step: parameters.step)
        let base = UInt32(out.positions.count)
        // Fences are drawn as thin walls for now; a chain-link cutout is a
        // material, not a geometry, decision.
        let thickness = max(barrier.width, 0.05)
        for row in 0 ... rowCount {
            let fraction = Float(row) / Float(rowCount)
            let s = toStart(segment, fraction: fraction)
            let width = geometry.width(segment: outer, toStart: s)
            let edgeToRight: Float = outerIsZero ? 0 : width
            let edge = TrackLocalPosition(segment: outer, toStart: s, toRight: edgeToRight)
            let xy = geometry.localToGlobal(edge)
            let z = geometry.height(edge)
            // Outward: away from the road across the strip's width.
            let inward = TrackLocalPosition(segment: outer, toStart: s, toRight: outerIsZero ? min(width, 0.5) : max(0, width - 0.5))
            let inwardXY = geometry.localToGlobal(inward)
            var outward = xy - inwardXY
            let length = simd_length(outward)
            outward = length > 1e-5 ? outward / length : SIMD2(0, 0)
            let along = geometry.segments[main].distanceFromStart + fraction * geometry.segments[main].length
            let innerFoot = SIMD3(xy.x, xy.y, z)
            let innerTop = SIMD3(xy.x, xy.y, z + barrier.height)
            let outerTop = SIMD3(xy.x + outward.x * thickness, xy.y + outward.y * thickness, z + barrier.height)
            let outerFoot = SIMD3(xy.x + outward.x * thickness, xy.y + outward.y * thickness, z)
            let inwardNormal = SIMD3(-outward.x, -outward.y, 0)
            let outwardNormal = SIMD3(outward.x, outward.y, 0)
            // Four vertices per row, in the order inner foot, inner top, outer top, outer foot.
            out.positions.append(contentsOf: [innerFoot, innerTop, outerTop, outerFoot])
            out.normals.append(contentsOf: [inwardNormal, inwardNormal, SIMD3(0, 0, 1), outwardNormal])
            out.uv0.append(contentsOf: wallCoordinates(along: along, height: barrier.height, thickness: thickness,
                                                       side: side, fit: fit, picture: picture,
                                                       fence: barrier.style == .fence))
            out.attributes.append(contentsOf: Array(repeating: SIMD4<UInt8>(0, 0, 3, 0), count: 4))
        }
        appendWallStrips(rows: rowCount, base: base, into: &out)
    }

    /// Makes each triangle's winding agree with its vertices' stored normals.
    /// Cheaper to derive than to reason per strip, and immune to the mirror
    /// between the two hands of the track.
    static func orient(_ out: inout GeneratedGeometry, from base: UInt32) {
        var i = out.indices.firstIndex(where: { $0 >= base }) ?? out.indices.count
        while i + 2 < out.indices.count {
            let a = Int(out.indices[i]), b = Int(out.indices[i + 1]), c = Int(out.indices[i + 2])
            let face = simd_cross(out.positions[b] - out.positions[a], out.positions[c] - out.positions[a])
            let stored = out.normals[a] + out.normals[b] + out.normals[c]
            if simd_dot(face, stored) < 0 { out.indices.swapAt(i + 1, i + 2) }
            i += 3
        }
    }
}
