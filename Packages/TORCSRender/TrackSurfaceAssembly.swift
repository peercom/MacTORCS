// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd
import TORCSAssets
import TORCSTrack
import TORCSTrackMesh

/// Turns generated track surfaces into render batches, and removes the baked
/// ones they replace.
///
/// Shared by the interactive session and `torcs-rendershot` so the two cannot
/// disagree about what a generated circuit looks like.
public enum TrackSurfaceAssembly {
    /// Removes trackgen's output from a baked scene. Every `tr-*` texture is a
    /// road, side, curb or barrier strip that TORCS's `trackgen` emitted from
    /// the same segment model the generator reads, so nothing authored by hand
    /// is lost: trees, buildings and furniture use other names.
    public static func strippingTrackgen(_ scene: RenderScene) -> RenderScene {
        removing(from: scene) { ($0.baseTexture ?? "").lowercased().hasPrefix("tr-") }
    }

    /// Removes batches, keeping the tree faces' batch indices valid.
    static func removing(from scene: RenderScene, where drop: (RenderBatch) -> Bool) -> RenderScene {
        var kept: [RenderBatch] = [], remap: [Int: Int] = [:]
        for (index, batch) in scene.batches.enumerated() where !drop(batch) {
            remap[index] = kept.count
            kept.append(batch)
        }
        var result = RenderScene(batches: kept, minimum: scene.minimum, maximum: scene.maximum, warnings: scene.warnings)
        result.treeFaces = scene.treeFaces.compactMap { face in
            remap[face.batch].map { TreeForest.Face(batch: $0, positions: face.positions, uvs: face.uvs) }
        }
        return result
    }

    /// Distance within which a tree draws at near detail; beyond it the
    /// lighter build, which is also what casts its shadow at every distance.
    /// A fifteen-metre tree at seventy metres is about 150 pixels tall on a
    /// 1280-wide frame, which is where the near build's extra clusters stop
    /// resolving.
    public static let nearTreeDistance: Float = 70

    public enum TreeDetail: Sendable, Equatable {
        /// One near and one middle batch per tree, switched by distance.
        case levelOfDetail
        /// One merged batch per species at the given detail, everywhere.
        case merged(middle: Bool)
    }

