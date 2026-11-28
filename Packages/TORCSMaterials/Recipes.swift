// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd

/// Procedural recipes for the surfaces a circuit is made of.
///
/// Each is a description of what the material physically is, not a filter stack
/// tuned by eye: asphalt is stone aggregate in bitumen, so it is built from
/// cellular noise at aggregate scale; grass is many small blades, so its normal
/// detail is high-frequency and its albedo varies in patches rather than per
/// texel. Building them that way is what makes the roughness and occlusion maps
/// meaningful instead of decorative.
public enum MaterialRecipes {
    /// The circuit's surfaces first, then trackside furniture, then what a
    /// car is made of. The car sets are detail maps: the car keeps its own
    /// painted atlas for colour and takes only their normal and ORM.
    public static let all = [
        "asphalt", "asphalt-worn", "asphalt-patched", "grass", "grass-dry", "concrete", "kerb",
        "gravel", "dirt", "mud", "sand", "rock", "snow", "grass-cards",
        "armco", "tyre-wall", "tyre-top", "chain-link", "catch-fence",
        "concrete-wall", "stone-wall", "brick", "wood", "painted-steel",
        "stand-seats", "corrugated",
        "roller-door", "blockwork", "pit-fascia", "pit-numbers", "roofing",
        "rubber-tread", "carbon-weave", "brushed-metal", "chrome", "plastic", "fabric", "paint-flake", "glass",
        "car-tyre", "car-tyre-rolling", "lens"]

    /// Deliberately smooth: allowed a roughness floor below the usual one.
    public static let smooth: Set<String> = ["chrome", "glass"]
    public static let metals: Set<String> = ["brushed-metal", "chrome", "paint-flake"]

    public static func generate(_ name: String, size: Int = 1024, seed: UInt32 = 1) throws -> GeneratedMaterial {
        switch name {
        case "asphalt": return asphalt(size: size, seed: seed, wear: 0.15)
        case "asphalt-worn": return asphalt(size: size, seed: seed &+ 17, wear: 0.65)
        case "asphalt-patched": return asphaltPatched(size: size, seed: seed &+ 23)
        case "grass": return turf(size: size, seed: seed, dryness: 0)
        case "grass-dry": return turf(size: size, seed: seed &+ 29, dryness: 0.45)
        case "concrete": return weatheredConcrete(size: size, seed: seed)
        case "kerb": return ribbedKerb(size: size, seed: seed)
        case "gravel": return gravel(size: size, seed: seed)
        case "dirt": return dirt(size: size, seed: seed)
        case "mud": return mud(size: size, seed: seed &+ 31)
        case "sand": return runOffSand(size: size, seed: seed &+ 37)
        case "rock": return rock(size: size, seed: seed &+ 107)
        case "snow": return snow(size: size, seed: seed &+ 109)
        case "grass-cards": return grassCards(size: size, seed: seed)
        case "armco": return tripleArmco(size: size, seed: seed &+ 41)
        case "tyre-wall": return tyreStack(size: size, seed: seed &+ 43)
        case "tyre-top": return tyreTop(size: size, seed: seed &+ 45)
        case "chain-link": return chainLinkPanel(size: size, seed: seed &+ 47)
        case "catch-fence": return catchFence(size: size, seed: seed &+ 47)
        case "concrete-wall": return concreteWall(size: size, seed: seed &+ 113)
        case "stone-wall": return stoneWall(size: size, seed: seed &+ 127)
        case "brick": return brickwork(size: size, seed: seed &+ 53)
        case "stand-seats": return standSeats(size: size, seed: seed &+ 137)
        case "corrugated": return ribbedCladding(size: size, seed: seed &+ 139)
        case "roller-door": return rollerDoor(size: size, seed: seed &+ 157)
        case "blockwork": return blockwork(size: size, seed: seed &+ 163)
        case "pit-fascia": return pitFascia(size: size, seed: seed &+ 167)
        case "pit-numbers": return pitNumbers(size: size, seed: seed &+ 173)
        case "roofing": return roofing(size: size, seed: seed &+ 179)
        case "wood": return wood(size: size, seed: seed &+ 59)
        case "painted-steel": return paintedSteel(size: size, seed: seed &+ 61)
        case "rubber-tread": return rubberTread(size: size, seed: seed &+ 67)
        case "carbon-weave": return carbonWeave(size: size, seed: seed &+ 71)
        case "brushed-metal": return brushedMetal(size: size, seed: seed &+ 73)
        case "chrome": return chrome(size: size, seed: seed &+ 79)
        case "plastic": return plastic(size: size, seed: seed &+ 83)
        case "fabric": return fabric(size: size, seed: seed &+ 89)
        case "paint-flake": return paintFlake(size: size, seed: seed &+ 97)
        case "glass": return glass(size: size, seed: seed &+ 101)
        case "car-tyre": return carTyre(size: size, seed: seed &+ 149)
        case "car-tyre-rolling": return carTyreRolling(size: size, seed: seed &+ 149)
        case "lens": return lampLens(size: size, seed: seed &+ 151)
        default: throw MaterialError.unknown(name)
        }
    }

