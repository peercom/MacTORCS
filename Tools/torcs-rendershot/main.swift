// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Metal
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import simd
import TORCSAssets
import TORCSRender
import TORCSTrack
import TORCSTrackMesh
import TORCSConfiguration

/// Renders a scene through the modern path and writes a PNG.
///
/// Exists so every renderer milestone produces a look-at-able image, not only a
/// passing assertion. Deliberately separate from the app: it needs no window
/// server session beyond a GPU, and it takes an explicit input path rather than
/// discovering content.
struct Options {
    var input = ""
    var output = ""
    var width = 1280, height = 832
    var car = false
    /// Loop subdivision levels for a car scene.
    var subdivide = 0
    var azimuth: Float = -60, elevation: Float = 18
    var sunAzimuth: Float = 135, sunElevation: Float = 40
    var exposure: Float = 0
    var preset = RenderSettings.Preset.m2Air
    var stats = false
    var frames = 1
    var noCull = false
    var terrainOnly = false
    var generateTrack = false
    var trees = false
    var grass = false
    var brake = false
    var headlights = false
    var grassEverywhere = false
    var treeDetail = TrackSurfaceAssembly.TreeDetail.levelOfDetail
    var cascades: Int? = nil
    var animationTime: Float = 0
    var roadCamera: Float? = nil
    var listSegments = false
    var roadCameraLateral: Float = 0.5
    /// With `--road-camera`, raise the eye this far and look down the road.
    var roadAerial: Float = 0
    var materials: String? = nil
    var depthPrepass = false
    var bloom: Bool? = nil
    var bloomStrength: Float? = nil
    var bloomThreshold: Float? = nil
    var ambientOcclusion: RenderSettings.Quality? = nil
    var contactShadows: Bool? = nil
    var compareOcclusion = false
    var occlusionView: String? = nil
    var reflections: RenderSettings.Quality? = nil
    var compareReflections = false
    var reflectionView: String? = nil
    var surfaceView: String? = nil
    var motionBlur: Bool? = nil
    var compareMotionBlur = false
    var compareParticles = false
    var compareSkid = false
    /// Lay an S-shaped pair of skid marks on the ground before rendering.
    var skid = false
    /// Scene wetness, 0 dry to 1 soaked.
    var wetness: Float = 0
    var compareWet = false
    var sunGlare: Bool? = nil
    var heatHaze: Bool? = nil
    var compareHaze = false
    /// Rain, 0 to 1: streaks pre-rolled around the camera, a dimmed sun.
    var rain: Float = 0
    var shadowRefresh: Int? = nil
    /// Per-pass GPU timing over the frames, from the GPU's timestamp counter.
    var passes = false
    /// Overrides the preset's anisotropy for the normal and roughness maps.
    var detailAnisotropy: Int?
    var compareGlare = false
    var reflectionTemporal: Bool? = nil
    var compareReflectionTemporal = false
    /// Report startup costs: shader library, renderer construction, scaler pre-warm.
    var startup = false
    /// Report the device's allocated memory after the frames.
    var memory = false
    /// Frames of tyre smoke to emit at the rear wheels before rendering.
    var smokeFrames = 0
    var orbitSpeed: Float = 0
    var sustainSeconds: Double = 0
    var dynamic = false
    var upscalingMode: RenderSettings.UpscalingMode? = nil
    var renderScale: Float? = nil
    var aoRadius: Float? = nil
    var aoPower: Float? = nil
    var upscale: Bool? = nil
    var comparePrepass = false
    var compareBloom = false
    var compareUpscale = false
    /// Track XML enabling procedural terrain from its Terrain Generation section.
    var trackXML: String? = nil
    var textureRoots: [String] = []
    var eye: SIMD3<Float>? = nil
    var target: SIMD3<Float>? = nil
    var fieldOfView: Float = 45
    var sunIntensity: Float = 4
    var ambient: Float = 1
}

/// Parses "x,y,z" in TORCS world coordinates (Z up).
func parseVector(_ text: String) -> SIMD3<Float>? {
    let parts = text.split(separator: ",").compactMap { Float($0.trimmingCharacters(in: .whitespaces)) }
    return parts.count == 3 ? SIMD3(parts[0], parts[1], parts[2]) : nil
}

