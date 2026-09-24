// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd

/// The rest of the material list: patched tarmac, loose surfaces, trackside
/// furniture, and the detail sets a car is made of.
///
/// Same discipline as the first recipes — each is a description of the
/// physical surface, and the roughness and occlusion fall out of the height
/// rather than being painted. Every set tiles; the fields are built from
/// periodic noise and periodic geometry only.
extension MaterialRecipes {
    /// Fractal noise as a normalised field, `cells` periods across the tile.
    static func fractalField(size: Int, cells: Int, octaves: Int, gain: Float = 0.55, seed: UInt32) -> ScalarField {
        var field = ScalarField(size: size) { x, y in
            Noise.fractal(Float(x) / Float(size) * Float(cells), Float(y) / Float(size) * Float(cells),
                          period: cells, octaves: octaves, gain: gain, seed: seed)
        }
        field.normalise()
        return field
    }

    /// Cellular noise inverted so cell centres are high, `cells` across.
    static func cellField(size: Int, cells: Int, seed: UInt32) -> ScalarField {
        var field = ScalarField(size: size) { x, y in
            1 - Noise.worley(Float(x) / Float(size) * Float(cells), Float(y) / Float(size) * Float(cells),
                             period: cells, seed: seed)
        }
        field.normalise()
        return field
    }

    /// Packs a finished set from its fields.
    static func pack(_ name: String, size: Int, height: ScalarField, occlusionRadius: Int, occlusionStrength: Float,
                     normalStrength: Float, roughness: ScalarField, albedo: [SIMD3<Float>], worldSize: Float,
                     metal: Bool = false, metalness: Float? = nil, flatNormal: Bool = false,
                     occlusion: ScalarField? = nil) -> GeneratedMaterial {
        let ao = occlusion ?? MaterialSynthesis.ambientOcclusion(from: height, radius: occlusionRadius, strength: occlusionStrength)
        let normals = flatNormal
            ? [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: size * size)
            : MaterialSynthesis.normals(from: height, strength: normalStrength)
        var clamped = roughness
        clamped.map { min(max($0, smooth.contains(name) ? 0.05 : 0.18), 1) }
        return GeneratedMaterial(name: name, size: size,
                                 albedo: MaterialPacking.albedo(albedo),
                                 normal: MaterialPacking.normal(normals),
                                 orm: MaterialPacking.orm(occlusion: ao, roughness: clamped, metalness: metalness ?? (metal ? 1 : 0)),
                                 worldSize: worldSize, isMetal: metal)
    }

    static func colours(_ size: Int, _ f: (Int, Int) -> SIMD3<Float>) -> [SIMD3<Float>] {
        (0 ..< size * size).map { f($0 % size, $0 / size) }
    }

    // MARK: - Track surfaces

