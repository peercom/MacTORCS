// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd

/// Loop subdivision with creases, for upgrading a low-polygon car in place.
///
/// The original car is 4,032 vertices: its wheel arches are octagons and its
/// roof line a handful of facets, and no material makes that read as a
/// modern model. Subdividing rounds the silhouette and gives the specular
/// highlights a surface to run over, while the panel edges the artist made
/// sharp stay sharp: any edge whose dihedral angle exceeds `creaseAngle`
/// is a crease and subdivides as a curve in its own right, and a boundary
/// edge — the border of a panel that meets another node — stays put.
///
/// Positions are subdivided on the welded topology, so the surface is
/// smooth across the duplicated vertices AC files carry at every texture
/// seam; texture coordinates are interpolated per face corner, so the seams
/// themselves are preserved. Normals are recomputed from the finer surface,
/// smoothed only across faces within the crease angle.
public enum MeshSubdivision {
    public struct Mesh {
        public var positions: [SIMD3<Float>]
        public var normals: [SIMD3<Float>]
        public var uv0: [SIMD2<Float>]
        public var uv1: [SIMD2<Float>]
        public var indices: [UInt32]
        public init(positions: [SIMD3<Float>], normals: [SIMD3<Float>], uv0: [SIMD2<Float>], uv1: [SIMD2<Float>], indices: [UInt32]) {
            self.positions = positions; self.normals = normals; self.uv0 = uv0; self.uv1 = uv1; self.indices = indices
        }
        public var triangleCount: Int { indices.count / 3 }
    }

    /// One face corner: its welded vertex and its own attributes, and the
    /// input mesh its face came from.
    struct Corner {
        var vertex: Int
        var uv0: SIMD2<Float>
        var uv1: SIMD2<Float>
        var group: Int
    }

    struct Edge: Hashable {
        let a: Int, b: Int
        init(_ x: Int, _ y: Int) { a = min(x, y); b = max(x, y) }
    }

    /// Subdivides `levels` times. `creaseAngle` in radians.
    public static func loop(_ mesh: Mesh, levels: Int, creaseAngle: Float = 35 * .pi / 180) -> Mesh {
        loop(group: [mesh], levels: levels, creaseAngle: creaseAngle)[0]
    }

    /// Subdivides several meshes as one surface, welded across them, and
    /// returns them separately. A car's panels are separate nodes that share
    /// their outlines; subdivided apart, each outline rounds by its own
    /// rule and the panels drift into gaps. Welded together, the join
    /// between two panels is an ordinary edge — a crease if they meet at an
    /// angle, smooth if they are one surface — and stays closed.
    public static func loop(group meshes: [Mesh], levels: Int, creaseAngle: Float = 35 * .pi / 180) -> [Mesh] {
        guard levels > 0, meshes.contains(where: { $0.indices.count >= 3 }) else { return meshes }
        var welded: [SIMD3<Int32>: Int] = [:]
        var vertices: [SIMD3<Float>] = []
        var faces: [[Corner]] = []
        for (group, mesh) in meshes.enumerated() {
            var corners: [Corner] = []
            corners.reserveCapacity(mesh.indices.count)
            for index in mesh.indices {
                let i = Int(index)
                let p = mesh.positions[i]
                let key = SIMD3<Int32>(Int32((p.x * 2000).rounded()), Int32((p.y * 2000).rounded()), Int32((p.z * 2000).rounded()))
                let v: Int
                if let existing = welded[key] { v = existing } else { v = vertices.count; vertices.append(p); welded[key] = v }
                corners.append(Corner(vertex: v, uv0: i < mesh.uv0.count ? mesh.uv0[i] : .zero,
                                      uv1: i < mesh.uv1.count ? mesh.uv1[i] : .zero, group: group))
            }
            // Drop degenerate faces that welding produced.
            for f in stride(from: 0, to: corners.count - 2, by: 3) {
                let c = [corners[f], corners[f + 1], corners[f + 2]]
                if c[0].vertex != c[1].vertex, c[1].vertex != c[2].vertex, c[0].vertex != c[2].vertex { faces.append(c) }
            }
        }
        guard !faces.isEmpty else { return meshes }

        // Creases from the original dihedral angles; they persist through
        // every level as the child edges of crease edges. Corners — where
        // a boundary turns sharply — stay fixed.
        var creases = Set<Edge>()
        var corners = Set<Int>()
        do {
            var facesByEdge: [Edge: [Int]] = [:]
            for (fi, f) in faces.enumerated() {
                for k in 0 ..< 3 { facesByEdge[Edge(f[k].vertex, f[(k + 1) % 3].vertex), default: []].append(fi) }
            }
            let normals = faces.map { faceNormal(vertices, $0) }
            let cosine = cos(creaseAngle)
            var boundaryNeighbours: [Int: [Int]] = [:]
            for (edge, list) in facesByEdge {
                if list.count != 2 {
                    creases.insert(edge)
                    boundaryNeighbours[edge.a, default: []].append(edge.b)
                    boundaryNeighbours[edge.b, default: []].append(edge.a)
                    continue
                }
                if simd_dot(normals[list[0]], normals[list[1]]) < cosine { creases.insert(edge) }
            }
            for (v, list) in boundaryNeighbours where list.count == 2 {
                let a = simd_normalize(vertices[list[0]] - vertices[v]), b = simd_normalize(vertices[list[1]] - vertices[v])
                // Straight through is a dot of −1; a turn of more than 60° is a corner.
                if simd_dot(a, b) > -0.5 { corners.insert(v) }
            }
        }

        for _ in 0 ..< levels {
            (vertices, faces, creases) = subdivideOnce(vertices, faces, creases, corners)
        }
        return assemble(vertices, faces, groups: meshes.count, creaseAngle: creaseAngle)
    }

