// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd
import TORCSTrack

/// Untextured geometry produced by the track mesh generators.
///
/// Deliberately a plain value type with no Metal dependency: these generators
/// are pure functions of the parity-verified track model, which makes them
/// testable without a GPU.
public struct GeneratedGeometry: Sendable, Equatable {
    public var positions: [SIMD3<Float>]
    public var normals: [SIMD3<Float>]
    /// Tiling UVs in metres, so a material's texel density is set by the
    /// material rather than by how the mesh happens to be parameterized.
    public var uv0: [SIMD2<Float>]
    public var indices: [UInt32]

    public init(positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [],
                uv0: [SIMD2<Float>] = [], indices: [UInt32] = []) {
        self.positions = positions
        self.normals = normals
        self.uv0 = uv0
        self.indices = indices
    }

    public var triangleCount: Int { indices.count / 3 }
    public var isEmpty: Bool { positions.isEmpty || indices.isEmpty }
}

/// Parameters from the track XML's `Terrain Generation` section.
///
/// Every TORCS track declares these and the port has never read them: the
/// visible ground came from whatever the baked `.acc` happened to contain, and
/// for Aalborg that is almost nothing. The result is a circuit sitting in a
/// void, which no amount of shading can fix.
public struct TerrainParameters: Sendable, Equatable {
    /// Longitudinal sampling interval along the track.
    public var trackStep: Float
    /// How far the generated ground extends beyond the track's outer edge.
    public var borderMargin: Float
    /// Lateral sampling interval across the margin.
    public var borderStep: Float
    /// Height the terrain's outer rim rises to.
    ///
    /// Measured from the track's overall bounding box, not from the road edge.
    /// Applying it per-side would build an embankment around every straight —
    /// including down the middle of the infield, which is flat on any real
    /// circuit.
    public var borderHeight: Float
    public var surface: String
    /// Sinks the generated apron slightly so authored geometry wins wherever a
    /// track's baked mesh already provides ground.
    ///
    /// Aalborg carries patches of its own grass at almost exactly the apron's
    /// height. Without an offset the two interleave into a patchwork; with it
    /// the generated ground fills only what the original left empty, which is
    /// what it is for.
    public var depthOffset: Float

    public init(trackStep: Float = 10, borderMargin: Float = 100, borderStep: Float = 30,
                borderHeight: Float = 20, surface: String = "grass-aa", depthOffset: Float = 0.08) {
        self.depthOffset = depthOffset
        self.trackStep = max(1, trackStep)
        self.borderMargin = max(0, borderMargin)
        self.borderStep = max(1, borderStep)
        self.borderHeight = borderHeight
        self.surface = surface
    }
}

public enum TerrainGeneration {
    /// Total lateral distance from the main segment's own edge out to the last
    /// side segment on that hand.
    ///
    /// Walks the `right`/`left` links the track builder produced rather than
    /// assuming a fixed number of sides, because tracks differ in how many
    /// side and border strips they declare.
    static func sideWidth(_ geometry: TrackGeometry, segment index: Int,
                          side: TrackSide, toStart: Float) -> Float {
        var total: Float = 0
        var current = index
        var guardCount = 0
        while guardCount < 8 {
            guardCount += 1
            let next = side == .right ? geometry.segments[current].right : geometry.segments[current].left
            guard let next, geometry.segments.indices.contains(next) else { break }
            total += geometry.width(segment: next, toStart: min(toStart, geometry.segments[next].extent))
            current = next
        }
        return total
    }