    /// Old asphalt with square patch repairs and tar snakes over the cracks.
    /// The patches are fresh bitumen: darker, smoother, and a millimetre
    /// proud; the tar snakes are glossy black lines a few centimetres wide.
    static func asphaltPatched(size: Int, seed: UInt32) -> GeneratedMaterial {
        let base = asphalt(size: size, seed: seed, wear: 0.35)
        // Recover the base height from its normal is not possible; rebuild the
        // aggregate field the same way instead.
        let aggregate = cellField(size: size, cells: 160, seed: seed)
        let cracks = fractalField(size: size, cells: 6, octaves: 4, seed: seed &+ 11)
        // Patches are cut square: a coarse grid of cells, some of which hold a
        // jittered rectangle. Wrapped indices keep the tile seamless.
        let grid = 4
        var patch = ScalarField(size: size) { x, y in
            let u = Float(x) / Float(size) * Float(grid), v = Float(y) / Float(size) * Float(grid)
            let cx = Int(u.rounded(.down)) % grid, cy = Int(v.rounded(.down)) % grid
            guard Noise.random(cx, cy, seed &+ 7) > 0.6 else { return 0 }
            let fu = u - u.rounded(.down), fv = v - v.rounded(.down)
            let x0 = 0.1 + Noise.random(cx, cy, seed &+ 8) * 0.25, x1 = 0.9 - Noise.random(cx, cy, seed &+ 9) * 0.25
            let y0 = 0.1 + Noise.random(cx, cy, seed &+ 10) * 0.25, y1 = 0.9 - Noise.random(cx, cy, seed &+ 12) * 0.25
            return fu > x0 && fu < x1 && fv > y0 && fv < y1 ? 1 : 0
        }
        // Soften the patch edge over a few texels so the normal shows a lip.
        patch = MaterialSynthesis.blurredField(patch, radius: 3)
        let snake = ScalarField(size: size) { x, y in
            let c = abs(cracks[x, y] - 0.5)
            return max(0, 1 - c / 0.012)
        }
        var height = ScalarField(size: size) { x, y in
            aggregate[x, y] * 0.7 * (1 - patch[x, y] * 0.6) + patch[x, y] * 0.25 + snake[x, y] * 0.08
        }
        height.normalise()
        let roughness = ScalarField(size: size) { x, y in
            let r = 0.9 - aggregate[x, y] * 0.15
            let patched = r * (1 - patch[x, y]) + 0.62 * patch[x, y]
            return patched * (1 - snake[x, y]) + 0.35 * snake[x, y]
        }
        let albedo = colours(size) { x, y in
            let i = (y * size + x) * 4
            var c = SIMD3(Float(base.albedo[i]), Float(base.albedo[i + 1]), Float(base.albedo[i + 2])) / 255
            // The base albedo bytes are sRGB; work approximately in linear.
            c = c * c
            let fresh = SIMD3<Float>(0.018, 0.018, 0.02)
            c = c * (1 - patch[x, y]) + fresh * patch[x, y]
            return c * (1 - snake[x, y]) + SIMD3<Float>(0.012, 0.012, 0.013) * snake[x, y]
        }
        return pack("asphalt-patched", size: size, height: height, occlusionRadius: 4, occlusionStrength: 1.5,
                    normalStrength: Float(size) / 140, roughness: roughness, albedo: albedo, worldSize: 3)
    }

    /// Wet earth: dirt with the fine structure smoothed under a water film,
    /// darker, and pitted where hooves and tyres have been.
    static func mud(size: Int, seed: UInt32) -> GeneratedMaterial {
        let coarse = fractalField(size: size, cells: 12, octaves: 4, seed: seed)
        let pits = cellField(size: size, cells: 18, seed: seed &+ 3)
        var height = ScalarField(size: size) { x, y in coarse[x, y] * 0.7 + (1 - pow(pits[x, y], 3)) * 0.3 }
        height.normalise()
        let roughness = ScalarField(size: size) { x, y in 0.45 + (1 - height[x, y]) * 0.25 }
        let albedo = colours(size) { x, y in
            let h = height[x, y]
            let wet = SIMD3<Float>(0.035, 0.026, 0.018), drier = SIMD3<Float>(0.085, 0.062, 0.040)
            return wet + (drier - wet) * h
        }
        return pack("mud", size: size, height: height, occlusionRadius: 6, occlusionStrength: 2.0,
                    normalStrength: Float(size) / 80, roughness: roughness, albedo: albedo, worldSize: 2.5)
    }

    /// Dry sand: fine grain under wind ripples, pale and rough.
    static func sand(size: Int, seed: UInt32) -> GeneratedMaterial {
        let grain = fractalField(size: size, cells: 200, octaves: 2, seed: seed)
        let drift = fractalField(size: size, cells: 3, octaves: 3, seed: seed &+ 5)
        var height = ScalarField(size: size) { x, y in
            // Ripples: a sine across the tile, its phase wandering with the drift.
            let ripple = 0.5 + 0.5 * sin((Float(y) / Float(size) * 14 + drift[x, y] * 0.8) * 2 * .pi)
            return grain[x, y] * 0.3 + ripple * 0.4 + drift[x, y] * 0.3
        }
        height.normalise()
        let roughness = ScalarField(size: size) { x, y in 0.93 + grain[x, y] * 0.05 }
        let albedo = colours(size) { x, y in
            let shade = 0.85 + height[x, y] * 0.3
            return SIMD3<Float>(0.33, 0.27, 0.17) * shade
        }
        return pack("sand", size: size, height: height, occlusionRadius: 5, occlusionStrength: 1.4,
                    normalStrength: Float(size) / 160, roughness: roughness, albedo: albedo, worldSize: 2)
    }

