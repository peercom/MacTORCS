// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import CryptoKit
import Metal
import simd
import TORCSMath
import TORCSAssets

/// Texture loading for the modern path.
///
/// Two things differ from the classic loader, both deliberate:
///
/// - Albedo is uploaded as `rgba8Unorm_srgb`, so sampling returns linear
///   radiance. The classic path uploaded `rgba8Unorm` and did its arithmetic on
///   the stored sRGB bytes, which is only correct if you never light anything.
/// - Mips are generated in **linear** space. `TexturePyramid` averages stored
///   sRGB bytes with integer arithmetic to reproduce upstream exactly; that is
///   right for parity and wrong for shading, because averaging gamma-encoded
///   values darkens every mip. On a road surface, where almost every pixel
///   samples a mip, the error is a visible darkening with distance.
public enum TextureLoading {
    /// Decodes SGI, PNG, or a compiled `.torcstex` cache by content.
    ///
    /// Prepared driving sessions ship compiled caches rather than source
    /// artwork, so the renderer has to read both. Only the base level is taken
    /// from a cache: its mip chain was built with upstream's integer averaging
    /// of sRGB bytes, which is correct for parity and wrong for shading, so the
    /// chain is rebuilt in linear space here.
    public static func decode(_ data: Data) throws -> TextureImage {
        if let compiled = try? TextureCache.decode(data), let base = compiled.pyramid.levels.first {
            return base
        }
        // PNG magic; anything else is treated as SGI, which fails explicitly.
        let isPNG = data.count >= 8 && data.prefix(8).elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        return isPNG ? try TextureImage.decodePNG(data) : try TextureImage.decodeSGI(data)
    }

    /// Fraction of texels that survive an alpha cutout at `threshold`.
    static func coverage(_ rgba: [UInt8], threshold: Float) -> Float {
        let cutoff = UInt8(max(0, min(255, threshold * 255)))
        var passing = 0
        for i in stride(from: 3, to: rgba.count, by: 4) where rgba[i] > cutoff { passing += 1 }
        return Float(passing) / Float(max(rgba.count / 4, 1))
    }

    /// Rescales alpha so a mip keeps its parent's cutout coverage.
    ///
    /// Without this, averaging alpha across a foliage mip chain steadily erodes
    /// coverage and distant trees dissolve into nothing — the classic reason
    /// alpha-tested vegetation looks broken at range. Upstream avoided the
    /// problem only by disabling mips on `_n` textures entirely, which trades
    /// dissolving leaves for aliasing ones.
    static func matchCoverage(_ rgba: inout [UInt8], target: Float, threshold: Float) {
        guard target > 0, target < 1 else { return }
        var low: Float = 0, high: Float = 4, scale: Float = 1
        for _ in 0 ..< 12 {
            scale = (low + high) * 0.5
            var scaled = rgba
            for i in stride(from: 3, to: scaled.count, by: 4) {
                scaled[i] = UInt8(max(0, min(255, Float(rgba[i]) * scale)))
            }
            if coverage(scaled, threshold: threshold) < target { low = scale } else { high = scale }
        }
        for i in stride(from: 3, to: rgba.count, by: 4) {
            rgba[i] = UInt8(max(0, min(255, Float(rgba[i]) * scale)))
        }
    }