func parse() -> Options {
    var options = Options()
    var positional: [String] = []
    var arguments = Array(CommandLine.arguments.dropFirst())
    while let argument = arguments.first {
        arguments.removeFirst()
        func next() -> String { arguments.isEmpty ? "" : arguments.removeFirst() }
        switch argument {
        case "--width": options.width = Int(next()) ?? options.width
        case "--height": options.height = Int(next()) ?? options.height
        case "--car": options.car = true
        case "--subdivide": options.subdivide = Int(next()) ?? 2
        case "--azimuth": options.azimuth = Float(next()) ?? options.azimuth
        case "--elevation": options.elevation = Float(next()) ?? options.elevation
        case "--sun-azimuth": options.sunAzimuth = Float(next()) ?? options.sunAzimuth
        case "--sun-elevation": options.sunElevation = Float(next()) ?? options.sunElevation
        case "--exposure": options.exposure = Float(next()) ?? options.exposure
        case "--preset": options.preset = RenderSettings.Preset(rawValue: next()) ?? options.preset
        case "--stats": options.stats = true
        case "--no-cull": options.noCull = true
        case "--terrain-only": options.terrainOnly = true
        case "--generate-track": options.generateTrack = true
        case "--trees": options.trees = true
        case "--grass": options.grass = true
        case "--brake": options.brake = true
        case "--headlights": options.headlights = true
        case "--grass-everywhere": options.grass = true; options.grassEverywhere = true
        case "--tree-detail":
            switch next() { case "near": options.treeDetail = .merged(middle: false)
                            case "middle": options.treeDetail = .merged(middle: true)
                            default: options.treeDetail = .levelOfDetail }
        case "--cascades": options.cascades = Int(next())
        case "--time": options.animationTime = Float(next()) ?? 0
        case "--road-camera": options.roadCamera = Float(next())
        case "--list-segments": options.listSegments = true
        case "--road-lateral": options.roadCameraLateral = Float(next()) ?? 0.5
        case "--road-aerial": options.roadAerial = Float(next()) ?? 40
        case "--materials": options.materials = next()
        case "--depth-prepass": options.depthPrepass = true
        case "--bloom": options.bloom = true
        case "--no-bloom": options.bloom = false
        case "--bloom-strength": options.bloomStrength = Float(next()) ?? options.bloomStrength
        case "--bloom-threshold": options.bloomThreshold = Float(next()) ?? options.bloomThreshold
        case "--upscale": options.upscale = true
        case "--no-upscale": options.upscale = false
        case "--compare-prepass": options.comparePrepass = true
        case "--compare-bloom": options.compareBloom = true
        case "--compare-upscale": options.compareUpscale = true
        case "--compare-occlusion": options.compareOcclusion = true
        case "--ao": options.ambientOcclusion = ["off": .off, "quarter": .quarter, "half": .half, "full": .full][next()]
        case "--contact": options.contactShadows = true
        case "--no-contact": options.contactShadows = false
        case "--occlusion-view": options.occlusionView = next()
        case "--ssr": options.reflections = ["off": .off, "quarter": .quarter, "half": .half, "full": .full][next()]
        case "--compare-ssr": options.compareReflections = true
        case "--reflection-view": options.reflectionView = next()
        case "--surface-view": options.surfaceView = next()
        case "--motion-blur": options.motionBlur = true
        case "--no-motion-blur": options.motionBlur = false
        case "--compare-motion-blur": options.compareMotionBlur = true
        case "--compare-particles": options.compareParticles = true
        case "--compare-skid": options.compareSkid = true
        case "--skid": options.skid = true
        case "--wet": options.wetness = Float(next()) ?? 1
        case "--compare-wet": options.compareWet = true
        case "--glare": options.sunGlare = true
        case "--haze": options.heatHaze = true
        case "--no-haze": options.heatHaze = false
        case "--compare-haze": options.compareHaze = true
        case "--rain": options.rain = Float(next()) ?? 1
        case "--shadow-refresh": options.shadowRefresh = Int(next())
        case "--passes": options.passes = true
        case "--detail-anisotropy": options.detailAnisotropy = Int(next())
        case "--no-glare": options.sunGlare = false
        case "--compare-glare": options.compareGlare = true
        case "--ssr-temporal": options.reflectionTemporal = true
        case "--no-ssr-temporal": options.reflectionTemporal = false
        case "--compare-ssr-temporal": options.compareReflectionTemporal = true
        case "--startup": options.startup = true
        case "--memory": options.memory = true
        case "--smoke": options.smokeFrames = Int(next()) ?? 45
        case "--orbit-speed": options.orbitSpeed = Float(next()) ?? 0
        case "--sustain": options.sustainSeconds = Double(next()) ?? 0
        case "--dynamic": options.dynamic = true
        case "--upscale-mode": options.upscalingMode = RenderSettings.UpscalingMode(rawValue: next())
        case "--render-scale": options.renderScale = Float(next())
        case "--ao-radius": options.aoRadius = Float(next())
        case "--ao-power": options.aoPower = Float(next())
        case "--frames": options.frames = Int(next()) ?? options.frames
        case "--track-xml": options.trackXML = next()
        case "--textures": options.textureRoots.append(next())
        case "--eye": options.eye = parseVector(next())
        case "--target": options.target = parseVector(next())
        case "--fov": options.fieldOfView = Float(next()) ?? options.fieldOfView
        case "--sun-intensity": options.sunIntensity = Float(next()) ?? options.sunIntensity
        case "--ambient": options.ambient = Float(next()) ?? options.ambient
        default: positional.append(argument)
        }
    }
    if positional.count >= 2 {
        options.input = positional[0]
        options.output = positional[1]
    }
    return options
}

func writePNG(_ pixels: [UInt8], width: Int, height: Int, to path: String) throws {
    let colourSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let provider = CGDataProvider(data: Data(pixels) as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: width * 4, space: colourSpace,
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false,
                              intent: .defaultIntent) else {
        throw RenderError.unavailable("Could not build a CGImage")
    }
    let url = URL(fileURLWithPath: path)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw RenderError.unavailable("Could not create \(path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw RenderError.unavailable("Could not write \(path)")
    }
}

var options = parse()
guard !options.input.isEmpty, !options.output.isEmpty else {
    FileHandle.standardError.write(Data("""
    usage: torcs-rendershot <input.acc> <output.png> [options]
      --width N --height N          render size (default 1280x832)
      --car                         load with car material semantics
      --azimuth D --elevation D     camera orbit in degrees
      --sun-azimuth D --sun-elevation D
      --exposure EV                 exposure compensation in stops
      --preset m2Air|balanced|high

    """.utf8))
    exit(2)
}