    // MARK: - Asphalt

    /// Stone aggregate suspended in bitumen.
    ///
    /// The aggregate is cellular noise: each cell is one stone, and the
    /// distance to its centre gives both the height of the stone and the
    /// binder gaps between them. Wear lifts the stones out of the binder,
    /// which is what a polished racing line actually is — the same aggregate
    /// with less bitumen over it, so it is both smoother and lighter.
    static func asphalt(size: Int, seed: UInt32, wear: Float) -> GeneratedMaterial {
        // About 12 mm stones over a 2 m tile.
        let aggregatePeriod = 160
        let scale = Float(aggregatePeriod) / Float(size)

        var height = ScalarField(size: size) { x, y in
            let fx = Float(x) * scale, fy = Float(y) * scale
            // Inverted so cell centres, the stones, are high.
            let stone = 1 - Noise.worley(fx, fy, period: aggregatePeriod, seed: seed)
            // Coarse undulation: laid asphalt is not flat at the metre scale.
            let surface = Noise.fractal(Float(x) / Float(size) * 4, Float(y) / Float(size) * 4,
                                        period: 4, octaves: 3, gain: 0.55, seed: seed &+ 3)
            return stone * 0.75 + surface * 0.25
        }
        height.normalise()

        // Wear flattens the surface toward its mean.
        var worn = height
        worn.map { 0.5 + ($0 - 0.5) * (1 - wear * 0.7) }

        let occlusion = MaterialSynthesis.ambientOcclusion(from: worn, radius: 4, strength: 1.6)
        let normals = MaterialSynthesis.normals(from: worn, strength: Float(size) / 128 * (1 - wear * 0.5))

        var roughness = ScalarField(size: size) { x, y in
            // Binder is rougher than exposed stone, and wear polishes both.
            let stoneExposure = worn[x, y]
            let base = 0.92 - stoneExposure * 0.18
            return base - wear * 0.22
        }
        roughness.map { min(max($0, 0.25), 1) }

        // The mat is not one tone: it went down in loads, some richer in
        // binder than others, and it has weathered unevenly since. Mottles
        // a hand to a pace across, slight, and many to the tile.
        let mottle = patches(size: size, cycles: 14, octaves: 3, seed: seed &+ 131)
        let albedo = (0 ..< size * size).map { index -> SIMD3<Float> in
            let x = index % size, y = index / size
            let stone = worn[x, y]
            // Fresh bitumen is very dark; exposed aggregate is grey. Wear
            // shifts the balance toward the stone, which is why a used racing
            // line is lighter than the track around it.
            let dark = SIMD3<Float>(0.020, 0.021, 0.024)
            // The stones are not one quarry's grey either: each is its own,
            // most of them mid grey, a few pale and a few nearly black.
            let which = cells(Float(x) * scale, Float(y) * scale, period: aggregatePeriod, seed: seed).cell
            let shade = Float(which & 0xFF) / 255
            let own = shade > 0.9 ? 1.9 : (shade < 0.12 ? 0.45 : 0.8 + shade * 0.45)
            let stoneColour = SIMD3<Float>(0.085, 0.084, 0.082) * own
                * SIMD3(1 + (Float((which >> 8) & 0xFF) / 255 - 0.5) * 0.10, 1, 1 - (Float((which >> 8) & 0xFF) / 255 - 0.5) * 0.10)
            let mix = min(max(stone * (0.35 + wear * 0.55), 0), 1)
            let speck = Noise.random(x, y, seed &+ 91) * 0.012
            return (dark + (stoneColour - dark) * mix + SIMD3(repeating: speck)) * (0.88 + 0.24 * mottle[x, y])
        }

        return GeneratedMaterial(name: wear > 0.4 ? "asphalt-worn" : "asphalt", size: size,
                                 albedo: MaterialPacking.albedo(albedo),
                                 normal: MaterialPacking.normal(normals),
                                 orm: MaterialPacking.orm(occlusion: occlusion, roughness: roughness, metalness: 0),
                                 worldSize: 2)
    }

    // MARK: - Grass cards

