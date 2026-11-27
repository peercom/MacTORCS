// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd

/// What years of use leave on a road, as a layer over its asphalt.
///
/// The asphalt set is a tile two metres across and can hold nothing larger
/// than a hand: a tile with a landmark in it shows as a grid. But a road's
/// history is all landmarks. It was laid in strips, a day's work at a time,
/// and the strips and the days meet in joints. It cracked along them and
/// was sealed with tar. It was dug up and patched. Things were spilled on
/// it, and dust and clippings lie along its edges where no tyre clears
/// them.
///
/// So this is a second map, laid along the road and across it rather than
/// tiled: its length is `length` metres of road and its height the road's
/// whole width, edge to edge, whatever that width is. It repeats along the
/// lap, far enough apart that a repeat is a way down the road and not a
/// pattern.
///
/// Four quantities, one a channel: in red the tone of the surface, mid grey
/// for none, darker for fresh or stained asphalt and lighter for old; in
/// green its roughness, the same way; in blue tar, the sealant in a joint
/// or a crack; in alpha the grime along the edges.
public enum RoadWear {
    /// Metres of road one repeat covers.
    public static let length: Float = 96
    /// The width the features are sized for. A narrower road squeezes them a
    /// little and a wider one spreads them.
    static let nominalWidth: Float = 11

