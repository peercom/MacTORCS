// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd

/// The ground a circuit sits in: the surfaces that fill most of every frame.
///
/// They differ from the other recipes in scale. A kerb or a wall is seen a
/// few metres at a time; a verge is seen from two metres to two hundred at
/// once, so it has to have something to show at every one of those
/// distances: blades close to, clumps and worn patches across the middle
/// ground, and broad drifts of colour beyond. A tile of two or three metres
/// can hold only the first of these. These sets are made for a tile of
/// eight, at twice the texels a side, so the texel is no coarser than it
/// was and the tile reaches up into the scales that carry at a distance.
///
/// It must not reach too far. A tile with three or four features to it,
/// a dry patch here and a dark one there, shows as a grid of them on any
/// hillside: the eye finds a repeat by its landmarks. So nothing in these
/// is much more than a metre across, a hundred or more of each thing to the
/// tile, and the drifts of tens of metres are left to the renderer, which
/// can lay them over the ground without repeating (the draw's macro
/// variation, see Forward.metal).
extension MaterialRecipes {
    /// Sets generated at this multiple of the requested size: the ground,
    /// whose tile is large.
    public static func sizeMultiple(for name: String) -> Int {
        ["grass", "grass-dry"].contains(name) ? 2 : 1
    }

    /// A reproducible stream of uniform values, for placing things.
    struct Scatter {
        var state: UInt32
        init(seed: UInt32) { state = Noise.hash(seed ^ 0x5bd1_e995) }
        mutating func next() -> Float {
            state = Noise.hash(state &+ 0x9e37_79b9)
            return Float(state >> 8) / Float(1 << 24)
        }
    }

    /// A tiling field of smooth noise with `cycles` features across the tile.
    static func patches(size: Int, cycles: Int, octaves: Int, seed: UInt32) -> ScalarField {
        var field = ScalarField(size: size) { x, y in
            Noise.fractal(Float(x) / Float(size) * Float(cycles), Float(y) / Float(size) * Float(cycles),
                          period: cycles, octaves: octaves, gain: 0.5, seed: seed)
        }
        field.normalise()
        return field
    }

