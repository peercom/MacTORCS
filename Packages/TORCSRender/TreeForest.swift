// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd
import TORCSAssets
import TORCSTrackMesh

/// Trees recovered from a baked circuit, and solid replacements for them.
///
/// TORCS tracks place trees as pairs of crossed alpha-cutout cards — two
/// planes at right angles, each a pair of triangles cut from a species
/// atlas. Seen from the road they pass; seen from above or at an angle they
/// are visibly two flat sheets, and they were the most dated thing left in
/// the frame once the road was generated. The classic path already carried a
/// recovery of these placements by their exact numerical signatures and a
/// volumetric replacement built from the same atlas; this is that, ported to
/// the new path, where the leaves also cast shadows.
///
/// Recovery keys on the atlas's own u-ranges and the cards' authored
/// heights, so it matches Aalborg's three species exactly and nothing else.
/// Other circuits keep their cards until their signatures are recorded.
public struct TreeForest: Sendable {
    /// One triangle of a tree card, in world space, with float precision —
    /// the packed vertex's half UVs would not distinguish the atlas ranges.
    public struct Face: Sendable, Equatable {
        public var batch: Int
        public var positions: [SIMD3<Float>]
        public var uvs: [SIMD2<Float>]
        public init(batch: Int, positions: [SIMD3<Float>], uvs: [SIMD2<Float>]) {
            self.batch = batch; self.positions = positions; self.uvs = uvs
        }
    }

    public struct Placement: Sendable, Equatable {
        public let family: Int, variant: Int
        /// Batches of the original cards this tree replaces.
        public let batches: [Int]
        /// Unit tree space (x, y in −0.5…0.5, z in 0…1) to world.
        public let transform: simd_float4x4
        public let centre: SIMD3<Float>
        public let height: Float, radius: Float
    }

    public static let textureName = "allborg-trees_n.rgb"

    struct Family {
        let ranges: [SIMD2<Float>]
        let height: Float
        let widths: SIMD2<Float>
        let top: Float
    }
    /// The three Aalborg species by their atlas columns, card heights and
    /// widths. Numerical descriptors, not artwork: the atlas stays the
    /// track's own.
    static let families: [Family] = [
        .init(ranges: [SIMD2(-0.000749199, 0.217693), SIMD2(0.000421695, 0.214337)], height: 14.23514, widths: SIMD2(8.51475, 7.63933), top: 0.582586),
        .init(ranges: [SIMD2(0.213165, 0.449185), SIMD2(0.211359, 0.450712)], height: 18.65, widths: SIMD2(8.51475, 7.63933), top: 0.562273),
        .init(ranges: [SIMD2(0.449736, 0.89474), SIMD2(0.448694, 0.894436)], height: 17.4117, widths: SIMD2(14.38994, 12.91047), top: 0.562273),
    ]

    public let placements: [Placement]
    /// Original batch → placement index, for stripping the cards.
    public let batchPlacement: [Int: Int]

    private struct Edge: Hashable {
        let a, b: SIMD3<Float>
        init(_ a: SIMD3<Float>, _ b: SIMD3<Float>) {
            let ordered = a.x != b.x ? a.x < b.x : (a.y != b.y ? a.y < b.y : a.z < b.z)
            self.a = ordered ? a : b; self.b = ordered ? b : a
        }
    }
    private struct Plane {
        let faces: [Int]
        let centre, up, horizontal: SIMD3<Float>
        let height, width: Float
        let uv: SIMD2<Float>
    }

