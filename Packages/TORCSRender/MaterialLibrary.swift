// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import CryptoKit
import Metal
import simd
import TORCSAssets
import TORCSMaterials

/// A generated set's normal and its roughness in one texture, so a surface
/// is two samples and not three: roughness in red, the normal's y in green,
/// occlusion in blue and the normal's x in alpha, block-compressed as BC3.
///
/// The generator writes a normal map and an occlusion-roughness-metalness
/// map; they are put together here, when a set is first loaded, and what
/// was two textures at 8 and 4 bits a texel is one at 8. That is not free.
/// BC3 gives its alpha eight levels a block between 8-bit endpoints, as BC5
/// gave each of the normal's two channels; its colour has four levels
/// between 5:6:5 endpoints for all three channels at once. So the normal's
/// y is coarser than it was and the roughness and occlusion share a line
/// with it: over the generated sets the normal's mean error goes from 0.9
/// to 1.4 degrees and the roughness's and the occlusion's about double,
/// with a longer tail at hard edges. The numbers are in FRAME_RATE.md.
///
/// Metalness is not stored. It is one value across every set, nought or
/// one, and the manifest says which.
public enum StructureMap {
    /// The colour block's fit: the normal's y counts double. The result
    /// hardly moves with the weights; the format decides it.
    public static let weights = SIMD3<Double>(1, 2, 1)
    /// Added to the normal's y before it is stored. Green's 6-bit endpoints
    /// cannot hold 128, the flat normal, and 130 they can: so a flat map
    /// stays exactly flat, and the shader takes the two back off.
    public static let greenBias: UInt8 = 2
    /// Part of what a kept encode is keyed by, so a change to the layout
    /// here is never served an old one.
    static let layout = "structure-1: R roughness, G normal y + 2, B occlusion, A normal x"