    /// Builds a complete mip chain, filtering colour in linear space.
    /// - Parameter encodeAsColour: filter in linear space and re-encode to
    ///   sRGB. True for albedo. False for data maps — a normal or a roughness
    ///   value is not a colour, and passing it through a transfer function
    ///   would bend it.
    public static func linearMipChain(_ image: TextureImage, preserveCutoutCoverage: Bool,
                                      cutoutThreshold: Float = 0.5,
                                      encodeAsColour: Bool = true) throws -> [(width: Int, height: Int, pixels: [UInt8])] {
        guard image.width > 0, image.height > 0 else {
            throw ACError.invalid("Cannot build mips for an empty image")
        }
        var levels: [(width: Int, height: Int, pixels: [UInt8])] = [(image.width, image.height, image.rgba8)]
        let baseCoverage = preserveCutoutCoverage ? coverage(levels[0].pixels, threshold: cutoutThreshold) : 0

        // Precomputed sRGB decode; a pow() per channel per texel is the whole
        // cost of this function otherwise.
        let toLinear = (0 ... 255).map { ColorSpace.linear(fromSRGB: Float($0) / 255) }

        while let parent = levels.last, parent.width > 1 || parent.height > 1 {
            let width = max(1, parent.width / 2), height = max(1, parent.height / 2)
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0 ..< height {
                for x in 0 ..< width {
                    let x0 = min(x * 2, parent.width - 1), x1 = min(x * 2 + 1, parent.width - 1)
                    let y0 = min(y * 2, parent.height - 1), y1 = min(y * 2 + 1, parent.height - 1)
                    let corners = [(x0, y0), (x1, y0), (x0, y1), (x1, y1)].map { ($0.1 * parent.width + $0.0) * 4 }
                    for c in 0 ..< 3 {
                        if encodeAsColour {
                            let sum = corners.reduce(Float(0)) { $0 + toLinear[Int(parent.pixels[$1 + c])] }
                            pixels[(y * width + x) * 4 + c] =
                                UInt8(max(0, min(255, (ColorSpace.srgb(fromLinear: sum / 4) * 255).rounded())))
                        } else {
                            let sum = corners.reduce(0) { $0 + Int(parent.pixels[$1 + c]) }
                            pixels[(y * width + x) * 4 + c] = UInt8(sum / 4)
                        }
                    }
                    // Alpha is a coverage mask, not a colour: average it
                    // directly, never through the transfer function.
                    let alpha = corners.reduce(0) { $0 + Int(parent.pixels[$1 + 3]) } / 4
                    pixels[(y * width + x) * 4 + 3] = UInt8(alpha)
                }
            }
            if preserveCutoutCoverage {
                matchCoverage(&pixels, target: baseCoverage, threshold: cutoutThreshold)
            }
            levels.append((width, height, pixels))
        }
        return levels
    }

    /// A mip chain block-compressed for upload: one encoded level per source
    /// level, in the given BC format.
    public struct CompressedChain: Sendable {
        public let format: BlockCompression.Format
        public let levels: [(width: Int, height: Int, blocks: [UInt8])]
        public var byteCount: Int { levels.reduce(0) { $0 + $1.blocks.count } }
        public init(format: BlockCompression.Format, levels: [(width: Int, height: Int, blocks: [UInt8])]) {
            self.format = format
            self.levels = levels
        }
    }

    /// Encodes every level of a chain. CPU work of the order of a second for
    /// a 2048² map, which is why `MaterialLibrary` keeps the result beside
    /// the source and only encodes once.
    public static func compress(_ levels: [(width: Int, height: Int, pixels: [UInt8])],
                                format: BlockCompression.Format) throws -> CompressedChain {
        CompressedChain(format: format, levels: try levels.map {
            ($0.width, $0.height, try BlockCompression.encode($0.pixels, width: $0.width, height: $0.height, format: format))
        })
    }

    /// The Metal format for a block-compressed chain: BC1 and BC3 carry
    /// colour and may be sRGB; BC4 and BC5 are data.
    public static func pixelFormat(for format: BlockCompression.Format, srgb: Bool) -> MTLPixelFormat {
        switch format {
        case .bc1: return srgb ? .bc1_rgba_srgb : .bc1_rgba
        case .bc3: return srgb ? .bc3_rgba_srgb : .bc3_rgba
        case .bc4: return .bc4_rUnorm
        case .bc5: return .bc5_rgUnorm
        }
    }