    /// Generates a terrain apron following the track out to the border margin
    /// on both sides.
    ///
    /// A ribbon rather than a triangulated field. The band the driver actually
    /// sees is the one flanking the circuit, and following the track guarantees
    /// the apron meets the road edge exactly — a general heightfield would have
    /// to be stitched to it, which is where cracks and z-fighting come from.
    ///
    /// Heights come from the parity-verified `height(_:)` query at the track
    /// edge, then rise across the margin on a smoothstep so the join is
    /// tangent-continuous and reads as ground rather than as a wall.
    public static func apron(_ geometry: TrackGeometry, parameters: TerrainParameters = .init()) -> GeneratedGeometry {
        let mains = geometry.segments.indices.filter { geometry.segments[$0].role == .main }
        guard !mains.isEmpty else { return GeneratedGeometry() }

        // Bounding box of the road itself, which is what the rim is measured
        // against.
        var boxLow = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var boxHigh = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        for index in mains {
            for corner in [geometry.segments[index].startRight, geometry.segments[index].startLeft,
                           geometry.segments[index].endRight, geometry.segments[index].endLeft] {
                boxLow = simd_min(boxLow, SIMD2(corner.x, corner.y))
                boxHigh = simd_max(boxHigh, SIMD2(corner.x, corner.y))
            }
        }

        /// Distance a point lies outside the road's bounding box. Zero inside,
        /// which is what keeps the infield flat.
        func distanceOutsideBox(_ p: SIMD2<Float>) -> Float {
            let outside = simd_max(simd_max(boxLow - p, p - boxHigh), SIMD2(0, 0))
            return simd_length(outside)
        }

        let lateralSpans = max(2, Int((parameters.borderMargin / parameters.borderStep).rounded(.up)))
        var result = GeneratedGeometry()
        // One row per longitudinal sample, each holding both sides' vertices.
        var previousRow: [UInt32]? = nil
        var distanceAlong: Float = 0

        for (order, index) in mains.enumerated() {
            let segment = geometry.segments[index]
            let extent = segment.extent
            guard extent > 0, extent.isFinite else { continue }
            // Curved segments measure toStart in radians, so convert the
            // longitudinal step into the segment's own units.
            let metresPerUnit = segment.curve == .straight ? 1 : max(segment.radius, 1e-3)
            let steps = max(1, Int((extent * metresPerUnit / parameters.trackStep).rounded(.up)))
            let isLast = order == mains.count - 1

            for step in 0 ... steps {
                // The next segment emits its own row 0, so stop before the seam
                // to avoid a duplicated row of degenerate triangles.
                if step == steps && !isLast { break }
                let toStart = extent * Float(step) / Float(steps)
                let position = TrackLocalPosition(segment: index, toStart: toStart, mode: .segment)

                var row: [UInt32] = []
                for side in [TrackSide.right, TrackSide.left] {
                    let mainWidth = geometry.width(segment: index, toStart: toStart)
                    let sides = sideWidth(geometry, segment: index, side: side, toStart: toStart)
                    // Lateral coordinate of the outermost track edge, in the
                    // right-origin convention the queries use.
                    let edgeToRight: Float = side == .right ? -sides : mainWidth + sides
                    var edge = position
                    edge.toRight = edgeToRight
                    let edgeWorld = geometry.localToGlobal(edge, origin: .right)
                    let edgeHeight = geometry.height(edge)

                    // Outward direction: away from the track centre.
                    var inner = position
                    inner.toRight = side == .right ? edgeToRight + 1 : edgeToRight - 1
                    let innerWorld = geometry.localToGlobal(inner, origin: .right)
                    var outward = edgeWorld - innerWorld
                    let length = simd_length(outward)
                    outward = length > 1e-5 ? outward / length : SIMD2(1, 0)

                    for span in 0 ... lateralSpans {
                        let fraction = Float(span) / Float(lateralSpans)
                        let distance = fraction * parameters.borderMargin
                        let xy = edgeWorld + outward * distance
                        // Rise only where the apron leaves the circuit's own
                        // footprint. Smoothstep so both the join at the box
                        // edge and the rim itself have zero slope.
                        let outsideFraction = parameters.borderMargin > 0
                            ? min(distanceOutsideBox(xy) / parameters.borderMargin, 1)
                            : 0
                        let rise = parameters.borderHeight * outsideFraction * outsideFraction * (3 - 2 * outsideFraction)
                        result.positions.append(SIMD3(xy.x, xy.y, edgeHeight + rise - parameters.depthOffset))
                        result.uv0.append(SIMD2(distanceAlong, distance))
                        row.append(UInt32(result.positions.count - 1))
                    }
                }

                if let previous = previousRow, previous.count == row.count {
                    let perSide = lateralSpans + 1
                    for side in 0 ..< 2 {
                        let base = side * perSide
                        for span in 0 ..< lateralSpans {
                            let a = previous[base + span], b = previous[base + span + 1]
                            let c = row[base + span], d = row[base + span + 1]
                            // The two sides' lateral directions are mirrored, so
                            // a single winding cannot serve both. Rather than
                            // hand-deriving each, emit either and let
                            // `orientUpward` settle it from the actual geometry.
                            result.indices.append(contentsOf: [a, c, b, b, c, d])
                        }
                    }
                }
                previousRow = row
                distanceAlong += extent * metresPerUnit / Float(steps)
            }
        }

        orientUpward(positions: result.positions, indices: &result.indices)
        result.normals = smoothNormals(positions: result.positions, indices: result.indices)
        return result
    }

