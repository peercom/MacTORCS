// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd

/// The shapes of clouds, as a map the sky is drawn from.
///
/// The sky's cloud was four octaves of value noise worked out at every
/// pixel and cut off at a threshold: a ceiling with holes in it, which is
/// what an overcast day is and nothing a fair one has. A fair day has
/// cumulus, heaps with flat bases and cauliflower tops and blue between,
/// and above them, some days, streaks of ice. Their shapes are here, one
/// to a channel, tiled:
///
/// - red, where cumulus is: billows inside billows, cells of rising air;
/// - green, the fine lumps that eat at a heap's edge;
/// - blue, cirrus: the same noise drawn out along the wind;
/// - alpha, how thick the heap is thereabouts, for the shade under it.
public enum CloudMap {
    public static func generate(size: Int = 1024, seed: UInt32 = 1) -> [UInt8] {
        func field(_ f: (Float, Float) -> Float) -> ScalarField {
            var result = ScalarField(size: size) { x, y in f(Float(x) / Float(size), Float(y) / Float(size)) }
            result.normalise()
            return result
        }
        let heaps = field { u, v in
            let drift: Float = Noise.fractal(u * 4, v * 4, period: 4, octaves: 5, seed: seed &+ 3) * 0.50
            let cells: Float = (1 - Noise.worley(u * 6, v * 6, period: 6, seed: seed &+ 5)) * 0.32
            let lumps: Float = (1 - Noise.worley(u * 13, v * 13, period: 13, seed: seed &+ 7)) * 0.18
            return drift + cells + lumps
        }
        let detail = field { u, v in
            (1 - Noise.worley(u * 24, v * 24, period: 24, seed: seed &+ 9)) * 0.6
                + Noise.fractal(u * 48, v * 48, period: 48, octaves: 3, seed: seed &+ 11) * 0.4
        }
        // Cirrus: noise smeared along one way and wrapped, so it tiles.
        let grain = field { u, v in Noise.fractal(u * 9, v * 9, period: 9, octaves: 5, seed: seed &+ 13) }
        var streaks = [Float](repeating: 0, count: size * size)
        let reach = size / 22
        for y in 0 ..< size {
            var sum: Float = 0
            for k in -reach ... reach { sum += grain[k, y + k / 7] }
            for x in 0 ..< size {
                streaks[y * size + x] = sum / Float(reach * 2 + 1)
                sum += grain[x + reach + 1, y + (reach + 1) / 7] - grain[x - reach, y - reach / 7]
            }
        }
        var low = streaks.min() ?? 0, high = streaks.max() ?? 1
        if high - low < 1e-6 { low = 0; high = 1 }
        let thick = FacadeStructure.blurred((0 ..< size * size).map { heaps[$0 % size, $0 / size] },
                                            width: size, height: size, radius: max(size / 40, 1))
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        func byte(_ v: Float) -> UInt8 { UInt8(min(max((v * 255).rounded(), 0), 255)) }
        for y in 0 ..< size {
            for x in 0 ..< size {
                let i = y * size + x
                bytes[i * 4] = byte(heaps[x, y])
                bytes[i * 4 + 1] = byte(detail[x, y])
                bytes[i * 4 + 2] = byte((streaks[i] - low) / (high - low))
                bytes[i * 4 + 3] = byte(thick[i])
            }
        }
        return bytes
    }
}

/// The land beyond the circuit, all the way round.
///
/// A circuit ends where its terrain does, a few hundred metres past the
/// track, and past that there was the sky's own ground: a tan band along
/// the foot of the sky. A circuit is somewhere. This is the somewhere: a
/// panorama drawn round the horizon, a plain running out to it and ridges
/// standing behind one another above it, each paler than the one in front
/// by the air between. Its colour is the land's own, lit when it is drawn;
/// its alpha is how much of the sky behind it the air lets it hide, which
/// is how haze is kept without knowing what colour the sky will be.
public enum HorizonMap {
    public enum Kind: String, CaseIterable, Sendable { case hills, mountains, snow, dry }

    /// The sine of the elevation at the picture's bottom row and at its top.
    public static let lowest: Float = -0.10, highest: Float = 0.14

    /// What lies round a circuit, by its name: two are in the mountains, one
    /// in the snow, two in dry country, and the rest among green hills.
    public static func kind(forTrack name: String) -> Kind {
        let key = String(name.lowercased().filter { $0.isLetter || $0.isNumber })
        if key.contains("alpine2") { return .snow }
        if key.contains("alpine1") || key.contains("aalborg") { return .mountains }
        if key.contains("corkscrew") || key.contains("etrack6") { return .dry }
        return .hills
    }

