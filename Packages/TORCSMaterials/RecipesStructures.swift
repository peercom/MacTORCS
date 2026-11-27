// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd

/// What is built beside a circuit: walls of concrete, stone and brick, and
/// the fences.
///
/// The walls are surfaces and tile; but a wall has an up and a down, which
/// the ground has not, and what marks a wall runs down it. Every set here
/// is drawn with the top of the picture at the top of the wall. The fences
/// are objects, a panel between two posts, and are laid out as one.
extension MaterialRecipes {
    /// One-dimensional noise across the tile, `cycles` to its width: what
    /// varies from one place along a wall to the next and not up it.
    static func across(_ x: Int, size: Int, cycles: Int, seed: UInt32) -> Float {
        Noise.value(Float(x) / Float(size) * Float(cycles), 0.5, period: cycles, seed: seed)
    }

    // MARK: - Concrete wall

    /// A wall cast in place behind plywood forms.
    ///
    /// The slab set is concrete that lies down: pits, crazing, damp. A wall
    /// stands, and everything on it says so. It was poured in panels 2.4 m
    /// wide between forms 1.2 m high, and the joint between two panels is a
    /// groove and the line between two lifts is a fin of grout that got
    /// between the sheets. The forms were held together through the wall by
    /// ties, four to a sheet, and each tie left a hole, and each hole has
    /// wept rust down the wall since. Rain has run down it in the same
    /// places for years and left them dark; lime has come out along the
    /// joints and left them pale.
    static func concreteWall(size: Int, seed: UInt32) -> GeneratedMaterial {
        let fine = fractalField(size: size, cells: 96, octaves: 3, seed: seed &+ 3)
        let mottle = fractalField(size: size, cells: 7, octaves: 3, seed: seed &+ 5)
        let reach = fractalField(size: size, cells: 3, octaves: 2, seed: seed &+ 7)
        let lime = fractalField(size: size, cells: 5, octaves: 3, seed: seed &+ 9)
        // Where the rain runs: fine across the wall, the same all the way down.
        var run = [Float](repeating: 0, count: size)
        for x in 0 ..< size {
            let broad: Float = across(x, size: size, cycles: 17, seed: seed &+ 11) * 0.45
            let middle: Float = across(x, size: size, cycles: 47, seed: seed &+ 13) * 0.35
            let narrow: Float = across(x, size: size, cycles: 127, seed: seed &+ 15) * 0.20
            run[x] = broad + middle + narrow
        }
        let columns = 4, rows = 2
        /// Distance to the nearest tie hole, in tile widths, and how far below it.
        func tie(_ x: Int, _ y: Int) -> (distance: Float, below: Float, aside: Float) {
            let u = Float(x) / Float(size) * Float(columns), v = Float(y) / Float(size) * Float(rows)
            let du = (u - floor(u) - 0.5) / Float(columns), dv = (v - floor(v) - 0.5) / Float(rows)
            return ((du * du + dv * dv).squareRoot(), dv, abs(du))
        }
        func joint(_ x: Int) -> Float {
            let u = Float(x) / Float(size)
            return 1 - smoothstep(0.0, 0.0045, min(u, 1 - u))
        }
        func fin(_ y: Int) -> Float {
            let v = (Float(y) / Float(size) * Float(rows)).truncatingRemainder(dividingBy: 1)
            return 1 - smoothstep(0.0, 0.006, min(v, 1 - v))
        }
        var pit = ScalarField(size: size, repeating: 0)
        for y in 0 ..< size {
            for x in 0 ..< size {
                let c = cells(Float(x) / Float(size) * 70, Float(y) / Float(size) * 70, period: 70, seed: seed &+ 17)
                if c.cell & 0xFF < 22 {
                    let radius: Float = 0.10 + fraction(c.cell, shift: 8) * 0.22
                    pit[x, y] = 1 - smoothstep(radius * 0.5, radius, c.nearest)
                }
            }
        }
        var height = ScalarField(size: size) { x, y in
            let hole: Float = 1 - smoothstep(0.0035, 0.0065, tie(x, y).distance)
            let surface: Float = 0.80 + fine[x, y] * 0.07 + mottle[x, y] * 0.04
            return surface - joint(x) * 0.5 + fin(y) * 0.10 * (1 - joint(x)) - hole * 0.45 - pit[x, y] * 0.16
        }
        height.normalise()
        /// How dark the rain has left this place.
        func stained(_ x: Int, _ y: Int) -> Float {
            smoothstep(0.50, 0.74, run[x]) * (0.25 + 0.75 * smoothstep(0.3, 0.7, reach[x, y]))
        }
        /// Rust below a tie hole: a streak a finger wide and a forearm long.
        func wept(_ x: Int, _ y: Int) -> Float {
            let t = tie(x, y)
            guard t.below > 0, t.below < 0.16 else { return 0 }
            let width: Float = 0.004 + t.below * 0.02
            return (1 - t.below / 0.16) * (1 - smoothstep(width * 0.4, width, t.aside))
        }
        let roughness = ScalarField(size: size) { x, y in
            0.84 + fine[x, y] * 0.08 - stained(x, y) * 0.06
        }
        let albedo = colours(size) { x, y in
            // Each lift came from another day's mix.
            let lift = Int(Float(y) / Float(size) * Float(rows))
            let batch: Float = 0.94 + fraction(Noise.hash(lift, 0, seed &+ 19)) * 0.12
            var c = SIMD3<Float>(0.345, 0.340, 0.325) * batch * (0.90 + mottle[x, y] * 0.14 + fine[x, y] * 0.08)
            // Lime, where water has come through: along the joints and in blooms.
            let near: Float = max(joint(x), fin(y) * 0.6)
            let bloom: Float = min(smoothstep(0.62, 0.86, lime[x, y]) * 0.22 + near * 0.18, 1)
            c = c + (SIMD3<Float>(0.56, 0.56, 0.54) - c) * bloom
            c = c + (SIMD3<Float>(0.135, 0.130, 0.118) - c) * stained(x, y) * 0.42
            c = c + (SIMD3<Float>(0.24, 0.135, 0.065) - c) * wept(x, y) * 0.55
            c *= 1 - pit[x, y] * 0.35
            let hole: Float = 1 - smoothstep(0.0035, 0.0065, tie(x, y).distance)
            return c * (1 - hole * 0.75) * (1 - joint(x) * 0.6)
        }
        return pack("concrete-wall", size: size, height: height, occlusionRadius: max(size / 256, 2), occlusionStrength: 1.3,
                    normalStrength: Float(size) / 110, roughness: roughness, albedo: albedo, worldSize: 2.4)
    }

