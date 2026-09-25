// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd

/// A material set derived from a single colour image — a photograph, or an
/// image model's output — by the same chain the recipes use.
///
/// The recipes author a height field and derive everything from it. An
/// image has no height, so one is estimated: the image's luminance, with its
/// large-scale shading removed, taken as relief — darker is deeper, which is
/// what a lit rough surface photographed from above mostly does. From that
/// height come normals and occlusion by the recipe's own functions, and the
/// roughness from the image's local contrast over an authored base. The
/// albedo is the image with the same large-scale shading divided out, so the
/// lighting baked into the picture is not lit a second time.
///
/// The provenance of the source is the caller's to state; `Provenance`
/// carries it into the generator's manifest, since an image model's output
/// cannot be documented the way `ASSET_LICENSES.md` documents artwork.
public enum ImageSourcedMaterial {
    public struct Provenance: Sendable, Equatable {
        public var model: String
        public var prompt: String
        public var seed: String
        public init(model: String, prompt: String, seed: String) {
            self.model = model; self.prompt = prompt; self.seed = seed
        }
    }

    public struct Parameters: Sendable {
        /// Base roughness the local contrast is added to.
        public var roughness: Float = 0.75
        /// How far local contrast raises roughness.
        public var roughnessContrast: Float = 0.6
        /// Relief strength for the normals, in the recipes' units.
        public var reliefStrength: Float = 2.5
        /// Whether lighter is deeper. A luminance cannot know: mortar is
        /// lighter than brick and recessed, stones are lighter than the tar
        /// between them and raised. The caller says; the default takes
        /// darker as deeper.
        public var invertRelief = false
        /// Metres covered by one tile.
        public var worldSize: Float = 2
        public var isMetal = false
        public init() {}
    }

    /// Luminance of the linear colour, from sRGB bytes.
    static func luminance(_ rgba: [UInt8], size: Int) -> ScalarField {
        let toLinear = (0 ... 255).map { v -> Float in
            let c = Float(v) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return ScalarField(size: size) { x, y in
            let i = (y * size + x) * 4
            return 0.2126 * toLinear[Int(rgba[i])] + 0.7152 * toLinear[Int(rgba[i + 1])] + 0.0722 * toLinear[Int(rgba[i + 2])]
        }
    }

    /// The large-scale shading of an image: its luminance blurred over a
    /// sixteenth of the tile. Dividing the image by this, normalised to its
    /// mean, removes the lighting a photograph carries and leaves the
    /// material's own colour.
    static func shading(of luminance: ScalarField) -> ScalarField {
        MaterialSynthesis.blurredField(luminance, radius: max(2, luminance.size / 16))
    }

    public static func derive(name: String, albedo rgba: [UInt8], size: Int,
                              parameters p: Parameters = Parameters()) throws -> GeneratedMaterial {
        guard size > 0, rgba.count == size * size * 4 else {
            throw MaterialError.unknown("\(name): expected \(size * size * 4) RGBA bytes, got \(rgba.count)")
        }
        let luminance = luminance(rgba, size: size)
        let shade = shading(of: luminance)
        let meanShade = max(shade.values.reduce(0, +) / Float(shade.values.count), 1e-4)

        // Delight: divide out the large-scale shading, keep the mean.
        var delit = rgba
        for y in 0 ..< size {
            for x in 0 ..< size {
                let gain = min(max(meanShade / max(shade[x, y], 1e-4), 0.5), 2.0)
                let i = (y * size + x) * 4
                for c in 0 ..< 3 {
                    delit[i + c] = UInt8(min(255, max(0, (Float(rgba[i + c]) * gain).rounded())))
                }
            }
        }

        // Height: the luminance's high-pass, normalised to [0, 1].
        var relief = ScalarField(size: size) { x, y in luminance[x, y] - shade[x, y] }
        let low = relief.values.min() ?? 0, high = relief.values.max() ?? 1
        let span = max(high - low, 1e-5)
        let invert = p.invertRelief
        relief = ScalarField(size: size) { x, y in
            let value = (relief[x, y] - low) / span
            return invert ? 1 - value : value
        }
        let height = MaterialSynthesis.blurredField(relief, radius: 1)

        let normals = MaterialSynthesis.normals(from: height, strength: p.reliefStrength)
        let occlusion = MaterialSynthesis.ambientOcclusion(from: height, radius: max(2, size / 64), strength: 1.0)

        // Roughness: a base plus the local contrast — a mottled surface
        // scatters, a smooth one does not. Contrast is the blurred absolute
        // deviation from the local mean, scaled to the tile's own range.
        let deviation = ScalarField(size: size) { x, y in abs(relief[x, y] - 0.5) }
        let contrast = MaterialSynthesis.blurredField(deviation, radius: max(1, size / 128))
        let contrastHigh = max(contrast.values.max() ?? 1, 1e-5)
        let roughness = ScalarField(size: size) { x, y in
            min(max(p.roughness + p.roughnessContrast * (contrast[x, y] / contrastHigh - 0.5), 0.05), 1)
        }

        return GeneratedMaterial(name: name, size: size, albedo: delit,
                                 normal: MaterialPacking.normal(normals),
                                 orm: MaterialPacking.orm(occlusion: occlusion, roughness: roughness,
                                                            metalness: p.isMetal ? 1 : 0),
                                 worldSize: p.worldSize, isMetal: p.isMetal)
    }
}
