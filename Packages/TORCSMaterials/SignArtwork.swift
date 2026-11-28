// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd

/// Advertising: the boards beside the track, the banners strung along its
/// fences and bridges, and the lettering painted on its walls.
///
/// These are the circuits' own artwork and stay so: a sponsor's name is not
/// something to make up. What is made here is what the artwork lacks. It
/// was drawn 256 texels wide for a board ten metres long, four centimetres
/// to the texel, and from the road its lettering is a smear; and it is a
/// picture of ink with nothing under it, no sheet, no cloth, no wall.
///
/// So two things are made from each picture:
///
/// - the picture again, larger, with its edges put back (`enlarged`).
///   Printed artwork is flat colour meeting flat colour, and where two
///   colours meet in the small picture the larger one can say exactly
///   where: half way between them. A photograph has no such edges and
///   comes through as it was.
/// - a surface for it to be printed on (`surface`), by what it is: a
///   board of sheets butted together, a banner pulled between its eyelets,
///   or paint on cast concrete.
public enum SignArtwork {
    public enum Kind: String, Sendable, CaseIterable {
        /// Rigid sheet on a frame.
        case board
        /// Cloth or vinyl, hemmed and tied.
        case banner
        /// Paint on a concrete wall.
        case wall
    }

    /// A strip this many times as long as it is high is a banner; anything
    /// squarer is a board.
    public static let bannerAspect: Float = 6

    /// What a sign's picture is printed on, from its shape.
    public static func kind(width: Int, height: Int) -> Kind {
        Float(width) >= Float(height) * bannerAspect ? .banner : .board
    }

    /// How many times larger the picture is made, each way.
    public static func scale(width: Int, height: Int) -> Int {
        let side = max(width, height)
        return side <= 256 ? 4 : (side <= 512 ? 2 : 1)
    }

    /// The picture `scale` times larger, its edges sharp again.
    ///
    /// Each point is first what plain interpolation makes it. Then, where
    /// the picture around it is two colours and the point lies between
    /// them, it is moved toward the nearer: the blur an edge was given by
    /// being drawn small is taken back out, and the edge falls where the
    /// blur was half way. Where there are not two colours, in a gradient
    /// or a photograph's grain or where three meet, nothing is moved.
    ///
    /// - Parameter rgba: any row order; the result has the same.
    public static func enlarged(rgba: [UInt8], width: Int, height: Int, scale: Int) -> [UInt8] {
        precondition(rgba.count == width * height * 4 && scale >= 1)
        guard scale > 1, width > 1, height > 1 else { return rgba }
        func texel(_ x: Int, _ y: Int) -> SIMD4<Float> {
            let i = (((y % height) + height) % height * width + ((x % width) + width) % width) * 4
            return SIMD4(Float(rgba[i]), Float(rgba[i + 1]), Float(rgba[i + 2]), Float(rgba[i + 3])) / 255
        }
        // The two colours about each cell of four texels, from the sixteen
        // texels round it. The texel farthest from their mean and the one
        // farthest from that give the line the two lie along; each colour
        // is then the mean of the texels on its half of the line, counted
        // the more the nearer its end they are. A mean, because an edge
        // moved toward the single darkest texel in sight grew a dark rim;
        // weighted, because the half-covered texels of the edge itself are
        // neither colour and pulled both toward the middle.
        // `flat` is how far the sixteen are two colours and not a spread.
        var low = [SIMD4<Float>](repeating: .zero, count: width * height), high = low
        var flat = [Float](repeating: 0, count: width * height)
        var window = [SIMD4<Float>](repeating: .zero, count: 16)
        for cy in 0 ..< height {
            for cx in 0 ..< width {
                var mean = SIMD4<Float>.zero
                for dy in 0 ..< 4 { for dx in 0 ..< 4 { let t = texel(cx + dx - 1, cy + dy - 1); window[dy * 4 + dx] = t; mean += t } }
                mean /= 16
                var a = window[0], far: Float = -1
                for t in window { let d = simd_length_squared(t - mean); if d > far { far = d; a = t } }
                var b = a
                far = -1
                for t in window { let d = simd_length_squared(t - a); if d > far { far = d; b = t } }
                let line = b - a, length = simd_length_squared(line)
                guard length > 1e-6 else { low[cy * width + cx] = a; high[cy * width + cx] = a; continue }
                var sumA = SIMD4<Float>.zero, sumB = SIMD4<Float>.zero, weightA: Float = 0, weightB: Float = 0
                for t in window {
                    let along = min(max(simd_dot(t - a, line) / length, 0), 1)
                    let weight = (1 - 2 * along) * (1 - 2 * along)
                    if along < 0.5 { sumA += t * weight; weightA += weight } else { sumB += t * weight; weightB += weight }
                }
                let poleA = weightA > 0 ? sumA / weightA : a, poleB = weightB > 0 ? sumB / weightB : b
                var spread: Float = 0
                for t in window {
                    let along = min(max(simd_dot(t - a, line) / length, 0), 1)
                    let weight = (1 - 2 * along) * (1 - 2 * along)
                    spread += weight * simd_length(t - (along < 0.5 ? poleA : poleB))
                }
                let contrast = simd_length(poleB - poleA)
                low[cy * width + cx] = poleA
                high[cy * width + cx] = poleB
                // Two flat colours lie on their own; grain lies a tenth of
                // the way between, weighted so.
                flat[cy * width + cx] = contrast > 1e-4
                    ? 1 - FacadeStructure.step(0.05, 0.10, spread / max(weightA + weightB, 1e-4) / contrast) : 0
            }
        }
        let w = width * scale, h = height * scale
        // An edge in the small picture is a texel wide; in the large one it
        // is to be a texel and a half of the large one.
        let half = 0.75 / Float(scale)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0 ..< h {
            let fy = (Float(y) + 0.5) / Float(scale) - 0.5
            let y0 = Int(floor(fy)), ty = fy - Float(y0)
            for x in 0 ..< w {
                let fx = (Float(x) + 0.5) / Float(scale) - 0.5
                let x0 = Int(floor(fx)), tx = fx - Float(x0)
                let plain = simd_mix(simd_mix(texel(x0, y0), texel(x0 + 1, y0), SIMD4(repeating: tx)),
                                     simd_mix(texel(x0, y0 + 1), texel(x0 + 1, y0 + 1), SIMD4(repeating: tx)),
                                     SIMD4(repeating: ty))
                let cell = ((y0 % height) + height) % height * width + ((x0 % width) + width) % width
                let a = low[cell], axis = high[cell] - a
                let contrast = simd_length_squared(axis)
                var colour = plain
                if contrast > 0.01 {
                    let t = simd_dot(plain - a, axis) / contrast
                    let off = simd_length(plain - (a + axis * t))
                    let sharp = FacadeStructure.step(0.5 - half, 0.5 + half, t)
                    let amount = FacadeStructure.step(0.10, 0.30, contrast.squareRoot()) * (1 - FacadeStructure.step(0.06, 0.16, off))
                        * flat[cell]
                    colour = plain + axis * ((sharp - min(max(t, 0), 1)) * amount)
                }
                let i = (y * w + x) * 4
                for c in 0 ..< 4 { out[i + c] = UInt8(min(max((colour[c] * 255).rounded(), 0), 255)) }
            }
        }
        return out
    }

