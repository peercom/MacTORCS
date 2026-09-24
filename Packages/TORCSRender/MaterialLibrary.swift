// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Metal
import simd
import TORCSAssets
import TORCSMaterials

/// Substitutes generated physically based materials for original textures.
///
/// The original art supplies a 256-square albedo and nothing else — no normal,
/// no roughness, no occlusion — so a surface can only ever be as convincing as
/// a flat colour. Generated sets supply all three maps at four to sixteen times
/// the resolution.
///
/// Substitution is by name, and deliberately conservative: a texture whose name
/// does not clearly identify a surface keeps its original artwork rather than
/// being guessed at. Getting this wrong is worse than not doing it, because a
/// mis-substituted surface looks confidently incorrect.
///
/// UVs are left alone. The mesh's tiling frequency is what the track author
/// chose and still reads correctly; only the detail within each tile improves.
public final class MaterialLibrary {
    public struct Binding {
        public let albedo: MTLTexture
        public let normal: MTLTexture
        public let orm: MTLTexture
        /// Metres one tile covers, from the generator's manifest. Geometry
        /// whose UVs are in metres divides by this; a 2 m asphalt tile sampled
        /// once per metre has its aggregate at half a millimetre and reads as
        /// flat grey.
        public let worldSize: Float
    }
    /// Per-material tile size from `materials.json`, when the directory has one.
    private var worldSizes: [String: Float] = [:]

    private let device: MTLDevice
    private var cache: [String: Binding] = [:]
    /// Keyed by texture rather than material: two roads sharing a material may
    /// carry different markings, so each needs its own composited albedo.
    private var composited: [String: Binding] = [:]
    public private(set) var substitutions: [String: String] = [:]

    /// Ordered longest-first so a specific match wins over a general one:
    /// `tr-g-to-asphalt` is a grass-to-asphalt transition, not asphalt.
    static let rules: [(fragment: String, material: String)] = [
        ("g-to-asphalt", "grass"), ("to-asphalt", "grass"),
        ("asphalt-pit", "concrete"), ("tarmac-wall", "concrete"),
        ("asphalt", "asphalt"), ("tarmac", "asphalt"), ("road", "asphalt"),
        ("curb", "kerb"), ("kerb", "kerb"),
        ("grass", "grass"), ("gazon", "grass"),
        ("concrete", "concrete"), ("beton", "concrete"),
        // Track barriers are painted concrete walls in every TORCS circuit.
        ("barrier", "concrete"), ("wall", "concrete"),
        ("gravel", "gravel"), ("sand", "gravel"),
        ("dirt", "dirt"), ("terre", "dirt"),
    ]

    /// The generated material a texture name maps to, or nil to keep the
    /// original.
    public static func material(for texture: String) -> String? {
        let name = (texture as NSString).lastPathComponent.lowercased()
        for rule in rules where name.contains(rule.fragment) { return rule.material }
        return nil
    }

    /// - Parameter directory: output of `torcs-matgen`.
    public init(device: MTLDevice, directory: URL) throws {
        if let data = try? Data(contentsOf: directory.appendingPathComponent("materials.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let entries = json["materials"] as? [[String: Any]] {
            for entry in entries {
                if let name = entry["name"] as? String, let size = entry["worldSize"] as? Double, size > 0 {
                    worldSizes[name] = Float(size)
                }
            }
        }
        self.device = device
        let manifest = directory.appendingPathComponent("materials.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            throw RenderError.unavailable("No generated materials at \(directory.path); run torcs-matgen")
        }
    }

    /// Loads a generated set on first use, decoding its three maps.
    private func binding(_ material: String, directory: URL) -> Binding? {
        if let cached = cache[material] { return cached }
        func load(_ suffix: String, srgb: Bool) -> MTLTexture? {
            let url = directory.appendingPathComponent("\(material)-\(suffix).png")
            guard let data = try? Data(contentsOf: url),
                  let image = try? TextureLoading.decode(data),
                  // Normal and ORM are data, not colour: filtering their mips
                  // in linear space would be wrong, and so would an sRGB
                  // decode on the way in.
                  let levels = try? TextureLoading.linearMipChain(image, preserveCutoutCoverage: false,
                                                                 encodeAsColour: srgb) else { return nil }
            return try? TextureLoading.upload(levels, device: device, srgb: srgb)
        }
        guard let albedo = load("albedo", srgb: true),
              let normal = load("normal", srgb: false),
              let orm = load("orm", srgb: false) else { return nil }
        let binding = Binding(albedo: albedo, normal: normal, orm: orm, worldSize: worldSizes[material] ?? 1)
        cache[material] = binding
        return binding
    }

    /// Resolves a texture reference, recording what was substituted.
    ///
    /// - Parameter original: the artwork being replaced. When supplied, any
    ///   painted content in it — lane markings, pit outlines, lettering — is
    ///   composited over the generated albedo, so substitution adds surface
    ///   detail without deleting what the track author painted.
    public func resolve(texture: String, directory: URL, original: TextureImage? = nil) -> Binding? {
        guard let material = Self.material(for: texture) else { return nil }
        guard let binding = binding(material, directory: directory) else { return nil }
        substitutions[texture] = material
        guard let original else { return binding }
        if let existing = composited[texture] { return existing }

        guard original.width == original.height,
              let generatedAlbedo = generatedAlbedoBytes(material, directory: directory) else { return binding }
        let size = Int(Double(generatedAlbedo.count / 4).squareRoot())
        let resampled = MarkingExtraction.resampled(original.rgba8, from: original.width, to: size)
        let merged = MarkingExtraction.composite(generated: generatedAlbedo, original: resampled, size: size)
        guard let levels = try? TextureLoading.linearMipChain(
                  TextureImage(width: size, height: size, channels: 4, pixels: merged),
                  preserveCutoutCoverage: false),
              let albedo = try? TextureLoading.upload(levels, device: device, srgb: true) else { return binding }
        let result = Binding(albedo: albedo, normal: binding.normal, orm: binding.orm, worldSize: binding.worldSize)
        composited[texture] = result
        markingsPreserved.insert(texture)
        return result
    }

    /// Raw generated albedo bytes, cached so compositing several textures onto
    /// the same material decodes it once.
    private var albedoBytes: [String: [UInt8]] = [:]
    private func generatedAlbedoBytes(_ material: String, directory: URL) -> [UInt8]? {
        if let cached = albedoBytes[material] { return cached }
        let url = directory.appendingPathComponent("\(material)-albedo.png")
        guard let data = try? Data(contentsOf: url),
              let image = try? TextureLoading.decode(data) else { return nil }
        let bytes = image.rgba8
        albedoBytes[material] = bytes
        return bytes
    }

    public private(set) var markingsPreserved: Set<String> = []

    public var substitutionCount: Int { substitutions.count }
    public var materialsUsed: Set<String> { Set(substitutions.values) }
}