do {
    let radians = Float.pi / 180
    let data = try Data(contentsOf: URL(fileURLWithPath: options.input))
    var scene = try RenderScene(ACScene.parse(data, car: options.car), car: options.car, subdivisionLevels: options.subdivide)
    var gridBoxes: [RoadPaint.Box] = []

    // Procedural terrain from the track's own Terrain Generation parameters.
    // Aalborg's baked mesh contains almost no ground, so without this the
    // circuit sits in a void and nothing can receive a shadow.
    if let trackXML = options.trackXML {
        let xml = URL(fileURLWithPath: trackXML)
        let directory = xml.deletingLastPathComponent()
        var entities: [String: Data] = [:]
        for (name, file) in [("default-surfaces", "surfaces.xml"), ("default-objects", "objects.xml")] {
            if let contents = try? Data(contentsOf: directory.appendingPathComponent(file)) {
                entities[name] = contents
            }
        }
        let document = try ParameterDocument.parse(Data(contentsOf: xml), entities: entities,
                                                   allowLegacyLatin1: true)
        let road = try TrackBuilder.buildRoad(parameters: document)
        if options.listSegments {
            // Main segments with their borders, for placing cameras.
            print("segment            start(m)  length  curve     surface              rborder            lborder")
            for index in road.geometry.mainSegments {
                let s = road.geometry.segments[index]
                func border(_ side: Int?) -> String {
                    guard let side, let b = Optional(road.geometry.segments[side]), b.role == .rightBorder || b.role == .leftBorder else { return "-" }
                    return "\(b.style) \(b.surface.material)"
                }
                print(String(format: "%-18@ %8.1f %7.1f  %-8@  %-20@ %-18@ %@",
                             s.name as NSString, s.distanceFromStart, s.length, "\(s.curve)" as NSString,
                             s.surface.material as NSString, border(s.right) as NSString, border(s.left) as NSString))
                // Side chains, with the quantities the road generator consumes.
                for side in [TrackSide.right, .left] {
                    var cursor = side == .right ? s.right : s.left
                    var guardCount = 0
                    while let index = cursor, guardCount < 8 {
                        guardCount += 1
                        let t = road.geometry.segments[index]
                        let mid = TrackLocalPosition(segment: index, toStart: t.extent / 2, toRight: road.geometry.width(segment: index, toStart: t.extent / 2) / 2)
                        let n = road.geometry.surfaceNormal(mid)
                        print(String(format: "    %@ %-12@ len %6.2f ext %6.3f dfs %7.1f w %5.2f..%5.2f  n (%.2f %.2f %.2f) %@",
                                     side == .right ? "R" : "L", "\(t.role)" as NSString, t.length, t.extent, t.distanceFromStart,
                                     t.startWidth, t.endWidth, n.x, n.y, n.z, t.surface.material as NSString))
                        cursor = side == .right ? t.right : t.left
                    }
                }
            }
            exit(0)
        }
        if let distance = options.roadCamera {
            // Driver's-eye camera on the main road: `--road-camera D` puts the
            // eye D metres from the start line at 1.2 m, looking 40 m ahead.
            // `--road-lateral` is the fraction across the width, 0 = right edge.
            func point(_ along: Float) -> SIMD3<Float> {
                let total = road.length
                var d = along.truncatingRemainder(dividingBy: total)
                if d < 0 { d += total }
                let mains = road.geometry.mainSegments
                var index = mains[0]
                for m in mains where road.geometry.segments[m].distanceFromStart <= d { index = m }
                let segment = road.geometry.segments[index]
                let fraction = min(max((d - segment.distanceFromStart) / max(segment.length, 1e-3), 0), 1)
                let toStart = segment.extent * fraction
                let width = road.geometry.width(segment: index, toStart: toStart)
                let local = TrackLocalPosition(segment: index, toStart: toStart, toRight: width * options.roadCameraLateral)
                let xy = road.geometry.localToGlobal(local)
                return SIMD3(xy.x, xy.y, road.geometry.height(local))
            }
            let eye = point(distance) + SIMD3(0, 0, 1.2 + options.roadAerial)
            let ahead = point(distance + 40 + options.roadAerial) + SIMD3(0, 0, 0.8)
            options.eye = eye
            options.target = ahead
            print("road camera at \(distance) m: eye \(eye), target \(ahead)")
        }
        let terrainParameters = TerrainParameters(document: document)
        if options.terrainOnly {
            scene = RenderScene(batches: [], minimum: scene.minimum, maximum: scene.maximum)
        }
        if let ground = try TrackSurfaceAssembly.terrainBatch(road.geometry, parameters: terrainParameters) {
            scene = scene.adding([ground])
            print("terrain: \(ground.mesh.indices.count / 3) triangles, surface \(terrainParameters.surface)")
        }
        if options.generateTrack {
            let before = scene.batches.count
            scene = TrackSurfaceAssembly.strippingTrackgen(scene)
            var generated = try TrackSurfaceAssembly.roadBatches(road.geometry)
            generated += try TrackSurfaceAssembly.pitBatches(road.geometry, pits: road.pits)
            generated += try TrackSurfaceAssembly.furnitureBatches(road.geometry)
            let gridConfiguration = try StartingGridConfiguration(race: document, raceName: "", track: document)
            gridBoxes = (try? StartingGrid.slots(road: road, configuration: gridConfiguration, cars: 20))?
                .map { RoadPaint.Box(centre: $0.world, yaw: $0.yaw) } ?? []
            scene = TrackSurfaceAssembly.strippingPitComplex(scene, garages: PitGeneration.footprints(road.geometry, pits: road.pits))
            if options.grass {
                var grassParameters = GrassGeneration.Parameters()
                if options.grassEverywhere { grassParameters.skipBehindBarriersTallerThan = .infinity }
                let grass = try TrackSurfaceAssembly.grassBatches(road.geometry, parameters: grassParameters)
                print("grass: \(grass.count) chunks, \(grass.reduce(0) { $0 + $1.mesh.indices.count / 6 }) cards")
                generated += grass
            }
            scene = scene.adding(generated)
            print("generated road: \(generated.count) materials, \(generated.reduce(0) { $0 + $1.mesh.indices.count / 3 }) triangles; \(before - (scene.batches.count - generated.count)) baked batches replaced")
        }
    }
    var settings = RenderSettings(preset: options.preset)
    settings.depthPrepass = options.depthPrepass
    if let upscale = options.upscale { settings.upscaling = upscale }
    if let mode = options.upscalingMode { settings.upscalingMode = mode }
    if let scale = options.renderScale { settings.renderScale = scale }
    if let bloom = options.bloom { settings.bloom = bloom }
    if let strength = options.bloomStrength { settings.bloomStrength = strength }
    if let threshold = options.bloomThreshold { settings.bloomThreshold = threshold }
    if let ao = options.ambientOcclusion { settings.ambientOcclusion = ao }
    if let contact = options.contactShadows { settings.contactShadows = contact }
    if let ssr = options.reflections { settings.screenSpaceReflections = ssr }
    if let blur = options.motionBlur { settings.motionBlur = blur }
    if let glare = options.sunGlare { settings.sunGlare = glare }
    if let haze = options.heatHaze { settings.heatHaze = haze }
    if let refresh = options.shadowRefresh { settings.staticShadowRefreshInterval = max(1, refresh) }
    if let anisotropy = options.detailAnisotropy { settings.detailAnisotropy = anisotropy }
    if let temporal = options.reflectionTemporal { settings.reflectionTemporal = temporal }
    if let cascades = options.cascades { settings.shadowCascades = max(0, min(4, cascades)) }
    let startupClock = DispatchTime.now()
    if options.startup, let device = MTLCreateSystemDefaultDevice() {
        let t0 = DispatchTime.now()
        let shaders = try ShaderLibrary(device: device)
        let t1 = DispatchTime.now()
        print(String(format: "shader library: %.1f ms (%@)", Double(t1.uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6,
                     shaders.prebuilt ? "prebuilt metallib" : "compiled from source"))
    }
    let renderer = try ForwardRenderer(settings: settings)
    if options.startup {
        let t = DispatchTime.now()
        print(String(format: "renderer construction: %.1f ms (shaders %@)",
                     Double(t.uptimeNanoseconds - startupClock.uptimeNanoseconds) / 1e6,
                     renderer.shadersPrebuilt ? "prebuilt" : "from source"))
        let w0 = DispatchTime.now()
        let built = try renderer.prewarmSpatialScalers(outputWidth: options.width, outputHeight: options.height)
        let w1 = DispatchTime.now()
        print(String(format: "scaler pre-warm: %d scalers in %.1f ms", built, Double(w1.uptimeNanoseconds - w0.uptimeNanoseconds) / 1e6))
    }
    renderer.animationTime = Double(options.animationTime)
    renderer.wetness = options.wetness
    renderer.roadPaint.set(gridBoxes)
    if options.passes { renderer.passTimer = try PassTimer(device: renderer.device) }
    var passSamples: [String: [Double]] = [:]
    renderer.rain = options.rain
    if options.rain > 0 { renderer.wetness = max(renderer.wetness, options.rain) }
    if !gridBoxes.isEmpty { print("grid: \(gridBoxes.count) boxes painted") }
    if let radius = options.aoRadius { renderer.occlusion.ambientRadius = radius }
    if let power = options.aoPower { renderer.occlusion.ambientPower = power }
    // Default to the scene file's own directory, which is where the original
    // per-track artwork sits. Extra roots are explicit, never implicit.
    var roots = options.textureRoots.map { URL(fileURLWithPath: $0) }
    roots.append(URL(fileURLWithPath: options.input).deletingLastPathComponent())
    // Generated atlases are resolved by name from the materials directory.
    if let materials = options.materials { roots.append(URL(fileURLWithPath: materials)) }
    let textures = TextureStore(device: renderer.device, roots: roots)
    if options.noCull {
        scene = RenderScene(batches: scene.batches.map {
            RenderBatch(mesh: $0.mesh, baseTexture: $0.baseTexture, blends: $0.blends, isDeferred: $0.isDeferred,
                        alphaTestThreshold: $0.alphaTestThreshold, culls: false, isDriver: $0.isDriver,
                        sourceMaterial: $0.sourceMaterial, material: $0.material)
        }, minimum: scene.minimum, maximum: scene.maximum, warnings: scene.warnings)
    }
    if options.trees {
        if let atlas = textures.image(named: TreeForest.textureName) {
            let before = scene.batches.count
            let (replaced, forest) = try TrackSurfaceAssembly.replacingTrees(scene, atlas: atlas, detail: options.treeDetail)
            scene = replaced
            print("trees: \(forest.placements.count) placements, \(before) -> \(scene.batches.count) batches")
        } else {
            print("trees: atlas \(TreeForest.textureName) not found in the texture roots")
        }
    }
    var library: MaterialLibrary? = nil
    var materialDirectory: URL? = nil
    if let path = options.materials {
        materialDirectory = URL(fileURLWithPath: path)
        library = try MaterialLibrary(device: renderer.device, directory: materialDirectory!)
    }
    let resources = try SceneResources(device: renderer.device, scene: scene, textures: textures,
                                       materials: library, materialDirectory: materialDirectory)
    if let library {
        print("materials: \(library.substitutionCount) textures substituted, "
              + "\(library.markingsPreserved.count) with markings preserved, "
              + "using \(library.materialsUsed.sorted().joined(separator: ", "))")
    }

    let camera: RenderCamera
    if let eye = options.eye, let target = options.target {
        camera = RenderCamera(eye: eye, target: target,
                              verticalFieldOfView: options.fieldOfView * radians)
    } else {
        camera = RenderCamera(framing: scene.minimum, scene.maximum,
                              azimuth: options.azimuth * radians,
                              elevation: options.elevation * radians)
    }
    let sunAzimuth = options.sunAzimuth * radians, sunElevation = options.sunElevation * radians
    var lighting = SunLighting(
        direction: SIMD3(cos(sunAzimuth) * cos(sunElevation),
                         sin(sunAzimuth) * cos(sunElevation),
                         sin(sunElevation)),
        intensity: options.sunIntensity,
        ambient: SIMD3(0.16, 0.20, 0.28) * options.ambient,
        exposureEV100: options.exposure)

    // Interleaved A/B in one process. This machine is fanless, so its GPU
    // clock falls under sustained load: two configurations measured minutes
    // apart are not comparable, and the drift is larger than the effect
    // being measured. Alternating frame by frame cancels it, which is the
    // same methodology the classic path's benchmarks use.
    func compare(_ name: String, set: (inout RenderSettings, Bool) -> Void) throws -> Never {
        var samples: [Bool: [Double]] = [false: [], true: []]
        let warmups = 20, pairs = 60
        for frame in 0 ..< (warmups + pairs * 2) {
            let on = frame.isMultiple(of: 2)
            set(&renderer.settings, on)
            _ = try renderer.render(scene: resources, camera: camera, lighting: lighting,
                                    width: options.width, height: options.height)
            if frame >= warmups { samples[on, default: []].append(renderer.lastGPUTime * 1000) }
        }
        func report(_ key: Bool) -> String {
            let sorted = samples[key]!.sorted()
            let median = sorted[sorted.count / 2]
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            return String(format: "median %.3f ms  p95 %.3f ms  (n=%d)", median, p95, sorted.count)
        }
        print("interleaved \(name) comparison, \(options.width)x\(options.height)")
        print("  \(name) off  \(report(false))")
        print("  \(name) on   \(report(true))")
        let off = samples[false]!.sorted()[samples[false]!.count / 2]
        let on = samples[true]!.sorted()[samples[true]!.count / 2]
        print(String(format: "  delta        %+.3f ms (%+.1f%%)", on - off, (on - off) / off * 100))
        exit(0)
    }
    if options.comparePrepass { try compare("depth prepass") { $0.depthPrepass = $1 } }
    if options.compareBloom { try compare("bloom") { $0.bloom = $1 } }
    if options.compareUpscale {
        // Blocks rather than single frames: toggling upscaling changes the
        // render targets, and alternating every frame would measure target
        // reallocation and a cold temporal history rather than the scaler.
        // Eight blocks of thirty, the first ten of each discarded.
        var samples: [Bool: [Double]] = [false: [], true: []]
        for block in 0 ..< 8 {
            let on = block.isMultiple(of: 2)
            renderer.settings.upscaling = on
            for frame in 0 ..< 30 {
                _ = try renderer.render(scene: resources, camera: camera, lighting: lighting,
                                        width: options.width, height: options.height)
                if frame >= 10 { samples[on, default: []].append(renderer.lastGPUTime * 1000) }
            }
        }
        func report(_ key: Bool) -> String {
            let sorted = samples[key]!.sorted()
            return String(format: "median %.3f ms  p95 %.3f ms  (n=%d)", sorted[sorted.count / 2],
                          sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))], sorted.count)
        }
        let size = settings.renderSize(output: (options.width, options.height))
        print("block-interleaved upscaling comparison, output \(options.width)x\(options.height), render \(size.width)x\(size.height)")
        print("  native      \(report(false))")
        print("  upscaled    \(report(true))\(renderer.lastUpscalerError.map { "  error: " + $0 } ?? "")")
        let off = samples[false]!.sorted()[samples[false]!.count / 2], on = samples[true]!.sorted()[samples[true]!.count / 2]
        print(String(format: "  delta       %+.3f ms (%+.1f%%)", on - off, (on - off) / off * 100))
        exit(0)
    }
    if options.sustainSeconds > 0 {
        // The fanless Air's steady state is the real target, and every short
        // measurement in this project has been taken on a chip somewhere on
        // its way down from a cold start. Render continuously and report the
        // median GPU time per fifteen-second window, orbiting so the frame
        // is not a cached best case.
        let start = Date()
        var window: [Double] = [], windows: [(Double, Double, Double)] = []
        var windowStart = start, frame = 0
        print("sustained run, \(options.width)x\(options.height), \(Int(options.sustainSeconds)) s")
        while Date().timeIntervalSince(start) < options.sustainSeconds {
            let frameCamera = RenderCamera(framing: scene.minimum, scene.maximum,
                                           azimuth: (options.azimuth + 0.5 * Float(frame)) * radians,
                                           elevation: options.elevation * radians)
            _ = try renderer.render(scene: resources, camera: frameCamera, lighting: lighting,
                                    width: options.width, height: options.height)
            window.append(renderer.lastGPUTime * 1000)
            // `--dynamic` lets the resolution controller act, as presentation
            // would, so the valve can be watched opening.
            if options.dynamic { renderer.recordDynamicResolution(gpuTime: renderer.lastGPUTime) }
            frame += 1
            if Date().timeIntervalSince(windowStart) >= 15 {
                let sorted = window.sorted()
                let median = sorted[sorted.count / 2], p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
                windows.append((Date().timeIntervalSince(start), median, p95))
                print(String(format: "  t=%4.0f s  median %6.3f ms  p95 %6.3f ms  (%d frames)  scale %.2f",
                             Date().timeIntervalSince(start), median, p95, sorted.count, renderer.effectiveRenderScale))
                window.removeAll(); windowStart = Date()
            }
        }
        if let first = windows.first, let last = windows.last {
            print(String(format: "  first window %.3f ms, last window %.3f ms: %+.1f%%",
                         first.1, last.1, (last.1 - first.1) / first.1 * 100))
        }
        exit(0)
    }
    if options.rain > 0 {
        // Rain: the sun dimmed as presentation dims it, and a second of
        // streaks pre-rolled around the camera so the frame is in the rain.
        lighting.intensity *= 1 - 0.7 * options.rain
        lighting.ambient *= 1 + 0.1 * options.rain
        lighting.exposureEV100 -= 1.2 * options.rain
        for _ in 0 ..< 70 {
            renderer.particles.sources = [ParticleSystem.Source(kind: .rain, position: camera.eye, velocity: .zero, intensity: options.rain)]
            renderer.particles.advance(by: 1 / 60)
        }
        print("rain: \(renderer.particles.count) drops in the air")
    }
    if options.smokeFrames > 0 {
        // A stationary car's rear wheels spinning up: two sources a frame,
        // stepped at 60 Hz so the cloud has had time to rise and thin.
        for _ in 0 ..< options.smokeFrames {
            renderer.particles.sources = [
                ParticleSystem.Source(kind: .smoke, position: SIMD3(-1.25, -0.8, 0.03), velocity: SIMD3(-2, 0, 0), intensity: 0.9),
                ParticleSystem.Source(kind: .smoke, position: SIMD3(-1.25, 0.8, 0.03), velocity: SIMD3(-2, 0, 0), intensity: 0.9),
                ParticleSystem.Source(kind: .dust, position: SIMD3(1.25, -0.8, 0.03), velocity: SIMD3(-3, 0, 0), intensity: 0.7)]
            renderer.particles.advance(by: 1 / 60)
        }
        print("particles: \(renderer.particles.count) live after \(options.smokeFrames) frames")
    }
    if options.skid {
        // Two rear tyres through an S, 12 m long, fading in and out.
        let steps = 80
        for step in 0 ..< steps {
            let t = Float(step) / Float(steps - 1)
            let x = -6 + t * 12, y = sin(t * .pi * 2) * 1.2
            let heading = simd_normalize(SIMD3<Float>(1, cos(t * .pi * 2) * 1.2 * 2 * .pi / 12, 0))
            let lateral = SIMD3(-heading.y, heading.x, 0)
            let intensity = sin(t * .pi)
            renderer.skidMarks.sources = [
                SkidMarks.Source(key: 0, position: SIMD3(x, y, 0) - lateral * 0.75, lateral: lateral, width: 0.3, intensity: intensity),
                SkidMarks.Source(key: 1, position: SIMD3(x, y, 0) + lateral * 0.75, lateral: lateral, width: 0.3, intensity: intensity * 0.8)]
            renderer.skidMarks.advance()
        }
        print("skid marks: \(renderer.skidMarks.quadCount) quads")
    }
    if options.compareSkid { try compare("skid marks") { $0.skidMarks = $1 } }
    if options.compareGlare { try compare("sun glare") { $0.sunGlare = $1 } }
    if options.compareHaze { try compare("heat haze") { $0.heatHaze = $1 } }
    if options.compareReflectionTemporal {
        // The history must survive between frames for the reuse to run.
        renderer.resetsHistoryPerRender = false
        try compare("reflection temporal reuse") { $0.reflectionTemporal = $1 }
    }
    if options.compareWet {
        // Wetness is a scene condition, not a setting: toggle it on the renderer.
        let wet = options.wetness > 0 ? options.wetness : 1
        try compare("wet ground") { _, on in renderer.wetness = on ? wet : 0 }
    }
    if options.compareParticles { try compare("particles") { $0.particles = $1 } }
    if options.compareMotionBlur { try compare("motion blur") { $0.motionBlur = $1 } }
    if options.compareReflections {
        let quality = settings.screenSpaceReflections == .off ? .half : settings.screenSpaceReflections
        try compare("reflections") { $0.screenSpaceReflections = $1 ? quality : .off }
    }
    if options.compareOcclusion {
        let quality = settings.ambientOcclusion == .off ? .half : settings.ambientOcclusion
        try compare("occlusion") { $0.ambientOcclusion = $1 ? quality : .off; $0.contactShadows = $1 }
    }

    // Repeat-render methodology matching the classic path's benchmarks:
    // discard warmups, then report median and p95. The first frame builds the
    // atmosphere tables, so a single sample measures startup, not steady state.
    var samples: [Double] = []
    var pixels: [UInt8] = []
    let warmups = options.frames > 1 ? min(10, options.frames) : 0
    for frame in 0 ..< (warmups + options.frames) {
        // `--orbit-speed D` turns the framing camera D degrees per frame, so a
        // still tool can show what depends on motion.
        var frameCamera = camera
        if options.orbitSpeed != 0, options.eye == nil {
            frameCamera = RenderCamera(framing: scene.minimum, scene.maximum,
                                       azimuth: (options.azimuth + options.orbitSpeed * Float(frame)) * radians,
                                       elevation: options.elevation * radians)
        }
        pixels = try renderer.render(scene: resources, camera: frameCamera, lighting: lighting,
                                     width: options.width, height: options.height,
                                     lightState: RenderInstance.lightState(brakeCommand: options.brake ? 1 : 0,
                                                                           lightCommand: options.headlights ? 1 : 0))
        if frame >= warmups {
            samples.append(renderer.lastGPUTime * 1000)
            for sample in renderer.lastPassTimes {
                if sample.vertexSeconds.isFinite { passSamples[sample.name + "|v", default: []].append(sample.vertexSeconds * 1000) }
                if sample.fragmentSeconds.isFinite { passSamples[sample.name + "|f", default: []].append(sample.fragmentSeconds * 1000) }
            }
        }
    }
    if options.memory {
        let bytes = renderer.device.currentAllocatedSize
        print(String(format: "device memory: %.1f MB allocated (budget %.0f MB)", Double(bytes) / 1_048_576,
                     Double(settings.textureMemoryBudgetBytes) / 1_048_576))
    }
    if options.passes {
        // Median per pass over the sampled frames, in the frame's order.
        let order = renderer.lastPassTimes.map(\.name)
        var total = 0.0
        print("per-pass GPU medians over \(samples.count) frames (vertex or encoder stage + fragment stage):")
        func median(_ key: String) -> Double? {
            guard let values = passSamples[key]?.sorted(), !values.isEmpty else { return nil }
            return values[values.count / 2]
        }
        for name in order {
            let v = median(name + "|v"), f = median(name + "|f")
            total += f ?? v ?? 0
            print(String(format: "  %-28@ %7.3f ms  %7.3f ms", name as NSString, v ?? .nan, f ?? .nan))
        }
        print(String(format: "  %-28@ %7.3f ms (sum of the working stages' medians)", "passes" as NSString, total))
    }
    samples.sort()
    let median = samples.isEmpty ? 0 : samples[samples.count / 2]
    let p95 = samples.isEmpty ? 0 : samples[min(samples.count - 1, Int(Double(samples.count) * 0.95))]
    try writePNG(pixels, width: options.width, height: options.height, to: options.output)
    if let view = options.surfaceView {
        // The reflection G-buffer: roughness and specular weight of the sharp
        // lobe, each as greyscale, straight from the target the trace reads.
        let texture = try renderer.targets(outputWidth: options.width, outputHeight: options.height).reflectionSurface
        let raw = try renderer.readback(texture, bytesPerPixel: 8)
        var rough = [UInt8](repeating: 255, count: texture.width * texture.height * 4)
        var weight = rough
        var stats: (minR: Float, maxR: Float, minW: Float, maxW: Float) = (1e9, -1e9, 1e9, -1e9)
        raw.withUnsafeBytes { bytes in
            let halves = bytes.bindMemory(to: UInt16.self)
            for i in 0 ..< texture.width * texture.height {
                let r = Float(Float16(bitPattern: halves[i * 4 + 2])), w = Float(Float16(bitPattern: halves[i * 4 + 3]))
                stats = (min(stats.minR, r), max(stats.maxR, r), min(stats.minW, w), max(stats.maxW, w))
                let g = UInt8(min(max(r, 0), 1) * 255), h = UInt8(min(max(w, 0), 1) * 255)
                rough[i * 4] = g; rough[i * 4 + 1] = g; rough[i * 4 + 2] = g
                weight[i * 4] = h; weight[i * 4 + 1] = h; weight[i * 4 + 2] = h
            }
        }
        // A few raw texels, for layout questions the images cannot answer.
        raw.withUnsafeBytes { bytes in
            let halves = bytes.bindMemory(to: UInt16.self)
            for (x, y) in [(texture.width / 2, texture.height * 7 / 8), (texture.width * 25 / 32, texture.height * 5 / 8),
                           (texture.width * 31 / 64, texture.height * 3 / 8), (texture.width / 2, texture.height / 8)] {
                let i = (y * texture.width + x) * 4
                let v = (0 ..< 4).map { Float(Float16(bitPattern: halves[i + $0])) }
                print(String(format: "  surface (%d,%d): %.3f %.3f %.3f %.3f", x, y, v[0], v[1], v[2], v[3]))
            }
        }
        try writePNG(rough, width: texture.width, height: texture.height, to: view)
        let weightPath = view.replacingOccurrences(of: ".png", with: "-weight.png")
        try writePNG(weight, width: texture.width, height: texture.height, to: weightPath)
        print("surface view: roughness \(stats.minR)...\(stats.maxR), weight \(stats.minW)...\(stats.maxW) -> \(view), \(weightPath)")
    }
    if let view = options.reflectionView {
        if let texture = renderer.reflections.result {
            // rgba16f: reflected radiance and confidence. Radiance is shown
            // clamped to white, confidence as a second greyscale image.
            let raw = try renderer.readback(texture, bytesPerPixel: 8)
            var radiance = [UInt8](repeating: 255, count: texture.width * texture.height * 4)
            var confidence = radiance
            raw.withUnsafeBytes { bytes in
                let halves = bytes.bindMemory(to: UInt16.self)
                for i in 0 ..< texture.width * texture.height {
                    for c in 0 ..< 3 {
                        let v = Float(Float16(bitPattern: halves[i * 4 + c]))
                        radiance[i * 4 + c] = UInt8(min(max(v, 0), 1) * 255)
                    }
                    let a = Float(Float16(bitPattern: halves[i * 4 + 3]))
                    let g = UInt8(min(max(a, 0), 1) * 255)
                    confidence[i * 4] = g; confidence[i * 4 + 1] = g; confidence[i * 4 + 2] = g
                }
            }
            try writePNG(radiance, width: texture.width, height: texture.height, to: view)
            let confidencePath = view.replacingOccurrences(of: ".png", with: "-confidence.png")
            try writePNG(confidence, width: texture.width, height: texture.height, to: confidencePath)
            print("reflection view: \(texture.width)x\(texture.height) -> \(view), \(confidencePath)")
        } else {
            print("reflection view: no reflection target this frame")
        }
    }
    if let view = options.occlusionView {
        if let texture = renderer.occlusion.result {
            // Two greyscale images: ambient visibility, and sun visibility.
            let raw = try renderer.readback(texture, bytesPerPixel: 2)
            var ambient = [UInt8](repeating: 255, count: texture.width * texture.height * 4)
            var contact = ambient
            for i in 0 ..< texture.width * texture.height {
                ambient[i * 4] = raw[i * 2]; ambient[i * 4 + 1] = raw[i * 2]; ambient[i * 4 + 2] = raw[i * 2]
                contact[i * 4] = raw[i * 2 + 1]; contact[i * 4 + 1] = raw[i * 2 + 1]; contact[i * 4 + 2] = raw[i * 2 + 1]
            }
            try writePNG(ambient, width: texture.width, height: texture.height, to: view)
            let contactPath = view.replacingOccurrences(of: ".png", with: "-contact.png")
            try writePNG(contact, width: texture.width, height: texture.height, to: contactPath)
            print("occlusion view: \(texture.width)x\(texture.height) -> \(view), \(contactPath)")
        } else {
            print("occlusion view: no occlusion target this frame")
        }
    }

    if options.stats {
        let cascades = ShadowCascades(camera: camera, sunDirection: lighting.direction,
                                      aspect: Float(options.width) / Float(options.height),
                                      count: 4, resolution: 2048, shadowDistance: 400).cascades
        for (i, c) in cascades.enumerated() {
            print(String(format: "cascade %d: split %.1f m, texel %.4f m, depthRange %.1f m",
                         i, c.splitDistance, c.texelWorldSize, c.depthRange))
        }
    }
    if options.stats {
        // Distribution of resolved materials, to tell "untextured but correct"
        // apart from "the diffuse colour never arrived".
        var buckets: [String: Int] = [:]
        var darkest = Float(1), brightest = Float(0)
        for batch in scene.batches {
            let c = batch.material.baseColour
            let luma = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
            darkest = min(darkest, luma); brightest = max(brightest, luma)
            let key = String(format: "luma %.1f rough %.2f", (luma * 10).rounded() / 10, batch.material.roughness)
            buckets[key, default: 0] += 1
        }
        var specBuckets: [String: Int] = [:]
        for batch in scene.batches {
            let m = batch.sourceMaterial.material
            let spec = m.count >= 3 ? max(m[0], max(m[1], m[2])) : 0
            let shine = m.count >= 13 ? m[12] : 0
            specBuckets[String(format: "specular %.3f shininess %.1f", spec, shine), default: 0] += 1
        }
        for (key, count) in specBuckets.sorted(by: { $0.value > $1.value }).prefix(6) {
            print("  \(key): \(count) batches")
        }
        print("materials: \(buckets.count) distinct, luma range \(String(format: "%.3f", darkest)) to \(String(format: "%.3f", brightest))")
        for (key, count) in buckets.sorted(by: { $0.value > $1.value }).prefix(8) {
            print("  \(key): \(count) batches")
        }
        let deferred = scene.batches.filter(\.isDeferred), blending = scene.batches.filter(\.blends)
        print("  deferred (transparent) batches: \(deferred.count), blending: \(blending.count), of \(scene.batches.count)")
        let textured = scene.batches.filter { $0.baseTexture != nil }.count
        print("  batches with a base texture: \(textured) of \(scene.batches.count)")
    }

    let megabytes = Double(resources.bufferBytes) / 1_048_576
    print("""
    bounds        \(scene.minimum) .. \(scene.maximum)
    rendered \(options.width)x\(options.height) -> \(options.output)
      batches       \(renderer.lastDrawCount)
      triangles     \(renderer.lastTriangleCount)
      geometry      \(String(format: "%.2f", megabytes)) MiB
      scalerBuilds  \(renderer.upscalerBuildCount)\(renderer.lastUpscalerError.map { " error: " + $0 } ?? "")
      bloom         \(settings.bloom ? "on, strength \(settings.bloomStrength), threshold \(settings.bloomThreshold) exposed, \(renderer.bloom.levelCount) levels" : "off")
      occlusion     ao \(String(describing: settings.ambientOcclusion)), contact \(settings.contactShadows ? "on" : "off")\(renderer.occlusion.result.map { ", \($0.width)x\($0.height)" } ?? "")
      motion blur   \(settings.motionBlur ? "on" : "off")\(renderer.motionBlur.result != nil ? ", applied" : "")
      reflections   \(String(describing: settings.screenSpaceReflections))\(renderer.reflections.result.map { ", \($0.width)x\($0.height)" } ?? "")
      upscaling     \(settings.upscaling ? "\(settings.upscalingMode.rawValue), render \(settings.renderSize(output: (options.width, options.height)).width)x\(settings.renderSize(output: (options.width, options.height)).height)" : "off")
      textures      \(textures.count) uploaded, \(String(format: "%.1f", Double(textures.uploadedBytes) / 1_048_576)) MiB
      textured      \(resources.texturedBatches) of \(resources.batchCount) batches
      missing       \(textures.missing.count)\(textures.missing.isEmpty ? "" : ": " + textures.missing.sorted().prefix(6).joined(separator: ", "))
      gpu median    \(String(format: "%.3f", median)) ms over \(samples.count) frames
      gpu p95       \(String(format: "%.3f", p95)) ms
    """)
} catch {
    FileHandle.standardError.write(Data("torcs-rendershot: \(error)\n".utf8))
    exit(1)
}
