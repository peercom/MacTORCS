// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd

/// A square, tiling scalar field. The intermediate every generated material is
/// built from: height, masks and wear are all height fields before they become
/// texture channels.
public struct ScalarField {
    public let size: Int
    public private(set) var values: [Float]

    public init(size: Int, repeating value: Float = 0) {
        self.size = max(1, size)
        values = [Float](repeating: value, count: self.size * self.size)
    }

    public init(size: Int, generator: (Int, Int) -> Float) {
        self.size = max(1, size)
        var values = [Float](repeating: 0, count: self.size * self.size)
        for y in 0 ..< self.size {
            for x in 0 ..< self.size { values[y * self.size + x] = generator(x, y) }
        }
        self.values = values
    }

    /// Wrapping access. Every read wraps because these fields tile; sampling
    /// with clamped edges would put a visible seam in the derived normal map
    /// exactly where the texture repeats.
    @inline(__always)
    public subscript(x: Int, y: Int) -> Float {
        get { values[(((y % size) + size) % size) * size + (((x % size) + size) % size)] }
        set { values[(((y % size) + size) % size) * size + (((x % size) + size) % size)] = newValue }
    }

    public var range: (minimum: Float, maximum: Float) {
        (values.min() ?? 0, values.max() ?? 0)
    }

    /// Rescales to [0, 1]. A flat field is left alone rather than amplified
    /// into noise by dividing by a near-zero span.
    public mutating func normalise() {
        let (low, high) = range
        guard high - low > 1e-6 else { return }
        let scale = 1 / (high - low)
        for index in values.indices { values[index] = (values[index] - low) * scale }
    }

    public mutating func map(_ transform: (Float) -> Float) {
        for index in values.indices { values[index] = transform(values[index]) }
    }

    public func blended(with other: ScalarField, by mask: ScalarField) -> ScalarField {
        var result = self
        for index in result.values.indices {
            let t = min(max(mask.values[index], 0), 1)
            result.values[index] = values[index] * (1 - t) + other.values[index] * t
        }
        return result
    }
}

public enum MaterialSynthesis {
    /// Derives a tangent-space normal map from a height field by central
    /// differences.
    ///
    /// `strength` is in height units per texel; a material's apparent relief
    /// depends on how many metres a texel covers, so the caller sets it rather
    /// than the generator guessing.
    public static func normals(from height: ScalarField, strength: Float) -> [SIMD3<Float>] {
        var result = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: height.size * height.size)
        for y in 0 ..< height.size {
            for x in 0 ..< height.size {
                // Central differences rather than forward: a forward difference
                // shifts the normal half a texel, which reads as the lighting
                // being offset from the bumps it comes from.
                let dx = (height[x + 1, y] - height[x - 1, y]) * 0.5
                let dy = (height[x, y + 1] - height[x, y - 1]) * 0.5
                result[y * height.size + x] = simd_normalize(SIMD3(-dx * strength, -dy * strength, 1))
            }
        }
        return result
    }

    /// Screen-space-style ambient occlusion over a height field.
    ///
    /// Sweeps a set of directions and finds the maximum horizon angle in each,
    /// which is the same idea as horizon-based occlusion in a renderer applied
    /// to a texture instead of a depth buffer. Cheaper and more stable than ray
    /// casting, and its bias toward crevices is exactly what a material wants.
    public static func ambientOcclusion(from height: ScalarField, radius: Int,
                                        strength: Float, directions: Int = 8) -> ScalarField {
        let radius = max(1, radius)
        var result = ScalarField(size: height.size, repeating: 1)
        let step = 2 * Float.pi / Float(max(1, directions))
        for y in 0 ..< height.size {
            for x in 0 ..< height.size {
                let centre = height[x, y]
                var occlusion: Float = 0
                for direction in 0 ..< directions {
                    let angle = Float(direction) * step
                    let dx = cos(angle), dy = sin(angle)
                    var highest: Float = 0
                    for distance in 1 ... radius {
                        let sx = x + Int((dx * Float(distance)).rounded())
                        let sy = y + Int((dy * Float(distance)).rounded())
                        let rise = (height[sx, sy] - centre) / Float(distance)
                        highest = max(highest, rise)
                    }
                    occlusion += highest
                }
                occlusion /= Float(directions)
                result[x, y] = max(0, 1 - occlusion * strength)
            }
        }
        return result
    }

    /// Curvature, from the Laplacian. Positive on ridges, negative in valleys.
    /// Used to put wear on the parts of a surface that would actually be worn.
    public static func curvature(from height: ScalarField) -> ScalarField {
        ScalarField(size: height.size) { x, y in
            height[x + 1, y] + height[x - 1, y] + height[x, y + 1] + height[x, y - 1] - 4 * height[x, y]
        }
    }
}

