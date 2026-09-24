// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd
import TORCSAssets

/// One drawable batch plus the source material state it came from.
///
/// The classic path drove rendering directly from AC/OpenGL material state:
/// four MODULATE texture units, with negative `mapLevel` values secretly
/// meaning "this is a car, reuse unit 1 for a scrolling reflection". None of
/// that survives here. The original state is retained only so physically based
/// material resolution can derive sensible defaults for content that has no
/// authored material set yet.
public struct RenderBatch: Sendable {
    public let mesh: RenderMesh
    public let baseTexture: String?
    /// Needs blending rather than depth-sorted opaque submission.
    public let isTranslucent: Bool
    /// Alpha cutout threshold, or nil for no alpha test. Cutouts also need a
    /// coverage-preserving mip chain, which the classic path did not build.
    public let alphaTestThreshold: Float?
    public let culls: Bool
    /// The driver subtree, hidden in cockpit views.
    public let isDriver: Bool
    public let sourceMaterial: ACRenderState
    /// Physically based stand-in derived from the original material state.
    public let material: ResolvedMaterial
}

/// Flattened scene ready for the modern render path.
public struct RenderScene: Sendable {
    public let batches: [RenderBatch]
    public let minimum: SIMD3<Float>, maximum: SIMD3<Float>
    public let warnings: [String]

    public var triangleCount: Int { batches.reduce(0) { $0 + $1.mesh.indices.count / 3 } }
    public var vertexCount: Int { batches.reduce(0) { $0 + $1.mesh.vertices.count } }

