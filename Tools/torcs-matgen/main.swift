// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import CryptoKit
import TORCSMaterials

/// Generates physically based material sets from project code.
///
/// The original content carries no roughness information at all — every one of
/// Aalborg's 1,315 batches is authored identically — and its textures are 256
/// square. No amount of shader work recovers detail that was never there, so
/// the materials have to be authored. Generating them rather than importing
/// them also means they carry the project's own terms and can be bundled, which
/// the original artwork cannot.
///
/// Output is deterministic from the seed, and a manifest records the hash of
/// every file so the pipeline can verify its own output.
struct Options {
    var output = URL(fileURLWithPath: "Artifacts/materials")
    var size = 1024
    var seed: UInt32 = 1
    var names: [String] = MaterialRecipes.all
    var preview = false
}

func writePNG(_ bytes: [UInt8], size: Int, to url: URL) throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let image = CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32,
                              bytesPerRow: size * 4, space: space,
                              // Straight alpha, kept: cutout atlases carry their coverage here.
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false,
                              intent: .defaultIntent),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw MaterialError.unknown("Could not encode \(url.lastPathComponent)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw MaterialError.unknown("Could not write \(url.path)")
    }
}

var options = Options()
var arguments = Array(CommandLine.arguments.dropFirst())
while let argument = arguments.first {
    arguments.removeFirst()
    func next() -> String { arguments.isEmpty ? "" : arguments.removeFirst() }
    switch argument {
    case "--out": options.output = URL(fileURLWithPath: next())
    case "--size": options.size = Int(next()) ?? options.size
    case "--seed": options.seed = UInt32(next()) ?? options.seed
    case "--only": options.names = next().split(separator: ",").map(String.init)
    case "--preview": options.preview = true
    case "--all": break
    default:
        FileHandle.standardError.write(Data("""
        usage: torcs-matgen [--all] [--only a,b] [--out dir] [--size N] [--seed N] [--preview]

          --preview  also write a side-by-side albedo/normal/ORM sheet per material

        """.utf8))
        exit(2)
    }
}

do {
    try FileManager.default.createDirectory(at: options.output, withIntermediateDirectories: true)
    var manifest: [[String: Any]] = []
    var total = 0
    let clock = Date()

    for name in options.names {
        let material = try MaterialRecipes.generate(name, size: options.size, seed: options.seed)
        var entry: [String: Any] = ["name": material.name, "size": material.size,
                                    "worldSize": material.worldSize, "seed": Int(options.seed)]
        for (suffix, bytes) in [("albedo", material.albedo), ("normal", material.normal), ("orm", material.orm)] {
            let url = options.output.appendingPathComponent("\(material.name)-\(suffix).png")
            try writePNG(bytes, size: material.size, to: url)
            entry[suffix] = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
            total += bytes.count
        }
        if options.preview {
            // One sheet per material so all three maps can be judged together;
            // a roughness map is meaningless next to the wrong albedo.
            let sheetWidth = material.size * 3
            var sheet = [UInt8](repeating: 255, count: sheetWidth * material.size * 4)
            for y in 0 ..< material.size {
                for x in 0 ..< material.size {
                    for (panel, source) in [material.albedo, material.normal, material.orm].enumerated() {
                        let from = (y * material.size + x) * 4
                        let to = (y * sheetWidth + panel * material.size + x) * 4
                        for channel in 0 ..< 4 { sheet[to + channel] = source[from + channel] }
                    }
                }
            }
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            if let provider = CGDataProvider(data: Data(sheet) as CFData),
               let image = CGImage(width: sheetWidth, height: material.size, bitsPerComponent: 8,
                                   bitsPerPixel: 32, bytesPerRow: sheetWidth * 4, space: space,
                                   // Straight alpha, kept: cutout atlases carry their coverage here.
                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
               let destination = CGImageDestinationCreateWithURL(
                   options.output.appendingPathComponent("\(material.name)-sheet.png") as CFURL,
                   UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                _ = CGImageDestinationFinalize(destination)
            }
        }
        manifest.append(entry)
        print("  \(material.name.padding(toLength: 14, withPad: " ", startingAt: 0)) "
              + "\(material.size)x\(material.size)  \(String(format: "%.1f", material.worldSize)) m tile")
    }

    try JSONSerialization.data(withJSONObject: ["materials": manifest, "seed": Int(options.seed),
                                                "size": options.size],
                               options: [.prettyPrinted, .sortedKeys])
        .write(to: options.output.appendingPathComponent("materials.json"))
    print("generated \(manifest.count) materials, \(String(format: "%.1f", Double(total) / 1_048_576)) MiB "
          + "uncompressed, in \(String(format: "%.1f", -clock.timeIntervalSinceNow)) s -> \(options.output.path)")
} catch {
    FileHandle.standardError.write(Data("torcs-matgen: \(error)\n".utf8))
    exit(1)
}
