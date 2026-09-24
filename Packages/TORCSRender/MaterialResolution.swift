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
    /// The conversion is deliberately blunt, because the source carries no
    /// usable gloss signal. Every one of Aalborg's 1,315 batches is authored
    /// `specular 0.5, shininess 50` — asphalt, grass, buildings and foliage
    /// alike. Mapping that exponent to a GGX roughness gives 0.196 for all of
    /// them, which renders a circuit as though it were wet plastic: large
    /// low-polygon surfaces sweep through a tight specular lobe and blow out to
    /// white.
    ///
    /// Two further reasons the naive conversion is wrong here. A Blinn-Phong
    /// highlight is bounded by its specular colour, while a GGX lobe at the
    /// equivalent exponent concentrates far more energy, so matching apparent
    /// gloss needs a markedly rougher surface. And the physically based path
    /// ignores the authored specular colour entirely, giving every dielectric
    /// the full 4% response whether or not the artist wanted a highlight.
    ///
    /// So content without a roughness map is treated as a rough dielectric,
    /// which is what a circuit actually is. Authored material sets carry real
    /// ORM maps and override this completely; this exists only to keep original
    /// content looking deliberate until they do.
    public static func resolve(state: ACRenderState, diffuse: SIMD4<Float>) -> ResolvedMaterial {
        // material layout: specular RGBA, emission RGBA, ambient RGBA, shininess.
        let shininess = state.material.count >= 13 ? state.material[12] : 0
        let specular = state.material.count >= 3
            ? max(state.material[0], max(state.material[1], state.material[2])) : 0

        // Rough by default. The exponent is allowed to pull the surface
        // glossier, but only within a range that cannot produce a mirror, and
        // only in proportion to how much specular the artist actually asked for.
        let fromExponent = roughness(fromShininess: shininess)
        let glossWeight = min(max(specular, 0), 1) * 0.35
        let combined = defaultRoughness * (1 - glossWeight) + fromExponent * glossWeight
        return ResolvedMaterial(baseColour: diffuse,
                                roughness: min(max(combined, 0.45), 1),
                                metallic: 0)
    }

    /// Roughness assumed for content with no roughness map.
    public static let defaultRoughness: Float = 0.9
}
