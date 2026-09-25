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
    /// Loop subdivision levels applied to the car's meshes at load.
    public static let carSubdivisionLevels = 2
    public static let sceneryResource = 5
    public static let brakeResources = Array(6 ..< 18)

    /// - Parameters:
    ///   - scenes: the loaded packages in `DrivingContent.renderScenes` order.
    ///   - road: track geometry used to generate terrain. Omitting it skips
    ///     terrain generation entirely rather than substituting a flat plane.
    ///   - materials: directory of generated material sets (`torcs-matgen`
    ///     output). Nil keeps the original artwork everywhere.
    ///   - generateRoad: replace the baked trackgen surfaces with ones built
    ///     from the segment model. Requires `road`.
    public init(device: MTLDevice, scenes: [LoadedScene],
                road: TrackGeometry? = nil, pits: TrackPits? = nil, terrain: TerrainParameters? = nil,
                materials materialDirectory: URL? = nil, generateRoad: Bool = true) throws {
        // Generated atlases (grass cards) live beside the materials and are
        // resolved by name; baked artwork comes from the compiled packages.
        let store = TextureStore(device: device, roots: materialDirectory.map { [$0] } ?? [])
        textures = store
        let library = try materialDirectory.map { try MaterialLibrary(device: device, directory: $0) }
        self.materials = library

        var built: [SceneResources] = []
        var low = SIMD3<Float>(repeating: .infinity), high = SIMD3<Float>(repeating: -.infinity)
        for (index, loaded) in scenes.enumerated() {
            // Everything but the scenery package is car: body, wheels, brakes.
            // The car and its wheels are subdivided twice: a 4,000-vertex
            // body becomes a smooth one, the scenery stays as generated.
            let isCar = index != Self.sceneryResource
            var flattened = try RenderScene(loaded.asset.scene, car: isCar,
                                            subdivisionLevels: isCar ? Self.carSubdivisionLevels : 0)
            // The scenery package is first; only it carries trackgen output.
            if index == Self.sceneryResource {
                // Solid trees first, while the card faces' batch indices are
                // still those of the flattened scene; then the trackgen strip.
                if let atlas = loaded.textures[TreeForest.textureName]?.pyramid.levels.first {
                    flattened = try TrackSurfaceAssembly.replacingTrees(flattened, atlas: atlas).scene
                }
                if let road, generateRoad {
                    flattened = TrackSurfaceAssembly.strippingTrackgen(flattened)
                    // The garages replace trackgen's pit building as well.
                    if let pits {
                        flattened = TrackSurfaceAssembly.strippingPitComplex(
                            flattened, garages: PitGeneration.footprints(road, pits: pits))
                    }
                }
            }
            built.append(try SceneResources(device: device, scene: flattened, textures: store,
                                            compiled: loaded.textures, materials: library,
                                            materialDirectory: materialDirectory))
            low = simd_min(low, flattened.minimum)
            high = simd_max(high, flattened.maximum)
        }
        trackBounds = (low, high)

        if let road {
            var generated: [RenderBatch] = []
            if let ground = try TrackSurfaceAssembly.terrainBatch(road, parameters: terrain ?? TerrainParameters()) {
                generated.append(ground)
            }
            if generateRoad {
                generated += try TrackSurfaceAssembly.roadBatches(road)
                if let pits { generated += try TrackSurfaceAssembly.pitBatches(road, pits: pits) }
                generated += try TrackSurfaceAssembly.furnitureBatches(road)
                if materialDirectory != nil {
                    generated += try TrackSurfaceAssembly.grassBatches(road)
                }
            }
            if !generated.isEmpty {
                let scene = RenderScene(batches: generated, minimum: low, maximum: high)
                terrainResource = built.count
                built.append(try SceneResources(device: device, scene: scene, textures: store,
                                                materials: library, materialDirectory: materialDirectory))
            }
        }
        resources = built
    }

    /// The generated material sets in use, if a directory was supplied.
    public let materials: MaterialLibrary?

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
                     compiled: [String: CompiledTexture],
                     materials: MaterialLibrary? = nil, materialDirectory: URL? = nil) throws {
        try self.init(device: device, scene: scene, materials: materials, materialDirectory: materialDirectory,
                      originalImage: { name in
                          // The compiled package holds the decoded artwork, so
                          // painted markings can still be composited over a
                          // generated set.
                          compiled[name]?.pyramid.levels.first
                      }) { name, isCutout in
            guard let texture = compiled[name] else { return textures.albedo(named: name, isCutout: isCutout) }
            return textures.albedo(compiled: texture, key: name, isCutout: isCutout)
        }
    }
}
