// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd
import TORCSAssets

/// Physically based material derived from original AC/OpenGL material state.
///
/// This is a bridge, not a destination. Original content carries a diffuse
/// colour, a specular colour and a Blinn-Phong exponent — it has no notion of
/// metalness, no roughness map and no energy conservation. Authored material
/// sets from `torcs-matgen` replace these defaults per surface in a later phase.
/// Until then this keeps existing content looking deliberate rather than wrong.
public struct ResolvedMaterial: Equatable, Sendable {
    public var baseColour: SIMD4<Float>
    public var roughness: Float
    public var metallic: Float
    public var clearcoat: Float
    public var clearcoatRoughness: Float
    public var normalStrength: Float

    public init(baseColour: SIMD4<Float>, roughness: Float, metallic: Float,
                clearcoat: Float = 0, clearcoatRoughness: Float = 0.04,
                normalStrength: Float = 1) {
        self.baseColour = baseColour
        self.roughness = roughness
        self.metallic = metallic
        self.clearcoat = clearcoat
        self.clearcoatRoughness = clearcoatRoughness
        self.normalStrength = normalStrength
    }
}

public enum MaterialResolution {
    /// Converts a Blinn-Phong exponent to a GGX perceptual roughness.
    ///
    /// The standard correspondence, from matching the two lobes' widths. An
    /// exponent of 0 means fully rough; the original content's default of 128
    /// lands near 0.12, which is a tight but not mirror-like highlight.
    public static func roughness(fromShininess shininess: Float) -> Float {
        let exponent = max(shininess.isFinite ? shininess : 0, 0)
        return min(max((2 / (exponent + 2)).squareRoot(), 0.045), 1)
    }

    /// Derives a material from AC state plus the mesh's diffuse colour.
    ///
    /// Metalness is 0 for everything. The original art was authored for a
    /// fixed-function pipeline where "shiny" meant a specular exponent, and
    /// guessing metalness from that would turn every polished surface into a
    /// mirror with no diffuse term at all — far worse than treating it as a
    /// glossy dielectric.
    public static func resolve(state: ACRenderState, diffuse: SIMD4<Float>) -> ResolvedMaterial {
        // material layout: specular RGBA, emission RGBA, ambient RGBA, shininess.
        let shininess = state.material.count >= 13 ? state.material[12] : 0
        var roughness = roughness(fromShininess: shininess)

        // A near-black specular colour means the surface was never meant to
        // have a highlight, whatever its exponent says.
        if state.material.count >= 3 {
            let specular = max(state.material[0], max(state.material[1], state.material[2]))
            if specular < 0.02 { roughness = max(roughness, 0.8) }
        }
        return ResolvedMaterial(baseColour: diffuse, roughness: roughness, metallic: 0)
    }
}
