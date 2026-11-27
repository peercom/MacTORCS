// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd

/// What stands along the edge of a circuit: tyre walls, kerbs, guard rails.
///
/// Unlike the ground these are objects, and their sets are laid out the way
/// the object is: a tyre wall's tile is tyres stacked from the ground up, a
/// guard rail's is its beams one above another, a kerb's is its blocks
/// along the track. So they are drawn once across the object and never
/// repeated within the original artwork's own repeat, as the ground's are.
extension MaterialRecipes {
    @inline(__always)
    static func fraction(_ hash: UInt32, shift: UInt32 = 0) -> Float { Float((hash >> shift) & 0xFF) / 255 }

    // MARK: - Tyre wall

    /// A tyre wall from the track: tyres lying flat in stacks six high, seen
    /// edge on.
    ///
    /// The earlier set drew each tyre as a ring, the way a tyre looks from
    /// its side, two to a stack. A tyre wall is not built that way and is
    /// not seen that way: the tyres lie flat, bolted through in columns, and
    /// what faces the track is tread. So each tyre here is a short drum,
    /// round across the tile and shouldered top and bottom, with its own
    /// tread, its own wear and its own place in a stack that nobody squared
    /// up. The tile is one wall's height, 1.3 m, and two stacks along. The
    /// top row is painted white, as the row a driver has to see is.
    static func tyreStack(size: Int, seed: UInt32) -> GeneratedMaterial {
        let columns = 2, rows = 6
        let dust = fractalField(size: size, cells: 5, octaves: 3, seed: seed &+ 3)
        let grain = fractalField(size: size, cells: 120, octaves: 2, seed: seed &+ 5)
        var height = ScalarField(size: size, repeating: 0)
        var groove = ScalarField(size: size, repeating: 0)
        var body = ScalarField(size: size, repeating: 0)      // 1 on a tyre, 0 in the gap between stacks
        var shade = ScalarField(size: size, repeating: 1)
        var paint = ScalarField(size: size, repeating: 0)
        var round = ScalarField(size: size, repeating: 0)     // how far a texel faces out of the wall
        for y in 0 ..< size {
            for x in 0 ..< size {
                let across = Float(x) / Float(size) * Float(columns), up = Float(y) / Float(size) * Float(rows)
                let column = Int(across), row = Int(up)
                let tyre = Noise.hash(column, row, seed &+ 11)
                // No stack is plumb: each tyre sits a centimetre or two off the one under it.
                let r = (across - Float(column) - 0.5 + (fraction(tyre) - 0.5) * 0.06) * 2.06
                let within = up - Float(row)
                guard abs(r) < 1 else { continue }
                body[x, y] = 1
                // Round across the tile, and shouldered where tread turns into sidewall.
                let drum = (1 - r * r).squareRoot()
                let edge = min(within, 1 - within)
                let q = min(edge / 0.17, 1)
                let shoulder = (1 - (1 - q) * (1 - q)).squareRoot()
                var h = drum * (0.30 + 0.70 * shoulder)
                // Tread: three grooves round the tyre and a pattern of sipes
                // across it, by the angle round the drum, so they crowd
                // together toward its edges as they do on a real one. Some
                // tyres are worn nearly smooth; that is why they are here.
                let angle = asin(min(max(r, -1), 1))
                let worn = fraction(tyre, shift: 8)
                let depth: Float = worn > 0.7 ? 0.25 : 1.0
                var cut: Float = 0
                if within > 0.16 && within < 0.84 {
                    for line in [Float(0.33), 0.5, 0.67] { cut = max(cut, 1 - smoothstep(0.012, 0.03, abs(within - line))) }
                    let lean: Float = fraction(tyre, shift: 16) > 0.5 ? 1 : -1
                    let pitch: Float = 9 + Float((tyre >> 24) & 0x7)
                    let round: Float = angle * pitch / Float.pi + within * 1.6 * lean + fraction(tyre, shift: 16)
                    let phase: Float = (round * 2 + 64).truncatingRemainder(dividingBy: 1)
                    let sipe: Float = abs(phase - 0.5)
                    let cross: Float = (1 - smoothstep(0.03, 0.09, sipe)) * 0.8
                    cut = max(cut, cross)
                }
                groove[x, y] = cut * depth
                h -= cut * depth * 0.06
                // Where two tyres meet, a dark crease.
                h *= 0.25 + 0.75 * smoothstep(0.0, 0.05, edge)
                height[x, y] = h
                round[x, y] = drum * (0.4 + 0.6 * smoothstep(0.0, 0.10, edge))
                shade[x, y] = 0.72 + 0.5 * fraction(tyre, shift: 12)
                paint[x, y] = row == 0 ? 1 : 0
            }
        }
        var relief = height
        relief.normalise()
        let roughness = ScalarField(size: size) { x, y in
            body[x, y] == 0 ? 0.95 : (paint[x, y] > 0 ? 0.62 : 0.80) + dust[x, y] * 0.10
        }
        let albedo = colours(size) { x, y in
            guard body[x, y] > 0 else { return SIMD3<Float>(0.006, 0.006, 0.006) }
            let rubber = SIMD3<Float>(0.024, 0.024, 0.026) * shade[x, y] * (0.85 + grain[x, y] * 0.3)
            // Paint goes on with a brush and comes off with every car that
            // finds the wall: thin over the grooves, scuffed through in patches.
            var c = rubber
            if paint[x, y] > 0 {
                let kept = smoothstep(0.25, 0.55, dust[x + size / 3, y] * 0.6 + grain[x, y] * 0.4 + 0.18) * (1 - groove[x, y] * 0.6)
                c = c + (SIMD3<Float>(0.60, 0.60, 0.57) * (0.8 + grain[x, y] * 0.3) - c) * kept
            }
            c *= 1 - groove[x, y] * 0.55
            // Dust settles on what faces up, and brake dust and rubber on the rest.
            let settled = smoothstep(0.5, 0.9, dust[x, y]) * 0.28
            c = c + (SIMD3<Float>(0.085, 0.078, 0.066) - c) * settled
            // Where one drum turns away and the next begins, and where one
            // tyre sits on another, neither sees much of the sky.
            return c * (0.30 + 0.70 * round[x, y])
        }
        return pack("tyre-wall", size: size, height: relief, occlusionRadius: max(size / 128, 2), occlusionStrength: 2.4,
                    normalStrength: Float(size) / 16, roughness: roughness, albedo: albedo, worldSize: 1.3)
    }