    // MARK: - Trackside

    /// Galvanised steel guardrail: the W-profile's two corrugations run along
    /// the tile, with a bolt every quarter and the mottled spangle of zinc.
    static func armco(size: Int, seed: UInt32) -> GeneratedMaterial {
        let spangle = cellField(size: size, cells: 28, seed: seed)
        let grime = fractalField(size: size, cells: 4, octaves: 3, seed: seed &+ 9)
        func profile(_ v: Float) -> Float {
            // Two rounded ridges with a valley between: 0 at the flanges.
            let a = sin(v * 2 * .pi), b = sin(v * 4 * .pi)
            return max(0, a) * 0.6 + max(0, b) * 0.4
        }
        func bolt(_ x: Int, _ y: Int) -> Float {
            let bx = (Float(x) / Float(size) * 4).truncatingRemainder(dividingBy: 1) - 0.5
            let by = (Float(y) / Float(size)).truncatingRemainder(dividingBy: 1) - 0.5
            let r = (bx * bx * 16 + by * by * 16).squareRoot()
            return r < 0.35 ? 1 - r / 0.35 : 0
        }
        var height = ScalarField(size: size) { x, y in
            profile(Float(y) / Float(size)) * 0.85 + spangle[x, y] * 0.03 + bolt(x, y) * 0.12
        }
        height.normalise()
        let roughness = ScalarField(size: size) { x, y in 0.42 + grime[x, y] * 0.25 + spangle[x, y] * 0.08 }
        let albedo = colours(size) { x, y in
            let zinc = SIMD3<Float>(0.52, 0.53, 0.55) * (0.85 + spangle[x, y] * 0.3)
            let dirt = SIMD3<Float>(0.25, 0.22, 0.18)
            return zinc + (dirt - zinc) * grime[x, y] * 0.45
        }
        return pack("armco", size: size, height: height, occlusionRadius: 6, occlusionStrength: 1.2,
                    normalStrength: Float(size) / 40, roughness: roughness, albedo: albedo, worldSize: 2, metal: true)
    }

    /// A wall of stacked tyres, two across and two rows per tile, alternate
    /// rows painted white, each tyre a torus in relief.
    static func tyreWall(size: Int, seed: UInt32) -> GeneratedMaterial {
        let n = 2
        let tread = fractalField(size: size, cells: 90, octaves: 2, seed: seed)
        func torus(_ x: Int, _ y: Int) -> (height: Float, inside: Bool, row: Int) {
            let u = Float(x) / Float(size) * Float(n), v = Float(y) / Float(size) * Float(n)
            let row = Int(v)
            // Stagger alternate rows by half a tyre.
            let su = u + (row % 2 == 0 ? 0 : 0.5)
            let cx = su - (su.rounded(.down) + 0.5), cy = v - (v.rounded(.down) + 0.5)
            let r = (cx * cx + cy * cy).squareRoot() * 2  // 1 at the tyre's outer edge
            if r > 1 { return (0, false, row) }
            let ring = 1 - abs(r - 0.7) / 0.3           // torus cross-section peak at 0.7
            return (max(0, ring), r < 0.4, row)
        }
        var height = ScalarField(size: size) { x, y in
            let t = torus(x, y)
            return t.height * 0.9 + tread[x, y] * 0.06 * (t.height > 0 ? 1 : 0)
        }
        height.normalise()
        let roughness = ScalarField(size: size) { x, y in
            let t = torus(x, y)
            return t.height > 0 ? (t.row % 2 == 0 ? 0.72 : 0.6) : 0.9
        }
        let albedo = colours(size) { x, y in
            let t = torus(x, y)
            if t.height <= 0 { return SIMD3<Float>(0.02, 0.02, 0.02) }
            let rubber = SIMD3<Float>(0.03, 0.03, 0.032) * (0.8 + tread[x, y] * 0.4)
            let paint = SIMD3<Float>(0.7, 0.7, 0.68) * (0.7 + tread[x, y] * 0.3)
            let painted = t.row % 2 == 1 && t.height > 0.25
            return painted ? paint : rubber
        }
        return pack("tyre-wall", size: size, height: height, occlusionRadius: 8, occlusionStrength: 2.2,
                    normalStrength: Float(size) / 30, roughness: roughness, albedo: albedo, worldSize: 1.3)
    }