    // MARK: - Stone wall

    /// A wall of field stone laid in mortar.
    ///
    /// Stones as they came out of the ground, the size of a loaf, each
    /// with a face of its own: its own colour, its own tilt, its own grain.
    /// The mortar sits back from the faces and is the colour of the sand it
    /// was made with. Lichen has found the stones that hold the damp.
    static func stoneWall(size: Int, seed: UInt32) -> GeneratedMaterial {
        let count = 11
        let grain = fractalField(size: size, cells: 80, octaves: 3, seed: seed &+ 3)
        let coarse = fractalField(size: size, cells: 22, octaves: 3, seed: seed &+ 5)
        let damp = fractalField(size: size, cells: 4, octaves: 3, seed: seed &+ 7)
        var face = ScalarField(size: size, repeating: 0)
        var tone = ScalarField(size: size, repeating: 0)
        var kind = ScalarField(size: size, repeating: 0)
        var tilt = ScalarField(size: size, repeating: 0)
        var dome = ScalarField(size: size, repeating: 0)
        for y in 0 ..< size {
            for x in 0 ..< size {
                // The stones' edges are not straight: the lookup wanders with the grain.
                let wobble: Float = (coarse[x, y] - 0.5) * 0.28
                let px: Float = Float(x) / Float(size) * Float(count) + wobble
                let py: Float = Float(y) / Float(size) * Float(count) * 1.0 + (coarse[x + size / 2, y] - 0.5) * 0.28
                let c = cells(px, py, period: count, seed: seed &+ 11)
                face[x, y] = smoothstep(0.05, 0.20, c.second - c.nearest)
                tone[x, y] = fraction(c.cell)
                kind[x, y] = fraction(c.cell, shift: 8)
                let lean = SIMD2<Float>(fraction(c.cell, shift: 16) - 0.5, fraction(c.cell, shift: 24) - 0.5)
                tilt[x, y] = simd_dot(c.offset, lean)
                dome[x, y] = max(0, 1 - c.nearest * 1.1)
            }
        }
        var height = ScalarField(size: size) { x, y in
            let stone: Float = 0.55 + dome[x, y] * 0.22 + tilt[x, y] * 0.30 + coarse[x, y] * 0.10 + grain[x, y] * 0.05
            let mortar: Float = 0.26 + grain[x, y] * 0.07
            return mortar + (stone - mortar) * face[x, y]
        }
        height.normalise()
        let roughness = ScalarField(size: size) { x, y in 0.93 - face[x, y] * 0.07 + grain[x, y] * 0.04 }
        let albedo = colours(size) { x, y in
            let k = kind[x, y]
            // Limestone grey for most, some brown with iron, a few nearly black.
            let grey = SIMD3<Float>(0.335, 0.325, 0.300), brown = SIMD3<Float>(0.300, 0.235, 0.165)
            let ochre = SIMD3<Float>(0.390, 0.330, 0.225), dark = SIMD3<Float>(0.215, 0.205, 0.195)
            var stone: SIMD3<Float> = k < 0.52 ? grey : (k < 0.78 ? brown : (k < 0.94 ? ochre : dark))
            stone *= 0.72 + tone[x, y] * 0.50
            stone *= 0.82 + coarse[x, y] * 0.24 + grain[x, y] * 0.12
            // Lichen: pale grey-green crusts on the stones in the damp.
            let crust: Float = smoothstep(0.58, 0.80, damp[x, y]) * smoothstep(0.55, 0.75, coarse[x + size / 3, y + size / 5])
            stone = stone + (SIMD3<Float>(0.40, 0.43, 0.30) - stone) * crust * 0.6
            let mortar = SIMD3<Float>(0.375, 0.350, 0.300) * (0.80 + grain[x, y] * 0.35)
            let c = mortar + (stone - mortar) * face[x, y]
            // The joints are deep and hold the dark.
            return c * (0.62 + 0.38 * smoothstep(0.0, 0.5, face[x, y]))
        }
        return pack("stone-wall", size: size, height: height, occlusionRadius: max(size / 100, 3), occlusionStrength: 2.2,
                    normalStrength: Float(size) / 34, roughness: roughness, albedo: albedo, worldSize: 2)
    }