    /// The top of a tyre wall: one tyre from above, sidewall up, a tile to a
    /// stack. Painted like the row it is the top of.
    static func tyreTop(size: Int, seed: UInt32) -> GeneratedMaterial {
        let dust = fractalField(size: size, cells: 4, octaves: 3, seed: seed &+ 3)
        let grain = fractalField(size: size, cells: 90, octaves: 2, seed: seed &+ 5)
        func ring(_ x: Int, _ y: Int) -> (radius: Float, angle: Float) {
            let dx = Float(x) / Float(size) - 0.5, dy = Float(y) / Float(size) - 0.5
            return ((dx * dx + dy * dy).squareRoot() * 2.04, atan2(dy, dx))
        }
        // The bead at 0.56 of the radius, the shoulder at 0.92, the tread's edge at 1.
        var height = ScalarField(size: size) { x, y in
            let (r, angle) = ring(x, y)
            guard r > 0.56, r < 1 else { return 0 }
            let wall = sin((r - 0.56) / 0.44 * Float.pi)
            // The maker's lettering, raised, a block of it on either side.
            let band = abs(r - 0.76) < 0.035
            let lettered = band && abs(sin(angle)) < 0.38 && sin(angle * 46) > 0.1
            // And the rings moulded round the sidewall.
            let moulded = 0.5 + 0.5 * cos((r - 0.56) * 70)
            return 0.35 + wall * 0.5 + moulded * 0.035 + (lettered ? 0.05 : 0)
        }
        height.normalise()
        let roughness = ScalarField(size: size) { x, y in
            let r = ring(x, y).radius
            return (r > 0.56 && r < 1) ? 0.64 + dust[x, y] * 0.14 : 0.95
        }
        let albedo = colours(size) { x, y in
            let r = ring(x, y).radius
            // Down the middle is the inside of the stack, and between the
            // stacks the ground: both in the dark.
            guard r > 0.56, r < 1 else { return SIMD3<Float>(0.007, 0.007, 0.007) }
            let rubber = SIMD3<Float>(0.030, 0.030, 0.032) * (0.85 + grain[x, y] * 0.3)
            let kept = smoothstep(0.25, 0.55, dust[x + size / 3, y] * 0.6 + grain[x, y] * 0.4 + 0.2)
            let c = rubber + (SIMD3<Float>(0.60, 0.60, 0.57) * (0.8 + grain[x, y] * 0.3) - rubber) * kept
            let settled = smoothstep(0.35, 0.8, dust[x, y]) * 0.55
            return c + (SIMD3<Float>(0.105, 0.095, 0.080) - c) * settled
        }
        return pack("tyre-top", size: size, height: height, occlusionRadius: max(size / 128, 2), occlusionStrength: 2.0,
                    normalStrength: Float(size) / 50, roughness: roughness, albedo: albedo, worldSize: 0.65)
    }

