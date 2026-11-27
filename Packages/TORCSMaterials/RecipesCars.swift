// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd

/// What a car is made of that its own painted atlas cannot hold: a tyre,
/// and the lens of a lamp.
extension MaterialRecipes {
    /// Where the tread lies across the tyre's tile, the sidewalls outside it.
    public static let tyreTread: ClosedRange<Float> = 0.22 ... 0.78

    /// Five by seven, the letters a tyre needs.
    static let glyphs: [Character: [String]] = [
        "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
        "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
        "R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
        "C": [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."],
        "S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
        "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
        "I": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "#####"],
        "N": ["#...#", "##..#", "#.#.#", "#.#.#", "#..##", "#...#", "#...#"],
        "G": [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".###."],
    ]

    /// Whether a point of a line of lettering is on a stroke: `along` 0 to 1
    /// across the whole line, `up` 0 at the letters' feet to 1 at their heads.
    public static func lettered(_ text: String, along: Float, up: Float) -> Bool {
        guard along >= 0, along < 1, up >= 0, up < 1 else { return false }
        let characters = Array(text)
        let column = along * Float(characters.count * 6)
        let index = Int(column), within = Int((column - Float(index / 6 * 6)).rounded(.down))
        guard index / 6 < characters.count, within < 5, let glyph = glyphs[characters[index / 6]] else { return false }
        let row = min(Int((1 - up) * 7), 6)
        return Array(glyph[row])[within] == "#"
    }

    struct TyreFields {
        var height: ScalarField, roughness: ScalarField, albedo: [SIMD3<Float>]
    }

    /// A tyre laid out as it is made: round the wheel along the tile, half
    /// of the way round to a tile, and across its section up the tile, one
    /// sidewall, the tread, the other sidewall.
    ///
    /// The cars' own wheel pictures show a tyre from its side and nothing
    /// else, the tread a ring of one colour at the picture's edge; and a
    /// tyre seen from behind a car is all tread. Here the tread has four
    /// grooves round it, sipes across its ribs and blocks on its shoulders,
    /// worn smooth down its middle with dust in the grooves; the sidewalls
    /// have a rim protector, ribs under the shoulder, and the maker's name
    /// in raised white letters, twice round.
    static func tyreFields(size: Int, seed: UInt32) -> TyreFields {
        let grain = fractalField(size: size, cells: 96, octaves: 3, seed: seed &+ 3)
        let scuff = fractalField(size: size, cells: 9, octaves: 3, seed: seed &+ 5)
        let low = tyreTread.lowerBound, high = tyreTread.upperBound
        /// What is here: how far up it stands, and what kind of surface it is.
        func surface(_ x: Int, _ y: Int) -> (height: Float, kind: Int, depth: Float) {
            let u = Float(x) / Float(size), v = Float(y) / Float(size)
            if v >= low && v <= high {
                let t = (v - low) / (high - low)
                var cut: Float = 0
                for groove in [Float(0.20), 0.40, 0.60, 0.80] { cut = max(cut, 1 - smoothstep(0.016, 0.026, abs(t - groove))) }
                // Shoulder blocks: grooves across the outer ribs, leaning with the way the tyre turns.
                if t < 0.20 || t > 0.80 {
                    let lean: Float = t < 0.5 ? t : 1 - t
                    let p = (u * 26 + lean * 2.2).truncatingRemainder(dividingBy: 1)
                    cut = max(cut, (1 - smoothstep(0.07, 0.12, abs(p - 0.5))) * smoothstep(0.02, 0.06, lean))
                } else {
                    // Sipes across the middle ribs: fine, and half as far apart.
                    let rib = Int(t * 5)
                    let p = (u * 52 + Float(rib) * 0.37 + (t - 0.5) * 3).truncatingRemainder(dividingBy: 1)
                    cut = max(cut, (1 - smoothstep(0.03, 0.06, abs(p - 0.5))) * 0.55)
                }
                // The tread rolls over into the sidewall at each edge.
                let edge = min(t, 1 - t)
                let crown: Float = 0.62 + 0.20 * smoothstep(0.0, 0.10, edge)
                return (crown - cut * 0.42, 0, cut)
            }
            // A sidewall: 0 at the bead, 1 where it meets the tread. Read from outside either way up.
            let first = v < low
            let s = first ? v / low : (1 - v) / (1 - high)
            let along = first ? u : 1 - u
            var h: Float = 0.50 + 0.12 * smoothstep(0.75, 1.0, s)
            h += 0.10 * (1 - smoothstep(0.03, 0.06, abs(s - 0.12)))                      // the rim protector
            for rib in [Float(0.80), 0.85, 0.90] { h += 0.05 * (1 - smoothstep(0.008, 0.016, abs(s - rib))) }
            let letter = lettered("TORCS RACING", along: (along - 0.06) / 0.62, up: (s - 0.32) / 0.36)
            if letter { return (h + 0.09, 2, 0) }
            // The rest of the way round: marks moulded in, a row of small bars.
            if along > 0.74 && along < 0.94 && abs(s - 0.50) < 0.06 && (along * 80).truncatingRemainder(dividingBy: 1) < 0.5 { h += 0.05 }
            return (h, 1, 0)
        }
        var height = ScalarField(size: size) { x, y in surface(x, y).height + grain[x, y] * 0.025 }
        height.normalise()
        let roughness = ScalarField(size: size) { x, y in
            let s = surface(x, y)
            let v = Float(y) / Float(size), t = (v - low) / (high - low)
            switch s.kind {
            case 0:
                // Polished down the middle, where the load is; rough in the grooves.
                let polish = (1 - abs(t - 0.5) * 2) * (0.5 + 0.5 * scuff[x, y])
                return 0.90 - polish * 0.16 + s.depth * 0.06
            case 2: return 0.60 + grain[x, y] * 0.1
            default: return 0.80 + grain[x, y] * 0.06
            }
        }
        let albedo = colours(size) { x, y in
            let s = surface(x, y)
            var c = SIMD3<Float>(0.022, 0.022, 0.024) * (0.85 + grain[x, y] * 0.3)
            switch s.kind {
            case 0:
                // Dust and grit in the grooves; a grey bloom where it has scrubbed.
                c = c + (SIMD3<Float>(0.060, 0.052, 0.042) - c) * s.depth * 0.7
                c = c + (SIMD3<Float>(0.040, 0.040, 0.042) - c) * smoothstep(0.55, 0.85, scuff[x, y]) * 0.5
            case 2:
                // Paint on rubber: it cracks and scuffs.
                let kept = smoothstep(0.25, 0.55, scuff[x + size / 3, y] * 0.5 + grain[x, y] * 0.5 + 0.2)
                c = c + (SIMD3<Float>(0.58, 0.58, 0.55) - c) * kept
            default:
                // A sidewall browns with age, in patches.
                c = c + (SIMD3<Float>(0.040, 0.032, 0.024) - c) * smoothstep(0.5, 0.9, scuff[x, y + size / 2]) * 0.5
            }
            return c
        }
        return TyreFields(height: height, roughness: roughness, albedo: albedo)
    }

