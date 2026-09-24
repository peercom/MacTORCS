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
        "gravel", "dirt", "mud", "sand", "grass-cards",
        "armco", "tyre-wall", "chain-link", "brick", "wood", "painted-steel",
        "rubber-tread", "carbon-weave", "brushed-metal", "chrome", "plastic", "fabric", "paint-flake", "glass"]

    /// Deliberately smooth: allowed a roughness floor below the usual one.
    public static let smooth: Set<String> = ["chrome", "glass"]
    public static let metals: Set<String> = ["armco", "brushed-metal", "chrome", "chain-link", "paint-flake"]

    public static func generate(_ name: String, size: Int = 1024, seed: UInt32 = 1) throws -> GeneratedMaterial {
        switch name {
        case "asphalt": return asphalt(size: size, seed: seed, wear: 0.15)
        case "asphalt-worn": return asphalt(size: size, seed: seed &+ 17, wear: 0.65)
        case "asphalt-patched": return asphaltPatched(size: size, seed: seed &+ 23)
        case "grass": return grass(size: size, seed: seed)
        case "grass-dry": return grass(size: size, seed: seed &+ 29, dryness: 0.7)
        case "concrete": return concrete(size: size, seed: seed)
        case "kerb": return kerb(size: size, seed: seed)
        case "gravel": return gravel(size: size, seed: seed)
        case "dirt": return dirt(size: size, seed: seed)
        case "mud": return mud(size: size, seed: seed &+ 31)
        case "sand": return sand(size: size, seed: seed &+ 37)
        case "grass-cards": return grassCards(size: size, seed: seed)
        case "armco": return armco(size: size, seed: seed &+ 41)
        case "tyre-wall": return tyreWall(size: size, seed: seed &+ 43)
        case "chain-link": return chainLink(size: size, seed: seed &+ 47)
        case "brick": return brick(size: size, seed: seed &+ 53)
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

        let albedo = (0 ..< size * size).map { index -> SIMD3<Float> in
            let x = index % size, y = index / size
            let stone = worn[x, y]
            // Fresh bitumen is very dark; exposed aggregate is grey. Wear
            // shifts the balance toward the stone, which is why a used racing
            // line is lighter than the track around it.
            let dark = SIMD3<Float>(0.020, 0.021, 0.024)
            let stoneColour = SIMD3<Float>(0.085, 0.084, 0.082)
            let mix = min(max(stone * (0.35 + wear * 0.55), 0), 1)
            let speck = Noise.random(x, y, seed &+ 91) * 0.012
            return dark + (stoneColour - dark) * mix + SIMD3(repeating: speck)
        }

        return GeneratedMaterial(name: wear > 0.4 ? "asphalt-worn" : "asphalt", size: size,
                                 albedo: MaterialPacking.albedo(albedo),
                                 normal: MaterialPacking.normal(normals),
                                 orm: MaterialPacking.orm(occlusion: occlusion, roughness: roughness, metalness: 0),
                                 worldSize: 2)
    }

    // MARK: - Grass

    /// Many small blades, so the detail is high-frequency, plus patch-scale
    /// variation in colour and density from soil and growth.
    static func grass(size: Int, seed: UInt32, dryness: Float = 0) -> GeneratedMaterial {
        var blades = ScalarField(size: size) { x, y in
            // Anisotropic: blades are long in one axis and thin in the other.
            Noise.fractal(Float(x) / Float(size) * 220, Float(y) / Float(size) * 70,
                          period: 220, octaves: 3, gain: 0.6, seed: seed)
        }
        blades.normalise()

        var patches = ScalarField(size: size) { x, y in
            Noise.fractal(Float(x) / Float(size) * 5, Float(y) / Float(size) * 5,
                          period: 5, octaves: 4, gain: 0.55, seed: seed &+ 41)
        }
        patches.normalise()

        let height = blades.blended(with: patches, by: ScalarField(size: size, repeating: 0.35))
        let occlusion = MaterialSynthesis.ambientOcclusion(from: height, radius: 5, strength: 2.2)
        let normals = MaterialSynthesis.normals(from: height, strength: Float(size) / 90)

        // Grass is rough everywhere; the variation is small and driven by how
        // dry the patch is.
        var roughness = ScalarField(size: size) { x, y in 0.88 + patches[x, y] * 0.09 }
        roughness.map { min(max($0, 0.6), 1) }

        let albedo = (0 ..< size * size).map { index -> SIMD3<Float> in
            let x = index % size, y = index / size
            let dry = min(patches[x, y] + dryness, 1)
            let lush = SIMD3<Float>(0.055, 0.115, 0.032)
            let parched = SIMD3<Float>(0.135, 0.130, 0.055)
            let soil = SIMD3<Float>(0.055, 0.042, 0.028)
            let blade = blades[x, y]
            let base = lush + (parched - lush) * dry
            // Soil shows through where the blades are sparse.
            return base + (soil - base) * max(0, 0.35 - blade) * 1.4
        }

        return GeneratedMaterial(name: dryness > 0 ? "grass-dry" : "grass", size: size,
                                 albedo: MaterialPacking.albedo(albedo),
                                 normal: MaterialPacking.normal(normals),
                                 orm: MaterialPacking.orm(occlusion: occlusion, roughness: roughness, metalness: 0),
                                 worldSize: 3)
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

    // MARK: - Concrete, kerb, gravel, dirt

    static func concrete(size: Int, seed: UInt32) -> GeneratedMaterial {
        var height = ScalarField(size: size) { x, y in
            let fine = Noise.fractal(Float(x) / Float(size) * 90, Float(y) / Float(size) * 90,
                                     period: 90, octaves: 4, gain: 0.5, seed: seed)
            let pores = 1 - Noise.worley(Float(x) / Float(size) * 40, Float(y) / Float(size) * 40,
                                         period: 40, seed: seed &+ 5)
            // Air pockets in the pour read as small dark pits.
            return fine * 0.7 + pow(pores, 6) * 0.3
        }
        height.normalise()
        let occlusion = MaterialSynthesis.ambientOcclusion(from: height, radius: 4, strength: 1.8)
        let normals = MaterialSynthesis.normals(from: height, strength: Float(size) / 200)
        var roughness = ScalarField(size: size) { x, y in 0.82 + height[x, y] * 0.12 }
        roughness.map { min(max($0, 0.5), 1) }
        let albedo = (0 ..< size * size).map { index -> SIMD3<Float> in
            let x = index % size, y = index / size
            let tone = 0.155 + height[x, y] * 0.035
            let stain = Noise.fractal(Float(x) / Float(size) * 3, Float(y) / Float(size) * 3,
                                      period: 3, octaves: 3, seed: seed &+ 77) * 0.03
            return SIMD3(tone - stain, tone - stain * 0.95, tone - stain * 0.85)
        }
        return GeneratedMaterial(name: "concrete", size: size,
                                 albedo: MaterialPacking.albedo(albedo),
                                 normal: MaterialPacking.normal(normals),
                                 orm: MaterialPacking.orm(occlusion: occlusion, roughness: roughness, metalness: 0),
                                 worldSize: 2.5)
    }

    /// Painted kerb stone. The paint is a hard-edged stripe, and it wears off
    /// the raised parts first, which is where the height field earns its keep.
    static func kerb(size: Int, seed: UInt32) -> GeneratedMaterial {
        var height = ScalarField(size: size) { x, y in
            let stone = 1 - Noise.worley(Float(x) / Float(size) * 24, Float(y) / Float(size) * 24,
                                         period: 24, seed: seed)
            let grain = Noise.fractal(Float(x) / Float(size) * 120, Float(y) / Float(size) * 120,
                                      period: 120, octaves: 3, seed: seed &+ 13)
            return stone * 0.6 + grain * 0.4
        }
        height.normalise()
        let occlusion = MaterialSynthesis.ambientOcclusion(from: height, radius: 4, strength: 1.5)
        let normals = MaterialSynthesis.normals(from: height, strength: Float(size) / 150)

        // Stripes run across the kerb, half its tile each.
        func painted(_ x: Int) -> Bool { (x * 2 / size) % 2 == 0 }
        var roughness = ScalarField(size: size) { x, y in
            // Paint is smoother than the stone under it until it wears.
            let wear = max(0, height[x, y] - 0.55) * 2
            return painted(x) ? min(0.45 + wear * 0.4, 1) : 0.85
        }
        roughness.map { min(max($0, 0.3), 1) }

        let albedo = (0 ..< size * size).map { index -> SIMD3<Float> in
            let x = index % size, y = index / size
            let stone = SIMD3<Float>(0.20, 0.195, 0.185)
            let colour: SIMD3<Float> = painted(x) ? SIMD3(0.52, 0.035, 0.030) : SIMD3(0.78, 0.77, 0.75)
            let wear = max(0, height[x, y] - 0.6) * 2.2
            return colour + (stone - colour) * min(wear, 1)
        }
        return GeneratedMaterial(name: "kerb", size: size,
                                 albedo: MaterialPacking.albedo(albedo),
                                 normal: MaterialPacking.normal(normals),
                                 orm: MaterialPacking.orm(occlusion: occlusion, roughness: roughness, metalness: 0),
                                 worldSize: 1)
    }

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