    /// An atlas of four blade clumps for the roadside cards, with coverage in
    /// alpha. Each clump is a few dozen tapered blades leaning from a common
    /// base, darker at the root than the tip as real grass is when lit from
    /// above. Not a tiling texture: `worldSize` is nominal.
    static func grassCards(size: Int, seed: UInt32) -> GeneratedMaterial {
        var colour = [SIMD3<Float>](repeating: SIMD3(0, 0, 0), count: size * size)
        var alpha = [Float](repeating: 0, count: size * size)
        let half = size / 2
        var state = seed &* 2_654_435_761 &+ 12345
        func random() -> Float {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Float(state >> 8) / Float(1 << 24)
        }
        for quadrant in 0 ..< 4 {
            let ox = (quadrant % 2) * half, oy = (quadrant / 2) * half
            let blades = 44 + quadrant * 6
            for _ in 0 ..< blades {
                // Base along the bottom of the cell, leaning either way, height
                // in cell fractions, width in pixels at the root.
                let baseX = 0.15 + random() * 0.7
                let lean = (random() - 0.5) * 0.9
                let height = 0.45 + random() * 0.5
                let width = 1.2 + random() * 2.2
                let dry = random()
                let tint = 0.75 + random() * 0.4
                let steps = Int(Float(half) * height)
                for step in 0 ..< steps {
                    let t = Float(step) / Float(max(steps - 1, 1))
                    // A gentle curve: lean grows with height squared.
                    let x = (baseX + lean * t * t * 0.6) * Float(half)
                    let y = Float(half) - 1 - t * height * Float(half)
                    let w = width * (1 - t * 0.85) + 0.4
                    let lush = SIMD3<Float>(0.06, 0.13, 0.03), parched = SIMD3<Float>(0.15, 0.14, 0.05)
                    let base = (lush + (parched - lush) * dry) * tint
                    let shade = 0.45 + 0.55 * t  // dark root, lit tip
                    for dx in stride(from: -w, through: w, by: 1) {
                        let px = Int(x + dx), py = Int(y)
                        guard px >= 0, px < half, py >= 0, py < half else { continue }
                        let coverage = max(0, 1 - abs(dx) / w)
                        let index = (oy + py) * size + ox + px
                        if coverage > alpha[index] {
                            alpha[index] = min(1, alpha[index] + coverage)
                            colour[index] = base * shade
                        }
                    }
                }
            }
        }
        let flat = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: size * size)
        return GeneratedMaterial(name: "grass-cards", size: size,
                                 albedo: MaterialPacking.albedo(colour, alpha: alpha),
                                 normal: MaterialPacking.normal(flat),
                                 orm: MaterialPacking.orm(occlusion: ScalarField(size: size, repeating: 1),
                                                          roughness: ScalarField(size: size, repeating: 0.9), metalness: 0),
                                 worldSize: 1)
    }

    // MARK: - Gravel, dirt

    static func gravel(size: Int, seed: UInt32) -> GeneratedMaterial {
        var height = ScalarField(size: size) { x, y in
            1 - Noise.worley(Float(x) / Float(size) * 70, Float(y) / Float(size) * 70, period: 70, seed: seed)
        }
        height.map { pow($0, 0.6) }
        height.normalise()
        let occlusion = MaterialSynthesis.ambientOcclusion(from: height, radius: 6, strength: 2.4)
        let normals = MaterialSynthesis.normals(from: height, strength: Float(size) / 70)
        var roughness = ScalarField(size: size) { x, y in 0.9 - height[x, y] * 0.1 }
        roughness.map { min(max($0, 0.6), 1) }
        let albedo = (0 ..< size * size).map { index -> SIMD3<Float> in
            let x = index % size, y = index / size
            let stone = height[x, y]
            let pale = SIMD3<Float>(0.28, 0.265, 0.235)
            let shade = SIMD3<Float>(0.10, 0.095, 0.085)
            return shade + (pale - shade) * stone
        }
        return GeneratedMaterial(name: "gravel", size: size,
                                 albedo: MaterialPacking.albedo(albedo),
                                 normal: MaterialPacking.normal(normals),
                                 orm: MaterialPacking.orm(occlusion: occlusion, roughness: roughness, metalness: 0),
                                 worldSize: 2)
    }

    static func dirt(size: Int, seed: UInt32) -> GeneratedMaterial {
        var height = ScalarField(size: size) { x, y in
            Noise.fractal(Float(x) / Float(size) * 30, Float(y) / Float(size) * 30,
                          period: 30, octaves: 5, gain: 0.55, seed: seed)
        }
        height.normalise()
        let occlusion = MaterialSynthesis.ambientOcclusion(from: height, radius: 5, strength: 1.7)
        let normals = MaterialSynthesis.normals(from: height, strength: Float(size) / 110)
        var roughness = ScalarField(size: size) { x, y in 0.9 + height[x, y] * 0.06 }
        roughness.map { min(max($0, 0.65), 1) }
        let albedo = (0 ..< size * size).map { index -> SIMD3<Float> in
            let x = index % size, y = index / size
            let damp = height[x, y]
            let dry = SIMD3<Float>(0.145, 0.105, 0.070)
            let wet = SIMD3<Float>(0.065, 0.046, 0.030)
            return wet + (dry - wet) * damp
        }
        return GeneratedMaterial(name: "dirt", size: size,
                                 albedo: MaterialPacking.albedo(albedo),
                                 normal: MaterialPacking.normal(normals),
                                 orm: MaterialPacking.orm(occlusion: occlusion, roughness: roughness, metalness: 0),
                                 worldSize: 2.5)
    }
}

public enum MaterialError: Error, CustomStringConvertible {
    case unknown(String)
    public var description: String {
        switch self { case .unknown(let name): return "Unknown material recipe: \(name)" }
    }
}