    /// Chain-link fence: a diamond mesh of galvanised wire with the gaps in
    /// alpha. A cutout, so the flat normal is right — the wire is thinner
    /// than a texel at any distance that matters.
    static func chainLink(size: Int, seed: UInt32) -> GeneratedMaterial {
        let cells = 8
        let wireHalf: Float = 0.055
        func wire(_ x: Int, _ y: Int) -> Float {
            let u = Float(x) / Float(size) * Float(cells), v = Float(y) / Float(size) * Float(cells)
            let a = abs(((u + v).truncatingRemainder(dividingBy: 1)) - 0.5) - (0.5 - wireHalf)
            let b = abs(((u - v + 8).truncatingRemainder(dividingBy: 1)) - 0.5) - (0.5 - wireHalf)
            return max(0, max(a, b)) / wireHalf
        }
        let alpha = (0 ..< size * size).map { i -> Float in min(wire(i % size, i / size) * 1.5, 1) }
        let albedo = colours(size) { x, y in SIMD3<Float>(0.55, 0.56, 0.58) * (0.85 + Noise.random(x, y, seed) * 0.3) }
        let flat = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: size * size)
        return GeneratedMaterial(name: "chain-link", size: size,
                                 albedo: MaterialPacking.albedo(albedo, alpha: alpha),
                                 normal: MaterialPacking.normal(flat),
                                 orm: MaterialPacking.orm(occlusion: ScalarField(size: size, repeating: 1),
                                                          roughness: ScalarField(size: size, repeating: 0.45), metalness: 1),
                                 worldSize: 1, isMetal: true)
    }

    /// Stretcher-bond brick: rows offset by half a brick, mortar recessed,
    /// each brick its own shade of fired clay.
    static func brick(size: Int, seed: UInt32) -> GeneratedMaterial {
        let across = 4, rows = 8
        let mortarX: Float = 0.06, mortarY: Float = 0.12
        let grain = fractalField(size: size, cells: 60, octaves: 3, seed: seed)
        func cell(_ x: Int, _ y: Int) -> (brick: Bool, id: Int, edge: Float) {
            let v = Float(y) / Float(size) * Float(rows)
            let row = Int(v)
            let u = Float(x) / Float(size) * Float(across) + (row % 2 == 0 ? 0 : 0.5)
            let fu = u - u.rounded(.down), fv = v - v.rounded(.down)
            let inBrick = fu > mortarX && fv > mortarY
            let edge = min(min(fu - mortarX, 1 - fu), min(fv - mortarY, 1 - fv))
            // Wrapped, so the brick straddling the tile edge is one brick.
            let id = (Int(u.rounded(.down)) % across) + (row % rows) * 97
            return (inBrick, id, edge)
        }
        var height = ScalarField(size: size) { x, y in
            let c = cell(x, y)
            return c.brick ? 0.7 + min(c.edge * 6, 1) * 0.2 + grain[x, y] * 0.1 : grain[x, y] * 0.15
        }
        height.normalise()
        let roughness = ScalarField(size: size) { x, y in cell(x, y).brick ? 0.78 + grain[x, y] * 0.1 : 0.92 }
        let albedo = colours(size) { x, y in
            let c = cell(x, y)
            if !c.brick { return SIMD3<Float>(0.32, 0.30, 0.27) * (0.85 + grain[x, y] * 0.3) }
            let t = Noise.random(c.id, 0, seed &+ 5)
            let red = SIMD3<Float>(0.30, 0.12, 0.08), dark = SIMD3<Float>(0.16, 0.08, 0.06), pale = SIMD3<Float>(0.36, 0.20, 0.12)
            let base = t < 0.5 ? red + (dark - red) * (0.5 - t) * 2 : red + (pale - red) * (t - 0.5) * 2
            return base * (0.85 + grain[x, y] * 0.3)
        }
        return pack("brick", size: size, height: height, occlusionRadius: 5, occlusionStrength: 1.6,
                    normalStrength: Float(size) / 60, roughness: roughness, albedo: albedo, worldSize: 1)
    }

    /// Sawn planks with a stretched grain, a gap between them, and a slightly
    /// different tone per plank.
    static func wood(size: Int, seed: UInt32) -> GeneratedMaterial {
        let planks = 4
        let gap: Float = 0.03
        let grain = ScalarField(size: size) { x, y in
            Noise.fractal(Float(x) / Float(size) * 6, Float(y) / Float(size) * 160, period: 160, octaves: 3, gain: 0.5, seed: seed)
        }
        let rings = ScalarField(size: size) { x, y in
            let g = Noise.fractal(Float(x) / Float(size) * 3, Float(y) / Float(size) * 40, period: 40, octaves: 2, seed: seed &+ 3)
            return 0.5 + 0.5 * sin(g * 30 + Float(x) / Float(size) * 20)
        }
        func plank(_ x: Int) -> (id: Int, edge: Float) {
            let u = Float(x) / Float(size) * Float(planks)
            let f = u - u.rounded(.down)
            return (Int(u.rounded(.down)) % planks, f < gap ? 0 : min((f - gap) * 20, 1))
        }
        var height = ScalarField(size: size) { x, y in
            let p = plank(x)
            return p.edge * 0.8 + grain[x, y] * 0.1 + rings[x, y] * 0.1
        }
        height.normalise()
        let roughness = ScalarField(size: size) { x, y in 0.65 + rings[x, y] * 0.15 }
        let albedo = colours(size) { x, y in
            let p = plank(x)
            if p.edge <= 0 { return SIMD3<Float>(0.04, 0.03, 0.02) }
            let t = Noise.random(p.id, 1, seed &+ 7)
            let light = SIMD3<Float>(0.42, 0.28, 0.15), dark = SIMD3<Float>(0.26, 0.16, 0.08)
            let base = dark + (light - dark) * t
            return base * (0.8 + rings[x, y] * 0.25 + grain[x, y] * 0.1)
        }
        return pack("wood", size: size, height: height, occlusionRadius: 4, occlusionStrength: 1.4,
                    normalStrength: Float(size) / 120, roughness: roughness, albedo: albedo, worldSize: 1.2)
    }

    /// Painted steel: an orange-peel skin, a few scuffs, white.
    static func paintedSteel(size: Int, seed: UInt32) -> GeneratedMaterial {
        let peel = fractalField(size: size, cells: 120, octaves: 2, seed: seed)
        let scuff = fractalField(size: size, cells: 5, octaves: 4, seed: seed &+ 3)
        var height = ScalarField(size: size) { x, y in peel[x, y] }
        height.normalise()
        let roughness = ScalarField(size: size) { x, y in 0.32 + max(0, scuff[x, y] - 0.65) * 1.2 }
        let albedo = colours(size) { x, y in
            let paint = SIMD3<Float>(0.75, 0.75, 0.72)
            let bare = SIMD3<Float>(0.3, 0.3, 0.32)
            return paint + (bare - paint) * max(0, scuff[x, y] - 0.72) * 3
        }
        return pack("painted-steel", size: size, height: height, occlusionRadius: 2, occlusionStrength: 0.6,
                    normalStrength: Float(size) / 900, roughness: roughness, albedo: albedo, worldSize: 1)
    }

    // MARK: - Car detail sets

    /// Tyre tread: longitudinal grooves with sipes across the blocks. A
    /// detail set — black, and tiled across the wheel's own UVs.
    static func rubberTread(size: Int, seed: UInt32) -> GeneratedMaterial {
        let grooves = 4, sipes = 12
        let grain = fractalField(size: size, cells: 100, octaves: 2, seed: seed)
        func pattern(_ x: Int, _ y: Int) -> Float {
            let u = Float(x) / Float(size) * Float(grooves)
            let v = Float(y) / Float(size) * Float(sipes)
            let fu = u - u.rounded(.down), fv = v - v.rounded(.down)
            let groove = fu < 0.22 ? 0 : 1
            let sipe: Float = fv < 0.12 ? 0.35 : 1
            return Float(groove) * sipe
        }
        var height = ScalarField(size: size) { x, y in pattern(x, y) * 0.9 + grain[x, y] * 0.1 }
        height.normalise()
        let roughness = ScalarField(size: size) { x, y in pattern(x, y) > 0.5 ? 0.62 + grain[x, y] * 0.1 : 0.85 }
        let albedo = colours(size) { x, y in SIMD3<Float>(0.03, 0.03, 0.031) * (0.8 + grain[x, y] * 0.4) }
        return pack("rubber-tread", size: size, height: height, occlusionRadius: 5, occlusionStrength: 1.8,
                    normalStrength: Float(size) / 50, roughness: roughness, albedo: albedo, worldSize: 0.25)
    }

    /// Twill-weave carbon fibre: bundles alternate direction in a 2×2 twill,
    /// and the sheen comes from the roughness varying with bundle direction.
    static func carbonWeave(size: Int, seed: UInt32) -> GeneratedMaterial {
        let bundles = 16
        func weave(_ x: Int, _ y: Int) -> (over: Bool, along: Float) {
            let u = Float(x) / Float(size) * Float(bundles), v = Float(y) / Float(size) * Float(bundles)
            let iu = Int(u.rounded(.down)), iv = Int(v.rounded(.down))
            let over = ((iu + iv) / 2) % 2 == 0   // 2x2 twill diagonal
            let f = over ? v - v.rounded(.down) : u - u.rounded(.down)
            return (over, f)
        }
        let fibre = fractalField(size: size, cells: 180, octaves: 2, seed: seed)
        var height = ScalarField(size: size) { x, y in
            let w = weave(x, y)
            return sin(w.along * .pi) * 0.8 + fibre[x, y] * 0.2
        }
        height.normalise()
        let roughness = ScalarField(size: size) { x, y in
            let w = weave(x, y)
            return (w.over ? 0.3 : 0.4) + fibre[x, y] * 0.08
        }
        let albedo = colours(size) { x, y in
            let w = weave(x, y)
            let shade = 0.6 + sin(w.along * .pi) * 0.6 + fibre[x, y] * 0.2
            return SIMD3<Float>(0.03, 0.031, 0.034) * shade
        }
        return pack("carbon-weave", size: size, height: height, occlusionRadius: 3, occlusionStrength: 0.9,
                    normalStrength: Float(size) / 300, roughness: roughness, albedo: albedo, worldSize: 0.1)
    }

    /// Brushed aluminium: fine parallel scratches, metal.
    static func brushedMetal(size: Int, seed: UInt32) -> GeneratedMaterial {
        let streaks = ScalarField(size: size) { x, y in
            Noise.fractal(Float(x) / Float(size) * 8, Float(y) / Float(size) * 400, period: 400, octaves: 2, gain: 0.5, seed: seed)
        }
        var height = streaks
        height.normalise()
        let roughness = ScalarField(size: size) { x, y in 0.3 + height[x, y] * 0.15 }
        let albedo = colours(size) { x, y in SIMD3<Float>(0.62, 0.63, 0.65) * (0.9 + height[x, y] * 0.2) }
        return pack("brushed-metal", size: size, height: height, occlusionRadius: 2, occlusionStrength: 0.5,
                    normalStrength: Float(size) / 1200, roughness: roughness, albedo: albedo, worldSize: 0.5, metal: true)
    }

    /// Chrome: flat, mirror-smooth, metal. Exists so a trim part can ask
    /// for it by name; the maps carry almost nothing.
    static func chrome(size: Int, seed: UInt32) -> GeneratedMaterial {
        let haze = fractalField(size: size, cells: 6, octaves: 2, seed: seed)
        let roughness = ScalarField(size: size) { x, y in 0.06 + haze[x, y] * 0.04 }
        let albedo = colours(size) { _, _ in SIMD3<Float>(0.9, 0.9, 0.9) }
        return pack("chrome", size: size, height: ScalarField(size: size, repeating: 0.5), occlusionRadius: 1,
                    occlusionStrength: 0, normalStrength: 0, roughness: roughness, albedo: albedo, worldSize: 1,
                    metal: true, flatNormal: true, occlusion: ScalarField(size: size, repeating: 1))
    }

    /// Moulded plastic: a fine leather-like grain, semi-gloss, dark.
    static func plastic(size: Int, seed: UInt32) -> GeneratedMaterial {
        let grain = cellField(size: size, cells: 140, seed: seed)
        var height = ScalarField(size: size) { x, y in pow(grain[x, y], 1.5) }
        height.normalise()
        let roughness = ScalarField(size: size) { x, y in 0.5 + height[x, y] * 0.1 }
        let albedo = colours(size) { x, y in SIMD3<Float>(0.045, 0.045, 0.047) * (0.9 + height[x, y] * 0.2) }
        return pack("plastic", size: size, height: height, occlusionRadius: 2, occlusionStrength: 0.8,
                    normalStrength: Float(size) / 500, roughness: roughness, albedo: albedo, worldSize: 0.3)
    }

    /// Woven fabric: warp and weft as a fine cross-hatch, rough, charcoal.
    static func fabric(size: Int, seed: UInt32) -> GeneratedMaterial {
        let threads = 96
        let fuzz = fractalField(size: size, cells: 150, octaves: 2, seed: seed)
        var height = ScalarField(size: size) { x, y in
            let u = Float(x) / Float(size) * Float(threads), v = Float(y) / Float(size) * Float(threads)
            let warp = 0.5 + 0.5 * sin(u * 2 * .pi), weft = 0.5 + 0.5 * sin(v * 2 * .pi)
            let over = (Int(u.rounded(.down)) + Int(v.rounded(.down))) % 2 == 0
            return (over ? warp : weft) * 0.8 + fuzz[x, y] * 0.2
        }
        height.normalise()
        let roughness = ScalarField(size: size) { x, y in 0.92 + fuzz[x, y] * 0.06 }
        let albedo = colours(size) { x, y in SIMD3<Float>(0.06, 0.06, 0.065) * (0.85 + height[x, y] * 0.3) }
        return pack("fabric", size: size, height: height, occlusionRadius: 2, occlusionStrength: 1.2,
                    normalStrength: Float(size) / 250, roughness: roughness, albedo: albedo, worldSize: 0.2)
    }

    /// Metallic paint flake: a detail set of sparse micro-facets in the
    /// normal and a speckled roughness, neutral in colour so the atlas
    /// supplies the paint. Metal, so the atlas's metallic setting stands.
    static func paintFlake(size: Int, seed: UInt32) -> GeneratedMaterial {
        let flakes = ScalarField(size: size) { x, y in
            let r = Noise.random(x, y, seed)
            return r > 0.965 ? (r - 0.965) / 0.035 : 0
        }
        let roughness = ScalarField(size: size) { x, y in Float(0.9) + flakes[x, y] * 0.1 - Noise.random(x, y, seed &+ 1) * 0.06 }
        let albedo = colours(size) { _, _ in SIMD3<Float>(1, 1, 1) }
        return pack("paint-flake", size: size, height: flakes, occlusionRadius: 1, occlusionStrength: 0,
                    normalStrength: Float(size) / 400, roughness: roughness, albedo: albedo, worldSize: 0.05,
                    metal: true, occlusion: ScalarField(size: size, repeating: 1))
    }

    /// Glass: flat and smooth. The renderer's glass part supplies the rest.
    static func glass(size: Int, seed: UInt32) -> GeneratedMaterial {
        let smear = fractalField(size: size, cells: 4, octaves: 2, seed: seed)
        let roughness = ScalarField(size: size) { x, y in 0.05 + smear[x, y] * 0.05 }
        let albedo = colours(size) { _, _ in SIMD3<Float>(1, 1, 1) }
        return pack("glass", size: size, height: ScalarField(size: size, repeating: 0.5), occlusionRadius: 1,
                    occlusionStrength: 0, normalStrength: 0, roughness: roughness, albedo: albedo, worldSize: 1,
                    flatNormal: true, occlusion: ScalarField(size: size, repeating: 1))
    }
}