    // MARK: - Brickwork

    /// Brickwork in stretcher bond, at a brick's own size.
    ///
    /// The earlier set had four bricks to the metre, each a quarter of a
    /// metre long and an eighth high: blocks, not bricks. A brick is 215 by
    /// 65 mm and its joint 10, so there are eight to the tile's 1.8 m and
    /// twenty-four courses up it. No two were fired alike: most are red,
    /// some orange from the edge of the kiln and a few purple-black from
    /// its middle. Their arrises are chipped, the joints are struck back
    /// from the face, and salts have come out white where the wall stays wet.
    static func brickwork(size: Int, seed: UInt32) -> GeneratedMaterial {
        let acrossCount = 8, courses = 24
        let jointX: Float = 10.0 / 225.0, jointY: Float = 10.0 / 75.0
        let grain = fractalField(size: size, cells: 110, octaves: 3, seed: seed &+ 3)
        let pock = fractalField(size: size, cells: 40, octaves: 2, seed: seed &+ 5)
        let weather = fractalField(size: size, cells: 8, octaves: 3, seed: seed &+ 7)
        let salt = fractalField(size: size, cells: 9, octaves: 3, seed: seed &+ 9)
        func place(_ x: Int, _ y: Int) -> (inside: Float, id: UInt32) {
            let v = Float(y) / Float(size) * Float(courses)
            let course = Int(v)
            let u = Float(x) / Float(size) * Float(acrossCount) + (course % 2 == 0 ? 0 : 0.5)
            let fu = u - floor(u), fv = v - floor(v)
            let column = ((Int(floor(u)) % acrossCount) + acrossCount) % acrossCount
            // How far inside the brick's edge, in courses; negative in the joint.
            let ragged: Float = (grain[x, y] - 0.5) * 0.05
            let du: Float = min(fu - jointX * 0.5, 1 - jointX * 0.5 - fu) * 3
            let dv: Float = min(fv - jointY * 0.5, 1 - jointY * 0.5 - fv)
            return (min(du, dv) + ragged, Noise.hash(column, course, seed &+ 11))
        }
        var height = ScalarField(size: size) { x, y in
            let p = place(x, y)
            let brick: Float = smoothstep(0.0, 0.07, p.inside)
            let proud: Float = (fraction(p.id, shift: 16) - 0.5) * 0.10
            let faceHeight: Float = 0.72 + proud + grain[x, y] * 0.07 - smoothstep(0.62, 0.85, pock[x, y]) * 0.09
            let jointHeight: Float = 0.42 + grain[x, y] * 0.06
            return jointHeight + (faceHeight - jointHeight) * brick
        }
        height.normalise()
        let roughness = ScalarField(size: size) { x, y in
            let brick: Float = smoothstep(0.0, 0.07, place(x, y).inside)
            return 0.94 - brick * 0.10 + grain[x, y] * 0.05
        }
        let albedo = colours(size) { x, y in
            let p = place(x, y)
            let brick: Float = smoothstep(0.0, 0.07, p.inside)
            let k = fraction(p.id), shade = fraction(p.id, shift: 8)
            let red = SIMD3<Float>(0.345, 0.125, 0.082), orange = SIMD3<Float>(0.420, 0.190, 0.105)
            let burnt = SIMD3<Float>(0.170, 0.085, 0.075), pale = SIMD3<Float>(0.400, 0.235, 0.165)
            var clay: SIMD3<Float> = k < 0.58 ? red : (k < 0.78 ? orange : (k < 0.90 ? pale : burnt))
            clay *= 0.80 + shade * 0.36
            clay *= 0.84 + grain[x, y] * 0.22 + pock[x, y] * 0.10
            // Soot and rain darken it in patches; salts whiten the damp ones.
            clay *= 1 - smoothstep(0.55, 0.85, weather[x, y]) * 0.28
            let white: Float = smoothstep(0.66, 0.88, salt[x, y]) * (0.5 + 0.5 * grain[x, y])
            clay = clay + (SIMD3<Float>(0.58, 0.56, 0.52) - clay) * white * 0.24
            let mortar = SIMD3<Float>(0.385, 0.370, 0.335) * (0.78 + grain[x, y] * 0.36)
                * (1 - smoothstep(0.55, 0.85, weather[x, y]) * 0.2)
            let c = mortar + (clay - mortar) * brick
            // The arris throws a line of shade into the joint under it.
            return c * (0.80 + 0.20 * smoothstep(-0.05, 0.05, p.inside))
        }
        return pack("brick", size: size, height: height, occlusionRadius: max(size / 256, 2), occlusionStrength: 1.6,
                    normalStrength: Float(size) / 64, roughness: roughness, albedo: albedo, worldSize: 1.8)
    }

