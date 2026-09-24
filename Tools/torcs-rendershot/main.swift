// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import simd
import TORCSAssets
import TORCSRender

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
    let scene = try RenderScene(ACScene.parse(data, car: options.car))
    let renderer = try ForwardRenderer(settings: RenderSettings(preset: options.preset))
    // Default to the scene file's own directory, which is where the original
    // per-track artwork sits. Extra roots are explicit, never implicit.
    var roots = options.textureRoots.map { URL(fileURLWithPath: $0) }
    roots.append(URL(fileURLWithPath: options.input).deletingLastPathComponent())
    let textures = TextureStore(device: renderer.device, roots: roots)
    let resources = try SceneResources(device: renderer.device, scene: scene, textures: textures)

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

    let pixels = try renderer.render(scene: resources, camera: camera, lighting: lighting,
                                     width: options.width, height: options.height)
    try writePNG(pixels, width: options.width, height: options.height, to: options.output)

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
        print("materials: \(buckets.count) distinct, luma range \(String(format: "%.3f", darkest)) to \(String(format: "%.3f", brightest))")
        for (key, count) in buckets.sorted(by: { $0.value > $1.value }).prefix(8) {
            print("  \(key): \(count) batches")
        }
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
      textures      \(textures.count) uploaded, \(String(format: "%.1f", Double(textures.uploadedBytes) / 1_048_576)) MiB
      textured      \(resources.texturedBatches) of \(resources.batchCount) batches
      missing       \(textures.missing.count)\(textures.missing.isEmpty ? "" : ": " + textures.missing.sorted().prefix(6).joined(separator: ", "))
      gpu time      \(String(format: "%.3f", renderer.lastGPUTime * 1000)) ms
    """)
} catch {
    FileHandle.standardError.write(Data("torcs-rendershot: \(error)\n".utf8))
    exit(1)
}
