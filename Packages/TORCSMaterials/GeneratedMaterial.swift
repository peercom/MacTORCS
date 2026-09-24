// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd
import TORCSMath

/// A complete physically based material set, ready to compress and upload.
///
/// Three maps, matching the renderer's slots: albedo in sRGB, a tangent-space
/// normal, and ORM packing ambient occlusion, roughness and metalness into one
/// texture. Authored by project code from a seed, so it carries the project's
/// own terms and can be bundled — unlike the original artwork, which cannot.
public struct GeneratedMaterial {
    public let name: String
    public let size: Int
    /// Straight RGBA, sRGB-encoded. Uploaded to an `_srgb` format.
    public let albedo: [UInt8]
    /// RGBA with the normal in RG. Z is reconstructed in the shader, which is
    /// why BC5 suffices.
    public let normal: [UInt8]
    /// R ambient occlusion, G roughness, B metalness.
    public let orm: [UInt8]
    /// Metres covered by one tile, so the renderer can set UV scale from the
    /// material rather than from how the mesh happens to be parameterised.
    public let worldSize: Float
    /// A metal: the renderer sets the surface's metalness to one and lets
    /// the ORM's blue channel scale it, instead of the dielectric default.
    public let isMetal: Bool

    public init(name: String, size: Int, albedo: [UInt8], normal: [UInt8], orm: [UInt8], worldSize: Float,
                isMetal: Bool = false) {
        self.name = name
        self.size = size
        self.albedo = albedo
        self.normal = normal
        self.orm = orm
        self.worldSize = worldSize
        self.isMetal = isMetal
    }

    public var byteCount: Int { albedo.count + normal.count + orm.count }
}

/// Packs synthesis outputs into texture bytes.
public enum MaterialPacking {
    @inline(__always)
    static func byte(_ value: Float) -> UInt8 {
        UInt8(max(0, min(255, (value * 255).rounded())))
    }

    /// Linear colour to sRGB bytes. Albedo is authored in linear so blends
    /// between materials are physically meaningful, then encoded once here.
    public static func albedo(_ colour: [SIMD3<Float>]) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: colour.count * 4)
        for (index, linear) in colour.enumerated() {
            bytes[index * 4] = byte(ColorSpace.srgb(fromLinear: linear.x))
            bytes[index * 4 + 1] = byte(ColorSpace.srgb(fromLinear: linear.y))
            bytes[index * 4 + 2] = byte(ColorSpace.srgb(fromLinear: linear.z))
        }
        return bytes
    }

    /// Linear colour and coverage to sRGB bytes with alpha, for cutouts.
    public static func albedo(_ colour: [SIMD3<Float>], alpha: [Float]) -> [UInt8] {
        var bytes = albedo(colour)
        for (index, a) in alpha.enumerated() where index < colour.count { bytes[index * 4 + 3] = byte(a) }
        return bytes
    }

    public static func normal(_ vectors: [SIMD3<Float>]) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: vectors.count * 4)
        for (index, n) in vectors.enumerated() {
            let unit = simd_length(n) > 1e-6 ? n / simd_length(n) : SIMD3(0, 0, 1)
            bytes[index * 4] = byte(unit.x * 0.5 + 0.5)
            bytes[index * 4 + 1] = byte(unit.y * 0.5 + 0.5)
            bytes[index * 4 + 2] = byte(unit.z * 0.5 + 0.5)
        }
        return bytes
    }

    public static func orm(occlusion: ScalarField, roughness: ScalarField, metalness: Float) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: occlusion.values.count * 4)
        for index in occlusion.values.indices {
            bytes[index * 4] = byte(occlusion.values[index])
            bytes[index * 4 + 1] = byte(roughness.values[index])
            bytes[index * 4 + 2] = byte(metalness)
        }
        return bytes
    }
}