    // MARK: - Fences

    /// One panel of chain-link fence, three metres from post to post.
    ///
    /// The earlier set was eight diamonds to a tile of a metre, wire as
    /// thick as a thumb, drawn as a mirror. Chain link is a 60 mm diamond of
    /// 3 mm wire, woven, hung from a rail between posts and held down by a
    /// wire along its foot. Here the wire is drawn at twice its width so it
    /// survives a texel, the rail runs along the top of the tile, the post
    /// stands at its edge, and the zinc is dull.
    static func chainLinkPanel(size: Int, seed: UInt32) -> GeneratedMaterial {
        let diamonds = 48
        let half: Float = 0.085                     // half the wire's width, in diamonds along the diagonal
        let dirt = fractalField(size: size, cells: 6, octaves: 3, seed: seed &+ 3)
        /// How far inside a wire, 0 at its edge and 1 on its axis, and which way it runs.
        func wire(_ x: Int, _ y: Int) -> (cover: Float, rising: Bool) {
            let u = Float(x) / Float(size) * Float(diamonds), v = Float(y) / Float(size) * Float(diamonds)
            let a: Float = abs((u + v).truncatingRemainder(dividingBy: 1) - 0.5)
            let b: Float = abs((u - v + Float(diamonds)).truncatingRemainder(dividingBy: 1) - 0.5)
            let ca: Float = max(0, 1 - (0.5 - a) / half), cb: Float = max(0, 1 - (0.5 - b) / half)
            return ca >= cb ? (ca, true) : (cb, false)
        }
        /// A tube seen side on: 1 on its axis, 0 at its edge and beyond.
        func tube(_ distance: Float, _ radius: Float) -> Float {
            let r = distance / radius
            return r < 1 ? (1 - r * r).squareRoot() : 0
        }
        func frame(_ x: Int, _ y: Int) -> Float {
            let u = Float(x) / Float(size), v = Float(y) / Float(size)
            let post = tube(min(u, 1 - u), 0.011)                       // 66 mm tube, half each side of the wrap
            let rail = tube(abs(v - 0.014), 0.0085)                     // 50 mm top rail
            let foot = tube(abs(v - 0.988), 0.0028)                     // the tension wire
            return max(post, max(rail, foot))
        }
        var height = ScalarField(size: size) { x, y in
            let w = wire(x, y)
            // Woven: at each crossing one wire goes over the other, by turns.
            let u = Float(x) / Float(size) * Float(diamonds), v = Float(y) / Float(size) * Float(diamonds)
            let crossing = (Int(floor(u + v)) + Int(floor(u - v + Float(diamonds)))) % 2 == 0
            let over: Float = w.rising == crossing ? 0.08 : 0
            let round: Float = (w.cover * (2 - w.cover)).squareRoot() * 0.22 + (w.cover > 0 ? over : 0)
            return max(round, frame(x, y))
        }
        height.normalise()
        var alpha = [Float](repeating: 0, count: size * size)
        for y in 0 ..< size {
            for x in 0 ..< size {
                let solid: Float = max(min(wire(x, y).cover * 3, 1), min(frame(x, y) * 6, 1))
                alpha[y * size + x] = solid
            }
        }
        let roughness = ScalarField(size: size) { x, y in 0.62 + dirt[x, y] * 0.2 }
        let albedo = colours(size) { x, y in
            let spangle: Float = 0.86 + Noise.random(x / 2, y / 2, seed &+ 5) * 0.26
            var c = SIMD3<Float>(0.40, 0.41, 0.42) * spangle
            c = c + (SIMD3<Float>(0.18, 0.16, 0.13) - c) * smoothstep(0.5, 0.9, dirt[x, y]) * 0.4
            // Rust where the mesh is tied to the frame and at the foot of the post.
            let v = Float(y) / Float(size)
            let tied: Float = frame(x, y) > 0 ? smoothstep(0.72, 0.9, dirt[x + size / 2, y]) * 0.5 + smoothstep(0.93, 1.0, v) * 0.5 : 0
            return c + (SIMD3<Float>(0.24, 0.11, 0.045) - c) * min(tied, 1)
        }
        let ao = ScalarField(size: size, repeating: 1)
        let normals = MaterialSynthesis.normals(from: height, strength: Float(size) / 220)
        var clamped = roughness
        clamped.map { min(max($0, 0.18), 1) }
        return GeneratedMaterial(name: "chain-link", size: size,
                                 albedo: MaterialPacking.albedo(albedo, alpha: alpha),
                                 normal: MaterialPacking.normal(normals),
                                 orm: MaterialPacking.orm(occlusion: ao, roughness: clamped, metalness: 0),
                                 worldSize: 3)
    }