    /// Uploads a block-compressed chain. Metal takes a level smaller than a
    /// block as one block, which is how the encoder padded it.
    public static func upload(_ chain: CompressedChain, device: MTLDevice, srgb: Bool) throws -> MTLTexture {
        guard let base = chain.levels.first else { throw ACError.invalid("No mip levels to upload") }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat(for: chain.format, srgb: srgb),
            width: base.width, height: base.height, mipmapped: chain.levels.count > 1)
        descriptor.mipmapLevelCount = chain.levels.count
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw ACError.invalid("Could not allocate a \(base.width)x\(base.height) compressed texture")
        }
        for (level, mip) in chain.levels.enumerated() {
            let bytesPerRow = BlockCompression.blocksWide(mip.width) * chain.format.bytesPerBlock
            mip.blocks.withUnsafeBytes { raw in
                texture.replace(region: MTLRegionMake2D(0, 0, mip.width, mip.height),
                                mipmapLevel: level, withBytes: raw.baseAddress!, bytesPerRow: bytesPerRow)
            }
        }
        return texture
    }

    public static func upload(_ levels: [(width: Int, height: Int, pixels: [UInt8])],
                              device: MTLDevice, srgb: Bool) throws -> MTLTexture {
        guard let base = levels.first else { throw ACError.invalid("No mip levels to upload") }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: srgb ? .rgba8Unorm_srgb : .rgba8Unorm,
            width: base.width, height: base.height, mipmapped: levels.count > 1)
        descriptor.mipmapLevelCount = levels.count
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw ACError.invalid("Could not allocate a \(base.width)x\(base.height) texture")
        }
        for (level, mip) in levels.enumerated() {
            mip.pixels.withUnsafeBytes { raw in
                texture.replace(region: MTLRegionMake2D(0, 0, mip.width, mip.height),
                                mipmapLevel: level, withBytes: raw.baseAddress!,
                                bytesPerRow: mip.width * 4)
            }
        }
        return texture
    }
}

/// Resolves texture references against explicit roots and caches uploads.
///
/// Explicit roots only, with no implicit current-directory or network fallback,
/// matching `ContentSearchPath`'s rule in the asset package. A missing texture
/// is reported, never silently replaced with something that looks plausible.
public final class TextureStore {
    private let device: MTLDevice
    private let roots: [URL]
    private var cache: [String: MTLTexture] = [:]
    public private(set) var missing: Set<String> = []
    public private(set) var uploadedBytes = 0
    /// Upload the original artwork block-compressed — BC1, or BC3 where it
    /// is a cutout — with the encode kept in `blockCache`. Process-wide,
    /// for measurement, like `MaterialLibrary.compressesMaps`.
    nonisolated(unsafe) public static var compressesUploads = true
    /// Where the encodes are kept, named by the source's SHA-256 and the
    /// format. Nil compresses without keeping, paying the encode each load.
    public var blockCache: URL?
    /// Encodes served from `blockCache` rather than done.
    public private(set) var sidecarHits = 0