    /// Flattens an AC scene graph into packed, tangent-bearing batches.
    ///
    /// Positions stay in each node's local space with the accumulated world
    /// transform kept alongside, which is what lets identical meshes be
    /// instanced later. Bounds are still computed in world space because
    /// culling and shadow cascade fitting need them there.
    ///
    /// This deliberately does not reproduce the classic path's PLIB draw
    /// scheduling or its scene-anchor submission order: ordering in the new path
    /// comes from depth state and explicit opaque/transparent passes, not from
    /// replaying upstream's traversal.
    public init(_ scene: ACScene) throws {
        try scene.validate()

        var children = Array(repeating: [Int](), count: scene.nodes.count)
        for i in scene.nodes.indices where scene.nodes[i].parent >= 0 {
            children[scene.nodes[i].parent].append(i)
        }
        var order: [Int] = [], stack = [0]
        while let i = stack.popLast() {
            order.append(i)
            stack.append(contentsOf: children[i].reversed())
        }
        let driverRoot = order.first { scene.nodes[$0].name == "DRIVER" }

        var transforms: [simd_float4x4] = [], driverFlags: [Bool] = []
        var collected: [Int: RenderBatch] = [:]
        var warnings = Set(scene.warnings ?? [])
        var low = SIMD3<Float>(repeating: .infinity), high = SIMD3<Float>(repeating: -.infinity)

        for (index, node) in scene.nodes.enumerated() {
            let isDriver = index == driverRoot || (node.parent >= 0 && driverFlags[node.parent])
            driverFlags.append(isDriver)

            let parent = node.parent < 0 ? matrix_identity_float4x4 : transforms[node.parent]
            let local = node.kind == 0 ? SceneTransform.matrix(node.matrix) : matrix_identity_float4x4
            let transform = parent * local
            guard SceneTransform.isUsable(transform) else {
                throw ACError.invalid("Scene transform must be finite, affine and nonsingular")
            }
            transforms.append(transform)

            guard let mesh = node.mesh else { continue }
            guard let material = mesh.states[0] else { throw ACError.invalid("Mesh has no base material") }
            let indices = try mesh.triangleIndices()
            if indices.isEmpty { continue }
            if mesh.normals.isEmpty {
                warnings.insert("Geometry without normals uses (0, 0, 1).")
            }

            let count = mesh.vertices.count / 3
            var positions = [SIMD3<Float>](), normals = [SIMD3<Float>](), uv0 = [SIMD2<Float>](), uv1 = [SIMD2<Float>]()
            positions.reserveCapacity(count); normals.reserveCapacity(count)
            for i in 0 ..< count {
                let p = SIMD3(mesh.vertices[i * 3], mesh.vertices[i * 3 + 1], mesh.vertices[i * 3 + 2])
                positions.append(p)
                // A single stored normal applies to the whole mesh, matching
                // the loader's handling of flat-shaded surfaces.
                if mesh.normals.isEmpty {
                    normals.append(SIMD3(0, 0, 1))
                } else {
                    let base = mesh.normals.count == 3 ? 0 : i * 3
                    normals.append(SIMD3(mesh.normals[base], mesh.normals[base + 1], mesh.normals[base + 2]))
                }
                let world = transform * SIMD4(p, 1)
                guard world.x.isFinite, world.y.isFinite, world.z.isFinite else {
                    throw ACError.invalid("Nonfinite world vertex")
                }
                low = simd_min(low, SIMD3(world.x, world.y, world.z))
                high = simd_max(high, SIMD3(world.x, world.y, world.z))
            }
            func layer(_ which: Int) -> [SIMD2<Float>] {
                guard which < mesh.uv.count, !mesh.uv[which].isEmpty else { return [] }
                return (0 ..< count).map { SIMD2(mesh.uv[which][$0 * 2], mesh.uv[which][$0 * 2 + 1]) }
            }
            uv0 = layer(0)
            uv1 = layer(1)

            let render = try RenderMesh.build(positions: positions, normals: normals,
                                              uv0: uv0, uv1: uv1, indices: indices, transform: transform)
            // AC stores diffuse RGBA per vertex; the loader writes the surface
            // material's colour to every vertex of the batch, so the first is
            // representative. Absent colours mean untinted white.
            let diffuse: SIMD4<Float> = mesh.colors.count >= 4
                ? SIMD4(mesh.colors[0], mesh.colors[1], mesh.colors[2], mesh.colors[3])
                : SIMD4(1, 1, 1, 1)

            // AC flags: bit 0 blend, bit 4 alpha test, bit 5 translucent.
            let alphaTested = material.flags & 16 != 0
            collected[index] = RenderBatch(
                mesh: render,
                baseTexture: material.texture,
                isTranslucent: material.flags & 32 != 0 || material.flags & 1 != 0,
                alphaTestThreshold: alphaTested ? material.alphaClamp : nil,
                culls: mesh.cull,
                isDriver: isDriver,
                sourceMaterial: material,
                material: MaterialResolution.resolve(state: material, diffuse: diffuse))
        }

        guard !collected.isEmpty else { throw ACError.invalid("Scene has no drawable triangles") }
        batches = order.compactMap { collected[$0] }
        minimum = low
        maximum = high
        self.warnings = warnings.sorted()
    }
}

enum SceneTransform {
    /// AC stores a column-major 4x4 with translation at indices 12...14.
    static func matrix(_ values: [Float]) -> simd_float4x4 {
        guard values.count == 16 else { return matrix_identity_float4x4 }
        return simd_float4x4(columns: (
            SIMD4(values[0], values[1], values[2], values[3]),
            SIMD4(values[4], values[5], values[6], values[7]),
            SIMD4(values[8], values[9], values[10], values[11]),
            SIMD4(values[12], values[13], values[14], values[15])))
    }

    /// Rejects transforms that would produce unusable geometry: nonfinite
    /// values, a projective last row, or a collapsed basis that has no inverse
    /// and therefore no valid normal transform.
    static func isUsable(_ m: simd_float4x4) -> Bool {
        for column in 0 ..< 4 {
            let c = m[column]
            guard c.x.isFinite, c.y.isFinite, c.z.isFinite, c.w.isFinite else { return false }
        }
        guard abs(simd_determinant(m)) > 1e-12 else { return false }
        return m.columns.0.w == 0 && m.columns.1.w == 0 && m.columns.2.w == 0 && m.columns.3.w == 1
    }
}