    public init(faces: [Face]) {
        // Pair triangles sharing an edge into card planes.
        var edges: [Edge: [Int]] = [:]
        for (i, face) in faces.enumerated() where face.positions.count == 3 {
            for k in 0 ..< 3 { edges[Edge(face.positions[k], face.positions[(k + 1) % 3]), default: []].append(i) }
        }
        var planes: [Plane] = [], used = Set<Int>()
        for (i, face) in faces.enumerated() where !used.contains(i) && face.positions.count == 3 {
            var partner: Int?
            for k in 0 ..< 3 {
                let shared = edges[Edge(face.positions[k], face.positions[(k + 1) % 3])] ?? []
                if let j = shared.first(where: { $0 != i && !used.contains($0) }) { partner = j; break }
            }
            guard let j = partner else { continue }
            let points = Array(Set((face.positions + faces[j].positions).map { Quantised($0) })).map(\.value)
            guard points.count == 4 else { continue }
            let sorted = points.sorted { a, b in a.x != b.x ? a.x < b.x : (a.y != b.y ? a.y < b.y : a.z < b.z) }
            let centre = sorted.reduce(SIMD3<Float>.zero, +) / 4
            var counts: [Edge: Int] = [:]
            for f in [i, j] { for k in 0 ..< 3 { counts[Edge(faces[f].positions[k], faces[f].positions[(k + 1) % 3]), default: 0] += 1 } }
            let boundary = counts.filter { $0.value == 1 }.map { $0.key.b - $0.key.a }
            let vertical = boundary.filter { abs($0.z) > simd_length($0) * 0.7 }.map { $0.z < 0 ? -$0 : $0 }
            let horizontal = boundary.filter { abs($0.z) <= simd_length($0) * 0.7 }
            guard boundary.count == 4, vertical.count == 2, horizontal.count == 2 else { continue }
            let v = (vertical[0] + vertical[1]) * 0.5
            let h = horizontal.sorted { a, b in a.x != b.x ? a.x < b.x : (a.y != b.y ? a.y < b.y : a.z < b.z) }[0]
            guard simd_length(v) > 1, simd_length(h) > 1,
                  simd_length(vertical[0] - vertical[1]) < 0.004,
                  abs(simd_length(horizontal[0]) - simd_length(horizontal[1])) < 0.004,
                  abs(simd_dot(simd_normalize(v), simd_normalize(h))) < 0.001,
                  abs(simd_dot(simd_normalize(horizontal[0]), simd_normalize(horizontal[1]))) > 0.9999 else { continue }
            let uv = face.uvs + faces[j].uvs
            planes.append(Plane(faces: [i, j], centre: centre, up: simd_normalize(v), horizontal: simd_normalize(h),
                                height: simd_length(v), width: simd_length(h),
                                uv: SIMD2(uv.map(\.x).min()!, uv.map(\.x).max()!)))
            used.insert(i); used.insert(j)
        }

        // Pair planes sharing a centre at right angles into trees, and match
        // each pair against the species descriptors.
        var paired = Set<Int>(), placements: [Placement] = [], mapping: [Int: Int] = [:]
        for i in planes.indices where !paired.contains(i) {
            let a = planes[i]
            let neighbours = planes.indices.filter { $0 != i && !paired.contains($0) && simd_distance(a.centre, planes[$0].centre) < 0.005 }
            guard neighbours.count == 1, let j = neighbours.first else { continue }
            let b = planes[j]
            guard simd_distance(a.up, b.up) < 0.001, abs(a.height - b.height) < 0.004,
                  abs(simd_dot(a.horizontal, b.horizontal)) < 0.03 else { continue }
            var match: (Int, Int)?
            for (family, descriptor) in Self.families.enumerated() {
                for side in 0 ..< 2 where simd_length(a.uv - descriptor.ranges[side]) < 0.00002
                    && simd_length(b.uv - descriptor.ranges[1 - side]) < 0.00002
                    && abs(a.height - descriptor.height) < 0.01
                    && abs(a.width - descriptor.widths[side]) < 0.004
                    && abs(b.width - descriptor.widths[1 - side]) < 0.004 {
                    match = (family, side)
                }
            }
            guard let (family, side) = match else { continue }
            let main = side == 0 ? a : b, other = side == 0 ? b : a
            let up = simd_normalize(a.up + b.up)
            let right = simd_normalize(main.horizontal - up * simd_dot(main.horizontal, up))
            let forward = simd_cross(up, right)
            let height = (a.height + b.height) * 0.5, centre = (a.centre + b.centre) * 0.5
            let base = centre - up * height * 0.5
            let transform = simd_float4x4(SIMD4(right * main.width, 0), SIMD4(forward * other.width, 0),
                                          SIMD4(up * height, 0), SIMD4(base, 1))
            let batches = (a.faces + b.faces).map { faces[$0].batch }.sorted()
            let index = placements.count
            let widest = max(a.width, b.width)
            placements.append(Placement(family: family, variant: index % 3, batches: batches, transform: transform,
                                        centre: centre, height: height,
                                        radius: sqrt(height * height + widest * widest) * 0.5))
            for batch in batches { mapping[batch] = index }
            paired.insert(i); paired.insert(j)
        }
        self.placements = placements
        batchPlacement = mapping
    }

    /// Hashable wrapper so the four corners of a card can be found from six
    /// triangle vertices without float-equality surprises.
    private struct Quantised: Hashable {
        let key: SIMD3<Int32>
        let value: SIMD3<Float>
        init(_ v: SIMD3<Float>) { value = v; key = SIMD3(Int32(v.x * 1000), Int32(v.y * 1000), Int32(v.z * 1000)) }
        static func == (a: Quantised, b: Quantised) -> Bool { a.key == b.key }
        func hash(into hasher: inout Hasher) { hasher.combine(key) }
    }
}