    /// Replaces the crossed tree cards with solid trees built from the same
    /// atlas. With level of detail, each tree is a pair of batches — near
    /// within `nearTreeDistance`, middle beyond, the middle one casting the
    /// shadow — so the forest costs its lighter build almost everywhere and
    /// the trees beside the road get the dense one. Scenes whose cards match
    /// no known signature are returned unchanged.
    public static func replacingTrees(_ scene: RenderScene, atlas: TextureImage,
                                      detail: TreeDetail = .levelOfDetail) throws -> (scene: RenderScene, forest: TreeForest) {
        let forest = TreeForest(faces: scene.treeFaces)
        guard !forest.placements.isEmpty else { return (scene, forest) }
        var cache: [Int: GeneratedGeometry] = [:]
        func unit(_ placement: TreeForest.Placement, middle: Bool) -> GeneratedGeometry {
            let key = placement.family * 6 + placement.variant * 2 + (middle ? 1 : 0)
            if let cached = cache[key] { return cached }
            let built = TreeMeshes.mesh(family: placement.family, variant: placement.variant, middle: middle, atlas: atlas)
            cache[key] = built
            return built
        }
        func placed(_ placement: TreeForest.Placement, into out: inout GeneratedGeometry, middle: Bool) {
            let source = unit(placement, middle: middle)
            let base = UInt32(out.positions.count)
            let m = placement.transform
            let linear = simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                       SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                       SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z))
            let normalMatrix = abs(simd_determinant(linear)) > 1e-12 ? linear.inverse.transpose : linear
            for (i, p) in source.positions.enumerated() {
                let w = m * SIMD4(p, 1)
                out.positions.append(SIMD3(w.x, w.y, w.z))
                out.normals.append(simd_normalize(normalMatrix * source.normals[i]))
            }
            out.uv0 += source.uv0
            out.attributes += source.attributes
            out.indices += source.indices.map { $0 + base }
        }
        func batch(_ geometry: GeneratedGeometry, range: ClosedRange<Float>?, castsShadow: Bool) throws -> RenderBatch {
            let mesh = try RenderMesh.build(positions: geometry.positions, normals: geometry.normals,
                                            uv0: geometry.uv0, blend: geometry.attributes, indices: geometry.indices)
            // Alpha-tested like the cards were (AC flag bit 4), two-sided,
            // rough: leaves are not glossy.
            let state = ACRenderState(material: [0, 0, 0, 1, 0, 0, 0, 1, 0.2, 0.2, 0.2, 1, 0],
                                      texture: TreeForest.textureName, flags: 16, alphaClamp: 0.5)
            return RenderBatch(mesh: mesh, baseTexture: TreeForest.textureName, blends: false, isDeferred: false,
                               alphaTestThreshold: 0.5, culls: false, isDriver: false, sourceMaterial: state,
                               material: ResolvedMaterial(baseColour: SIMD4(1, 1, 1, 1), roughness: 0.9, metallic: 0),
                               swaysInWind: true, detailRange: range, castsShadow: castsShadow)
        }

        var trees: [RenderBatch] = []
        switch detail {
        case .levelOfDetail:
            for placement in forest.placements {
                var near = GeneratedGeometry(), middle = GeneratedGeometry()
                placed(placement, into: &near, middle: false)
                placed(placement, into: &middle, middle: true)
                trees.append(try batch(near, range: 0 ... Self.nearTreeDistance, castsShadow: false))
                trees.append(try batch(middle, range: Self.nearTreeDistance ... Float.greatestFiniteMagnitude, castsShadow: true))
            }
        case .merged(let middle):
            var merged = Array(repeating: GeneratedGeometry(), count: TreeForest.families.count)
            for placement in forest.placements { placed(placement, into: &merged[placement.family], middle: middle) }
            for geometry in merged where !geometry.isEmpty { trees.append(try batch(geometry, range: nil, castsShadow: true)) }
        }

        let stripped = Set(forest.batchPlacement.keys)
        var kept: [RenderBatch] = []
        for (index, batch) in scene.batches.enumerated() where !stripped.contains(index) { kept.append(batch) }
        // The cards are consumed; no faces carry forward.
        let result = RenderScene(batches: kept, minimum: scene.minimum, maximum: scene.maximum, warnings: scene.warnings)
        return (result.adding(trees), forest)
    }

    /// One batch per surface material, UVs in metres.
    public static func roadBatches(_ geometry: TrackGeometry,
                                   parameters: RoadGeneration.Parameters = .init()) throws -> [RenderBatch] {
        var batches: [RenderBatch] = []
        for group in RoadGeneration.road(geometry, parameters: parameters).groups where !group.geometry.isEmpty {
            let mesh = try RenderMesh.build(positions: group.geometry.positions, normals: group.geometry.normals,
                                            uv0: group.geometry.uv0, blend: group.geometry.attributes,
                                            indices: group.geometry.indices, uvInMetres: true)
            batches.append(surfaceBatch(mesh: mesh, texture: group.material + ".rgb", roughness: 0.85, markings: true))
        }
        return batches
    }

    /// The ground plane out to the border margin, or nil when the generator
    /// declines (a pathological track).
    public static func terrainBatch(_ geometry: TrackGeometry, parameters: TerrainParameters) throws -> RenderBatch? {
        let ground = TerrainGeneration.ground(geometry, parameters: parameters)
        guard !ground.isEmpty else { return nil }
        let mesh = try RenderMesh.build(positions: ground.positions, normals: ground.normals,
                                        uv0: ground.uv0, indices: ground.indices, uvInMetres: true)
        return surfaceBatch(mesh: mesh, texture: parameters.surface + ".rgb", roughness: 0.92)
    }

    /// Beyond this the verge's cards are not drawn; at sixty metres a
    /// forty-centimetre clump is a few pixels and the terrain texture carries it.
    public static let grassDistance: Float = 60
    public static let grassTexture = "grass-cards-albedo.png"

    /// Grass clumps along both verges, one batch per hundred metres of track.
    /// The atlas is `torcs-matgen`'s `grass-cards`, resolved by name from the
    /// texture roots — the materials directory must be one of them.
    public static func grassBatches(_ geometry: TrackGeometry,
                                    parameters: GrassGeneration.Parameters = .init()) throws -> [RenderBatch] {
        var batches: [RenderBatch] = []
        for chunk in GrassGeneration.chunks(geometry, parameters: parameters) where !chunk.geometry.isEmpty {
            let g = chunk.geometry
            let mesh = try RenderMesh.build(positions: g.positions, normals: g.normals, uv0: g.uv0,
                                            blend: g.attributes, indices: g.indices)
            let state = ACRenderState(material: [0, 0, 0, 1, 0, 0, 0, 1, 0.2, 0.2, 0.2, 1, 0],
                                      texture: grassTexture, flags: 16, alphaClamp: 0.5)
            batches.append(RenderBatch(mesh: mesh, baseTexture: grassTexture, blends: false, isDeferred: false,
                                       alphaTestThreshold: 0.5, culls: false, isDriver: false, sourceMaterial: state,
                                       material: ResolvedMaterial(baseColour: SIMD4(1, 1, 1, 1), roughness: 0.9, metallic: 0),
                                       swaysInWind: true, detailRange: 0 ... grassDistance, castsShadow: false,
                                       prepass: false))
        }
        return batches
    }

    /// A rough dielectric whose colour comes from the generated set bound by
    /// name; the source state mirrors what trackgen would have written so the
    /// batch reads like any other.
    static func surfaceBatch(mesh: RenderMesh, texture: String, roughness: Float, markings: Bool = false) -> RenderBatch {
        let state = ACRenderState(material: [0, 0, 0, 1, 0, 0, 0, 1, 0.2, 0.2, 0.2, 1, 0],
                                  texture: texture, flags: 8, alphaClamp: 0)
        return RenderBatch(mesh: mesh, baseTexture: texture, blends: false, isDeferred: false,
                           alphaTestThreshold: nil, culls: true, isDriver: false,
                           sourceMaterial: state,
                           material: ResolvedMaterial(baseColour: SIMD4(1, 1, 1, 1), roughness: roughness, metallic: 0),
                           uvInMetres: true, paintsRoadMarkings: markings, receivesWeather: true)
    }
}