    /// One RGBA8 image from a normal map (x in red, y in green) and an ORM
    /// map (occlusion in red, roughness in green) of the same size.
    public static func pack(normal: [UInt8], orm: [UInt8]) -> [UInt8] {
        precondition(normal.count == orm.count && normal.count % 4 == 0)
        var packed = [UInt8](repeating: 0, count: normal.count)
        for i in stride(from: 0, to: normal.count, by: 4) {
            packed[i] = orm[i + 1]
            packed[i + 1] = UInt8(min(Int(normal[i + 1]) + Int(greenBias), 255))
            packed[i + 2] = orm[i]
            packed[i + 3] = normal[i]
        }
        return packed
    }
}

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
        /// The normal, the roughness and the occlusion: see `StructureMap`.
        public let structure: MTLTexture
        /// Metres one tile covers, from the generator's manifest. Geometry
        /// whose UVs are in metres divides by this; a 2 m asphalt tile sampled
        /// once per metre has its aggregate at half a millimetre and reads as
        /// flat grey.
        public let worldSize: Float
        /// A metal set, by the manifest: its surface's metalness is one, and
        /// any other set's is nought.
        public let metallic: Bool
    }
    /// Per-material tile size from `materials.json`, when the directory has one.
    private var worldSizes: [String: Float] = [:]
    private var metals: Set<String> = []

    private let device: MTLDevice
    private var cache: [String: Binding] = [:]
    /// Keyed by texture rather than material: two roads sharing a material may
    /// carry different markings, so each needs its own composited albedo.
    private var composited: [String: Binding] = [:]
    public private(set) var substitutions: [String: String] = [:]

    /// Ordered longest-first so a specific match wins over a general one:
    /// `tr-g-to-asphalt` is a grass-to-asphalt transition, not asphalt.
    public static let rules: [(fragment: String, material: String)] = [
        ("g-to-asphalt", "grass"), ("to-asphalt", "grass"),
        ("asphalt-pit", "concrete"), ("tarmac-wall", "concrete"),
        // Aalborg's side strips and its second asphalt are the older, patched tarmac.
        ("asphalt-aa-l", "asphalt-patched"), ("asphalt-aa-1-l", "asphalt-patched"), ("asphalt-2", "asphalt-patched"),
        ("asphalt", "asphalt"), ("tarmac", "asphalt"), ("road", "asphalt"),
        ("curb", "kerb"), ("kerb", "kerb"),
        ("grass-dry", "grass-dry"), ("grass", "grass"), ("gazon", "grass"),
        ("concrete", "concrete"), ("beton", "concrete"),
        ("armco", "armco"), ("guardrail", "armco"), ("rail", "armco"),
        ("tyre", "tyre-wall"), ("tire", "tyre-wall"), ("pneu", "tyre-wall"),
        // Wood before fence: a wooden fence is wood.
        ("wood", "wood"), ("bois", "wood"), ("painted-steel", "painted-steel"), ("poutre", "painted-steel"), ("pylon", "painted-steel"),
        ("fence", "chain-link"), ("grillage", "chain-link"),
        ("brick", "brick"), ("brique", "brick"),
        // Track barriers are painted concrete walls in every TORCS circuit.
        ("barrier", "concrete"), ("wall", "concrete"),
        ("gravel", "gravel"), ("sand", "sand"),
        ("mud", "mud"), ("boue", "mud"),
        ("dirt", "dirt"), ("terre", "dirt"),
    ]

    /// Detail sets for the parts of a car: the atlas keeps the colour, the
    /// set supplies surface structure. Nil keeps the part as it is.
    public static func detail(for part: CarMaterials.Part) -> (material: String, uvScale: Float)? {
        switch part {
        case .paint: return ("paint-flake", 40)
        case .wheel: return ("rubber-tread", 6)
        case .interior: return ("fabric", 12)
        case .driver: return ("fabric", 8)
        case .glass, .lens, .brakeLens, .headLens: return nil
        }
    }

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
                if let name = entry["name"] as? String, entry["metal"] as? Bool == true { metals.insert(name) }
            }
        }
        self.device = device
        let manifest = directory.appendingPathComponent("materials.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else {
            throw RenderError.unavailable("No generated materials at \(directory.path); run torcs-matgen")
        }
    }

    /// Upload the maps block-compressed — BC1 for albedo, BC3 for the
    /// structure — a quarter to an eighth of the memory and bandwidth of RGBA8.
    /// Process-wide, for measurement: the render tool's `--no-compression`.
    nonisolated(unsafe) public static var compressesMaps = true
    /// Bytes of texture uploaded by this library, for the record.
    public private(set) var uploadedBytes = 0
    /// Maps whose encode was read from a sidecar rather than done.
    public private(set) var sidecarHits = 0

    /// The block format a map takes: colour in BC1 (opaque, 4 bits a texel),
    /// the structure's four channels in BC3.
    public static func format(forMap suffix: String) -> BlockCompression.Format {
        suffix == "structure" ? .bc3 : .bc1
    }

    /// The structure texture of a set, from its normal and ORM maps: packed,
    /// given its mips, and encoded once, the encode kept beside the sources
    /// and keyed by both of them. Nil when either is missing or they differ
    /// in size.
    private func loadStructure(_ material: String, directory: URL) -> MTLTexture? {
        func url(_ suffix: String) -> URL { directory.appendingPathComponent("\(material)-\(suffix).png") }
        guard let normalData = try? Data(contentsOf: url("normal")),
              let ormData = try? Data(contentsOf: url("orm")) else { return nil }
        func levels() -> [(width: Int, height: Int, pixels: [UInt8])]? {
            guard let normal = try? TextureLoading.decode(normalData), let orm = try? TextureLoading.decode(ormData),
                  normal.width == orm.width, normal.height == orm.height else { return nil }
            // Data, not colour: the mips are plain averages of each channel,
            // alpha among them.
            guard let packed = try? TextureImage(width: normal.width, height: normal.height, channels: 4,
                                                 pixels: StructureMap.pack(normal: normal.rgba8, orm: orm.rgba8))
            else { return nil }
            return try? TextureLoading.linearMipChain(packed, preserveCutoutCoverage: false, encodeAsColour: false)
        }
        guard Self.compressesMaps else {
            guard let levels = levels() else { return nil }
            uploadedBytes += levels.reduce(0) { $0 + $1.width * $1.height * 4 }
            return try? TextureLoading.upload(levels, device: device, srgb: false)
        }
        var hash = SHA256()
        hash.update(data: Data(StructureMap.layout.utf8))
        hash.update(data: normalData)
        hash.update(data: ormData)
        let sourceHash = Array(hash.finalize())
        let sidecar = directory.appendingPathComponent("\(material)-structure.bc3.torcsbc")
        let chain: TextureLoading.CompressedChain
        if let cached = MapSidecar.read(sidecar, sourceHash: sourceHash, format: .bc3) {
            chain = cached
            sidecarHits += 1
        } else {
            guard let levels = levels(),
                  let encoded = try? TextureLoading.compress(levels, format: .bc3, dataWeights: StructureMap.weights)
            else { return nil }
            chain = encoded
            MapSidecar.write(chain, to: sidecar, sourceHash: sourceHash)
        }
        uploadedBytes += chain.byteCount
        return try? TextureLoading.upload(chain, device: device, srgb: false)
    }

    /// Loads a generated set on first use: its albedo, and its structure.
    private func binding(_ material: String, directory: URL) -> Binding? {
        if let cached = cache[material] { return cached }
        func load(_ suffix: String, srgb: Bool) -> MTLTexture? {
            let url = directory.appendingPathComponent("\(material)-\(suffix).png")
            guard let data = try? Data(contentsOf: url) else { return nil }
            if Self.compressesMaps {
                // An albedo with alpha — a card atlas — keeps it in BC3.
                var format = Self.format(forMap: suffix)
                let sidecarFor = { (format: BlockCompression.Format) in
                    directory.appendingPathComponent("\(material)-\(suffix).\(format.rawValue).torcsbc")
                }
                let chain: TextureLoading.CompressedChain
                if let cached = MapSidecar.read(sidecarFor(format), source: data, format: format)
                    ?? (format == .bc1 ? MapSidecar.read(sidecarFor(.bc3), source: data, format: .bc3) : nil) {
                    chain = cached
                    format = cached.format
                    sidecarHits += 1
                } else {
                    guard let image = try? TextureLoading.decode(data),
                          let levels = try? TextureLoading.linearMipChain(image, preserveCutoutCoverage: false,
                                                                         encodeAsColour: srgb) else { return nil }
                    if format == .bc1, TextureStore.hasTransparency(levels[0].pixels) { format = .bc3 }
                    guard let encoded = try? TextureLoading.compress(levels, format: format) else { return nil }
                    chain = encoded
                    // Best effort: a directory that cannot be written to
                    // costs the encode again next time, nothing more.
                    MapSidecar.write(chain, to: sidecarFor(format), source: data)
                }
                uploadedBytes += chain.byteCount
                return try? TextureLoading.upload(chain, device: device, srgb: srgb)
            }
            guard let image = try? TextureLoading.decode(data),
                  let levels = try? TextureLoading.linearMipChain(image, preserveCutoutCoverage: false,
                                                                 encodeAsColour: srgb) else { return nil }
            uploadedBytes += levels.reduce(0) { $0 + $1.width * $1.height * 4 }
            return try? TextureLoading.upload(levels, device: device, srgb: srgb)
        }
        guard let albedo = load("albedo", srgb: true),
              let structure = loadStructure(material, directory: directory) else { return nil }
        let binding = Binding(albedo: albedo, structure: structure, worldSize: worldSizes[material] ?? 1,
                              metallic: metals.contains(material))
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
        let result = Binding(albedo: albedo, structure: binding.structure, worldSize: binding.worldSize,
                             metallic: binding.metallic)
        composited[texture] = result
        markingsPreserved.insert(texture)
        return result
    }

    /// A detail set by name, for car parts: loaded like any other, and the
    /// caller ignores its albedo.
    public func detailBinding(_ material: String, directory: URL) -> Binding? {
        binding(material, directory: directory)
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

/// A block-compressed mip chain kept beside its source map, so the encode —
/// a second or two of CPU per 2048² map — is paid once per source, not per
/// launch. Named by the map and format, keyed inside by the source's SHA-256
/// so a regenerated map is never served stale blocks, and checksummed so a
/// truncated file is ignored rather than uploaded.
enum MapSidecar {
    static let magic = Array("TORCSBC1".utf8)
    static let version: UInt32 = 1

    static func read(_ url: URL, source: Data, format: BlockCompression.Format) -> TextureLoading.CompressedChain? {
        read(url, sourceHash: Array(SHA256.hash(data: source)), format: format)
    }

    static func read(_ url: URL, sourceHash: [UInt8], format: BlockCompression.Format) -> TextureLoading.CompressedChain? {
        guard let data = try? Data(contentsOf: url), data.count > 64 else { return nil }
        let payload = data.dropLast(32)
        guard Array(SHA256.hash(data: payload)) == Array(data.suffix(32)) else { return nil }
        var bytes = Array(payload)
        var cursor = 0
        func take(_ n: Int) -> [UInt8]? {
            guard cursor + n <= bytes.count else { return nil }
            defer { cursor += n }
            return Array(bytes[cursor ..< cursor + n])
        }
        func u32() -> Int? { take(4).map { Int($0[0]) | Int($0[1]) << 8 | Int($0[2]) << 16 | Int($0[3]) << 24 } }
        guard take(8) == magic, u32() == Int(version),
              take(32) == sourceHash,
              let formatLength = u32(), let formatBytes = take(formatLength),
              String(decoding: formatBytes, as: UTF8.self) == format.rawValue,
              let count = u32(), count > 0, count <= 16 else { return nil }
        var levels: [(width: Int, height: Int, blocks: [UInt8])] = []
        for _ in 0 ..< count {
            guard let width = u32(), let height = u32(), let size = u32(),
                  size == BlockCompression.encodedSize(width: width, height: height, format: format),
                  let blocks = take(size) else { return nil }
            levels.append((width, height, blocks))
        }
        guard cursor == bytes.count else { return nil }
        bytes.removeAll()
        return TextureLoading.CompressedChain(format: format, levels: levels)
    }

    static func write(_ chain: TextureLoading.CompressedChain, to url: URL, source: Data) {
        write(chain, to: url, sourceHash: Array(SHA256.hash(data: source)))
    }

    static func write(_ chain: TextureLoading.CompressedChain, to url: URL, sourceHash: [UInt8]) {
        var bytes = magic
        func u32(_ value: Int) { for shift in [0, 8, 16, 24] { bytes.append(UInt8((value >> shift) & 0xff)) } }
        u32(Int(version))
        bytes += sourceHash
        let name = Array(chain.format.rawValue.utf8)
        u32(name.count); bytes += name
        u32(chain.levels.count)
        for level in chain.levels {
            u32(level.width); u32(level.height); u32(level.blocks.count); bytes += level.blocks
        }
        bytes += Array(SHA256.hash(data: Data(bytes)))
        try? Data(bytes).write(to: url, options: .atomic)
    }
}