    /// A catch fence: chain link above a guard rail, the barrier a circuit
    /// puts between the cars and the people.
    ///
    /// The upper two thirds of the tile are the fence panel as it is, rail
    /// and post and mesh at their own size; the lower third is the three
    /// beams of the guard rail, twice along the panel. Drawn once up the
    /// barrier it stands on.
    static func catchFence(size: Int, seed: UInt32) -> GeneratedMaterial {
        let fence = chainLinkPanel(size: size, seed: seed)
        let rail = tripleArmco(size: size, seed: seed &+ 41)
        let split = size * 2 / 3
        var albedo = fence.albedo, normal = fence.normal, orm = fence.orm
        for y in split ..< size {
            for x in 0 ..< size {
                // Two rail tiles along and one up the third: each texel is
                // two of the rail's along and three up it.
                var a = SIMD4<Float>(repeating: 0), n = SIMD4<Float>(repeating: 0), o = SIMD4<Float>(repeating: 0)
                for sy in 0 ..< 3 {
                    for sx in 0 ..< 2 {
                        let source = (((y - split) * 3 + sy) % size * size + (x * 2 + sx) % size) * 4
                        a += SIMD4(Float(rail.albedo[source]), Float(rail.albedo[source + 1]), Float(rail.albedo[source + 2]), 255)
                        n += SIMD4(Float(rail.normal[source]), Float(rail.normal[source + 1]), Float(rail.normal[source + 2]), 255)
                        o += SIMD4(Float(rail.orm[source]), Float(rail.orm[source + 1]), Float(rail.orm[source + 2]), 255)
                    }
                }
                let target = (y * size + x) * 4
                var unit = SIMD3(n.x, n.y, n.z) / 6 / 127.5 - 1
                unit = simd_normalize(unit)
                for channel in 0 ..< 4 {
                    albedo[target + channel] = UInt8(min(max((a[channel] / 6).rounded(), 0), 255))
                    orm[target + channel] = UInt8(min(max((o[channel] / 6).rounded(), 0), 255))
                }
                normal[target] = UInt8(min(max(((unit.x + 1) * 127.5).rounded(), 0), 255))
                normal[target + 1] = UInt8(min(max(((unit.y + 1) * 127.5).rounded(), 0), 255))
                normal[target + 2] = UInt8(min(max(((unit.z + 1) * 127.5).rounded(), 0), 255))
                normal[target + 3] = 255
            }
        }
        return GeneratedMaterial(name: "catch-fence", size: size, albedo: albedo, normal: normal, orm: orm, worldSize: 3)
    }
}