    /// The sheets a board of this shape is made of, side by side: each
    /// about half as wide as the board is high.
    public static func panels(width: Int, height: Int) -> Int {
        min(max(Int((Float(width) / Float(max(height, 1)) * 2).rounded()), 2), 12)
    }

    /// The eyelets along each hem of a banner of this shape: one every
    /// half of its height.
    public static func eyelets(width: Int, height: Int) -> Int {
        max(Int((Float(width) / Float(max(height, 1)) * 2).rounded()), 4)
    }

    /// The surface a sign is printed on, `width` by `height` texels: the
    /// normal map (x in red, y in green) and the ORM map (occlusion in red,
    /// roughness in green). Repeats along its length, as the picture does.
    ///
    /// - Returns: rows bottom first, as a `TextureImage` holds them.
    public static func surface(_ kind: Kind, width w: Int, height h: Int, seed: UInt32 = 11) -> (normal: [UInt8], orm: [UInt8]) {
        precondition(w > 0 && h > 0)
        var relief = [Float](repeating: 0.5, count: w * h)
        var rough = [Float](repeating: 0.5, count: w * h), occlusion = [Float](repeating: 1, count: w * h)
        let strength: Float
        switch kind {
        case .board:
            // Sheets butted together: a joint between each, a sheet not
            // quite flat, a film of dirt that the rain has drawn downward.
            let count = panels(width: w, height: h)
            strength = 4
            for y in 0 ..< h {
                for x in 0 ..< w {
                    let u = Float(x) / Float(w), v = Float(y) / Float(h)
                    let across = u * Float(count)
                    let joint = max(1 - abs(across - across.rounded()) / Float(count) * Float(w) / 1.2, 0)
                    let wave = Noise.fractal(u * Float(max(count / 2, 1)), v * 2, period: max(count / 2, 1), octaves: 2, seed: seed)
                    let dirt = Noise.fractal(u * Float(count) * 2, v * 4, period: count * 2, octaves: 3, seed: seed &+ 1)
                    let streak = Noise.value(u * Float(count) * 12, v * 1.5, period: count * 12, seed: seed &+ 2)
                    let i = y * w + x
                    relief[i] = 0.5 + (wave - 0.5) * 0.6 - joint * 0.15
                    rough[i] = 0.74 + (dirt - 0.5) * 0.14 + (streak - 0.5) * 0.10 * (1 - v * 0.5) + joint * 0.3
                    occlusion[i] = 1 - joint * 0.5
                }
            }
        case .banner:
            // Cloth pulled between eyelets: it billows in the middle, where
            // nothing holds it, in folds that lean; at the hems it is held
            // flat at each eyelet and sags a little between them.
            let count = eyelets(width: w, height: h)
            let broad = max(count / 3, 1), narrow = max(count / 2, 2)
            let hem: Float = 0.09
            strength = 5
            for y in 0 ..< h {
                for x in 0 ..< w {
                    let u = Float(x) / Float(w), v = Float(y) / Float(h)
                    let free = pow(max(sin(v * .pi), 0), 0.7)
                    let lean = Noise.value(u * Float(broad), v * 1.5, period: broad, seed: seed) - 0.5
                    let folds = sin((u * Float(broad) + lean * 0.6 + v * 0.12) * 2 * .pi) * 0.65
                        + sin((u * Float(narrow) + lean * 0.9 - v * 0.2) * 2 * .pi) * 0.35
                    let edge = min(v, 1 - v)
                    let hemmed = 1 - FacadeStructure.step(hem * 0.85, hem, edge)
                    // Eyelets sit in the middle of each hem.
                    let along = u * Float(count) - 0.5
                    let dx = (along - along.rounded()) / Float(count) * Float(w)
                    let dy = (edge - hem * 0.5) * Float(h)
                    let radius = max(hem * Float(h) * 0.30, 1.2)
                    let distance = (dx * dx + dy * dy).squareRoot()
                    let ring = max(1 - abs(distance - radius * 0.75) / (radius * 0.45), 0)
                    let hole = 1 - FacadeStructure.step(radius * 0.35, radius * 0.6, distance)
                    let sag = abs(sin(u * Float(count) * .pi)) * max(1 - edge / (hem * 2.5), 0)
                    let i = y * w + x
                    relief[i] = 0.5 + folds * free * 0.15 + hemmed * 0.04 - sag * 0.05 + ring * 0.06 - hole * 0.1
                    rough[i] = 0.82 - hemmed * 0.06 - ring * 0.5
                    occlusion[i] = 1 - hole * 0.6 - max(-folds, 0) * free * 0.12
                }
            }
        case .wall:
            // Cast concrete under paint: pores the paint did not fill, the
            // grain of the cast, a joint where one element meets the next.
            strength = 3
            let cells = max(w / 3, 8)
            for y in 0 ..< h {
                for x in 0 ..< w {
                    let u = Float(x) / Float(w), v = Float(y) / Float(h)
                    let grain = Noise.fractal(u * Float(max(cells / 4, 1)), v * Float(max(cells / 4, 1)), period: max(cells / 4, 1), octaves: 3, seed: seed)
                    let pit = Noise.value(u * Float(cells), v * Float(cells), period: cells, seed: seed &+ 5)
                    let pore = FacadeStructure.step(0.80, 0.88, pit)
                    let joint = max(1 - min(u, 1 - u) * Float(w) / 2.0, 0)
                    let streak = Noise.value(u * Float(max(cells / 2, 1)), v * 3, period: max(cells / 2, 1), seed: seed &+ 7)
                    let i = y * w + x
                    relief[i] = 0.5 + (grain - 0.5) * 0.18 - pore * 0.22 - joint * 0.35
                    rough[i] = 0.76 + (grain - 0.5) * 0.14 + (streak - 0.5) * 0.12 + pore * 0.3 + joint * 0.2
                    occlusion[i] = 1 - pore * 0.35 - joint * 0.5
                }
            }
        }
        var normal = [UInt8](repeating: 255, count: w * h * 4), orm = [UInt8](repeating: 255, count: w * h * 4)
        // Along its length the surface repeats; up it, it ends.
        func at(_ x: Int, _ y: Int) -> Float { relief[min(max(y, 0), h - 1) * w + ((x % w) + w) % w] }
        for y in 0 ..< h {
            for x in 0 ..< w {
                let i = y * w + x
                let dx = (at(x + 1, y) - at(x - 1, y)) * 0.5, dy = (at(x, y + 1) - at(x, y - 1)) * 0.5
                let n = simd_normalize(SIMD3(-dx * strength, dy * strength, 1))
                normal[i * 4] = UInt8(min(max(((n.x + 1) * 127.5).rounded(), 0), 255))
                normal[i * 4 + 1] = UInt8(min(max(((n.y + 1) * 127.5).rounded(), 0), 255))
                normal[i * 4 + 2] = UInt8(min(max(((n.z + 1) * 127.5).rounded(), 0), 255))
                orm[i * 4] = UInt8((min(max(occlusion[i], 0), 1) * 255).rounded())
                orm[i * 4 + 1] = UInt8((min(max(rough[i], 0.05), 1) * 255).rounded())
                orm[i * 4 + 2] = 0
            }
        }
        return (normal, orm)
    }
}
