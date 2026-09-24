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
    public init(mesh: RenderMesh, baseTexture: String?, blends: Bool, isDeferred: Bool,
                alphaTestThreshold: Float?, culls: Bool, isDriver: Bool,
                sourceMaterial: ACRenderState, material: ResolvedMaterial, uvInMetres: Bool = false,
                paintsRoadMarkings: Bool = false, swaysInWind: Bool = false,
                detailRange: ClosedRange<Float>? = nil, castsShadow: Bool = true, prepass: Bool = true,
                receivesWeather: Bool = false) {
        self.mesh = mesh
        self.receivesWeather = receivesWeather
        self.uvInMetres = uvInMetres
        self.paintsRoadMarkings = paintsRoadMarkings
        self.swaysInWind = swaysInWind
        self.detailRange = detailRange
        self.castsShadow = castsShadow
        self.prepass = prepass
        self.baseTexture = baseTexture
        self.blends = blends
        self.isDeferred = isDeferred
        self.alphaTestThreshold = alphaTestThreshold
        self.culls = culls
        self.isDriver = isDriver
        self.sourceMaterial = sourceMaterial
        self.material = material
    }

    public let mesh: RenderMesh
    public let baseTexture: String?
    /// Generated geometry authors `uv0` in world metres; the renderer divides
    /// by the bound material's tile size. Baked artwork is in texture space.
    public let uvInMetres: Bool
    /// The road shader paints edge lines, centre dashes, the start line and
    /// rubber from the vertex attributes the road generator wrote.
    public let paintsRoadMarkings: Bool
    /// Foliage: the vertex shader sways it by its height attribute, and the
    /// fragment shader applies the per-leaf tint.
    public let swaysInWind: Bool
    /// Ground: the scene's wetness darkens and glosses it and fills puddles
    /// on its near-horizontal parts.
    public let receivesWeather: Bool
    /// Camera distance to the batch's centre, in metres, within which it is
    /// drawn. Nil draws always. Two batches of the same object with abutting
    /// ranges are a level-of-detail pair.
    public let detailRange: ClosedRange<Float>?
    /// Whether the shadow cascades draw it. A near-detail batch leaves the
    /// casting to its lighter partner.
    public let castsShadow: Bool
    /// Whether the depth prepass draws it. Dense alpha-tested cutouts pay
    /// for their discard twice if it does; grass skips it and depth-tests in
    /// the forward pass instead, at the price of no occlusion or reflection
    /// on it.
    public let prepass: Bool
    /// Draw through the alpha-blending pipeline.
    ///
    /// Distinct from `isDeferred`, and the two are genuinely independent in the
    /// source data: TORCS enables blending on nearly every car surface, where
    /// it is a no-op at alpha 1, but defers only the actually see-through ones.
    /// Conflating them marks an entire car transparent.
    public let blends: Bool
    /// Draw in the sorted transparent phase, after all opaque geometry and
    /// without writing depth. This is what glass needs.
    public let isDeferred: Bool
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
    /// Triangles of tree cards, for `TreeForest`. Empty for scenes without them.
    public var treeFaces: [TreeForest.Face] = []
    public let minimum: SIMD3<Float>, maximum: SIMD3<Float>
    public let warnings: [String]

    public init(batches: [RenderBatch], minimum: SIMD3<Float>, maximum: SIMD3<Float>, warnings: [String] = []) {
        self.batches = batches
        self.minimum = minimum
        self.maximum = maximum
        self.warnings = warnings
    }

    /// Returns a scene with extra generated batches appended and bounds grown
    /// to include them. Used to add procedural terrain and track geometry
    /// alongside whatever the original `.acc` provided.
    public func adding(_ extra: [RenderBatch]) -> RenderScene {
        guard !extra.isEmpty else { return self }
        var low = minimum, high = maximum
        for batch in extra {
            for vertex in batch.mesh.vertices {
                let world = batch.mesh.transform * SIMD4(vertex.position, 1)
                low = simd_min(low, SIMD3(world.x, world.y, world.z))
                high = simd_max(high, SIMD3(world.x, world.y, world.z))
            }
        }
        var result = RenderScene(batches: batches + extra, minimum: low, maximum: high, warnings: warnings)
        result.treeFaces = treeFaces
        return result
    }

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
    /// - Parameter car: apply `CarMaterials` by node name. Car models carry
    ///   one AC material for paint, glass and everything else, so this is the
    ///   only way they get distinct surfaces.
    public init(_ scene: ACScene, car: Bool = false) throws {
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
        // AC puts the name on a transform node and the mesh on an unnamed
        // geometry child, so a mesh's name is its nearest named ancestor's.
        var names: [String] = []
        var collected: [Int: RenderBatch] = [:]
        var faces: [TreeForest.Face] = []
        var warnings = Set(scene.warnings ?? [])
        var low = SIMD3<Float>(repeating: .infinity), high = SIMD3<Float>(repeating: -.infinity)

        for (index, node) in scene.nodes.enumerated() {
            let isDriver = index == driverRoot || (node.parent >= 0 && driverFlags[node.parent])
            driverFlags.append(isDriver)
            let name = node.name.isEmpty && node.parent >= 0 ? names[node.parent] : node.name
            names.append(name)

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

            // Tree cards are kept at float precision for placement recovery;
            // the packed vertex's half UVs cannot tell the atlas ranges apart.
            if material.texture == TreeForest.textureName, count == 3, uv0.count == 3 {
                let world = positions.map { p -> SIMD3<Float> in let q = transform * SIMD4(p, 1); return SIMD3(q.x, q.y, q.z) }
                faces.append(TreeForest.Face(batch: index, positions: world, uvs: uv0))
            }
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
            var resolved = MaterialResolution.resolve(state: material, diffuse: diffuse)
            if car {
                let part = CarMaterials.part(name: name, texture: material.texture, isDriver: isDriver)
                resolved = CarMaterials.material(for: part, base: resolved)
            }
            collected[index] = RenderBatch(
                mesh: render,
                baseTexture: material.texture,
                // Bit 0 selects the blending pipeline; bit 5 defers the draw.
                // Both come straight from the original render state.
                blends: material.flags & 1 != 0,
                isDeferred: material.flags & 32 != 0,
                alphaTestThreshold: alphaTested ? material.alphaClamp : nil,
                culls: mesh.cull,
                isDriver: isDriver,
                sourceMaterial: material,
                material: resolved)
        }

        guard !collected.isEmpty else { throw ACError.invalid("Scene has no drawable triangles") }
        // Faces carry node indices; convert to batch positions in `batches`.
        let batchOrder = order.filter { collected[$0] != nil }
        let position = Dictionary(uniqueKeysWithValues: batchOrder.enumerated().map { ($1, $0) })
        treeFaces = faces.compactMap { face in
            position[face.batch].map { TreeForest.Face(batch: $0, positions: face.positions, uvs: face.uvs) }
        }
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