    static func faceNormal(_ v: [SIMD3<Float>], _ f: [Corner]) -> SIMD3<Float> {
        let n = simd_cross(v[f[1].vertex] - v[f[0].vertex], v[f[2].vertex] - v[f[0].vertex])
        let l = simd_length(n)
        return l > 1e-12 ? n / l : SIMD3(0, 0, 1)
    }

    static func subdivideOnce(_ vertices: [SIMD3<Float>], _ faces: [[Corner]], _ creases: Set<Edge>, _ corners: Set<Int>)
        -> ([SIMD3<Float>], [[Corner]], Set<Edge>) {
        // Adjacency.
        var neighbours = [Set<Int>](repeating: [], count: vertices.count)
        var facesByEdge: [Edge: [Int]] = [:]
        for (fi, f) in faces.enumerated() {
            for k in 0 ..< 3 {
                let a = f[k].vertex, b = f[(k + 1) % 3].vertex
                neighbours[a].insert(b); neighbours[b].insert(a)
                facesByEdge[Edge(a, b), default: []].append(fi)
            }
        }
        // Even vertices.
        var even = [SIMD3<Float>](repeating: .zero, count: vertices.count)
        for v in vertices.indices {
            let creaseNeighbours = neighbours[v].filter { creases.contains(Edge(v, $0)) }
            if corners.contains(v) {
                even[v] = vertices[v]
            } else if creaseNeighbours.count == 2 {
                // A vertex on a crease curve: the curve's own cubic rule.
                let a = creaseNeighbours[creaseNeighbours.startIndex], b = creaseNeighbours[creaseNeighbours.index(after: creaseNeighbours.startIndex)]
                even[v] = vertices[v] * 0.75 + (vertices[a] + vertices[b]) * 0.125
            } else if creaseNeighbours.count > 2 || neighbours[v].isEmpty {
                even[v] = vertices[v]   // a corner: fixed
            } else {
                let n = Float(neighbours[v].count)
                let beta: Float = n == 3 ? 3.0 / 16.0 : (1 / n) * (5.0 / 8.0 - pow(3.0 / 8.0 + 0.25 * cos(2 * .pi / n), 2))
                var sum = SIMD3<Float>.zero
                for u in neighbours[v] { sum += vertices[u] }
                even[v] = vertices[v] * (1 - n * beta) + sum * beta
            }
        }
        // Odd vertices, one per edge.
        var odd: [Edge: Int] = [:]
        var out = even
        var newCreases = Set<Edge>()
        for (edge, list) in facesByEdge {
            let a = vertices[edge.a], b = vertices[edge.b]
            var p: SIMD3<Float>
            if creases.contains(edge) || list.count != 2 {
                p = (a + b) * 0.5
            } else {
                // The two opposite corners.
                var opposite = SIMD3<Float>.zero
                for fi in list {
                    for c in faces[fi] where c.vertex != edge.a && c.vertex != edge.b { opposite += vertices[c.vertex] }
                }
                p = (a + b) * 0.375 + opposite * 0.125
            }
            let index = out.count
            out.append(p)
            odd[edge] = index
            if creases.contains(edge) {
                newCreases.insert(Edge(edge.a, index)); newCreases.insert(Edge(edge.b, index))
            }
        }
        // Four faces per face, corner attributes interpolated per face.
        var newFaces: [[Corner]] = []
        newFaces.reserveCapacity(faces.count * 4)
        for f in faces {
            func mid(_ i: Int, _ j: Int) -> Corner {
                Corner(vertex: odd[Edge(f[i].vertex, f[j].vertex)]!,
                       uv0: (f[i].uv0 + f[j].uv0) * 0.5, uv1: (f[i].uv1 + f[j].uv1) * 0.5, group: f[i].group)
            }
            let m01 = mid(0, 1), m12 = mid(1, 2), m20 = mid(2, 0)
            newFaces.append([f[0], m01, m20])
            newFaces.append([m01, f[1], m12])
            newFaces.append([m20, m12, f[2]])
            newFaces.append([m01, m12, m20])
        }
        return (out, newFaces, newCreases)
    }

