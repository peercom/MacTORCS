// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd

/// The surface of a building, read off its photograph.
///
/// A building in these circuits is a box with a picture of a building on
/// it: a few hundred texels of somebody's photograph of a block of flats,
/// composed top to bottom, door at the foot and cornice at the top. No tile
/// can replace it. But the picture says where the windows are, and a window
/// is the one part of a wall that is not matt: it is glass, set back in its
/// opening, and it shows the sky. So the picture keeps its colour and gets,
/// from itself, the two maps it never had: a roughness that is low on the
/// glass and high on the wall, and a relief with the glass set back.
///
/// Glass in a photograph is darker than the wall round it, and grey. A
/// shutter, a door or ivy is dark too, but coloured, and stays matt. Glass
/// that is bright with the sky is not found: taking everything blue for
/// glass made a mirror of a blue shed and of every slate roof.
public enum FacadeStructure {
    /// How much of a texel is glass, 0 to 1, for an RGBA8 image.
    public static func glass(rgba: [UInt8], width: Int, height: Int) -> [Float] {
        precondition(rgba.count == width * height * 4)
        let count = width * height
        var value = [Float](repeating: 0, count: count)
        for i in 0 ..< count {
            value[i] = (0.30 * Float(rgba[i * 4]) + 0.59 * Float(rgba[i * 4 + 1]) + 0.11 * Float(rgba[i * 4 + 2])) / 255
        }
        // The wall round a texel: the mean over a sixth of the picture each way.
        let around = blurred(value, width: width, height: height, radius: max(max(width, height) / 6, 2))
        var result = [Float](repeating: 0, count: count)
        for i in 0 ..< count {
            let r = Float(rgba[i * 4]) / 255, g = Float(rgba[i * 4 + 1]) / 255, b = Float(rgba[i * 4 + 2]) / 255
            let high = max(r, max(g, b)), low = min(r, min(g, b))
            let saturation: Float = high > 0.02 ? (high - low) / high : 0
            // Darker than the wall round it by a fifth or more, and near enough grey.
            let darker: Float = (around[i] - value[i]) / max(around[i], 0.08)
            result[i] = step(0.12, 0.30, darker) * (1 - step(0.18, 0.40, saturation))
        }
        // A pane is glass all over or not at all. Texel by texel a blind
        // behind a window is half glass in a speckle, and the wall came out
        // dented; so the answer is taken over a few texels and made up.
        // That also drops what is too thin to be a pane: the line of shadow
        // under a sill, which as glass was a row of glints along every floor.
        let settled = blurred(result, width: width, height: height, radius: max(max(width, height) / 96, 2))
        for i in 0 ..< count { result[i] = step(0.45, 0.70, settled[i]) }
        return result
    }

    /// The normal map (x in red, y in green) and the ORM map (occlusion in
    /// red, roughness in green) of a facade, from its picture.
    ///
    /// - Parameter rgba: bottom row first, as a `TextureImage` holds it; the
    ///   normal's green follows that order as a generated set's does.
    public static func derive(rgba: [UInt8], width: Int, height: Int) -> (normal: [UInt8], orm: [UInt8]) {
        let count = width * height
        let pane = glass(rgba: rgba, width: width, height: height)
        // Relief: the wall proud of the glass, and nothing else. The
        // picture's own light and shade is not relief: taken for it, every
        // blind and every compression block became a dent, and a flat
        // office front was crumpled foil.
        var relief = [Float](repeating: 0, count: count)
        for i in 0 ..< count { relief[i] = 1 - pane[i] }
        relief = blurred(relief, width: width, height: height, radius: 1)
        // Slight: a window's reveal is a hand deep, and the mask's edge is
        // not the window's edge to the texel.
        let strength = Float(max(width, height)) / 420
        var normal = [UInt8](repeating: 255, count: count * 4), orm = [UInt8](repeating: 255, count: count * 4)
        func at(_ x: Int, _ y: Int) -> Float { relief[((y + height) % height) * width + (x + width) % width] }
        for y in 0 ..< height {
            for x in 0 ..< width {
                let i = y * width + x
                let dx = (at(x + 1, y) - at(x - 1, y)) * 0.5, dy = (at(x, y + 1) - at(x, y - 1)) * 0.5
                let n = simd_normalize(SIMD3(-dx * strength, dy * strength, 1))
                normal[i * 4] = UInt8(min(max(((n.x + 1) * 127.5).rounded(), 0), 255))
                normal[i * 4 + 1] = UInt8(min(max(((n.y + 1) * 127.5).rounded(), 0), 255))
                normal[i * 4 + 2] = UInt8(min(max(((n.z + 1) * 127.5).rounded(), 0), 255))
                let roughness: Float = 0.94 + (0.10 - 0.94) * pane[i]
                orm[i * 4] = 255
                orm[i * 4 + 1] = UInt8((roughness * 255).rounded())
                orm[i * 4 + 2] = 0
            }
        }
        return (normal, orm)
    }

    static func step(_ low: Float, _ high: Float, _ value: Float) -> Float {
        let t = min(max((value - low) / (high - low), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// A box blur, wrapping at the edges as the texture does.
    static func blurred(_ field: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        guard radius > 0 else { return field }
        var across = [Float](repeating: 0, count: field.count)
        let span = Float(radius * 2 + 1)
        for y in 0 ..< height {
            var sum: Float = 0
            for k in -radius ... radius { sum += field[y * width + ((k % width) + width) % width] }
            for x in 0 ..< width {
                across[y * width + x] = sum / span
                sum += field[y * width + (x + radius + 1) % width] - field[y * width + ((x - radius) % width + width) % width]
            }
        }
        var result = [Float](repeating: 0, count: field.count)
        for x in 0 ..< width {
            var sum: Float = 0
            for k in -radius ... radius { sum += across[(((k % height) + height) % height) * width + x] }
            for y in 0 ..< height {
                result[y * width + x] = sum / span
                sum += across[((y + radius + 1) % height) * width + x] - across[(((y - radius) % height + height) % height) * width + x]
            }
        }
        return result
    }
}
