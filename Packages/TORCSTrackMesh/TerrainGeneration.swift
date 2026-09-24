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

    /// Generates ground covering the circuit and its margin, as a regular grid.
    ///
    /// The first implementation followed the track outward as a ribbon, which
    /// is wrong in a way that only shows from the air: on the inside of a curve
    /// the outward direction converges, so marching further than the radius
    /// folds the surface through the centre of curvature, and neighbouring
    /// segments' ribbons overlap each other. Aalborg has 12-metre corners
    /// against a 100-metre margin, so every hairpin produced a fan of
    /// degenerate triangles, and degenerate triangles produce garbage normals.
    ///
    /// A grid in world space cannot fold over or self-overlap, whatever the
    /// track does. It pays for that with a seam: the grid does not follow the
    /// road edge exactly, so it is sunk slightly and the road is drawn over it.
    public static func ground(_ geometry: TrackGeometry, parameters: TerrainParameters = .init()) -> GeneratedGeometry {
        let mains = geometry.mainSegments
        guard !mains.isEmpty else { return GeneratedGeometry() }

        var low = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        var centres: [(index: Int, point: SIMD2<Float>, height: Float)] = []
        for index in mains {
            let segment = geometry.segments[index]
            for corner in [segment.startRight, segment.startLeft, segment.endRight, segment.endLeft] {
                low = simd_min(low, SIMD2(corner.x, corner.y))
                high = simd_max(high, SIMD2(corner.x, corner.y))
            }
            let mid = (segment.startRight + segment.endLeft) * 0.5
            centres.append((index, SIMD2(mid.x, mid.y), mid.z))
        }

        let origin = low - parameters.borderMargin
        let extent = (high + parameters.borderMargin) - origin
        // Finer than the declared border step: that value describes the rim,
        // and using it everywhere leaves the ground visibly faceted where it
        // meets the road.
        let step = max(1, min(parameters.borderStep, parameters.trackStep))
        let columns = max(2, Int((extent.x / step).rounded(.up)) + 1)
        let rows = max(2, Int((extent.y / step).rounded(.up)) + 1)
        // A grid this size is a few tens of thousands of triangles; guard
        // against a pathological track turning it into millions.
        guard columns * rows <= 400_000 else { return GeneratedGeometry() }

        /// Nearest main segment by midpoint, used as the search hint the track
        /// queries need and as the fallback height when the query fails.
        func nearest(_ point: SIMD2<Float>) -> (index: Int, height: Float) {
            var best = centres[0], bestDistance = Float.greatestFiniteMagnitude
            for candidate in centres {
                let d = simd_length_squared(candidate.point - point)
                if d < bestDistance { bestDistance = d; best = candidate }
            }
            return (best.index, best.height)
        }

        func distanceOutsideBox(_ p: SIMD2<Float>) -> Float {
            simd_length(simd_max(simd_max(low - p, p - high), SIMD2(0, 0)))
        }

        var result = GeneratedGeometry()
        result.positions.reserveCapacity(columns * rows)
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let xy = origin + SIMD2(Float(column), Float(row)) * step
                let hint = nearest(xy)
                var height = hint.height
                if let local = try? geometry.globalToLocal(xy, startingAt: hint.index, mode: .main) {
                    // Clamp the lateral coordinate to the segment's own extent
                    // before asking for a height: beyond the road the query
                    // extrapolates banking, which diverges with distance.
                    var clamped = local
                    let width = geometry.width(segment: local.segment, toStart: local.toStart)
                    clamped.toRight = min(max(local.toRight, 0), width)
                    let candidate = geometry.height(clamped)
                    if candidate.isFinite { height = candidate }
                }
                let outside = parameters.borderMargin > 0
                    ? min(distanceOutsideBox(xy) / parameters.borderMargin, 1) : 0
                let rise = parameters.borderHeight * outside * outside * (3 - 2 * outside)
                result.positions.append(SIMD3(xy.x, xy.y, height + rise - parameters.depthOffset))
                result.uv0.append(SIMD2(xy.x, xy.y))
            }
        }

        for row in 0 ..< rows - 1 {
            for column in 0 ..< columns - 1 {
                let a = UInt32(row * columns + column), b = a + 1
                let c = UInt32((row + 1) * columns + column), d = c + 1
                result.indices.append(contentsOf: [a, c, b, b, c, d])
            }
        }

        orientUpward(positions: result.positions, indices: &result.indices)
        result.normals = smoothNormals(positions: result.positions, indices: result.indices)
        return result
    }

    /// Retained name for the ground generator. See ``ground(_:parameters:)``.
    public static func apron(_ geometry: TrackGeometry, parameters: TerrainParameters = .init()) -> GeneratedGeometry {
        ground(geometry, parameters: parameters)
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