    struct Ridge {
        var base: Float, rise: Float            // sines of elevation: where the ridge line stands and how far it wanders
        var cycles: Int, octaves: Int
        var crest: SIMD3<Float>, foot: SIMD3<Float>
        var opacity: Float                      // what the air leaves of it
        var speckle: Float                      // woods and fields, texel by texel
        var snowline: Float? = nil              // above this elevation, snow
    }

    static func ridges(_ kind: Kind) -> [Ridge] {
        switch kind {
        case .hills:
            return [Ridge(base: 0.016, rise: 0.034, cycles: 5, octaves: 4, crest: SIMD3(0.11, 0.15, 0.15), foot: SIMD3(0.09, 0.13, 0.11), opacity: 0.34, speckle: 0.05),
                    Ridge(base: 0.008, rise: 0.028, cycles: 9, octaves: 4, crest: SIMD3(0.060, 0.105, 0.060), foot: SIMD3(0.050, 0.090, 0.045), opacity: 0.58, speckle: 0.12),
                    Ridge(base: 0.002, rise: 0.016, cycles: 14, octaves: 5, crest: SIMD3(0.034, 0.066, 0.030), foot: SIMD3(0.045, 0.085, 0.036), opacity: 0.84, speckle: 0.22)]
        case .mountains:
            return [Ridge(base: 0.030, rise: 0.085, cycles: 4, octaves: 5, crest: SIMD3(0.17, 0.18, 0.20), foot: SIMD3(0.10, 0.13, 0.14), opacity: 0.40, speckle: 0.08, snowline: 0.074),
                    Ridge(base: 0.014, rise: 0.050, cycles: 7, octaves: 5, crest: SIMD3(0.10, 0.11, 0.10), foot: SIMD3(0.050, 0.085, 0.050), opacity: 0.62, speckle: 0.14),
                    Ridge(base: 0.003, rise: 0.020, cycles: 12, octaves: 5, crest: SIMD3(0.032, 0.062, 0.030), foot: SIMD3(0.042, 0.080, 0.036), opacity: 0.86, speckle: 0.22)]
        case .snow:
            return [Ridge(base: 0.030, rise: 0.085, cycles: 4, octaves: 5, crest: SIMD3(0.62, 0.65, 0.70), foot: SIMD3(0.42, 0.46, 0.52), opacity: 0.42, speckle: 0.06, snowline: 0.02),
                    Ridge(base: 0.014, rise: 0.045, cycles: 7, octaves: 5, crest: SIMD3(0.55, 0.58, 0.62), foot: SIMD3(0.30, 0.34, 0.38), opacity: 0.62, speckle: 0.12),
                    Ridge(base: 0.003, rise: 0.018, cycles: 12, octaves: 5, crest: SIMD3(0.10, 0.14, 0.13), foot: SIMD3(0.40, 0.43, 0.46), opacity: 0.84, speckle: 0.25)]
        case .dry:
            return [Ridge(base: 0.018, rise: 0.040, cycles: 5, octaves: 4, crest: SIMD3(0.21, 0.19, 0.17), foot: SIMD3(0.19, 0.17, 0.14), opacity: 0.36, speckle: 0.05),
                    Ridge(base: 0.008, rise: 0.028, cycles: 8, octaves: 4, crest: SIMD3(0.20, 0.165, 0.105), foot: SIMD3(0.17, 0.14, 0.085), opacity: 0.60, speckle: 0.10),
                    Ridge(base: 0.002, rise: 0.014, cycles: 13, octaves: 5, crest: SIMD3(0.105, 0.105, 0.055), foot: SIMD3(0.19, 0.155, 0.090), opacity: 0.85, speckle: 0.22)]
        }
    }

    static func plain(_ kind: Kind) -> (near: SIMD3<Float>, far: SIMD3<Float>) {
        switch kind {
        case .hills, .mountains: return (SIMD3(0.060, 0.115, 0.045), SIMD3(0.070, 0.115, 0.065))
        case .snow: return (SIMD3(0.55, 0.58, 0.62), SIMD3(0.50, 0.54, 0.60))
        case .dry: return (SIMD3(0.20, 0.165, 0.095), SIMD3(0.20, 0.17, 0.11))
        }
    }