/// Preserves painted content when a generated material replaces original art.
///
/// Track textures carry more than surface: lane markings, arrows, pit-box
/// outlines and seams are painted into the same albedo. Substituting the
/// material wholesale gains micro-detail and silently deletes all of that,
/// which looks confidently wrong — the road reads as new tarmac with no
/// markings at all.
///
/// Painted content is what stands out from its surroundings, so it can be
/// separated from the surface without knowing what it depicts: compare each
/// texel against a blurred copy of the same image and keep what differs
/// strongly. The surface itself, being high-frequency and low-contrast, mostly
/// cancels; a white line against dark tarmac does not.
///
/// This is a bridge. Markings properly belong to a decal layer generated from
/// the track model, where they would be crisp at any resolution instead of
/// limited by the original texture.
public enum MarkingExtraction {
    /// Separable box blur with wrapping edges, giving the low-frequency
    /// content a texel should be compared against.
    static func blurred(_ channel: [Float], size: Int, radius: Int) -> [Float] {
        guard radius > 0 else { return channel }
        var horizontal = [Float](repeating: 0, count: channel.count)
        let window = Float(radius * 2 + 1)
        for y in 0 ..< size {
            for x in 0 ..< size {
                var total: Float = 0
                for offset in -radius ... radius {
                    total += channel[y * size + (((x + offset) % size) + size) % size]
                }
                horizontal[y * size + x] = total / window
            }
        }
        var result = [Float](repeating: 0, count: channel.count)
        for y in 0 ..< size {
            for x in 0 ..< size {
                var total: Float = 0
                for offset in -radius ... radius {
                    total += horizontal[((((y + offset) % size) + size) % size) * size + x]
                }
                result[y * size + x] = total / window
            }
        }
        return result
    }

    /// Composites painted content from `original` over `generated`.
    ///
    /// Both are straight RGBA at `size`. `threshold` is how far above the local
    /// mean a texel must sit, in luminance, before it counts as paint; 0.10
    /// keeps lines and lettering while ignoring the surface's own variation.
    public static func composite(generated: [UInt8], original: [UInt8], size: Int,
                                 threshold: Float = 0.10, radius: Int = 12) -> [UInt8] {
        guard generated.count == original.count, generated.count == size * size * 4 else { return generated }
        var luminance = [Float](repeating: 0, count: size * size)
        for index in 0 ..< size * size {
            let r = Float(original[index * 4]) / 255
            let g = Float(original[index * 4 + 1]) / 255
            let b = Float(original[index * 4 + 2]) / 255
            luminance[index] = 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        let background = blurred(luminance, size: size, radius: radius)

        var result = generated
        for index in 0 ..< size * size {
            // Only brighter-than-surroundings content is treated as paint.
            // Darker patches are shadow and dirt in the original, which the
            // generated material already expresses better.
            let excess = luminance[index] - background[index]
            guard excess > threshold else { continue }
            let weight = min((excess - threshold) / 0.18, 1)
            for channel in 0 ..< 3 {
                let from = Float(result[index * 4 + channel])
                let to = Float(original[index * 4 + channel])
                result[index * 4 + channel] = UInt8(max(0, min(255, from + (to - from) * weight)))
            }
        }
        return result
    }

    /// Nearest-neighbour resample, used to bring an original texture up to the
    /// generated material's resolution before compositing. Nearest rather than
    /// bilinear because a marking's edge should stay an edge; the generated
    /// detail supplies smoothness everywhere else.
    public static func resampled(_ pixels: [UInt8], from source: Int, to target: Int) -> [UInt8] {
        guard source > 0, target > 0, pixels.count == source * source * 4 else { return pixels }
        if source == target { return pixels }
        var result = [UInt8](repeating: 255, count: target * target * 4)
        for y in 0 ..< target {
            let sy = min(source - 1, y * source / target)
            for x in 0 ..< target {
                let sx = min(source - 1, x * source / target)
                let from = (sy * source + sx) * 4, to = (y * target + x) * 4
                for channel in 0 ..< 4 { result[to + channel] = pixels[from + channel] }
            }
        }
        return result
    }
}