    /// Builds the output meshes, one per input group, with recomputed
    /// normals, welding identical corners so the vertex count stays close
    /// to the welded count.
    static func assemble(_ vertices: [SIMD3<Float>], _ faces: [[Corner]], groups: Int, creaseAngle: Float) -> [Mesh] {
        let faceNormals = faces.map { faceNormal(vertices, $0) }
        var incident = [[Int]](repeating: [], count: vertices.count)
        for (fi, f) in faces.enumerated() { for c in f { incident[c.vertex].append(fi) } }
        let cosine = cos(creaseAngle)

        struct Key: Hashable { let v: Int; let n: SIMD3<Int32>; let uv0: SIMD2<Int32>; let uv1: SIMD2<Int32> }
        var lookups = [[Key: UInt32]](repeating: [:], count: groups)
        var out = [Mesh](repeating: Mesh(positions: [], normals: [], uv0: [], uv1: [], indices: []), count: groups)
        for (fi, f) in faces.enumerated() {
            let g = f[0].group
            for c in f {
                // Average the incident faces within the crease angle of this one.
                var n = SIMD3<Float>.zero
                for other in incident[c.vertex] where simd_dot(faceNormals[other], faceNormals[fi]) >= cosine {
                    n += faceNormals[other]
                }
                let l = simd_length(n)
                n = l > 1e-8 ? n / l : faceNormals[fi]
                let key = Key(v: c.vertex,
                              n: SIMD3<Int32>(Int32((n.x * 1000).rounded()), Int32((n.y * 1000).rounded()), Int32((n.z * 1000).rounded())),
                              uv0: SIMD2<Int32>(Int32((c.uv0.x * 8192).rounded()), Int32((c.uv0.y * 8192).rounded())),
                              uv1: SIMD2<Int32>(Int32((c.uv1.x * 8192).rounded()), Int32((c.uv1.y * 8192).rounded())))
                if let existing = lookups[g][key] {
                    out[g].indices.append(existing)
                } else {
                    let index = UInt32(out[g].positions.count)
                    out[g].positions.append(vertices[c.vertex]); out[g].normals.append(n)
                    out[g].uv0.append(c.uv0); out[g].uv1.append(c.uv1)
                    lookups[g][key] = index
                    out[g].indices.append(index)
                }
            }
        }
        return out
    }
}
