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
        /// How far the surface's colour drifts over tens of metres: see
        /// `MaterialLibrary.macroVariation`.
        public let macroVariation: Float
        /// See `MaterialLibrary.tilesFreely`.
        public let tilesFreely: Bool
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
        ("asphalt-pit", "concrete"), ("tarmac-wall", "concrete-wall"),
        // Aalborg's side strips and its second asphalt are the older, patched tarmac.
        ("asphalt-aa-l", "asphalt-patched"), ("asphalt-aa-1-l", "asphalt-patched"), ("asphalt-2", "asphalt-patched"),
        ("asphalt", "asphalt"), ("tarmac", "asphalt"), ("road", "asphalt"),
        ("curb", "kerb"), ("kerb", "kerb"),
        ("grass-dry", "grass-dry"), ("grass", "grass"), ("gazon", "grass"), ("gras2", "grass"),
        // The cuttings whose artwork is 256 texels or fewer over thirty
        // metres of cliff. The larger rock faces are photographs composed
        // top to bottom, grass at the lip and scree at the foot, and a tile
        // would lose that; they keep their own.
        ("rockg", "rock"), ("rock3", "rock"), ("rock4", "rock"),
        ("snow", "snow"),
        ("concdal", "concrete"), ("cmnt", "concrete"),
        // Walls of laid stone, and the one wall that is a photograph of brick.
        ("rock-wall", "stone-wall"), ("rockwall", "stone-wall"), ("stone-wall", "stone-wall"), ("mur2", "stone-wall"),
        ("wall4", "brick"),
        // Concrete that stands: the walls' own texture and the ones named for it.
        ("concrete2", "concrete-wall"), ("concwall", "concrete-wall"), ("concrete-wall", "concrete-wall"),
        ("concrete", "concrete"), ("beton", "concrete"),
        ("armco", "armco"), ("guardrail", "armco"), ("rail", "armco"),
        // A car's own tyre, unwrapped (`TyreUnwrap`), standing and turning.
        ("car-tyre-rolling", "car-tyre-rolling"), ("car-tyre", "car-tyre"),
        // A tyre wall's top is the same tyres from above, a set of its own.
        ("tyre-top", "tyre-top"),
        ("tyre", "tyre-wall"), ("tire", "tyre-wall"), ("pneu", "tyre-wall"),
        // A pit building's own sets, by the names its garages are made under.
        ("roller-door", "roller-door"), ("blockwork", "blockwork"), ("pit-interior", "blockwork"), ("pit-fascia", "pit-fascia"),
        ("pit-numbers", "pit-numbers"), ("roofing", "roofing"),
        // Wood before fence: a wooden fence is wood.
        ("wood", "wood"), ("bois", "wood"), ("painted-steel", "painted-steel"), ("poutre", "painted-steel"), ("pylon", "painted-steel"),
        // A stand: the steps the people sit on, and the sheet its back is
        // closed in with.
        ("tribb01", "stand-seats"), ("tribb02", "corrugated"),
        // A fence standing on a guard rail is one barrier and one set.
        ("barrier-arbor-fence", "catch-fence"), ("barrier-fence", "catch-fence"),
        ("fence", "chain-link"), ("grillage", "chain-link"),
        ("brick", "brick"), ("brique", "brick"),
        // A circuit's barrier is whatever its surface's texture is a picture
        // of. TORCS's own `tr-barrier` is a guard rail, and so are the
        // photographs several circuits use in its place; the rest are walls.
        ("barrier-metal", "armco"), ("tr-barrier.", "armco"), ("barrier-1.", "armco"), ("barrier.", "armco"),
        ("tr-bar.", "armco"), ("tr-barrier-bw", "armco"), ("barg", "armco"),
        ("barrier", "concrete-wall"), ("wall", "concrete-wall"),
        ("gravel", "gravel"), ("sand", "sand"),
        ("mud", "mud"), ("boue", "mud"),
        ("dirt", "dirt"), ("terre", "dirt"),
    ]

    /// Textures no set replaces whatever the rules say: pictures of whole
    /// things that happen to be named for what they are made of. `walls.rgb`
    /// is the fronts of a village's houses, doors and shutters and all, and
    /// `cwallpt` a pit wall with its windows; as concrete they were grey boxes.
    public static let keeps: [String] = ["walls.", "walls2.", "cwallpt"]

    /// Walls that are pictures of paint: a sponsor's name along a pit wall,
    /// a wall in stripes, a plank in hazard chevrons. Named for the wall,
    /// they were drawn as bare concrete and the paint was gone. They keep
    /// their picture and take a surface under it (`SignArtwork`).
    public static let paintedWalls: [String] = [
        "improveyou-wall", "megafuel-wall", "flatspot-wall", "wall-torcs", "wall-green-yellow", "wall-m1.", "barrier-2.",
    ]

    /// Whether a texture is paint on a wall.
    public static func isPaintedWall(_ texture: String) -> Bool {
        let name = (texture as NSString).lastPathComponent.lowercased()
        return paintedWalls.contains(where: name.contains)
    }

    /// Whether a texture is printed artwork on a board or a banner: an
    /// advertisement, a circuit's name over a bridge, a braking-distance
    /// marker. By how these circuits name them, and no wider.
    public static func isSign(_ texture: String) -> Bool {
        let name = (texture as NSString).lastPathComponent.lowercased()
        guard !name.contains("back") else { return false }
        return ["logo", "sign", "torcsad", "torcs1.", "torcs2.", "torcs-url", "bridgead", "murpub", "dblogo",
                "infomich", "pdkka01", "pdkka02", "turn", "dist0"].contains(where: name.hasPrefix)
            || ["mcn.", "kilo.", "zbrid.", "ref.", "100.", "300."].contains(name.prefix(while: { $0 != "." }) + ".")
    }

    /// What a picture of printed or painted artwork is on, or nil if the
    /// texture is neither.
    public static func signKind(_ texture: String, width: Int, height: Int) -> SignArtwork.Kind? {
        if isPaintedWall(texture) { return .wall }
        return isSign(texture) ? SignArtwork.kind(width: width, height: height) : nil
    }

    /// Detail sets for the parts of a car: the atlas keeps the colour, the
    /// set supplies surface structure. Nil keeps the part as it is.
    public static func detail(for part: CarMaterials.Part) -> (material: String, uvScale: Float)? {
        switch part {
        case .paint: return ("paint-flake", 40)
        case .wheel, .tyre: return ("rubber-tread", 6)
        case .interior: return ("fabric", 12)
        case .driver: return ("fabric", 8)
        // A lamp's lens is moulded: flutes and pillows over the atlas's colour.
        case .lens, .brakeLens, .headLens: return ("lens", 48)
        case .glass, .rim: return nil
        }
    }

    /// How far a set's colour drifts across the ground over tens of metres,
    /// 1 being the most. A tile repeats every few metres and cannot hold
    /// anything that large; the renderer lays it over from the place itself.
    /// Grass varies most, with soil and water and wear; the loose surfaces
    /// less; a laid one, asphalt or concrete, a little, with age and the
    /// batch it was laid from. What is made in a factory does not.
    public static func macroVariation(for material: String) -> Float {
        switch material {
        case "grass", "grass-dry": return 1
        case "dirt", "mud", "rock": return 0.7
        case "sand", "gravel": return 0.5
        case "asphalt", "asphalt-worn", "asphalt-patched": return 0.3
        case "concrete", "snow", "stone-wall": return 0.25
        case "concrete-wall": return 0.2
        case "brick": return 0.15
        default: return 0
        }
    }

    /// Whether a set may be repeated within the original artwork's own
    /// repeat to bring it to its own scale. The ground's sets and anything
    /// else that is the same all over may. A set laid out as the object it
    /// covers, a rail's beams one above another or a wall's tyres from the
    /// ground up, is drawn once across that object or it is three rails
    /// where there was one.
    public static func tilesFreely(_ material: String) -> Bool {
        !["armco", "tyre-wall", "tyre-top", "kerb", "chain-link", "catch-fence", "car-tyre", "car-tyre-rolling",
          "pit-fascia", "pit-numbers"].contains(material)
    }

    /// Whether a set has holes in it: its albedo's alpha says where, and
    /// what it is drawn on is alpha-tested and seen from both sides.
    public static func isCutout(_ material: String) -> Bool {
        ["chain-link", "catch-fence"].contains(material)
    }

    /// The tile size of a set that is drawn once up a generated barrier,
    /// whatever the barrier's height: three beams on a rail a metre high or
    /// one sixty centimetres high, not two and a half. Nil for a set that
    /// goes up a wall by the metre. Equal to the set's `worldSize`, which
    /// the mesh's coordinates are divided by.
    public static func fittedTile(for material: String) -> Float? {
        switch material {
        case "armco": return 2
        case "catch-fence", "chain-link": return 3
        default: return nil
        }
    }

    /// The generated material a texture name maps to, or nil to keep the
    /// original.
    public static func material(for texture: String) -> String? {
        let name = (texture as NSString).lastPathComponent.lowercased()
        for kept in keeps + paintedWalls where name.contains(kept) { return nil }
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
                          let levels = try? TextureLoading.linearMipChain(image, preserveCutoutCoverage: srgb && Self.isCutout(material),
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
                  let levels = try? TextureLoading.linearMipChain(image, preserveCutoutCoverage: srgb && Self.isCutout(material),
                                                                 encodeAsColour: srgb) else { return nil }
            uploadedBytes += levels.reduce(0) { $0 + $1.width * $1.height * 4 }
            return try? TextureLoading.upload(levels, device: device, srgb: srgb)
        }
        guard let albedo = load("albedo", srgb: true),
              let structure = loadStructure(material, directory: directory) else { return nil }
        let binding = Binding(albedo: albedo, structure: structure, worldSize: worldSizes[material] ?? 1,
                              metallic: metals.contains(material),
                              macroVariation: Self.macroVariation(for: material),
                              tilesFreely: Self.tilesFreely(material))
        cache[material] = binding
        return binding
    }

    /// The layer of wear a road wears over its asphalt, when the directory
    /// has one (`road-wear.png`, see `RoadWear`): the tone of the surface in
    /// red, its roughness in green, tar in blue and the edges' grime in
    /// alpha. Block-compressed as data, the encode kept beside it.
    public func roadWear(directory: URL) -> MTLTexture? {
        if let wear { return wear }
        let url = directory.appendingPathComponent("road-wear.png")
        guard !wearMissing, let data = try? Data(contentsOf: url) else { wearMissing = true; return nil }
        func levels() -> [(width: Int, height: Int, pixels: [UInt8])]? {
            guard let image = try? TextureLoading.decode(data) else { return nil }
            return try? TextureLoading.linearMipChain(image, preserveCutoutCoverage: false, encodeAsColour: false)
        }
        var texture: MTLTexture?
        if Self.compressesMaps {
            let sidecar = directory.appendingPathComponent("road-wear.bc3.torcsbc")
            var chain = MapSidecar.read(sidecar, source: data, format: .bc3)
            if chain != nil { sidecarHits += 1 } else if let levels = levels() {
                chain = try? TextureLoading.compress(levels, format: .bc3, dataWeights: SIMD3(1, 1, 1))
                if let chain { MapSidecar.write(chain, to: sidecar, source: data) }
            }
            if let chain {
                uploadedBytes += chain.byteCount
                texture = try? TextureLoading.upload(chain, device: device, srgb: false)
            }
        } else if let levels = levels() {
            uploadedBytes += levels.reduce(0) { $0 + $1.width * $1.height * 4 }
            texture = try? TextureLoading.upload(levels, device: device, srgb: false)
        }
        wear = texture
        wearMissing = texture == nil
        return texture
    }
    private var wear: MTLTexture?
    private var wearMissing = false

    /// A map the sky is drawn from, by its file's name in the directory:
    /// `cloud-map` (data) or `horizon-<kind>` (colour). See `SkyMaps`.
    /// Uncompressed: one of each is in use, and encoding four thousand
    /// texels of horizon at a first launch would be seconds of nothing.
    public func skyMap(_ name: String, directory: URL, colour: Bool, mipmapped: Bool) -> MTLTexture? {
        if let made = skyMaps[name] { return made }
        guard !skyMapsMissing.contains(name),
              let data = try? Data(contentsOf: directory.appendingPathComponent(name + ".png")),
              let image = try? TextureLoading.decode(data),
              var levels = try? TextureLoading.linearMipChain(image, preserveCutoutCoverage: false, encodeAsColour: colour) else {
            skyMapsMissing.insert(name)
            return nil
        }
        if !mipmapped { levels = Array(levels.prefix(1)) }
        guard let made = try? TextureLoading.upload(levels, device: device, srgb: colour) else {
            skyMapsMissing.insert(name)
            return nil
        }
        uploadedBytes += levels.reduce(0) { $0 + $1.width * $1.height * 4 }
        skyMaps[name] = made
        return made
    }
    private var skyMaps: [String: MTLTexture] = [:]
    private var skyMapsMissing: Set<String> = []

    /// Whether the directory's manifest lists a set.
    public func has(_ material: String) -> Bool { worldSizes[material] != nil }

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
                             metallic: binding.metallic, macroVariation: binding.macroVariation,
                             tilesFreely: binding.tilesFreely)
        composited[texture] = result
        markingsPreserved.insert(texture)
        return result
    }

    /// The height one tile of a fitted set stands for, where the set may be
    /// stacked: a guard rail's three beams are a metre, and a barrier three
    /// metres high is nine beams, not three a metre deep each. Nil for a set
    /// that goes up once however tall: a fence has one rail along its top.
    public static func fittedHeight(for material: String) -> Float? {
        material == "armco" ? 1 : nil
    }

    /// Whether a texture is a picture of a building's face: one whose
    /// windows can be found in it (`FacadeStructure`). By name, like the
    /// rules, and no wider: a roof, a ceiling or a car park is none, and
    /// nor is a sheet of several houses and their roofs (`walls.rgb`).
    public static func isFacade(_ texture: String) -> Bool {
        let name = (texture as NSString).lastPathComponent.lowercased()
        guard !["roof", "ceil", "parking", "base"].contains(where: name.contains) else { return false }
        return ["building", "house", "block", "facade", "pitbld", "cwallpt"].contains(where: name.contains)
    }

    /// The structure of a building's face, made from its own picture: glass
    /// where the picture has windows, set back and smooth, and wall
    /// elsewhere. Uncompressed: these are a few hundred texels a side, and
    /// encoding them at every load would cost more than they weigh.
    public func facadeStructure(texture: String, image: TextureImage) -> MTLTexture? {
        if let made = facades[texture] { return made }
        guard !facadesFailed.contains(texture) else { return nil }
        let maps = FacadeStructure.derive(rgba: image.rgba8, width: image.width, height: image.height)
        guard let packed = try? TextureImage(width: image.width, height: image.height, channels: 4,
                                             pixels: StructureMap.pack(normal: maps.normal, orm: maps.orm)),
              let levels = try? TextureLoading.linearMipChain(packed, preserveCutoutCoverage: false, encodeAsColour: false),
              let made = try? TextureLoading.upload(levels, device: device, srgb: false) else {
            facadesFailed.insert(texture)
            return nil
        }
        uploadedBytes += levels.reduce(0) { $0 + $1.width * $1.height * 4 }
        facades[texture] = made
        return made
    }
    private var facades: [String: MTLTexture] = [:]
    private var facadesFailed: Set<String> = []

    /// Whether a texture is a picture of a tree or a wood on a card. By
    /// name, and by where in the name: these circuits end the name of any
    /// cut-out in `tree` or `_arbor`, a flag (`GBtree`), a truss, a row of
    /// spectators (`GSPAtree`), so only a name that begins as a tree's is one.
    public static func isFoliage(_ texture: String) -> Bool {
        let name = (texture as NSString).lastPathComponent.lowercased()
        guard !name.hasPrefix("treewate") else { return false }
        return name.hasPrefix("tree") || name.hasPrefix("alltree") || name.hasPrefix("butree")
            || name.hasPrefix("rk_tree") || name.contains("forest")
            || (name.hasPrefix("arbor") && !name.contains("frame")) || name.hasPrefix("arb0") || name.hasPrefix("michigan-arbor")
    }

    /// The form of a tree card, made from its own picture
    /// (`FoliageStructure`), at half the picture's size.
    public func foliageStructure(texture: String, image: TextureImage) -> MTLTexture? {
        if let made = facades[texture] { return made }
        guard !facadesFailed.contains(texture) else { return nil }
        let half = FoliageStructure.halved(rgba: image.rgba8, width: image.width, height: image.height)
        let maps = FoliageStructure.derive(rgba: half.rgba, width: half.width, height: half.height)
        guard let packed = try? TextureImage(width: half.width, height: half.height, channels: 4,
                                             pixels: StructureMap.pack(normal: maps.normal, orm: maps.orm)),
              let levels = try? TextureLoading.linearMipChain(packed, preserveCutoutCoverage: false, encodeAsColour: false),
              let made = try? TextureLoading.upload(levels, device: device, srgb: false) else {
            facadesFailed.insert(texture)
            return nil
        }
        uploadedBytes += levels.reduce(0) { $0 + $1.width * $1.height * 4 }
        facades[texture] = made
        return made
    }

    /// The surface of a car's cabin and its driver, made from the car's own
    /// picture (`CabinStructure`): paint, trim, skin and cloth, each as it is.
    public func cabinStructure(texture: String, image: TextureImage) -> MTLTexture? {
        let key = "cabin:" + texture
        if let made = facades[key] { return made }
        guard !facadesFailed.contains(key) else { return nil }
        let maps = CabinStructure.derive(rgba: image.rgba8, width: image.width, height: image.height)
        guard let packed = try? TextureImage(width: maps.width, height: maps.height, channels: 4,
                                             pixels: StructureMap.pack(normal: maps.normal, orm: maps.orm)),
              let levels = try? TextureLoading.linearMipChain(packed, preserveCutoutCoverage: false, encodeAsColour: false),
              let made = try? TextureLoading.upload(levels, device: device, srgb: false) else {
            facadesFailed.insert(key)
            return nil
        }
        uploadedBytes += levels.reduce(0) { $0 + $1.width * $1.height * 4 }
        facades[key] = made
        return made
    }

    /// A sign's artwork made larger and sharp, and the surface it is
    /// printed on (`SignArtwork`).
    ///
    /// The artwork is block-compressed and the encode kept in `signCache`
    /// under the picture's own hash, as the original artwork's is: a
    /// circuit has twenty boards, and uncompressed they were fifty
    /// megabytes on Brondehach. The surface depends only on what kind of
    /// sign it is and its shape, so every board of one shape shares one.
    public func signArtwork(texture: String, image: TextureImage) -> (albedo: MTLTexture, structure: MTLTexture)? {
        let key = "sign:" + texture
        if let made = signs[key] { return made }
        guard !facadesFailed.contains(key),
              let kind = Self.signKind(texture, width: image.width, height: image.height) else { return nil }
        let scale = SignArtwork.scale(width: image.width, height: image.height)
        guard let albedo = signPicture(image, scale: scale),
              let structure = signSurface(kind, width: image.width * max(scale / 2, 1), height: image.height * max(scale / 2, 1)) else {
            facadesFailed.insert(key)
            return nil
        }
        signs[key] = (albedo, structure)
        return (albedo, structure)
    }
    private var signs: [String: (albedo: MTLTexture, structure: MTLTexture)] = [:]
    /// Where enlarged artwork's encodes are kept: the cache the original
    /// artwork's are in. Nil encodes at every load.
    public var signCache: URL? = TextureStore.defaultBlockCache()
    /// Enlarged pictures served from `signCache` rather than made.
    public private(set) var signCacheHits = 0
    /// Part of the cache's key: changed when `SignArtwork.enlarged` is.
    static let signVersion = "sign-artwork-1"

    private func signPicture(_ image: TextureImage, scale: Int) -> MTLTexture? {
        let rgba = image.rgba8
        func enlarged() -> [(width: Int, height: Int, pixels: [UInt8])]? {
            let large = SignArtwork.enlarged(rgba: rgba, width: image.width, height: image.height, scale: scale)
            guard let picture = try? TextureImage(width: image.width * scale, height: image.height * scale, channels: 4, pixels: large)
            else { return nil }
            return try? TextureLoading.linearMipChain(picture, preserveCutoutCoverage: false)
        }
        guard TextureStore.compressesUploads else {
            guard let levels = enlarged(), let made = try? TextureLoading.upload(levels, device: device, srgb: true) else { return nil }
            uploadedBytes += levels.reduce(0) { $0 + $1.width * $1.height * 4 }
            return made
        }
        var hash = SHA256()
        hash.update(data: Data("\(Self.signVersion):\(image.width)x\(image.height)x\(scale):".utf8))
        rgba.withUnsafeBytes { hash.update(bufferPointer: $0) }
        let sourceHash = Array(hash.finalize())
        let sidecar = signCache?.appendingPathComponent(sourceHash.map { String(format: "%02x", $0) }.joined() + ".bc1.torcsbc")
        let chain: TextureLoading.CompressedChain
        if let sidecar, let kept = MapSidecar.read(sidecar, sourceHash: sourceHash, format: .bc1) {
            chain = kept
            signCacheHits += 1
        } else {
            guard let levels = enlarged(), let encoded = try? TextureLoading.compress(levels, format: .bc1) else { return nil }
            chain = encoded
            if let sidecar {
                try? FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
                MapSidecar.write(chain, to: sidecar, sourceHash: sourceHash)
            }
        }
        uploadedBytes += chain.byteCount
        return try? TextureLoading.upload(chain, device: device, srgb: true)
    }

    private func signSurface(_ kind: SignArtwork.Kind, width: Int, height: Int) -> MTLTexture? {
        let key = "sign-surface:\(kind.rawValue):\(width)x\(height)"
        if let made = facades[key] { return made }
        let maps = SignArtwork.surface(kind, width: width, height: height)
        guard let packed = try? TextureImage(width: width, height: height, channels: 4,
                                             pixels: StructureMap.pack(normal: maps.normal, orm: maps.orm)),
              let levels = try? TextureLoading.linearMipChain(packed, preserveCutoutCoverage: false, encodeAsColour: false),
              let made = try? TextureLoading.upload(levels, device: device, srgb: false) else { return nil }
        uploadedBytes += levels.reduce(0) { $0 + $1.width * $1.height * 4 }
        facades[key] = made
        return made
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
