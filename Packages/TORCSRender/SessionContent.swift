// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Metal
import simd
import TORCSAssets
import TORCSTrack
import TORCSTrackMesh

/// GPU resources for a prepared driving session, in the modern render path.
///
/// The resource indices follow the contract `DrivingContent` established and
/// the classic renderer consumes, so both paths can be driven from the same
/// per-frame instance list:
///
/// - `0` car body
/// - `1...4` wheels, by speed level
/// - `5` scenery and track
/// - `6...17` brake hubs, discs and calipers, three per wheel
/// - `18` generated terrain, which has no classic counterpart
public final class SessionRenderResources {
    public let resources: [SceneResources]
    public let textures: TextureStore
    public private(set) var terrainResource: Int?
    public let trackBounds: (minimum: SIMD3<Float>, maximum: SIMD3<Float>)

    public static let bodyResource = 0
    public static let wheelResources = [1, 2, 3, 4]
    public static let sceneryResource = 5
    public static let brakeResources = Array(6 ..< 18)

    /// - Parameters:
    ///   - scenes: the loaded packages in `DrivingContent.renderScenes` order.
    ///   - road: track geometry used to generate terrain. Omitting it skips
    ///     terrain generation entirely rather than substituting a flat plane.
    public init(device: MTLDevice, scenes: [LoadedScene],
                road: TrackGeometry? = nil, terrain: TerrainParameters? = nil) throws {
        let store = TextureStore(device: device, roots: [])
        textures = store

        var built: [SceneResources] = []
        var low = SIMD3<Float>(repeating: .infinity), high = SIMD3<Float>(repeating: -.infinity)
        for loaded in scenes {
            let flattened = try RenderScene(loaded.asset.scene)
            built.append(try SceneResources(device: device, scene: flattened,
                                            textures: store, compiled: loaded.textures))
            low = simd_min(low, flattened.minimum)
            high = simd_max(high, flattened.maximum)
        }
        trackBounds = (low, high)

        if let road {
            let parameters = terrain ?? TerrainParameters()
            let apron = TerrainGeneration.apron(road, parameters: parameters)
            if !apron.isEmpty {
                let mesh = try RenderMesh.build(positions: apron.positions, normals: apron.normals,
                                                uv0: apron.uv0, indices: apron.indices)
                // Ground is a rough dielectric; the surface texture supplies the
                // colour. Alpha testing is off, so it needs no cutout coverage.
                let material = ResolvedMaterial(baseColour: SIMD4(1, 1, 1, 1), roughness: 0.92, metallic: 0)
                let state = ACRenderState(material: [0, 0, 0, 1, 0, 0, 0, 1, 0.2, 0.2, 0.2, 1, 0],
                                          texture: parameters.surface + ".rgb", flags: 8, alphaClamp: 0)
                let batch = RenderBatch(mesh: mesh, baseTexture: state.texture, blends: false, isDeferred: false,
                                        alphaTestThreshold: nil, culls: true, isDriver: false,
                                        sourceMaterial: state, material: material)
                let scene = RenderScene(batches: [batch], minimum: low, maximum: high)
                terrainResource = built.count
                built.append(try SceneResources(device: device, scene: scene, textures: store))
            }
        }
        resources = built
    }

    /// The static instances present every frame regardless of vehicle state.
    public func staticInstances() -> [RenderInstance] {
        var instances = [RenderInstance(resource: Self.sceneryResource)]
        if let terrainResource {
            instances.append(RenderInstance(resource: terrainResource))
        }
        return instances
    }
}

public extension SceneResources {
    /// Builds resources binding textures from an already-decoded compiled
    /// package rather than from files on disk.
    convenience init(device: MTLDevice, scene: RenderScene, textures: TextureStore,
                     compiled: [String: CompiledTexture]) throws {
        try self.init(device: device, scene: scene) { name, isCutout in
            guard let texture = compiled[name] else { return nil }
            return textures.albedo(compiled: texture, key: name, isCutout: isCutout)
        }
    }
}
