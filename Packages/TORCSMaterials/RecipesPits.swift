// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd

/// A pit building: what its garages are closed with, what they are built
/// of, the band over their doors and the numbers on it, and its roof.
extension MaterialRecipes {
    // MARK: - Roller door

    /// A roller shutter: steel laths ten to the metre, each bowed outward
    /// and hooked into the next, painted light grey; the dirt the rain
    /// brings down it in streaks, and more of it low down where hands and
    /// trolleys reach. A metre to the tile, so the laths count up a door
    /// from the floor.
    static func rollerDoor(size: Int, seed: UInt32) -> GeneratedMaterial {
        let laths = 10
        let grain = fractalField(size: size, cells: 72, octaves: 2, seed: seed &+ 3)
        let grime = fractalField(size: size, cells: 5, octaves: 3, seed: seed &+ 5)
        /// Dirt run down the door: the same from top to bottom of a tile.
        func streak(_ x: Int) -> Float {
            Noise.fractal(Float(x) / Float(size) * 36, 0.5, period: 36, octaves: 3, seed: seed &+ 7)
        }
        /// Where up its own lath a texel is, from its lower edge.
        func lath(_ y: Int) -> Float {
            let up = 1 - Float(y) / Float(size)
            return (up * Float(laths)).truncatingRemainder(dividingBy: 1)
        }
        /// 1 in the joint where one lath hooks into the next.
        func joint(_ y: Int) -> Float { 1 - smoothstep(0.05, 0.10, min(lath(y), 1 - lath(y)) * 2) }
        /// A dent or two, where something has leant on the door.
        func dent(_ x: Int, _ y: Int) -> Float { smoothstep(0.80, 0.95, grime[(x + size / 3) % size, y]) }
        var height = ScalarField(size: size) { x, y in
            let p = lath(y)
            let bow: Float = pow(max(sin(p * .pi), 0), 0.6)
            return 0.25 + bow * 0.60 - joint(y) * 0.20 - dent(x, y) * 0.10 + grain[x, y] * 0.02
        }
        height.normalise()
        let roughness = ScalarField(size: size) { x, y in
            0.40 + joint(y) * 0.30 + smoothstep(0.45, 0.80, streak(x)) * 0.16 + grime[x, y] * 0.10
        }
        let albedo = colours(size) { x, y in
            var c = SIMD3<Float>(0.50, 0.52, 0.54) * (0.94 + grain[x, y] * 0.12)
            let dirt = SIMD3<Float>(0.16, 0.15, 0.13)
            c = c + (dirt - c) * smoothstep(0.50, 0.85, streak(x)) * 0.30
            c = c + (dirt - c) * smoothstep(0.55, 0.90, grime[x, y]) * 0.18
            // The joint is in its own shadow, and holds what runs down.
            return c * (1 - joint(y) * 0.50)
        }
        return pack("roller-door", size: size, height: height, occlusionRadius: max(size / 256, 2), occlusionStrength: 1.0,
                    normalStrength: Float(size) / 70, roughness: roughness, albedo: albedo, worldSize: 1)
    }

    // MARK: - Blockwork

