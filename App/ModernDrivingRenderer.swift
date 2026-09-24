// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Metal
import MetalKit
import simd
import TORCSAssets
import TORCSMetal
import TORCSRaceEngine
import TORCSRender
import TORCSTrack
import TORCSTrackMesh

/// Drives the modern render path from the same per-frame state the classic
/// renderer consumes.
///
/// Deliberately a thin adapter. Camera selection, physics interpolation and
/// vehicle presentation stay exactly where they were — this only translates
/// their output into the new renderer's types, so the two paths can be compared
/// on identical input rather than on two different pipelines' idea of a frame.
@MainActor
final class ModernDrivingRenderer {
    let renderer: ForwardRenderer
    private let resources: SessionRenderResources
    private let staticInstances: [RenderInstance]
    private let lighting: SunLighting

    private(set) var lastDrawCount = 0
    private(set) var lastTriangleCount = 0
    var lastError: String?

    init(content: DrivingContent, settings: RenderSettings = .init(), materials: URL? = nil) throws {
        renderer = try ForwardRenderer(settings: settings)
        resources = try SessionRenderResources(
            device: renderer.device,
            scenes: content.renderScenes,
            road: content.simulation.road.geometry,
            terrain: TerrainParameters(),
            materials: materials)
        staticInstances = resources.staticInstances()
        lighting = Self.lighting(from: content.graphics)
    }

    /// The generated material sets for a session: a `materials` folder beside
    /// the session's content, or the directory `TORCS_MATERIALS` names, or
    /// none. None keeps the original artwork rather than failing the session.
    static func materialsDirectory(beside directory: URL?) -> URL? {
        let candidates = [directory?.appendingPathComponent("materials"),
                          ProcessInfo.processInfo.environment["TORCS_MATERIALS"].map { URL(fileURLWithPath: $0) }]
        for candidate in candidates.compactMap({ $0 })
        where FileManager.default.fileExists(atPath: candidate.appendingPathComponent("materials.json").path) {
            return candidate
        }
        return nil
    }

    /// Maps the track's own graphics section onto physical sun parameters.
    ///
    /// The track supplies a light position and colours authored for
    /// fixed-function OpenGL. Only the direction carries over meaningfully: the
    /// ambient and diffuse values were tuned against a renderer that clamped to
    /// [0, 1] and had no tonemapper, so reusing them as radiance would reproduce
    /// the flatness the new path exists to remove. Sky irradiance supplies the
    /// ambient instead.
    static func lighting(from graphics: TrackGraphics?) -> SunLighting {
        let position = graphics?.lightPosition ?? SIMD3(-10_000, 10_000, 7_000)
        let length = simd_length(position)
        let direction = length > 1e-3 ? position / length : SIMD3<Float>(0, 0, 1)
        return SunLighting(direction: direction)
    }

    /// Bridges the classic camera to the modern one.
    ///
    /// Every preset, including the fly and television cameras, resolves to a
    /// `SceneCamera`, so this single conversion covers all 32 of them. Only the
    /// projection differs: the modern path uses reversed depth, so the matrices
    /// are never mixed — just the eye, target, up, field of view and clip range.
    static func camera(from scene: SceneCamera) -> RenderCamera {
        let clipping = scene.clippingRange
        return RenderCamera(eye: scene.eye, target: scene.target, up: scene.up,
                            verticalFieldOfView: scene.fieldOfView,
                            near: max(clipping.x, 0.05),
                            // The classic far plane is tuned to where its linear
                            // fog finished. Aerial perspective reaches much
                            // further, so keep enough depth for the horizon.
                            far: max(clipping.y, 4000))
    }

    /// Assembles the vehicle from its body, wheels and brake parts.
    ///
    /// `VehiclePresentation` already pre-multiplies each wheel by the body
    /// matrix, so every transform here is world-space and there is no rig to
    /// maintain.
    static func vehicleInstances(_ pose: VehiclePresentation, drawsDriver: Bool,
                                 drawsCar: Bool, castsShadow: Bool) -> [RenderInstance] {
        guard drawsCar else { return [] }
        var instances = [RenderInstance(resource: SessionRenderResources.bodyResource,
                                        transform: pose.body, drawsDriver: drawsDriver,
                                        castsShadow: castsShadow)]
        for index in 0 ..< 4 {
            let wheel = pose.wheels[index]
            for part in 0 ..< 3 {
                instances.append(RenderInstance(resource: SessionRenderResources.brakeResources[index * 3 + part],
                                                transform: wheel.brakeTransform, castsShadow: castsShadow))
            }
            let level = min(max(wheel.level, 0), SessionRenderResources.wheelResources.count - 1)
            instances.append(RenderInstance(resource: SessionRenderResources.wheelResources[level],
                                            transform: wheel.transform, castsShadow: castsShadow))
        }
        return instances
    }

    func configure(_ view: MTKView) {
        renderer.configure(view)
    }

    func draw(in view: MTKView, pose: VehiclePresentation, camera sceneCamera: SceneCamera,
              drawsDriver: Bool, drawsCar: Bool) {
        do {
            // A car filling the near cascade would shadow the camera in cockpit
            // views, where the body is hidden but would still cast.
            let instances = staticInstances + Self.vehicleInstances(
                pose, drawsDriver: drawsDriver, drawsCar: drawsCar, castsShadow: drawsCar)
            try renderer.present(in: view, resources: resources.resources, instances: instances,
                                 camera: Self.camera(from: sceneCamera), lighting: lighting)
            lastDrawCount = renderer.lastDrawCount
            lastTriangleCount = renderer.lastTriangleCount
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    var uploadedTextureBytes: Int { resources.textures.uploadedBytes }
    var missingTextures: [String] { resources.textures.missing.sorted() }
}
