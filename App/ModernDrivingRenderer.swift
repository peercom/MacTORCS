// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Metal
import MetalKit
import simd
import TORCSAssets
import TORCSPresentation
import TORCSRaceEngine
import TORCSSimulation
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

    /// Set per frame by the session, as for the classic renderer; nil hides it.
    var mirror: RearViewMirror?
    /// A second, lighter renderer for the mirror: no screen-space passes, no
    /// post, two cascades. Created on first use.
    private var mirrorRenderer: ForwardRenderer?

    static func mirrorSettings() -> RenderSettings {
        var settings = RenderSettings()
        settings.upscaling = false
        settings.dynamicResolution = false
        settings.screenSpaceReflections = .off
        settings.ambientOcclusion = .off
        settings.contactShadows = false
        settings.bloom = false
        settings.motionBlur = false
        settings.sunGlare = false
        settings.heatHaze = false
        settings.depthPrepass = false
        settings.shadowCascades = 2
        return settings
    }

    /// The mirror's request for this frame, or nil when the mirror is off.
    /// From a cockpit view the body stays — the cage and rear window are
    /// what a mirror there sees; from an external view the whole car is
    /// hidden, so the mirror shows the road behind rather than the cabin.
    func mirrorRequest(pose: VehiclePresentation, drawableWidth: Int, drawableHeight: Int,
                       lightState: SIMD4<Float>, drawsCar: Bool) throws -> ForwardRenderer.MirrorRequest? {
        guard let mirror, drawableWidth >= 8, drawableHeight >= 48 else { return nil }
        let layout = MirrorLayout(width: drawableWidth, height: drawableHeight)
        let camera = try mirror.camera(width: layout.width, height: layout.height)
        if mirrorRenderer == nil {
            mirrorRenderer = try ForwardRenderer(device: renderer.device, settings: Self.mirrorSettings())
        }
        guard let mirrorRenderer else { return nil }
        let instances = staticInstances + (drawsCar ? [] : Self.vehicleInstances(
            pose, drawsDriver: false, drawsCar: true, castsShadow: true, lightState: lightState)
            .filter { $0.resource == SessionRenderResources.bodyResource })
        return ForwardRenderer.MirrorRequest(renderer: mirrorRenderer, resources: resources.resources,
                                             instances: instances, camera: Self.camera(from: camera),
                                             width: layout.width, height: layout.height,
                                             rect: (layout.x, layout.y, layout.width, layout.height))
    }

    private(set) var lastDrawCount = 0
    private(set) var lastTriangleCount = 0
    var lastError: String?

    init(content: DrivingContent, settings: RenderSettings = .init(), materials: URL? = nil) throws {
        renderer = try ForwardRenderer(settings: settings)
        resources = try SessionRenderResources(
            device: renderer.device,
            scenes: content.renderScenes,
            road: content.simulation.road.geometry, pits: content.simulation.road.pits,
            terrain: TerrainParameters(),
            materials: materials)
        staticInstances = resources.staticInstances()
        lighting = Self.lighting(from: content.graphics)
        renderer.roadPaint.set(content.gridSlots.map { RoadPaint.Box(centre: $0.world, yaw: $0.yaw) })
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
                                 drawsCar: Bool, castsShadow: Bool,
                                 lightState: SIMD4<Float> = .zero) -> [RenderInstance] {
        guard drawsCar else { return [] }
        var instances = [RenderInstance(resource: SessionRenderResources.bodyResource,
                                        transform: pose.body, drawsDriver: drawsDriver,
                                        castsShadow: castsShadow, lightState: lightState)]
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

    /// Smoke where a tyre skids, dust where it runs on a loose surface.
    ///
    /// The simulation publishes the original per-wheel skid factor; the
    /// surface comes from the track query at the hub, because the physics
    /// contact segment is not published and the query is what it would use.
    static func particleSources(pose: VehiclePresentation, snapshot: VehicleVisualSnapshot, speed: Float,
                                geometry: TrackGeometry, segment: Int, wetness: Float = 0) -> [ParticleSystem.Source] {
        var sources: [ParticleSystem.Source] = []
        let forward = SIMD3(pose.body[0].x, pose.body[0].y, pose.body[0].z)
        let velocity = forward * speed
        for i in 0 ..< 4 {
            let wheel = snapshot.wheels[i]
            let hub = pose.wheels[i].transform[3]
            let contact = SIMD3(hub.x, hub.y, hub.z - wheel.radius + 0.02)
            let skid = wheel.skid
            if skid > 0.2, abs(speed) > 3 {
                sources.append(.init(kind: .smoke, position: contact, velocity: velocity,
                                     intensity: min((skid - 0.2) / 0.5, 1)))
            }
            guard abs(speed) > 2 else { continue }
            // On a wet road every tyre flings spray, more the faster it goes.
            if wetness > 0.2, abs(speed) > 8 {
                sources.append(.init(kind: .spray, position: contact, velocity: velocity,
                                     intensity: min(abs(speed) / 40, 1) * wetness))
            }
            let loose: Bool
            if let local = try? geometry.globalToLocal(SIMD2(hub.x, hub.y), startingAt: segment, mode: .segment) {
                let material = geometry.segments[local.segment].surface.material.lowercased()
                loose = ["grass", "gravel", "sand", "dirt", "terre", "mud"].contains { material.contains($0) }
            } else {
                loose = true  // off every strip: the terrain
            }
            if loose {
                sources.append(.init(kind: .dust, position: contact, velocity: velocity,
                                     intensity: min(abs(speed) / 25, 1) * 0.8))
            }
        }
        return sources
    }

    /// Marks where a tyre skids hard enough. The threshold sits above the
    /// smoke's: a tyre chirps before it leaves rubber.
    static func skidSources(pose: VehiclePresentation, snapshot: VehicleVisualSnapshot, speed: Float) -> [SkidMarks.Source] {
        guard abs(speed) > 1 else { return [] }
        var sources: [SkidMarks.Source] = []
        for i in 0 ..< 4 {
            let wheel = snapshot.wheels[i]
            guard wheel.skid > 0.3 else { continue }
            let transform = pose.wheels[i].transform
            let hub = transform[3]
            let axle = SIMD3(transform[1].x, transform[1].y, transform[1].z)
            let length = simd_length(axle)
            guard length > 1e-5 else { continue }
            sources.append(.init(key: i, position: SIMD3(hub.x, hub.y, hub.z - wheel.radius),
                                 lateral: axle / length, width: wheel.width,
                                 intensity: min((wheel.skid - 0.3) / 0.5, 1)))
        }
        return sources
    }

    func draw(in view: MTKView, pose: VehiclePresentation, camera sceneCamera: SceneCamera,
              brakeCommand: Float = 0, lightCommand: UInt32 = 0,
              drawsDriver: Bool, drawsCar: Bool,
              particleSources: [ParticleSystem.Source] = [], skidSources: [SkidMarks.Source] = [],
              deltaTime: Float = 1 / 60) {
        do {
            var sources = particleSources
            if let rainSource = Self.rainSource(eye: sceneCamera.eye, rain: renderer.rain) { sources.append(rainSource) }
            renderer.particles.sources = sources
            renderer.particles.advance(by: deltaTime)
            renderer.skidMarks.sources = skidSources
            renderer.skidMarks.advance()
            // A car filling the near cascade would shadow the camera in cockpit
            // views, where the body is hidden but would still cast.
            let lightState = RenderInstance.lightState(brakeCommand: brakeCommand, lightCommand: lightCommand)
            let instances = staticInstances + Self.vehicleInstances(
                pose, drawsDriver: drawsDriver, drawsCar: drawsCar, castsShadow: drawsCar, lightState: lightState)
            let drawableWidth = view.currentDrawable?.texture.width ?? 0
            let drawableHeight = view.currentDrawable?.texture.height ?? 0
            let mirror = try mirrorRequest(pose: pose, drawableWidth: drawableWidth, drawableHeight: drawableHeight,
                                           lightState: lightState, drawsCar: drawsCar)
            try renderer.present(in: view, resources: resources.resources, instances: instances,
                                 camera: Self.camera(from: sceneCamera), lighting: Self.lighting(lighting, rain: renderer.rain),
                                 mirror: mirror)
            lastDrawCount = renderer.lastDrawCount
            lastTriangleCount = renderer.lastTriangleCount
            lastError = nil
        } catch {
            lastError = String(describing: error)
        }
    }

    /// The scene's wetness, 0 dry to 1 soaked, applied to the main and mirror renderers.
    var wetness: Float {
        get { renderer.wetness }
        set { renderer.wetness = newValue }
    }
    /// Rain, 0 to 1: streaks around the camera and a sun dimmed to a
    /// quarter, the ambient to two thirds.
    /// The lens for the television view; nil for every other preset.
    var depthOfField: DepthOfField? {
        get { renderer.depthOfField }
        set { renderer.depthOfField = newValue }
    }
    var rain: Float {
        get { renderer.rain }
        set { renderer.rain = newValue }
    }

    /// The rain falls through a box above the camera, wherever it is.
    static func rainSource(eye: SIMD3<Float>, rain: Float) -> ParticleSystem.Source? {
        guard rain > 0.02 else { return nil }
        return ParticleSystem.Source(kind: .rain, position: eye, velocity: .zero, intensity: min(rain, 1))
    }

    static func lighting(_ base: SunLighting, rain: Float) -> SunLighting {
        var lighting = base
        let r = min(max(rain, 0), 1)
        // Overcast: the sun to a third, the skylight kept — diffuse light is
        // what an overcast day has plenty of. Dimming both read as dusk.
        lighting.intensity *= 1 - 0.7 * r
        lighting.ambient *= 1 + 0.1 * r
        // No auto-exposure yet: open up as an eye would under an overcast
        // sky, a little over a stop at full rain.
        lighting.exposureEV100 -= 1.2 * r
        return lighting
    }

    var uploadedTextureBytes: Int { resources.textures.uploadedBytes }
    var missingTextures: [String] { resources.textures.missing.sorted() }
}