    /// One-dimensional noise round the horizon, the same at 360° as at 0°.
    static func round(_ u: Float, cycles: Int, octaves: Int, seed: UInt32) -> Float {
        var sum: Float = 0, weight: Float = 0, amplitude: Float = 1
        var frequency = cycles
        for octave in 0 ..< octaves {
            sum += Noise.value(u * Float(frequency), 0.5, period: frequency, seed: seed &+ UInt32(octave) &* 31) * amplitude
            weight += amplitude
            amplitude *= 0.5
            frequency *= 2
        }
        return sum / weight
    }

    /// RGBA8, top row first: the land's colour, sRGB-encoded, and what it hides of the sky.
    public static func generate(_ kind: Kind, width: Int = 4096, height: Int = 512, seed: UInt32 = 1) -> [UInt8] {
        let layers = ridges(kind), ground = plain(kind)
        let span = highest - lowest, texel = span / Float(height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        func encode(_ linear: Float) -> UInt8 {
            let c = min(max(linear, 0), 1)
            let s = c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
            return UInt8((s * 255).rounded())
        }
        for x in 0 ..< width {
            let u = Float(x) / Float(width)
            let lines = layers.enumerated().map { index, ridge in
                ridge.base + ridge.rise * round(u, cycles: ridge.cycles, octaves: ridge.octaves, seed: seed &+ UInt32(index) &* 101 &+ 7)
            }
            // The plain meets the sky a hair off level, and its own woods stand on it.
            let edge: Float = 0.001 + 0.003 * round(u, cycles: 40, octaves: 3, seed: seed &+ 401)
            for y in 0 ..< height {
                let elevation = highest - (Float(y) + 0.5) * texel
                var colour = SIMD3<Float>(repeating: 0), alpha: Float = 0
                func over(_ c: SIMD3<Float>, _ a: Float) { colour = colour * (1 - a) + c * a; alpha = alpha * (1 - a) + a }
                for (index, ridge) in layers.enumerated() {
                    let under = lines[index] - elevation
                    let cover = min(max(under / texel + 0.5, 0), 1)
                    guard cover > 0 else { continue }
                    let depth = min(max(under / max(ridge.rise, 1e-4), 0), 1)
                    var c = ridge.crest + (ridge.foot - ridge.crest) * depth
                    let grain = Noise.random(x / 2 + index * 977, y / 2, seed &+ 211) - 0.5
                    let patch = round(u + Float(y) * 0.0007, cycles: ridge.cycles * 9, octaves: 2, seed: seed &+ UInt32(index) &* 53 &+ 301) - 0.5
                    c *= 1 + (grain * 0.5 + patch) * ridge.speckle * 2
                    if let snowline = ridge.snowline {
                        let line = snowline + (round(u, cycles: ridge.cycles * 6, octaves: 3, seed: seed &+ 503) - 0.5) * 0.03
                        let white = min(max((elevation - line) / 0.008, 0), 1)
                        c = c + (SIMD3<Float>(0.72, 0.75, 0.80) - c) * white
                    }
                    over(c, cover * ridge.opacity)
                }
                let below = edge - elevation
                let land = min(max(below / texel + 0.5, 0), 1)
                if land > 0 {
                    // Fields and woods, drawn out sideways as the ground is seen at a glance.
                    let away = 1 / max(below + 0.004, 0.004)
                    let field = Noise.value(u * 240, away * 0.9, period: 240, seed: seed &+ 601) - 0.5
                    let wood = Noise.value(u * 90 + 31, away * 0.35, period: 90, seed: seed &+ 607)
                    var c = ground.far + (ground.near - ground.far) * min(below / 0.06, 1)
                    c *= 1 + field * 0.30
                    if kind != .snow { c *= 1 - max(wood - 0.6, 0) * 1.1 }
                    // The air between: thickest at the horizon, gone a few degrees below it.
                    over(c, land * (0.62 + 0.36 * min(below / 0.05, 1)))
                }
                let i = (y * width + x) * 4
                let shown = alpha > 1e-4 ? colour / alpha : SIMD3<Float>(repeating: 0)
                bytes[i] = encode(shown.x); bytes[i + 1] = encode(shown.y); bytes[i + 2] = encode(shown.z)
                bytes[i + 3] = UInt8((min(max(alpha, 0), 1) * 255).rounded())
            }
        }
        return bytes
    }
}
