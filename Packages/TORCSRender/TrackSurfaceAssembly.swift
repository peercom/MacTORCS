// SPDX-License-Identifier: GPL-2.0-only
import Foundation
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
        let kept = scene.batches.filter { !($0.baseTexture ?? "").lowercased().hasPrefix("tr-") }
        return RenderScene(batches: kept, minimum: scene.minimum, maximum: scene.maximum, warnings: scene.warnings)
    }

    /// One batch per surface material, UVs in metres.
    public static func roadBatches(_ geometry: TrackGeometry,
                                   parameters: RoadGeneration.Parameters = .init()) throws -> [RenderBatch] {
        var batches: [RenderBatch] = []
        for group in RoadGeneration.road(geometry, parameters: parameters).groups where !group.geometry.isEmpty {
            let mesh = try RenderMesh.build(positions: group.geometry.positions, normals: group.geometry.normals,
                                            uv0: group.geometry.uv0, indices: group.geometry.indices, uvInMetres: true)
            batches.append(surfaceBatch(mesh: mesh, texture: group.material + ".rgb", roughness: 0.85))
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

    /// A rough dielectric whose colour comes from the generated set bound by
    /// name; the source state mirrors what trackgen would have written so the
    /// batch reads like any other.
    static func surfaceBatch(mesh: RenderMesh, texture: String, roughness: Float) -> RenderBatch {
        let state = ACRenderState(material: [0, 0, 0, 1, 0, 0, 0, 1, 0.2, 0.2, 0.2, 1, 0],
                                  texture: texture, flags: 8, alphaClamp: 0)
        return RenderBatch(mesh: mesh, baseTexture: texture, blends: false, isDeferred: false,
                           alphaTestThreshold: nil, culls: true, isDriver: false,
                           sourceMaterial: state,
                           material: ResolvedMaterial(baseColour: SIMD4(1, 1, 1, 1), roughness: roughness, metallic: 0),
                           uvInMetres: true)
    }
}