    /// Concrete blocks, forty centimetres by twenty, laid in running bond
    /// and painted off-white: what a pit building is built of. The paint
    /// follows the block's open face and the raked joints, greys with the
    /// years, and is scuffed dark along the courses a trolley reaches.
    static func blockwork(size: Int, seed: UInt32) -> GeneratedMaterial {
        let acrossCount = 5, courses = 10
        let jointX: Float = 0.025, jointY: Float = 0.05
        let grain = fractalField(size: size, cells: 120, octaves: 3, seed: seed &+ 3)
        let pores = fractalField(size: size, cells: 64, octaves: 2, seed: seed &+ 5)
        let weather = fractalField(size: size, cells: 6, octaves: 3, seed: seed &+ 7)
        func place(_ x: Int, _ y: Int) -> (inside: Float, id: UInt32) {
            let v = Float(y) / Float(size) * Float(courses)
            let course = Int(v)
            let u = Float(x) / Float(size) * Float(acrossCount) + (course % 2 == 0 ? 0 : 0.5)
            let fu = u - floor(u), fv = v - floor(v)
            let column = ((Int(floor(u)) % acrossCount) + acrossCount) % acrossCount
            // How far inside the block's edge, in courses; negative in the joint.
            let du: Float = min(fu - jointX * 0.5, 1 - jointX * 0.5 - fu) * 2
            let dv: Float = min(fv - jointY * 0.5, 1 - jointY * 0.5 - fv)
            return (min(du, dv), Noise.hash(column, course, seed &+ 11))
        }
        var height = ScalarField(size: size) { x, y in
            let p = place(x, y)
            let block: Float = smoothstep(0.0, 0.05, p.inside)
            let proud: Float = (fraction(p.id, shift: 16) - 0.5) * 0.05
            let face: Float = 0.70 + proud + grain[x, y] * 0.05 - smoothstep(0.66, 0.86, pores[x, y]) * 0.10
            return 0.46 + (face - 0.46) * block
        }
        height.normalise()
        let roughness = ScalarField(size: size) { x, y in
            let block: Float = smoothstep(0.0, 0.05, place(x, y).inside)
            return 0.86 - block * 0.12 + smoothstep(0.66, 0.86, pores[x, y]) * 0.10
        }
        let albedo = colours(size) { x, y in
            let p = place(x, y)
            let block: Float = smoothstep(0.0, 0.05, p.inside)
            var c = SIMD3<Float>(0.60, 0.59, 0.55) * (0.95 + fraction(p.id) * 0.08)
            c *= 0.93 + grain[x, y] * 0.10
            // Greyed by the weather in drifts, and darker in the pores and the joints.
            c = c + (SIMD3<Float>(0.36, 0.36, 0.35) - c) * smoothstep(0.45, 0.85, weather[x, y]) * 0.30
            c *= 1 - smoothstep(0.66, 0.86, pores[x, y]) * 0.22
            return c * (0.72 + 0.28 * block)
        }
        return pack("blockwork", size: size, height: height, occlusionRadius: max(size / 256, 2), occlusionStrength: 1.2,
                    normalStrength: Float(size) / 80, roughness: roughness, albedo: albedo, worldSize: 2)
    }

    // MARK: - Fascia

    /// The band over a row of garage doors, a metre high and a metre to the
    /// tile: pressed steel panels painted white, a red stripe along the
    /// foot of them, a dark coping along the top, a joint between panels.
    /// Laid once up the band, so the stripe is at its foot.
    static func pitFascia(size: Int, seed: UInt32) -> GeneratedMaterial {
        let grain = fractalField(size: size, cells: 80, octaves: 2, seed: seed &+ 3)
        let chalk = fractalField(size: size, cells: 7, octaves: 3, seed: seed &+ 5)
        func up(_ y: Int) -> Float { 1 - (Float(y) + 0.5) / Float(size) }
        func joint(_ x: Int) -> Float {
            let u = (Float(x) + 0.5) / Float(size)
            return 1 - smoothstep(0.003, 0.007, min(u, 1 - u))
        }
        func stripe(_ y: Int) -> Float { smoothstep(0.07, 0.08, up(y)) * (1 - smoothstep(0.20, 0.21, up(y))) }
        func coping(_ y: Int) -> Float { smoothstep(0.92, 0.93, up(y)) }
        /// What runs down from under the coping.
        func run(_ x: Int, _ y: Int) -> Float {
            let below = 0.92 - up(y)
            guard below > 0, below < 0.5 else { return 0 }
            let source = Noise.fractal(Float(x) / Float(size) * 28, 0.5, period: 28, octaves: 2, seed: seed &+ 9)
            return smoothstep(0.55, 0.85, source) * (1 - below / 0.5)
        }
        var height = ScalarField(size: size) { x, y in
            0.5 + coping(y) * 0.30 - joint(x) * 0.30 * (1 - coping(y)) + grain[x, y] * 0.015
                - (1 - smoothstep(0.0, 0.03, up(y))) * 0.2
        }
        height.normalise()
        let roughness = ScalarField(size: size) { x, y in
            0.42 + smoothstep(0.4, 0.8, chalk[x, y]) * 0.16 + run(x, y) * 0.18 + coping(y) * 0.10
        }
        let albedo = colours(size) { x, y in
            var c = SIMD3<Float>(0.62, 0.63, 0.64) * (0.95 + grain[x, y] * 0.10)
            c = c + (SIMD3<Float>(0.42, 0.030, 0.035) - c) * stripe(y)
            c = c + (SIMD3<Float>(0.050, 0.055, 0.065) - c) * coping(y)
            c = c + (SIMD3<Float>(0.14, 0.13, 0.11) - c) * run(x, y) * 0.35
            return c * (1 - joint(x) * 0.5 * (1 - coping(y)))
        }
        return pack("pit-fascia", size: size, height: height, occlusionRadius: max(size / 256, 2), occlusionStrength: 0.8,
                    normalStrength: Float(size) / 200, roughness: roughness, albedo: albedo, worldSize: 1)
    }