    public static func generate(width: Int = 2048, height: Int = 512, seed: UInt32 = 1) -> [UInt8] {
        let along = Float(width) / length, across = Float(height) / nominalWidth   // texels a metre
        var tone = [Float](repeating: 0, count: width * height)
        var rough = [Float](repeating: 0, count: width * height)
        var tar = [Float](repeating: 0, count: width * height)
        var grime = [Float](repeating: 0, count: width * height)
        var scatter = MaterialRecipes.Scatter(seed: seed &+ 977)
        func smoothstep(_ low: Float, _ high: Float, _ value: Float) -> Float {
            MaterialRecipes.smoothstep(low, high, value)
        }
        @inline(__always) func at(_ x: Int, _ y: Int) -> Int? {
            guard y >= 0, y < height else { return nil }
            return y * width + ((x % width) + width) % width
        }
        /// A slow wander along the road, periodic with it, about ±1.
        func wander(_ x: Int, cycles: Int, seed: UInt32) -> Float {
            (Noise.fractal(Float(x) / Float(width) * Float(cycles), 0.5, period: cycles, octaves: 3, seed: seed) - 0.5) * 2
        }

        // The mat went down in three strips, each from its own loads, and in
        // lengths of a day's work. Each piece is its own tone.
        let days: [Float] = [0.0, 0.23, 0.71]
        for y in 0 ..< height {
            for x in 0 ..< width {
                let v = Float(y) / Float(height), u = Float(x) / Float(width)
                let first = 0.335 + wander(x, cycles: 5, seed: seed &+ 3) * 0.012
                let second = 0.665 + wander(x, cycles: 7, seed: seed &+ 5) * 0.012
                let strip = v < first ? 0 : (v < second ? 1 : 2)
                let day = u < days[1] ? 0 : (u < days[2] ? 1 : 2)
                let piece = Float(Noise.hash(strip, day, seed &+ 11) & 0xFF) / 255 - 0.5
                let index = y * width + x
                tone[index] = piece * 0.09
                // And it has weathered unevenly since: blotches a few metres across.
                tone[index] += (Noise.fractal(u * 24, v * 3, period: 24, octaves: 3, seed: seed &+ 17) - 0.5) * 0.10
                rough[index] = piece * 0.05
                // The joints between strips, sealed where they have opened.
                for joint in [first, second] {
                    let distance = abs(v - joint) * nominalWidth      // metres
                    let opened = Noise.fractal(u * 9 + joint * 31, 0.5, period: 9, octaves: 2, seed: seed &+ 23)
                    // Most of a joint is only a line where two tones meet; it
                    // is sealed in the stretches where it has opened.
                    if opened > 0.57 { tar[index] = max(tar[index], (1 - smoothstep(0.008, 0.026, distance)) * 0.8) }
                    else { tone[index] -= (1 - smoothstep(0.0, 0.025, distance)) * 0.045 }
                }
                // The day joints, straight across, sealed over part of their
                // length. One of them is where the map comes round: the
                // last day's work meets the first's there like any other two.
                for start in days {
                    let apart = abs(u - start)
                    let distance = min(apart, 1 - apart) * length     // metres
                    let opened = Noise.fractal(v * 6 + start * 17, 0.5, period: 64, octaves: 2, seed: seed &+ 29)
                    if opened > 0.52 { tar[index] = max(tar[index], (1 - smoothstep(0.03, 0.07, distance)) * 0.8) }
                    else { tone[index] -= (1 - smoothstep(0.0, 0.06, distance)) * 0.04 }
                }
                // Dust, grit and clippings along both edges, where no tyre runs.
                let edge = min(v, 1 - v) * nominalWidth
                let lying = Noise.fractal(u * 40, v * 2 + 3, period: 40, octaves: 3, seed: seed &+ 31)
                grime[index] = (1 - smoothstep(0.05, 0.55 + lying * 0.5, edge)) * (0.45 + 0.55 * lying)
            }
        }

        // Repairs: a rectangle cut out and filled, darker while it is newer
        // than what is round it and paler once it is older, sealed round its edge.
        for _ in 0 ..< 6 {
            let cx = scatter.next() * Float(width), cy = (0.12 + 0.76 * scatter.next()) * Float(height)
            let halfLong = (0.8 + 2.4 * scatter.next()) * along, halfWide = (0.35 + 0.75 * scatter.next()) * across
            let fresh = scatter.next() < 0.65
            let shade: Float = fresh ? -(0.08 + 0.06 * scatter.next()) : 0.05 + 0.04 * scatter.next()
            for dy in Int(-halfWide - 3) ... Int(halfWide + 3) {
                for dx in Int(-halfLong - 3) ... Int(halfLong + 3) {
                    guard let index = at(Int(cx) + dx, Int(cy) + dy) else { continue }
                    // Signed distance to the rectangle, in metres.
                    let qx = (abs(Float(dx)) - halfLong) / along, qy = (abs(Float(dy)) - halfWide) / across
                    let outside = simd_length(SIMD2(max(qx, 0), max(qy, 0))) + min(max(qx, qy), 0)
                    if outside < 0 { tone[index] = shade + (tone[index] - shade) * 0.25; rough[index] = fresh ? 0.10 : -0.04 }
                    let seal = 1 - smoothstep(0.012, 0.04, abs(outside))
                    tar[index] = max(tar[index], seal * (fresh ? 0.9 : 0.55))
                }
            }
        }

        // Cracks running with the road, wandering as they go, most of them
        // sealed. A sealed crack is a band of tar two fingers wide.
        for _ in 0 ..< 7 {
            var y = (0.08 + 0.84 * scatter.next()) * Float(height)
            let start = Int(scatter.next() * Float(width)), run = Int((5 + 22 * scatter.next()) * along)
            let sealed = scatter.next() < 0.7
            let phase = UInt32(scatter.next() * 65_535)
            for step in 0 ..< run {
                let jitter: Float = (Noise.random(start + step, 3, seed &+ phase) - 0.5) * 1.1
                let lean: Float = wander(start + step, cycles: 31, seed: seed &+ phase) * 0.12
                y += jitter + lean
                let fromEnd = Float(min(step, run - step))
                let strength: Float = min(fromEnd / (0.6 * along), 1)
                let half: Float = (sealed ? 0.022 : 0.008) * across
                for dy in Int(-half - 2) ... Int(half + 2) {
                    guard let index = at(start + step, Int(y) + dy) else { continue }
                    let off: Float = abs(Float(dy))
                    let line: Float = (1 - smoothstep(half * 0.5, half + 1, off)) * strength
                    if sealed { tar[index] = max(tar[index], line) } else { tone[index] -= line * 0.16 }
                }
            }
        }
        // And a few short ones across it.
        for _ in 0 ..< 8 {
            var x = scatter.next() * Float(width)
            let start = Int((0.05 + 0.6 * scatter.next()) * Float(height)), run = Int((0.8 + 2.6 * scatter.next()) * across)
            let phase = UInt32(scatter.next() * 65_535)
            for step in 0 ..< run {
                x += (Noise.random(step, start, seed &+ phase) - 0.5) * 0.5
                guard let index = at(Int(x), start + step) else { continue }
                let fromEnd = Float(min(step, run - step))
                tone[index] -= 0.14 * min(fromEnd / 6, 1)
            }
        }

        // What was spilled, and where the cars sit and drip: dark smears
        // drawn out along the road, slightly glossy.
        for _ in 0 ..< 9 {
            let cx = scatter.next() * Float(width), cy = (0.15 + 0.7 * scatter.next()) * Float(height)
            let halfLong = (0.8 + 3.5 * scatter.next()) * along, halfWide = (0.10 + 0.22 * scatter.next()) * across
            let depth = 0.05 + 0.07 * scatter.next()
            for dy in Int(-halfWide * 1.6) ... Int(halfWide * 1.6) {
                for dx in Int(-halfLong * 1.6) ... Int(halfLong * 1.6) {
                    guard let index = at(Int(cx) + dx, Int(cy) + dy) else { continue }
                    let r = simd_length(SIMD2(Float(dx) / halfLong, Float(dy) / halfWide))
                    let ragged = r + (Noise.random(Int(cx) + dx, Int(cy) + dy, seed &+ 41) - 0.5) * 0.25
                    let smear = 1 - smoothstep(0.55, 1.35, ragged)
                    tone[index] -= smear * depth
                    rough[index] -= smear * 0.10
                }
            }
        }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        func byte(_ value: Float) -> UInt8 { UInt8(max(0, min(255, (value * 255).rounded()))) }
        for index in 0 ..< width * height {
            bytes[index * 4] = byte(0.5 + tone[index])
            bytes[index * 4 + 1] = byte(0.5 + rough[index])
            bytes[index * 4 + 2] = byte(tar[index])
            bytes[index * 4 + 3] = byte(grime[index])
        }
        return bytes
    }
}
