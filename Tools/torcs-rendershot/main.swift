// SPDX-License-Identifier: GPL-2.0-only
import Foundation
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
    var azimuth: Float = -60, elevation: Float = 18
    var sunAzimuth: Float = 135, sunElevation: Float = 40
    var exposure: Float = 0
    var preset = RenderSettings.Preset.m2Air
    var stats = false
    var frames = 1
    var noCull = false
    var terrainOnly = false
    var materials: String? = nil
    var depthPrepass = false
    var bloom: Bool? = nil
    var bloomStrength: Float? = nil
    var bloomThreshold: Float? = nil
    var ambientOcclusion: RenderSettings.Quality? = nil
    var contactShadows: Bool? = nil
    var compareOcclusion = false
    var occlusionView: String? = nil
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
        case "--azimuth": options.azimuth = Float(next()) ?? options.azimuth
        case "--elevation": options.elevation = Float(next()) ?? options.elevation
        case "--sun-azimuth": options.sunAzimuth = Float(next()) ?? options.sunAzimuth
        case "--sun-elevation": options.sunElevation = Float(next()) ?? options.sunElevation
        case "--exposure": options.exposure = Float(next()) ?? options.exposure
        case "--preset": options.preset = RenderSettings.Preset(rawValue: next()) ?? options.preset
        case "--stats": options.stats = true
        case "--no-cull": options.noCull = true
        case "--terrain-only": options.terrainOnly = true
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
        case "--ao": options.ambientOcclusion = ["off": .off, "half": .half, "full": .full][next()]
        case "--contact": options.contactShadows = true
        case "--no-contact": options.contactShadows = false
        case "--occlusion-view": options.occlusionView = next()
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

let options = parse()
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
    var scene = try RenderScene(ACScene.parse(data, car: options.car))

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
        let terrainParameters = TerrainParameters(document: document)
        let apron = TerrainGeneration.apron(road.geometry, parameters: terrainParameters)
        if !apron.isEmpty {
            let mesh = try RenderMesh.build(positions: apron.positions, normals: apron.normals,
                                            uv0: apron.uv0, indices: apron.indices)
            let material = ResolvedMaterial(baseColour: SIMD4(1, 1, 1, 1), roughness: 0.9, metallic: 0)
            let state = ACRenderState(material: [0, 0, 0, 1, 0, 0, 0, 1, 0.2, 0.2, 0.2, 1, 0],
                                      texture: terrainParameters.surface + ".rgb",
                                      flags: 8, alphaClamp: 0)
            if options.terrainOnly {
                scene = RenderScene(batches: [], minimum: scene.minimum, maximum: scene.maximum)
            }
            scene = scene.adding([RenderBatch(mesh: mesh, baseTexture: state.texture,
                                              blends: false, isDeferred: false, alphaTestThreshold: nil,
                                              culls: true, isDriver: false,
                                              sourceMaterial: state, material: material)])
            print("terrain: \(apron.triangleCount) triangles, \(apron.positions.count) vertices, surface \(terrainParameters.surface)")
        }
    }
    var settings = RenderSettings(preset: options.preset)
    settings.depthPrepass = options.depthPrepass
    if let upscale = options.upscale { settings.temporalUpscaling = upscale }
    if let bloom = options.bloom { settings.bloom = bloom }
    if let strength = options.bloomStrength { settings.bloomStrength = strength }
    if let threshold = options.bloomThreshold { settings.bloomThreshold = threshold }
    if let ao = options.ambientOcclusion { settings.ambientOcclusion = ao }
    if let contact = options.contactShadows { settings.contactShadows = contact }
    let renderer = try ForwardRenderer(settings: settings)
    if let radius = options.aoRadius { renderer.occlusion.ambientRadius = radius }
    if let power = options.aoPower { renderer.occlusion.ambientPower = power }
    // Default to the scene file's own directory, which is where the original
    // per-track artwork sits. Extra roots are explicit, never implicit.
    var roots = options.textureRoots.map { URL(fileURLWithPath: $0) }
    roots.append(URL(fileURLWithPath: options.input).deletingLastPathComponent())
    let textures = TextureStore(device: renderer.device, roots: roots)
    if options.noCull {
        scene = RenderScene(batches: scene.batches.map {
            RenderBatch(mesh: $0.mesh, baseTexture: $0.baseTexture, blends: $0.blends, isDeferred: $0.isDeferred,
                        alphaTestThreshold: $0.alphaTestThreshold, culls: false, isDriver: $0.isDriver,
                        sourceMaterial: $0.sourceMaterial, material: $0.material)
        }, minimum: scene.minimum, maximum: scene.maximum, warnings: scene.warnings)
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
    let lighting = SunLighting(
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
            renderer.settings.temporalUpscaling = on
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
        pixels = try renderer.render(scene: resources, camera: camera, lighting: lighting,
                                     width: options.width, height: options.height)
        if frame >= warmups { samples.append(renderer.lastGPUTime * 1000) }
    }
    samples.sort()
    let median = samples.isEmpty ? 0 : samples[samples.count / 2]
    let p95 = samples.isEmpty ? 0 : samples[min(samples.count - 1, Int(Double(samples.count) * 0.95))]
    try writePNG(pixels, width: options.width, height: options.height, to: options.output)
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
      occlusion     ao \(["off","half","full"][settings.ambientOcclusion.rawValue]), contact \(settings.contactShadows ? "on" : "off")\(renderer.occlusion.result.map { ", \($0.width)x\($0.height)" } ?? "")
      upscaling     \(settings.temporalUpscaling ? "on, render \(settings.renderSize(output: (options.width, options.height)).width)x\(settings.renderSize(output: (options.width, options.height)).height)" : "off")
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