    // MARK: - Numbers

    /// The figures a garage is numbered with, five dots by seven.
    static let figures: [[String]] = [
        [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
        ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
        [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
        [".###.", "#...#", "....#", "..##.", "....#", "#...#", ".###."],
        ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
        ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
        [".###.", "#....", "#....", "####.", "#...#", "#...#", ".###."],
        ["#####", "....#", "...#.", "..#..", "..#..", "..#..", "..#.."],
        [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
        [".###.", "#...#", "#...#", ".####", "....#", "....#", ".###."],
    ]

    /// How much of a point of a figure is stroke: the dots joined up, so a
    /// stroke is round at its ends and a diagonal is a line. `along` and
    /// `up` are 0 to 1 over the figure's own box.
    public static func figure(_ digit: Int, along: Float, up: Float) -> Float {
        guard (0 ... 9).contains(digit), along >= 0, along <= 1, up >= 0, up <= 1 else { return 0 }
        let rows = figures[digit]
        func dot(_ column: Int, _ row: Int) -> Float {
            guard (0 ..< 5).contains(column), (0 ..< 7).contains(row) else { return 0 }
            return Array(rows[row])[column] == "#" ? 1 : 0
        }
        let fx = along * 5 - 0.5, fy = (1 - up) * 7 - 0.5
        let x0 = Int(floor(fx)), y0 = Int(floor(fy))
        let tx = fx - Float(x0), ty = fy - Float(y0)
        let cover = (dot(x0, y0) * (1 - tx) + dot(x0 + 1, y0) * tx) * (1 - ty)
            + (dot(x0, y0 + 1) * (1 - tx) + dot(x0 + 1, y0 + 1) * tx) * ty
        return smoothstep(0.42, 0.52, cover)
    }

    /// The numbers' sheet is four plates across and three up; where a
    /// figure's plate is on it, as the lower left corner and the size, in
    /// texture coordinates with the foot of the sheet at nought.
    public static func figurePlate(_ digit: Int) -> (origin: SIMD2<Float>, size: SIMD2<Float>) {
        let column = digit % 4, row = digit / 4
        return (SIMD2(Float(column) / 4, 1 - Float(row + 1) / 3), SIMD2(0.25, 1.0 / 3))
    }

    /// Number plates: a white figure on dark blue enamel with a white line
    /// round it, ten of them on one sheet. Not a tile: each garage's plate
    /// shows the part of the sheet its figure is on (`figurePlate`).
    static func pitNumbers(size: Int, seed: UInt32) -> GeneratedMaterial {
        let grain = fractalField(size: size, cells: 64, octaves: 2, seed: seed &+ 3)
        let chalk = fractalField(size: size, cells: 6, octaves: 3, seed: seed &+ 5)
        /// How much of a texel is white, and how far inside its plate's edge it is.
        func mark(_ x: Int, _ y: Int) -> (white: Float, edge: Float) {
            let u = (Float(x) + 0.5) / Float(size) * 4, v = (Float(y) + 0.5) / Float(size) * 3
            let column = Int(u), row = Int(v)
            let pu = u - Float(column), pv = 1 - (v - Float(row))
            let edge = min(min(pu, 1 - pu), min(pv, 1 - pv) * 4 / 3)
            let digit = row * 4 + column
            let line = smoothstep(0.045, 0.055, edge) * (1 - smoothstep(0.075, 0.085, edge))
            // The figure stands in the middle of the plate, five wide to seven high.
            let stroke = digit <= 9 ? figure(digit, along: (pu - 0.195) / 0.61, up: (pv - 0.18) / 0.64) : 0
            return (max(line, stroke), edge)
        }
        var height = ScalarField(size: size) { x, y in
            let m = mark(x, y)
            return 0.5 + m.white * 0.04 - (1 - smoothstep(0.0, 0.02, m.edge)) * 0.25 + grain[x, y] * 0.01
        }
        height.normalise()
        let roughness = ScalarField(size: size) { x, y in 0.30 + smoothstep(0.4, 0.8, chalk[x, y]) * 0.18 + mark(x, y).white * 0.08 }
        let albedo = colours(size) { x, y in
            let m = mark(x, y)
            var c = SIMD3<Float>(0.015, 0.035, 0.110) * (0.92 + grain[x, y] * 0.16)
            c = c + (SIMD3<Float>(0.70, 0.70, 0.68) - c) * m.white
            return c * (0.85 + 0.15 * smoothstep(0.3, 0.7, chalk[x, y]))
        }
        return pack("pit-numbers", size: size, height: height, occlusionRadius: 2, occlusionStrength: 0.5,
                    normalStrength: Float(size) / 300, roughness: roughness, albedo: albedo, worldSize: 1)
    }

    // MARK: - Roofing

    /// A flat roof in mineral felt: dark grey, gritted, laid in strips a
    /// metre wide with a line of tar along each lap, and paler where water
    /// has stood and dried.
    static func roofing(size: Int, seed: UInt32) -> GeneratedMaterial {
        let grit = fractalField(size: size, cells: 160, octaves: 2, seed: seed &+ 3)
        let stain = fractalField(size: size, cells: 5, octaves: 3, seed: seed &+ 5)
        let wobble = fractalField(size: size, cells: 12, octaves: 2, seed: seed &+ 7)
        /// 1 on the tar line along a lap, two laps to the tile.
        func lap(_ x: Int, _ y: Int) -> Float {
            let v = (Float(y) / Float(size) * 2 + (wobble[x, 0] - 0.5) * 0.012).truncatingRemainder(dividingBy: 1)
            return 1 - smoothstep(0.006, 0.014, min(v, 1 - v))
        }
        var height = ScalarField(size: size) { x, y in 0.40 + grit[x, y] * 0.22 + lap(x, y) * 0.30 }
        height.normalise()
        let roughness = ScalarField(size: size) { x, y in 0.92 - lap(x, y) * 0.40 - smoothstep(0.6, 0.9, stain[x, y]) * 0.06 }
        let albedo = colours(size) { x, y in
            var c = SIMD3<Float>(0.060, 0.062, 0.066) * (0.75 + grit[x, y] * 0.50)
            c = c + (SIMD3<Float>(0.17, 0.165, 0.15) - c) * smoothstep(0.55, 0.90, stain[x, y]) * 0.40
            return c + (SIMD3<Float>(0.012, 0.012, 0.013) - c) * lap(x, y) * 0.85
        }
        return pack("roofing", size: size, height: height, occlusionRadius: max(size / 256, 2), occlusionStrength: 0.8,
                    normalStrength: Float(size) / 110, roughness: roughness, albedo: albedo, worldSize: 2)
    }
}