    // MARK: - Kerb

    /// A sawtooth kerb: precast blocks a metre long, red and white by turns,
    /// ribbed across the way the cars go.
    ///
    /// The earlier set was paint on a flat stone. What a kerb is, to the eye
    /// and to the car, is its teeth: ribs an eighth of a metre apart, each
    /// rising slowly and falling short, that catch the sun on one face and
    /// hold the dirt behind the other. Paint wears off their crests first
    /// and stays in their troughs under the grime; tyres leave rubber along
    /// the length of the kerb; and here and there a flake of paint has gone
    /// with the frost. Two metres of track to the tile, a block of each colour.
    static func ribbedKerb(size: Int, seed: UInt32) -> GeneratedMaterial {
        let ribs = 16
        let grain = fractalField(size: size, cells: 110, octaves: 3, seed: seed &+ 3)
        let wear = fractalField(size: size, cells: 9, octaves: 3, seed: seed &+ 5)
        // Rubber goes down in the direction of travel: long along the tile, narrow across it.
        var rubber = ScalarField(size: size) { x, y in
            Noise.fractal(Float(x) / Float(size) * 3, Float(y) / Float(size) * 34, period: 34, octaves: 3, seed: seed &+ 7)
        }
        rubber.normalise()
        func tooth(_ x: Int) -> Float {
            let p = (Float(x) / Float(size) * Float(ribs)).truncatingRemainder(dividingBy: 1)
            return p < 0.78 ? p / 0.78 : (1 - p) / 0.22
        }
        /// A groove where one block ends and the next begins.
        func joint(_ x: Int) -> Float {
            let p = (Float(x) / Float(size) * 2).truncatingRemainder(dividingBy: 1)
            return 1 - smoothstep(0.0, 0.006, min(p, 1 - p))
        }
        var chipped = ScalarField(size: size, repeating: 0)
        for y in 0 ..< size {
            for x in 0 ..< size {
                let c = cells(Float(x) / Float(size) * 46, Float(y) / Float(size) * 46, period: 46, seed: seed &+ 13)
                if c.cell & 0xFF < 12 {
                    // A flake, not a disc: ragged, and longer one way than the other.
                    let radius = 0.14 + fraction(c.cell, shift: 8) * 0.22
                    let stretched = simd_length(c.offset * SIMD2(1.0, 0.55 + fraction(c.cell, shift: 16)))
                    chipped[x, y] = 1 - smoothstep(radius * 0.5, radius, stretched + (grain[x, y] - 0.5) * 0.35)
                }
            }
        }
        var height = ScalarField(size: size) { x, y in
            tooth(x) * 0.80 + grain[x, y] * 0.10 - chipped[x, y] * 0.04 - joint(x) * 0.5
        }
        height.normalise()
        /// How much of the paint is left here.
        func painted(_ x: Int, _ y: Int) -> Float {
            let crest = smoothstep(0.62, 0.98, tooth(x)) * smoothstep(0.30, 0.62, wear[x, y])
            return (1 - crest * 0.85) * (1 - chipped[x, y])
        }
        func rubbered(_ x: Int, _ y: Int) -> Float {
            smoothstep(0.62, 0.86, rubber[x, y]) * (0.35 + 0.65 * tooth(x))
        }
        let roughness = ScalarField(size: size) { x, y in
            let paint = painted(x, y)
            return 0.86 - paint * 0.30 - rubbered(x, y) * 0.10
        }
        let albedo = colours(size) { x, y in
            let red = x < size / 2
            let colour: SIMD3<Float> = red ? SIMD3(0.46, 0.032, 0.028) : SIMD3(0.70, 0.69, 0.66)
            let stone = SIMD3<Float>(0.19, 0.185, 0.175) * (0.8 + grain[x, y] * 0.4)
            var c = stone + (colour * (0.86 + grain[x, y] * 0.22) - stone) * painted(x, y)
            // Dirt lies behind each tooth, in the trough the sweeper misses.
            let trough = 1 - smoothstep(0.0, 0.22, tooth(x))
            c = c + (SIMD3<Float>(0.060, 0.055, 0.045) - c) * trough * 0.42
            c = c + (SIMD3<Float>(0.022, 0.022, 0.024) - c) * rubbered(x, y) * 0.6
            return c * (1 - joint(x) * 0.7)
        }
        return pack("kerb", size: size, height: height, occlusionRadius: max(size / 200, 2), occlusionStrength: 1.6,
                    normalStrength: Float(size) / 60, roughness: roughness, albedo: albedo, worldSize: 2)
    }