    /// Flips any triangle whose geometric normal points below the horizon.
    ///
    /// Terrain faces the sky by definition, so its winding can be derived from
    /// the geometry rather than hand-reasoned per side. The apron's two sides
    /// are mirror images, so their lateral parameterizations have opposite
    /// handedness and no single winding rule covers both — deriving it here
    /// removes a whole class of sign error, and back-face culling can then be
    /// enabled on terrain instead of disabled to hide the problem.
    public static func orientUpward(positions: [SIMD3<Float>], indices: inout [UInt32]) {
        var triangle = 0
        while triangle + 2 < indices.count {
            let i0 = Int(indices[triangle]), i1 = Int(indices[triangle + 1]), i2 = Int(indices[triangle + 2])
            if i0 < positions.count, i1 < positions.count, i2 < positions.count {
                let face = simd_cross(positions[i1] - positions[i0], positions[i2] - positions[i0])
                if face.z < 0 { indices.swapAt(triangle + 1, triangle + 2) }
            }
            triangle += 3
        }
    }

    /// Area-weighted vertex normals. Accumulating the unnormalized cross
    /// product weights each face by twice its area, which is what keeps a long
    /// thin apron triangle from steering the normal as much as a large one.
    public static func smoothNormals(positions: [SIMD3<Float>], indices: [UInt32]) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        var triangle = 0
        while triangle + 2 < indices.count {
            let i0 = Int(indices[triangle]), i1 = Int(indices[triangle + 1]), i2 = Int(indices[triangle + 2])
            triangle += 3
            guard i0 < positions.count, i1 < positions.count, i2 < positions.count else { continue }
            let face = simd_cross(positions[i1] - positions[i0], positions[i2] - positions[i0])
            guard face.x.isFinite, face.y.isFinite, face.z.isFinite else { continue }
            normals[i0] += face; normals[i1] += face; normals[i2] += face
        }
        return normals.map { normal in
            let length = simd_length(normal)
            // Z up: an isolated vertex points at the sky rather than nowhere.
            return length > 1e-8 ? normal / length : SIMD3(0, 0, 1)
        }
    }
}

import TORCSConfiguration

public extension TerrainParameters {
    /// Reads the track XML's `Graphic/Terrain Generation` section.
    ///
    /// Every value falls back to the documented TORCS default, so a track that
    /// omits the section still produces ground rather than nothing.
    init(document: ParameterDocument) {
        let section = document.section("Graphic/Terrain Generation")
        self.init(
            trackStep: section?.number("track step", unit: "m", default: 10) ?? 10,
            borderMargin: section?.number("border margin", unit: "m", default: 100) ?? 100,
            borderStep: section?.number("border step", unit: "m", default: 30) ?? 30,
            borderHeight: section?.number("border height", unit: "m", default: 20) ?? 20,
            surface: section?.string("surface", default: "grass-aa") ?? "grass-aa")
    }
}