    @inline(__always)
    static func smoothstep(_ low: Float, _ high: Float, _ value: Float) -> Float {
        let t = min(max((value - low) / (high - low), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: - Turf

    /// Mown grass, as blades.
    ///
    /// The earlier recipe took its blades from stretched noise, which gives
    /// a grain and no blade: nothing in it has a root and a tip, lies across
    /// another or differs from its neighbour in colour, and those are what
    /// the eye reads as grass. Here each blade is laid down as a stroke a
    /// few centimetres long, dark at the root and light at the tip, the
    /// later ones over the earlier, each with its own green. Where the
    /// ground is drier more of them are straw. Over that, clumps a hand or
    /// two across stand a little higher and lighter, and drifts of a few
    /// metres lean toward yellow or toward blue-green.
    static func turf(size: Int, seed: UInt32, dryness: Float) -> GeneratedMaterial {
        let world: Float = 8
        let perMetre = Float(size) / world

        let drift = patches(size: size, cycles: 6, octaves: 2, seed: seed &+ 11)     // over a metre across
        let wear = patches(size: size, cycles: 13, octaves: 3, seed: seed &+ 23)     // half a metre across
        let clump = patches(size: size, cycles: 29, octaves: 2, seed: seed &+ 37)    // a hand or two
        let tuft = patches(size: size, cycles: 97, octaves: 2, seed: seed &+ 53)     // a few blades

        // How dry each place is: mottles half a metre across with the
        // clumps' edges to them, and the set's own dryness moving the whole.
        var dry = ScalarField(size: size) { x, y in
            let mottle = wear[x, y] * 0.62 + clump[x, y] * 0.26 + tuft[x, y] * 0.12
            return min(max(smoothstep(0.56, 0.84, mottle) * 0.8 + dryness, 0), 1)
        }
        // Bare, scuffed ground: rare, small, and only where it is driest.
        let bare = ScalarField(size: size) { x, y in
            smoothstep(0.80, 0.95, wear[x, y] * 0.55 + clump[x, y] * 0.25 + dry[x, y] * 0.2 + dryness * 0.12)
        }
        dry.map { min($0, 1) }

        // Thatch and soil under the blades.
        var height = ScalarField(size: size, repeating: 0)
        var colour = [SIMD3<Float>](repeating: SIMD3(0.030, 0.034, 0.016), count: size * size)
        var tip = ScalarField(size: size, repeating: 0)   // how far along its blade each texel is

        let greenRoot = SIMD3<Float>(0.020, 0.046, 0.010), greenTip = SIMD3<Float>(0.088, 0.150, 0.026)
        let blueRoot = SIMD3<Float>(0.015, 0.042, 0.013), blueTip = SIMD3<Float>(0.058, 0.128, 0.032)
        let strawRoot = SIMD3<Float>(0.075, 0.062, 0.028), strawTip = SIMD3<Float>(0.250, 0.215, 0.100)

        // Blades about five centimetres long and six millimetres wide, enough
        // of them to lie three deep.
        let length = max(0.05 * perMetre, 1), width = max(Int((0.006 * perMetre).rounded()), 1)
        let count = Int(Float(size * size) / (length * Float(width)) * 3)
        var scatter = Scatter(seed: seed)
        for _ in 0 ..< count {
            let px = scatter.next() * Float(size), py = scatter.next() * Float(size)
            let ix = Int(px), iy = Int(py)
            // Fewer blades on bare ground.
            let sparse = bare[ix, iy]
            let chance = scatter.next()
            if chance < sparse * 0.85 { _ = scatter.next(); _ = scatter.next(); _ = scatter.next(); _ = scatter.next(); continue }
            let angle = scatter.next() * 2 * Float.pi
            let reach = length * (0.55 + 0.9 * scatter.next())
            let shade = 0.72 + 0.56 * scatter.next()
            let kind = scatter.next()
            let dryHere = dry[ix, iy]
            // Straw: a few everywhere, most of them where it is dry.
            let isStraw = kind < 0.05 + dryHere * 0.70
            let cool = drift[ix + size / 3, iy + size / 5]
            let root = isStraw ? strawRoot : greenRoot + (blueRoot - greenRoot) * cool
            let end = isStraw ? strawTip : greenTip + (blueTip - greenTip) * cool
            // Blades in a clump stand higher than those between clumps.
            let stand = clump[ix, iy] * 0.35 + tuft[ix, iy] * 0.15 + scatter.next() * 0.25
            let dx = cos(angle), dy = sin(angle)
            let steps = max(Int(reach.rounded(.up)), 1)
            for step in 0 ... steps {
                let t = Float(step) / Float(steps)
                let z = stand + t * 0.30
                let c = (root + (end - root) * (t * (2 - t))) * shade
                for across in 0 ..< width {
                    let offset = Float(across) - Float(width - 1) * 0.5
                    let x = Int((px + dx * Float(step) - dy * offset).rounded(.down))
                    let y = Int((py + dy * Float(step) + dx * offset).rounded(.down))
                    if z > height[x, y] {
                        height[x, y] = z
                        tip[x, y] = t
                        let index = (((y % size) + size) % size) * size + (((x % size) + size) % size)
                        colour[index] = c
                    }
                }
            }
        }

        // The clumps and the drifts, over the blades: a clump is a little
        // lighter where it stands up into the light, and the drifts lean the
        // whole toward yellow or away from it.
        for y in 0 ..< size {
            for x in 0 ..< size {
                let index = y * size + x
                let lift = 0.80 + 0.40 * clump[x, y]
                let lean = drift[x, y] - 0.5
                var c = colour[index] * lift
                c *= SIMD3(1 + 0.16 * lean, 1 + 0.04 * lean, 1 - 0.14 * lean)
                // Bare ground shows as soil between what blades are left.
                let soil = SIMD3<Float>(0.085, 0.066, 0.044)
                let shows = bare[x, y] * (1 - smoothstep(0.15, 0.5, height[x, y]))
                colour[index] = c + (soil - c) * shows
            }
        }

        var relief = ScalarField(size: size) { x, y in height[x, y] * 0.65 + clump[x, y] * 0.35 }
        relief.normalise()
        let occlusion = MaterialSynthesis.ambientOcclusion(from: relief, radius: max(Int(perMetre / 64), 2), strength: 2.0)
        let normals = MaterialSynthesis.normals(from: relief, strength: max(perMetre / 256, 0.05) * 9)

        // A blade is waxy and catches the light along its length; thatch and
        // straw are dull.
        var roughness = ScalarField(size: size) { x, y in
            0.90 - tip[x, y] * 0.20 + dry[x, y] * 0.08
        }
        roughness.map { min(max($0, 0.6), 1) }

        return GeneratedMaterial(name: dryness > 0 ? "grass-dry" : "grass", size: size,
                                 albedo: MaterialPacking.albedo(colour),
                                 normal: MaterialPacking.normal(normals),
                                 orm: MaterialPacking.orm(occlusion: occlusion, roughness: roughness, metalness: 0),
                                 worldSize: world)
    }

    // MARK: - Rock

    /// The two nearest feature points of a tiling cellular noise: their
    /// distances, and a hash that names the nearest cell.
    static func cells(_ x: Float, _ y: Float, period: Int, seed: UInt32)
        -> (nearest: Float, second: Float, cell: UInt32, offset: SIMD2<Float>) {
        func wrap(_ i: Int) -> Int { ((i % period) + period) % period }
        let cx = Int(floor(x)), cy = Int(floor(y))
        var nearest = Float.greatestFiniteMagnitude, second = Float.greatestFiniteMagnitude
        var cell: UInt32 = 0
        var offset = SIMD2<Float>(0, 0)
        for dy in -1 ... 1 {
            for dx in -1 ... 1 {
                let gx = cx + dx, gy = cy + dy
                let h = Noise.hash(wrap(gx), wrap(gy), seed)
                let px = Float(gx) + Float(h & 0xFFFF) / 65_536, py = Float(gy) + Float((h >> 16) & 0xFFFF) / 65_536
                let d = ((px - x) * (px - x) + (py - y) * (py - y)).squareRoot()
                if d < nearest {
                    second = nearest; nearest = d; cell = h; offset = SIMD2(x - px, y - py)
                } else if d < second { second = d }
            }
        }
        return (nearest, second, cell, offset)
    }

    /// A weathered rock face: bedded, jointed and broken.
    ///
    /// Rock in a cutting is beds a hand to a forearm thick, split across by
    /// joints into blocks, the face of each block rough where it broke.
    /// Water darkens the joints and leaves iron in streaks below them;
    /// lichen takes the faces the weather reaches. So: beds as steps in the
    /// height along one axis, blocks from cellular noise with the joints
    /// where two cells meet, a ridged surface over both, and the colour from
    /// the block, the joint and what grows there.
    static func rock(size: Int, seed: UInt32) -> GeneratedMaterial {
        let world: Float = 6
        let beds = 15, blocks = 7
        let warp = patches(size: size, cycles: 5, octaves: 3, seed: seed &+ 3)
        var surface = ScalarField(size: size) { x, y in
            // Ridged: the breaks in a rock's face are creases, not bumps.
            var total: Float = 0, amplitude: Float = 0.5, norm: Float = 0
            var frequency = 8
            for octave in 0 ..< 6 {
                let n = Noise.value(Float(x) / Float(size) * Float(frequency), Float(y) / Float(size) * Float(frequency),
                                    period: frequency, seed: seed &+ 101 &+ UInt32(octave) &* 13)
                total += (1 - abs(2 * n - 1)) * amplitude
                norm += amplitude; amplitude *= 0.55; frequency *= 2
            }
            return total / norm
        }
        surface.normalise()

        // Which joints have opened: not all of them have. A face with every
        // block outlined is a wall somebody built.
        let open = patches(size: size, cycles: 11, octaves: 2, seed: seed &+ 223)
        let width = patches(size: size, cycles: 17, octaves: 2, seed: seed &+ 227)

        var height = ScalarField(size: size, repeating: 0)
        var joint = ScalarField(size: size, repeating: 0)     // 1 in a joint or a bedding plane
        var tint = ScalarField(size: size, repeating: 0)      // the block's own shade
        for y in 0 ..< size {
            for x in 0 ..< size {
                let u = Float(x) / Float(size), v = Float(y) / Float(size)
                // Beds: wavering lines across the face, each bed set back or
                // forward a little from the next.
                let bedding = v * Float(beds) + (warp[x, y] - 0.5) * 2.4
                let bed = Int(floor(bedding))
                let within = bedding - Float(bed)
                let wrapped = ((bed % beds) + beds) % beds
                let step = Float(Noise.hash(wrapped, 7, seed &+ 211) & 0xFF) / 255
                let gape = 0.025 + 0.07 * width[x, y]
                let plane = (1 - smoothstep(0.0, gape, min(within, 1 - within)))
                    * smoothstep(0.25, 0.5, open[x + size / 4, y])
                // Blocks, stretched along the beds, each face tilted its own way.
                let c = cells(u * Float(blocks) * 1.0 + (warp[x + size / 2, y] - 0.5) * 1.2,
                              v * Float(blocks) * 2.0, period: blocks * 2, seed: seed &+ 307 &+ UInt32(wrapped % 3))
                let crack = (1 - smoothstep(0.0, gape * 1.4, c.second - c.nearest)) * smoothstep(0.45, 0.7, open[x, y])
                joint[x, y] = max(crack, plane)
                tint[x, y] = Float(c.cell & 0xFF) / 255 * 0.5 + step * 0.5
                let lean = SIMD2(Float((c.cell >> 8) & 0xFF) / 255 - 0.5, Float((c.cell >> 16) & 0xFF) / 255 - 0.5)
                height[x, y] = surface[x, y] * 0.50 + step * 0.16 + simd_dot(lean, c.offset) * 0.55
                    - joint[x, y] * 0.40
            }
        }
        height.normalise()
        let occlusion = MaterialSynthesis.ambientOcclusion(from: height, radius: max(size / 256, 2), strength: 1.8)
        let normals = MaterialSynthesis.normals(from: height, strength: Float(size) / 55)

        let lichen = patches(size: size, cycles: 41, octaves: 2, seed: seed &+ 401)
        let stain = patches(size: size, cycles: 9, octaves: 3, seed: seed &+ 409)
        var roughness = ScalarField(size: size, repeating: 0.9)
        let albedo = (0 ..< size * size).map { index -> SIMD3<Float> in
            let x = index % size, y = index / size
            let grey = SIMD3<Float>(0.195, 0.195, 0.188), warm = SIMD3<Float>(0.265, 0.238, 0.196)
            let pale = SIMD3<Float>(0.335, 0.330, 0.315)
            let t = tint[x, y]
            var c = t < 0.5 ? grey + (warm - grey) * (t * 2) : warm + (pale - warm) * (t * 2 - 2 * 0.5)
            // The broken face: lighter on its ridges, darker in its creases
            // and wherever the face is shut in.
            c *= (0.62 + 0.85 * surface[x, y]) * (0.70 + 0.30 * occlusion[x, y])
            // Iron, in streaks below where the water comes out.
            let iron = smoothstep(0.62, 0.9, stain[x, y]) * 0.45
            c = c + (SIMD3<Float>(0.30, 0.17, 0.08) - c) * iron
            // The grain of the stone itself: flecks a texel or two across.
            let fleck = Noise.random(x, y, seed &+ 419), pit = Noise.random(x / 2, y / 2, seed &+ 421)
            c *= 0.86 + 0.24 * fleck
            if pit > 0.94 { c *= 0.62 }
            // Lichen on the open faces: crusts with ragged edges, pale
            // grey-green, and a little of the orange kind.
            let ragged = lichen[x, y] + (fleck - 0.5) * 0.10
            let grown = smoothstep(0.76, 0.84, ragged) * (1 - joint[x, y]) * 0.55
            let orange = lichen[x + size / 3, y + size / 7] > 0.88
            c = c + ((orange ? SIMD3<Float>(0.36, 0.24, 0.07) : SIMD3<Float>(0.29, 0.31, 0.24)) - c) * grown
            // Joints hold damp, soil and moss.
            let damp = joint[x, y]
            c = c + (SIMD3<Float>(0.040, 0.045, 0.030) - c) * damp * 0.85
            roughness[x, y] = min(0.86 + grown * 0.1 + damp * 0.08 - surface[x, y] * 0.05, 1)
            return c
        }

        return GeneratedMaterial(name: "rock", size: size,
                                 albedo: MaterialPacking.albedo(albedo),
                                 normal: MaterialPacking.normal(normals),
                                 orm: MaterialPacking.orm(occlusion: occlusion, roughness: roughness, metalness: 0),
                                 worldSize: world)
    }

    // MARK: - Snow

    /// Settled snow: wind-packed, a little rippled, and granular close to.
    ///
    /// Snow is nearly white and nearly matte, so its albedo has little to
    /// say; what reads as snow is its surface. Soft drifts a metre across,
    /// fine ripples across the wind, and a grain of crystals that the sun
    /// picks out as glitter, which is why its roughness varies texel by
    /// texel while its colour barely moves. The hollows are a shade bluer:
    /// they see more sky than sun.
    static func snow(size: Int, seed: UInt32) -> GeneratedMaterial {
        let world: Float = 6
        let drift = patches(size: size, cycles: 6, octaves: 3, seed: seed &+ 5)
        let ripple = ScalarField(size: size) { x, y in
            let across = Float(y) / Float(size) * 60 + (drift[x, y] - 0.5) * 5
            return 0.5 + 0.5 * sin(across * 2 * Float.pi + Noise.fractal(Float(x) / Float(size) * 9, Float(y) / Float(size) * 9,
                                                                         period: 9, octaves: 2, seed: seed &+ 19) * 4)
        }
        var height = ScalarField(size: size) { x, y in
            drift[x, y] * 0.62 + ripple[x, y] * 0.10 + Noise.random(x, y, seed &+ 71) * 0.10
                + Noise.fractal(Float(x) / Float(size) * 90, Float(y) / Float(size) * 90, period: 90, octaves: 2, seed: seed &+ 29) * 0.18
        }
        height.normalise()
        let occlusion = MaterialSynthesis.ambientOcclusion(from: height, radius: max(size / 200, 2), strength: 1.2)
        let normals = MaterialSynthesis.normals(from: height, strength: Float(size) / 150)
        var roughness = ScalarField(size: size) { x, y in
            // Most crystals scatter; one in a few dozen faces the eye.
            let crystal = Noise.random(x, y, seed &+ 83)
            return crystal > 0.965 ? 0.22 : 0.62 + Noise.random(x, y, seed &+ 89) * 0.22
        }
        roughness.map { min(max($0, 0.2), 1) }
        let albedo = (0 ..< size * size).map { index -> SIMD3<Float> in
            let x = index % size, y = index / size
            let lit = SIMD3<Float>(0.86, 0.87, 0.88), hollow = SIMD3<Float>(0.70, 0.76, 0.86)
            let depth = 1 - height[x, y]
            return lit + (hollow - lit) * smoothstep(0.35, 0.9, depth) * 0.7
        }
        return GeneratedMaterial(name: "snow", size: size,
                                 albedo: MaterialPacking.albedo(albedo),
                                 normal: MaterialPacking.normal(normals),
                                 orm: MaterialPacking.orm(occlusion: occlusion, roughness: roughness, metalness: 0),
                                 worldSize: world)
    }

    // MARK: - Concrete

    /// Cast concrete that has stood outside for years.
    ///
    /// New concrete is an even grey and nothing else, which is how the
    /// first recipe drew it and why every wall looked like card. What makes
    /// concrete read as concrete is what happened to it: the air that was
    /// trapped against the form and left pits, the fine crazing of its
    /// skin as it cured, the sand and stone showing where the skin has worn
    /// through, lime leached out in pale blooms, and damp and algae darkening
    /// it in mottles. All of it small: a wall is seen a few metres at a
    /// time, and the tile is two and a half.
    static func weatheredConcrete(size: Int, seed: UInt32) -> GeneratedMaterial {
        let fine = patches(size: size, cycles: 90, octaves: 3, seed: seed)
        let damp = patches(size: size, cycles: 23, octaves: 4, seed: seed &+ 7)
        let bloom = patches(size: size, cycles: 31, octaves: 3, seed: seed &+ 13)
        let worn = patches(size: size, cycles: 23, octaves: 3, seed: seed &+ 17)
        let crazed = patches(size: size, cycles: 9, octaves: 2, seed: seed &+ 19)
        var pit = ScalarField(size: size, repeating: 0), craze = ScalarField(size: size, repeating: 0)
        var grit = ScalarField(size: size, repeating: 0.5)
        for y in 0 ..< size {
            for x in 0 ..< size {
                let u = Float(x) / Float(size), v = Float(y) / Float(size)
                // Bug holes: a few millimetres across, round, most of them
                // absent. Only the cells whose hash says so hold one.
                let hole = cells(u * 70, v * 70, period: 70, seed: seed &+ 23)
                if hole.cell & 0xFF < 46 {
                    let radius = 0.10 + Float((hole.cell >> 8) & 0xFF) / 255 * 0.16
                    pit[x, y] = 1 - smoothstep(radius * 0.6, radius, hole.nearest)
                }
                // Crazing: a net of hairlines, cells a hand across, only
                // where the skin is thin.
                let net = cells(u * 26 + (damp[x, y] - 0.5) * 0.6, v * 26, period: 26, seed: seed &+ 29)
                craze[x, y] = (1 - smoothstep(0.0, 0.035, net.second - net.nearest)) * smoothstep(0.50, 0.68, crazed[x, y])
                // The sand in the mix, a grain to a texel or two.
                grit[x, y] = Float(cells(u * 300, v * 300, period: 300, seed: seed &+ 31).cell & 0xFF) / 255
            }
        }
        var height = ScalarField(size: size) { x, y in
            fine[x, y] * 0.55 + grit[x, y] * 0.15 * smoothstep(0.45, 0.75, worn[x, y]) + 0.3 - pit[x, y] * 0.55 - craze[x, y] * 0.18
        }
        height.normalise()
        let occlusion = MaterialSynthesis.ambientOcclusion(from: height, radius: max(size / 256, 2), strength: 1.6)
        let normals = MaterialSynthesis.normals(from: height, strength: Float(size) / 170)
        var roughness = ScalarField(size: size) { x, y in
            0.84 + fine[x, y] * 0.10 + smoothstep(0.45, 0.75, worn[x, y]) * 0.05
        }
        roughness.map { min(max($0, 0.5), 1) }
        let albedo = (0 ..< size * size).map { index -> SIMD3<Float> in
            let x = index % size, y = index / size
            var c = SIMD3<Float>(0.170, 0.166, 0.158) * (0.90 + fine[x, y] * 0.20)
            // Where the skin has worn the sand shows: speckled, a little warmer.
            let exposed = smoothstep(0.45, 0.75, worn[x, y])
            c *= 1 + exposed * (grit[x, y] - 0.45) * 0.55
            c *= SIMD3(1 + exposed * 0.04, 1, 1 - exposed * 0.05)
            // Damp and what grows in it: darker, toward green.
            // Slight, and in small mottles: a wall with a dozen dark blots
            // to the tile is a wall with spots.
            let wet = smoothstep(0.50, 0.90, damp[x, y])
            c = c + (SIMD3<Float>(0.105, 0.110, 0.092) - c) * wet * 0.32
            // Lime: pale, thin, with soft edges.
            let lime = smoothstep(0.66, 0.86, bloom[x, y]) * (1 - wet)
            c = c + (SIMD3<Float>(0.27, 0.27, 0.26) - c) * lime * 0.22
            c *= 1 - pit[x, y] * 0.55
            c *= 1 - craze[x, y] * 0.45
            return c
        }
        return GeneratedMaterial(name: "concrete", size: size,
                                 albedo: MaterialPacking.albedo(albedo),
                                 normal: MaterialPacking.normal(normals),
                                 orm: MaterialPacking.orm(occlusion: occlusion, roughness: roughness, metalness: 0),
                                 worldSize: 2.5)
    }

    // MARK: - Sand

    /// The bed of a run-off: coarse sand with stones in it.
    ///
    /// The first recipe drew a beach, rippled by the wind, and ripples every
    /// fifteen centimetres across a run-off read as corduroy. A trap is
    /// builder's sand and gravel, raked now and then and ploughed by
    /// whoever went off last: grains, stones the size of a fingernail to a
    /// thumb in every colour a quarry has, hollows that hold the damp.
    static func runOffSand(size: Int, seed: UInt32) -> GeneratedMaterial {
        let hollow = patches(size: size, cycles: 9, octaves: 3, seed: seed &+ 3)
        let damp = patches(size: size, cycles: 15, octaves: 3, seed: seed &+ 5)
        let grain = patches(size: size, cycles: 200, octaves: 2, seed: seed &+ 7)
        var stone = ScalarField(size: size, repeating: 0)
        var kind = ScalarField(size: size, repeating: 0)
        for y in 0 ..< size {
            for x in 0 ..< size {
                let u = Float(x) / Float(size), v = Float(y) / Float(size)
                for (count, share, offset) in [(64, UInt32(70), UInt32(11)), (150, UInt32(110), UInt32(13))] {
                    let c = cells(u * Float(count), v * Float(count), period: count, seed: seed &+ offset)
                    guard c.cell & 0xFF < share else { continue }
                    // No two stones are round the same way.
                    let radius = (0.14 + Float((c.cell >> 8) & 0xFF) / 255 * 0.20) * (0.75 + 0.5 * grain[x, y])
                    let dome = 1 - smoothstep(radius * 0.35, radius, c.nearest)
                    if dome > stone[x, y] { stone[x, y] = dome; kind[x, y] = Float((c.cell >> 16) & 0xFF) / 255 }
                }
            }
        }
        var height = ScalarField(size: size) { x, y in
            hollow[x, y] * 0.35 + grain[x, y] * 0.25 + stone[x, y] * 0.40
        }
        height.normalise()
        let occlusion = MaterialSynthesis.ambientOcclusion(from: height, radius: max(size / 256, 2), strength: 1.5)
        let normals = MaterialSynthesis.normals(from: height, strength: Float(size) / 120)
        var roughness = ScalarField(size: size) { x, y in 0.93 - stone[x, y] * 0.18 + grain[x, y] * 0.04 }
        roughness.map { min(max($0, 0.5), 1) }
        let albedo = (0 ..< size * size).map { index -> SIMD3<Float> in
            let x = index % size, y = index / size
            var c = SIMD3<Float>(0.300, 0.255, 0.180) * (0.80 + grain[x, y] * 0.40)
            // Damp sand is darker and less yellow.
            let wet = smoothstep(0.5, 0.85, damp[x, y] * 0.6 + (1 - hollow[x, y]) * 0.4)
            c = c + (SIMD3<Float>(0.170, 0.150, 0.115) - c) * wet * 0.6
            // The stones: grey, buff, rust, and the odd white one.
            let k = kind[x, y]
            let pebble: SIMD3<Float> = k < 0.4 ? SIMD3(0.215, 0.205, 0.185) : (k < 0.72 ? SIMD3(0.33, 0.285, 0.215)
                : (k < 0.93 ? SIMD3(0.245, 0.185, 0.135) : SIMD3(0.43, 0.41, 0.36)))
            c = c + (pebble * (0.75 + 0.5 * stone[x, y]) - c) * smoothstep(0.1, 0.5, stone[x, y])
            return c
        }
        return GeneratedMaterial(name: "sand", size: size,
                                 albedo: MaterialPacking.albedo(albedo),
                                 normal: MaterialPacking.normal(normals),
                                 orm: MaterialPacking.orm(occlusion: occlusion, roughness: roughness, metalness: 0),
                                 worldSize: 3)
    }
}