    // MARK: - Guard rail

    /// Three guard rails one above another, as a circuit mounts them.
    ///
    /// A guard rail is a W: two ribs with a valley between, pressed from
    /// galvanised sheet, each length lapped over the next and bolted through
    /// at the post. At a circuit they go up three deep, and that is the
    /// tile: three beams across it, a post and a lap in its middle. The
    /// zinc has dulled and bloomed white; rust has started at the bolts and
    /// along the cut edges; cars have left paint and rubber along the ribs,
    /// and scraped through to bright metal in places.
    static func tripleArmco(size: Int, seed: UInt32) -> GeneratedMaterial {
        let beams = 3
        // The tile is drawn over about 2.4 m of rail and a metre of height,
        // so a round thing is this much narrower than tall in it.
        let aspect: Float = 2.4
        let grime = fractalField(size: size, cells: 6, octaves: 3, seed: seed &+ 9)
        let bloom = fractalField(size: size, cells: 17, octaves: 2, seed: seed &+ 11)
        var scrape = ScalarField(size: size) { x, y in
            Noise.fractal(Float(x) / Float(size) * 4, Float(y) / Float(size) * 150, period: 150, octaves: 2, seed: seed &+ 13)
        }
        scrape.normalise()
        var spangle = ScalarField(size: size, repeating: 0.5)
        for y in 0 ..< size {
            for x in 0 ..< size {
                spangle[x, y] = fraction(cells(Float(x) / Float(size) * 150, Float(y) / Float(size) * 62, period: 2, seed: seed &+ 17).cell)
            }
        }
        /// Where a texel is across its beam, 0 to 1, and which beam.
        func place(_ y: Int) -> (within: Float, beam: Int) {
            let across = Float(y) / Float(size) * Float(beams)
            return (across - floor(across), Int(across))
        }
        /// The W, 0 at the flanges and 1 on the ribs, the valley at a third.
        func profile(_ w: Float) -> Float {
            let t = min(max((w - 0.05) / 0.90, 0), 1)
            let ribs = sin(t * 2 * Float.pi) * sin(t * 2 * Float.pi)
            return (0.34 + 0.66 * ribs) * smoothstep(0.0, 0.08, t) * smoothstep(0.0, 0.08, 1 - t)
        }
        /// Bolt heads: one through the post at the tile's edge and three
        /// through the lap at its middle, all in the valley.
        func bolt(_ x: Int, _ y: Int) -> Float {
            let u = Float(x) / Float(size), w = place(y).within
            var best: Float = 0
            for at in [Float(0.0), 1.0, 0.455, 0.5, 0.545] {
                let dx = (u - at) * aspect * Float(beams), dy = w - 0.5
                best = max(best, 1 - smoothstep(0.035, 0.05, (dx * dx + dy * dy).squareRoot()))
            }
            return best
        }
        /// Rust round a bolt: a stain three times its width.
        func stain(_ x: Int, _ y: Int) -> Float {
            let u = Float(x) / Float(size), w = place(y).within
            var best: Float = 0
            for at in [Float(0.0), 1.0, 0.455, 0.5, 0.545] {
                let dx = (u - at) * aspect * Float(beams), dy = w - 0.5
                best = max(best, 1 - smoothstep(0.04, 0.17, (dx * dx + dy * dy * 0.5).squareRoot()))
            }
            return best
        }
        var height = ScalarField(size: size) { x, y in
            let (w, _) = place(y)
            // One length laps over the next: a step of the sheet's thickness at the middle.
            let lap: Float = Float(x) / Float(size) < 0.5 ? 0.025 : 0
            return profile(w) * 0.84 + lap + bolt(x, y) * 0.10 + (spangle[x, y] - 0.5) * 0.012
        }
        height.normalise()
        func gap(_ y: Int) -> Float {
            let w = place(y).within
            return 1 - smoothstep(0.0, 0.022, min(w, 1 - w))
        }
        func rusted(_ x: Int, _ y: Int) -> Float {
            let w = place(y).within
            let edges = 1 - smoothstep(0.02, 0.07, min(w, 1 - w))
            let seeded = smoothstep(0.45, 0.8, bloom[x, y])
            return min(stain(x, y) * (0.35 + 0.65 * seeded) + edges * seeded * 0.8, 1)
        }
        /// Marks along the ribs, where cars have run along the rail.
        func marked(_ x: Int, _ y: Int) -> Float {
            let rib = smoothstep(0.75, 0.95, profile(place(y).within))
            return rib * smoothstep(0.62, 0.80, scrape[x, y])
        }
        let roughness = ScalarField(size: size) { x, y in
            let bright = marked(x, y) * (scrape[x + size / 2, y] > 0.5 ? 1 : 0)
            return 0.60 + grime[x, y] * 0.2 + rusted(x, y) * 0.2 - bright * 0.25 + gap(y) * 0.3
        }
        let albedo = colours(size) { x, y in
            // Weathered zinc: grey, each crystal its own shade, with a white bloom in patches.
            var c = SIMD3<Float>(0.40, 0.41, 0.42) * (0.86 + spangle[x, y] * 0.26)
            c = c + (SIMD3<Float>(0.58, 0.59, 0.60) - c) * smoothstep(0.55, 0.85, bloom[x + size / 2, y]) * 0.4
            // Road dirt, most where the rain does not wash: the valleys and under the flanges.
            let sheltered = 1 - smoothstep(0.3, 0.8, profile(place(y).within))
            c = c + (SIMD3<Float>(0.17, 0.15, 0.12) - c) * min(grime[x, y] * 0.35 + sheltered * 0.3, 1)
            c = c + (SIMD3<Float>(0.23, 0.095, 0.035) - c) * rusted(x, y) * 0.65
            // Rubber and somebody's paint, or the bright metal under the zinc.
            let mark = marked(x, y)
            let kind = scrape[x + size / 2, y]
            let left: SIMD3<Float> = kind > 0.5 ? SIMD3(0.62, 0.63, 0.65) : (kind > 0.3 ? SIMD3(0.04, 0.04, 0.045) : SIMD3(0.38, 0.06, 0.05))
            c = c + (left - c) * mark * 0.8
            c *= 1 - bolt(x, y) * 0.25
            return c * (1 - gap(y) * 0.92)
        }
        return pack("armco", size: size, height: height, occlusionRadius: max(size / 128, 2), occlusionStrength: 1.6,
                    normalStrength: Float(size) / 42, roughness: roughness, albedo: albedo, worldSize: 2)
    }
}
