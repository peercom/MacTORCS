// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import ImageIO
import UniformTypeIdentifiers
import simd
import TORCSAssets
import TORCSPresentation
import TORCSRaceEngine
import TORCSRender
import TORCSTrackMesh

/// Offscreen diagnostic of the modern render path against real prepared
/// content.
///
/// Exercises everything the driving window does except presentation: compiled
/// scene packages, compiled textures, generated terrain, settled physics, the
/// original camera presets and the instance assembly for body, wheels and
/// brakes. Timings exclude CPU readback and are not gameplay frame rates.
@MainActor enum ModernDrivingSmoke {
    static func run(session: URL, output: URL, width: Int = 1280, height: Int = 832) throws {
        guard !FileManager.default.fileExists(atPath: output.path) else {
            throw ACError.invalid("Visual output directory already exists")
        }
        let content = try DrivingContent.load(session)
        // TORCS_NO_COMPRESSION=1 uploads every texture as RGBA8, to measure
        // what the block formats save on a full session.
        if ProcessInfo.processInfo.environment["TORCS_NO_COMPRESSION"] != nil {
            TextureStore.compressesUploads = false
            MaterialLibrary.compressesMaps = false
        }
        let renderer = try ForwardRenderer()
        let resources = try SessionRenderResources(
            device: renderer.device, scenes: content.renderScenes,
            road: content.simulation.road.geometry, pits: content.simulation.road.pits, terrain: TerrainParameters(),
            materials: ModernDrivingRenderer.materialsDirectory(beside: session))
        let lighting = ModernDrivingRenderer.lighting(from: content.graphics)
        renderer.roadPaint.set(content.gridSlots.map { RoadPaint.Box(centre: $0.world, yaw: $0.yaw) })
        let pose = try VehiclePresentation(content.simulation.visualSnapshot)
        let world = try CameraWorld(bounds: content.simulation.road.bounds)
        let geometry = content.simulation.road.geometry
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let body = pose.body
        let heading = geometry.tangent(try geometry.globalToLocal(SIMD2(body[3].x, body[3].y), startingAt: 0))
        var report: [[String: Any]] = []

        // The fly and television presets need their own controllers, which this
        // diagnostic does not build.
        for preset in DrivingCameraPreset.allCases where preset != .fly && preset != .television {
            var rig = DrivingCameraRig()
            var camera: SceneCamera?
            // Chase relaxation steps a fixed fraction per call, so it has to be
            // spun to steady state before capture, exactly as the classic
            // diagnostic does.
            for _ in 0 ..< 200 {
                camera = try rig.view(preset: preset, body: body, bonnetPosition: content.bonnetPosition,
                                      driverPosition: content.driverPosition, world: world,
                                      roadCameraPosition: content.simulation.road.camera(at: content.simulation.vehicle.chassis.trackPosition.segment)?.position,
                                      yaw: content.simulation.visualSnapshot.body.orientation.z,
                                      trackHeading: heading) { try geometry.height(at: $0, startingAt: 0) }
            }
            guard let sceneCamera = camera else { continue }

            // Each preset is an unrelated view; without this the frame blurs
            // against the previous preset's camera.
            renderer.resetHistory()
            let instances = resources.staticInstances() + ModernDrivingRenderer.vehicleInstances(
                pose, drawsDriver: preset.drawsDriver, drawsCar: preset.drawsCar, castsShadow: preset.drawsCar)
            let pixels = try renderer.render(resources: resources.resources, instances: instances,
                                             camera: ModernDrivingRenderer.camera(from: sceneCamera),
                                             lighting: lighting, width: width, height: height)
            try writePNG(Data(pixels), width: width, height: height,
                                    output: output.appendingPathComponent("\(preset).png"))
            report.append(["camera": "\(preset)", "draws": renderer.lastDrawCount,
                           "triangles": renderer.lastTriangleCount,
                           "gpuMilliseconds": renderer.lastGPUTime * 1000])
        }

        // The rear-view mirror composited on the chase view: the mirror's
        // own lighter renderer, the classic layout, the classic camera.
        do {
            var chaseRig = DrivingCameraRig()
            var chase: SceneCamera?
            for _ in 0 ..< 200 {
                chase = try chaseRig.view(preset: .chase, body: body, bonnetPosition: content.bonnetPosition,
                                          driverPosition: content.driverPosition, world: world,
                                          roadCameraPosition: nil,
                                          yaw: content.simulation.visualSnapshot.body.orientation.z,
                                          trackHeading: heading) { try geometry.height(at: $0, startingAt: 0) }
            }
            if let chase {
                let mirror = RearViewMirror(body: body, bonnetPosition: content.bonnetPosition, hiddenInstances: Set(1 ... 17))
                let layout = MirrorLayout(width: width, height: height)
                let mirrorRenderer = try ForwardRenderer(device: renderer.device, settings: ModernDrivingRenderer.mirrorSettings())
                // An external view: the mirror hides the car.
                let mirrorInstances = resources.staticInstances()
                let request = ForwardRenderer.MirrorRequest(
                    renderer: mirrorRenderer, resources: resources.resources, instances: mirrorInstances,
                    camera: ModernDrivingRenderer.camera(from: try mirror.camera(width: layout.width, height: layout.height)),
                    width: layout.width, height: layout.height,
                    rect: (layout.x, layout.y, layout.width, layout.height))
                let instances = resources.staticInstances() + ModernDrivingRenderer.vehicleInstances(
                    pose, drawsDriver: true, drawsCar: true, castsShadow: true)
                renderer.resetHistory()
                let pixels = try renderer.render(resources: resources.resources, instances: instances,
                                                 camera: ModernDrivingRenderer.camera(from: chase),
                                                 lighting: lighting, width: width, height: height, mirror: request)
                try writePNG(Data(pixels), width: width, height: height,
                                        output: output.appendingPathComponent("mirror.png"))
            }
        }

        // A fixed three-quarter view close to the car. The original presets are
        // all either behind it or far away, which hides the wheels and brakes
        // exactly where assembly errors show up.
        let centre = SIMD3(body[3].x, body[3].y, body[3].z)
        let forward = SIMD3(body[0].x, body[0].y, body[0].z)
        let right = SIMD3(body[1].x, body[1].y, body[1].z)
        let diagnostic = RenderCamera(eye: centre + forward * 4.5 + right * 3.6 + SIMD3(0, 0, 1.6),
                                      target: centre + SIMD3(0, 0, 0.4),
                                      verticalFieldOfView: 38 * .pi / 180, near: 0.2, far: 4000)
        let diagnosticInstances = resources.staticInstances() + ModernDrivingRenderer.vehicleInstances(
            pose, drawsDriver: true, drawsCar: true, castsShadow: true)
        renderer.resetHistory()
        let diagnosticPixels = try renderer.render(resources: resources.resources, instances: diagnosticInstances,
                                                   camera: diagnostic, lighting: lighting,
                                                   width: width, height: height)
        try writePNG(Data(diagnosticPixels), width: width, height: height,
                                output: output.appendingPathComponent("diagnostic.png"))

        // Particle emission on the settled session: at rest on asphalt there
        // must be nothing to emit, and the query must not throw.
        let sources = ModernDrivingRenderer.particleSources(
            pose: pose, snapshot: content.simulation.visualSnapshot, speed: 0,
            geometry: geometry, segment: content.simulation.vehicle.chassis.trackPosition.segment)
        let summary: [String: Any] = [
            "cameras": report.count,
            "particleSourcesAtRest": sources.count,
            "shadersPrebuilt": renderer.shadersPrebuilt,
            "gridBoxes": renderer.roadPaint.quadCount,
            "resources": resources.resources.count,
            "terrainResource": resources.terrainResource ?? -1,
            "texturesUploaded": resources.textures.count,
            "textureMegabytes": Double(resources.textures.uploadedBytes) / 1_048_576,
            "missingTextures": resources.textures.missing.sorted(),
            "views": report]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("report.json"))
        print("modern driving smoke: \(report.count) cameras, \(resources.textures.count) textures, \(resources.textures.missing.count) missing")
        let materialBytes = resources.materials?.uploadedBytes ?? 0
        print(String(format: "modern driving smoke: textures %.1f MiB + materials %.1f MiB uploaded, device %.1f MB allocated, %d texture encodes served from the block cache",
                     Double(resources.textures.uploadedBytes) / 1_048_576, Double(materialBytes) / 1_048_576,
                     Double(renderer.device.currentAllocatedSize) / 1_048_576, resources.textures.sidecarHits))
    }
}

/// RGBA8 to PNG through ImageIO, for the diagnostic's images.
@MainActor func writePNG(_ data: Data, width: Int, height: Int, output: URL) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let provider = CGDataProvider(data: data as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: width * 4, space: space,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw RenderError.unavailable("Could not encode \(output.lastPathComponent)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw RenderError.unavailable("Could not write \(output.path)") }
}