    /// The cache the app and the tool share: the user's caches directory.
    public static func defaultBlockCache() -> URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("TORCSMac", isDirectory: true)
            .appendingPathComponent("texture-blocks", isDirectory: true)
    }

    public init(device: MTLDevice, roots: [URL], blockCache: URL? = TextureStore.defaultBlockCache()) {
        self.device = device
        self.roots = roots
        self.blockCache = blockCache
    }

    /// Whether any texel is less than fully opaque.
    static func hasTransparency(_ rgba: [UInt8]) -> Bool {
        var i = 3
        while i < rgba.count {
            if rgba[i] != 255 { return true }
            i += 4
        }
        return false
    }

    /// Uploads a linear mip chain, block-compressed when the store is asked
    /// to, serving the encode from the block cache when it holds one for
    /// this source. `sourceHash` is the source's SHA-256; `isCutout` picks
    /// BC3 so the alpha survives.
    private func uploadChain(_ levels: [(width: Int, height: Int, pixels: [UInt8])],
                             sourceHash: [UInt8], isCutout: Bool) throws -> MTLTexture {
        guard Self.compressesUploads else {
            uploadedBytes += levels.reduce(0) { $0 + $1.width * $1.height * 4 }
            return try TextureLoading.upload(levels, device: device, srgb: true)
        }
        // Alpha is kept wherever the image has any: a cutout's coverage, or
        // the transparency of glass that is drawn blended rather than
        // tested. BC1 has no alpha and made the windscreen a solid pane.
        let format: BlockCompression.Format = isCutout || Self.hasTransparency(levels[0].pixels) ? .bc3 : .bc1
        let name = sourceHash.map { String(format: "%02x", $0) }.joined() + ".\(format.rawValue).torcsbc"
        let sidecar = blockCache?.appendingPathComponent(name)
        let chain: TextureLoading.CompressedChain
        if let sidecar, let kept = MapSidecar.read(sidecar, sourceHash: sourceHash, format: format) {
            chain = kept
            sidecarHits += 1
        } else {
            chain = try TextureLoading.compress(levels, format: format)
            if let sidecar {
                try? FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
                MapSidecar.write(chain, to: sidecar, sourceHash: sourceHash)
            }
        }
        uploadedBytes += chain.byteCount
        return try TextureLoading.upload(chain, device: device, srgb: true)
    }

    /// Case-insensitive search by basename, because AC files reference textures
    /// with inconsistent casing and the original loader compared case-insensitively.
    func locate(_ name: String) -> URL? {
        let basename = (name as NSString).lastPathComponent.lowercased()
        let stem = (basename as NSString).deletingPathExtension
        for root in roots {
            for candidate in [basename, stem + ".torcstex"] {
                let direct = root.appendingPathComponent(candidate)
                if FileManager.default.fileExists(atPath: direct.path) { return direct }
            }
            guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            if let match = entries.first(where: { $0.lastPathComponent.lowercased() == basename }) { return match }
        }
        return nil
    }

    /// Uploads an already-decoded compiled texture.
    ///
    /// Prepared session packages hand the loader `CompiledTexture` values keyed
    /// by the name the mesh references, so no file search is involved. Only the
    /// base level is used: the cached chain was built with upstream's integer
    /// averaging of sRGB bytes, which is right for parity and wrong for
    /// shading, so it is rebuilt in linear space.
    public func albedo(compiled: CompiledTexture, key: String, isCutout: Bool) -> MTLTexture? {
        if let cached = cache[key] { return cached }
        if missing.contains(key) { return nil }
        guard let base = compiled.pyramid.levels.first,
              let levels = try? TextureLoading.linearMipChain(base, preserveCutoutCoverage: isCutout),
              let hash = Self.bytes(ofHex: compiled.sourceSHA256),
              let texture = try? uploadChain(levels, sourceHash: hash, isCutout: isCutout) else {
            missing.insert(key)
            return nil
        }
        cache[key] = texture
        return texture
    }

    static func bytes(ofHex hex: String) -> [UInt8]? {
        guard hex.count == 64 else { return nil }
        var out: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    /// Loads from an explicit file, bypassing the search roots. Used for
    /// compiled session packages, where a scene's textures are addressed by
    /// index rather than by the name the mesh references.
    public func albedo(at url: URL, key: String, isCutout: Bool) -> MTLTexture? {
        if let cached = cache[key] { return cached }
        if missing.contains(key) { return nil }
        guard let data = try? Data(contentsOf: url),
              let image = try? TextureLoading.decode(data),
              let levels = try? TextureLoading.linearMipChain(image, preserveCutoutCoverage: isCutout),
              let texture = try? uploadChain(levels, sourceHash: Array(SHA256.hash(data: data)), isCutout: isCutout) else {
            missing.insert(key)
            return nil
        }
        cache[key] = texture
        return texture
    }

    public func albedo(named name: String, isCutout: Bool) -> MTLTexture? {
        if let cached = cache[name] { return cached }
        if missing.contains(name) { return nil }
        guard let url = locate(name), let data = try? Data(contentsOf: url),
              let image = try? TextureLoading.decode(data),
              let levels = try? TextureLoading.linearMipChain(image, preserveCutoutCoverage: isCutout),
              let texture = try? uploadChain(levels, sourceHash: Array(SHA256.hash(data: data)), isCutout: isCutout) else {
            missing.insert(name)
            return nil
        }
        cache[name] = texture
        return texture
    }

    /// Decoded source image, for callers that need the pixels rather than a
    /// GPU texture — such as preserving painted markings when a generated
    /// material replaces the artwork.
    public func image(named name: String) -> TextureImage? {
        guard let url = locate(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? TextureLoading.decode(data)
    }

    public var count: Int { cache.count }
}
