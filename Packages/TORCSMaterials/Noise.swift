// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// Deterministic noise primitives for procedural material synthesis.
///
/// Everything here is a pure function of its inputs and an explicit seed, with
/// no floating-point accumulation across calls. That is what lets a generated
/// material set be hash-verified: the same seed must produce the same bytes on
/// any machine, or the asset pipeline cannot check its own output.
public enum Noise {
    /// Integer hash (Wang). Avalanches well enough for texture work and is
    /// exactly reproducible, unlike anything seeded from a system source.
    @inline(__always)
    public static func hash(_ value: UInt32) -> UInt32 {
        var x = value
        x = (x ^ 61) ^ (x >> 16)
        x = x &+ (x << 3)
        x = x ^ (x >> 4)
        x = x &* 0x27d4_eb2d
        x = x ^ (x >> 15)
        return x
    }

    @inline(__always)
    public static func hash(_ x: Int, _ y: Int, _ seed: UInt32) -> UInt32 {
        hash(UInt32(bitPattern: Int32(truncatingIfNeeded: x &* 73_856_093))
             ^ UInt32(bitPattern: Int32(truncatingIfNeeded: y &* 19_349_663))
             ^ seed)
    }

    /// Uniform value in [0, 1).
    @inline(__always)
    public static func random(_ x: Int, _ y: Int, _ seed: UInt32) -> Float {
        Float(hash(x, y, seed) >> 8) / Float(1 << 24)
    }

    /// Smoothstep, used for interpolation so value noise has continuous
    /// derivatives — a linear blend would leave grid creases visible in the
    /// normal map even where the height map looks smooth.
    @inline(__always)
    static func fade(_ t: Float) -> Float { t * t * (3 - 2 * t) }

    /// Tiling value noise. Coordinates wrap at `period`, which is what keeps a
    /// generated texture seamless.
    public static func value(_ x: Float, _ y: Float, period: Int, seed: UInt32) -> Float {
        let period = max(1, period)
        func wrap(_ i: Int) -> Int { ((i % period) + period) % period }
        let x0 = Int(floor(x)), y0 = Int(floor(y))
        let fx = fade(x - Float(x0)), fy = fade(y - Float(y0))
        let a = random(wrap(x0), wrap(y0), seed)
        let b = random(wrap(x0 + 1), wrap(y0), seed)
        let c = random(wrap(x0), wrap(y0 + 1), seed)
        let d = random(wrap(x0 + 1), wrap(y0 + 1), seed)
        return (a + (b - a) * fx) + ((c + (d - c) * fx) - (a + (b - a) * fx)) * fy
    }

    /// Sum of octaves. `lacunarity` 2 and `gain` 0.5 is the usual 1/f spectrum;
    /// surfaces like asphalt want a flatter spectrum, so gain is a parameter.
    public static func fractal(_ x: Float, _ y: Float, period: Int, octaves: Int,
                               gain: Float = 0.5, lacunarity: Float = 2, seed: UInt32) -> Float {
        var total: Float = 0, amplitude: Float = 1, normalisation: Float = 0
        var frequency = 1, scale: Float = 1
        for octave in 0 ..< max(1, octaves) {
            total += value(x * scale, y * scale, period: period * frequency, seed: seed &+ UInt32(octave) &* 7919) * amplitude
            normalisation += amplitude
            amplitude *= gain
            scale *= lacunarity
            frequency = Int(Float(frequency) * lacunarity)
        }
        return normalisation > 0 ? total / normalisation : 0
    }

    /// Tiling Worley (cellular) noise, returning the distance to the nearest
    /// feature point. The basis for aggregate surfaces: asphalt and concrete
    /// are stone particles in a binder, and that is what this describes.
    public static func worley(_ x: Float, _ y: Float, period: Int, seed: UInt32) -> Float {
        let period = max(1, period)
        func wrap(_ i: Int) -> Int { ((i % period) + period) % period }
        let cx = Int(floor(x)), cy = Int(floor(y))
        var nearest = Float.greatestFiniteMagnitude
        for dy in -1 ... 1 {
            for dx in -1 ... 1 {
                let gx = cx + dx, gy = cy + dy
                let h = hash(wrap(gx), wrap(gy), seed)
                // Feature point placed inside its cell by two decorrelated
                // bits of the same hash.
                let px = Float(gx) + Float(h & 0xFFFF) / 65_536
                let py = Float(gy) + Float((h >> 16) & 0xFFFF) / 65_536
                let d = (px - x) * (px - x) + (py - y) * (py - y)
                nearest = min(nearest, d)
            }
        }
        return min(nearest.squareRoot(), 1)
    }
}