    static func carTyre(size: Int, seed: UInt32) -> GeneratedMaterial {
        let f = tyreFields(size: size, seed: seed)
        return pack("car-tyre", size: size, height: f.height, occlusionRadius: max(size / 128, 2), occlusionStrength: 1.8,
                    normalStrength: Float(size) / 28, roughness: f.roughness, albedo: f.albedo, worldSize: 1)
    }

    /// The same tyre turning fast: everything round it drawn out into
    /// rings, as the eye and the cars' own blurred wheel pictures have it.
    /// The grooves round the tyre stay; the sipes, the blocks and the
    /// letters become bands.
    static func carTyreRolling(size: Int, seed: UInt32) -> GeneratedMaterial {
        var f = tyreFields(size: size, seed: seed)
        for y in 0 ..< size {
            var h: Float = 0, r: Float = 0, c = SIMD3<Float>(repeating: 0)
            for x in 0 ..< size { h += f.height[x, y]; r += f.roughness[x, y]; c += f.albedo[y * size + x] }
            for x in 0 ..< size {
                f.height[x, y] = h / Float(size); f.roughness[x, y] = r / Float(size); f.albedo[y * size + x] = c / Float(size)
            }
        }
        return pack("car-tyre-rolling", size: size, height: f.height, occlusionRadius: max(size / 128, 2), occlusionStrength: 1.8,
                    normalStrength: Float(size) / 28, roughness: f.roughness, albedo: f.albedo, worldSize: 1)
    }

    /// The moulding of a lamp's lens: rows of flutes that spread the light
    /// sideways, crossed by a fine grid of pillows. A detail set: the car's
    /// own picture keeps the lamp's colour and this gives its surface.
    static func lampLens(size: Int, seed: UInt32) -> GeneratedMaterial {
        let flutes = 8, pillows = 16
        var height = ScalarField(size: size) { x, y in
            let u = Float(x) / Float(size), v = Float(y) / Float(size)
            let flute = abs(sin(v * Float(flutes) * .pi))
            let pillow = abs(sin(u * Float(pillows) * .pi)) * abs(sin(v * Float(pillows) * .pi))
            return flute * 0.7 + pillow * 0.3
        }
        height.normalise()
        let roughness = ScalarField(size: size, repeating: 0.9)
        let albedo = colours(size) { _, _ in SIMD3<Float>(0.8, 0.8, 0.8) }
        return pack("lens", size: size, height: height, occlusionRadius: 2, occlusionStrength: 0.4,
                    normalStrength: Float(size) / 160, roughness: roughness, albedo: albedo, worldSize: 0.05,
                    occlusion: ScalarField(size: size, repeating: 1))
    }
}
