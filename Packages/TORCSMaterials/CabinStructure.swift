// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd

/// What the inside of a car and the man in it are made of, read off the
/// car's own picture.
///
/// A car's cabin and its driver are painted on its atlas with everything
/// else, and were given one surface between them: a cloth weave, tiled
/// over dashboard, steering wheel, roll cage, dials, helmet and overalls
/// alike, all of it matt. But the picture says what each thing is, by its
/// colour, well enough to tell four materials apart:
///
/// - *paint*, anything strongly coloured: a helmet, a painted cage or
///   pillar, a body-colour panel. Smooth and glossy.
/// - *trim*, anything dark: dashboard, wheel rim, harness, rubber. A fine
///   twill, half matt.
/// - *skin*, the tan of a face or a hand. Smooth, a little shine.
/// - *cloth*, the rest, pale grey to white: overalls, seats, lining.
///   Woven, quilted in diamonds, quite matt.
///
/// The map is made finer than the picture, because a weave is finer than
/// anything painted on a 256-texel atlas: four times for one that small.
public enum CabinStructure {
    /// How many texels of the map there are to one of the picture, each way.
    public static func scale(width: Int, height: Int) -> Int {
        let side = max(width, height)
        return side <= 256 ? 4 : (side <= 512 ? 2 : 1)
    }

    /// How much of a texel is paint, trim and skin; cloth is what is left.
    public static func materials(rgba: [UInt8], width: Int, height: Int) -> (paint: [Float], trim: [Float], skin: [Float]) {
        precondition(rgba.count == width * height * 4)
        let count = width * height
        var paint = [Float](repeating: 0, count: count), trim = paint, skin = paint
        for i in 0 ..< count {
            let r = Float(rgba[i * 4]) / 255, g = Float(rgba[i * 4 + 1]) / 255, b = Float(rgba[i * 4 + 2]) / 255
            let high = max(r, max(g, b)), low = min(r, min(g, b))
            let saturation: Float = high > 0.02 ? (high - low) / high : 0
            // Dark, and that is most of a cabin: what is not light is not
            // cloth. With the line drawn near black a grey dashboard was
            // half one thing and half the other, texel by texel, and blotchy.
            let dark = 1 - FacadeStructure.step(0.36, 0.50, high)
            // Skin: red over green over blue, not much of any of it missing.
            let tan: Float = r > g && g > b ? FacadeStructure.step(0.12, 0.22, saturation) * (1 - FacadeStructure.step(0.48, 0.60, saturation))
                * FacadeStructure.step(0.45, 0.60, high) : 0
            let coloured = FacadeStructure.step(0.42, 0.60, saturation) * FacadeStructure.step(0.20, 0.32, high)
            trim[i] = dark
            skin[i] = tan * (1 - dark)
            paint[i] = coloured * (1 - dark) * (1 - skin[i])
        }
        // A texel is not a material: taken over its neighbours, an edge in
        // the picture is an edge in the surface and not a speckle.
        return (FacadeStructure.blurred(paint, width: width, height: height, radius: 1),
                FacadeStructure.blurred(trim, width: width, height: height, radius: 1),
                FacadeStructure.blurred(skin, width: width, height: height, radius: 1))
    }

    /// The normal map (x in red, y in green) and the ORM map (occlusion in
    /// red, roughness in green), `scale` times the picture's size.
    ///
    /// - Parameter rgba: bottom row first, as a `TextureImage` holds it.
    public static func derive(rgba: [UInt8], width: Int, height: Int) -> (normal: [UInt8], orm: [UInt8], width: Int, height: Int) {
        let k = scale(width: width, height: height)
        let w = width * k, h = height * k
        let m = materials(rgba: rgba, width: width, height: height)
        func sample(_ field: [Float], _ x: Int, _ y: Int) -> Float {
            let fx = (Float(x) + 0.5) / Float(k) - 0.5, fy = (Float(y) + 0.5) / Float(k) - 0.5
            let x0 = Int(floor(fx)), y0 = Int(floor(fy))
            let tx = fx - Float(x0), ty = fy - Float(y0)
            func at(_ cx: Int, _ cy: Int) -> Float { field[min(max(cy, 0), height - 1) * width + min(max(cx, 0), width - 1)] }
            return (at(x0, y0) * (1 - tx) + at(x0 + 1, y0) * tx) * (1 - ty) + (at(x0, y0 + 1) * (1 - tx) + at(x0 + 1, y0 + 1) * tx) * ty
        }
        var relief = [Float](repeating: 0.5, count: w * h), rough = [Float](repeating: 0.9, count: w * h)
        for y in 0 ..< h {
            for x in 0 ..< w {
                let paint = sample(m.paint, x, y), trim = sample(m.trim, x, y), skin = sample(m.skin, x, y)
                let cloth = max(1 - paint - trim - skin, 0)
                // Cloth: a plain weave three texels to the thread, each thread
                // over one and under the next, and a seam every forty.
                let cx = x / 3, cy = y / 3
                let along = (Float(x % 3) + 0.5) / 3, up = (Float(y % 3) + 0.5) / 3
                let thread: Float = (cx + cy) % 2 == 0 ? sin(along * .pi) : sin(up * .pi)
                let seam = min(abs(Float((x + y) % 40) - 20), abs(Float((x - y + 40 * 4096) % 40) - 20))
                let woven: Float = 0.42 + 0.20 * thread - 0.22 * max(1 - seam / 1.4, 0)
                // Trim: a fine twill, the weave of carbon and of the vinyl
                // made to look like it, with a little grain in it.
                let grain = Noise.value(Float(x) / 2.1, Float(y) / 2.1, period: 4096, seed: 77)
                let twill: Float = sin((Float(x) + Float(y)) * .pi / 3) * sin((Float(x) - Float(y)) * .pi / 6)
                let moulded: Float = 0.50 + twill * 0.13 + (grain - 0.5) * 0.05
                let i = y * w + x
                relief[i] = cloth * woven + trim * moulded + (paint + skin) * 0.5
                rough[i] = cloth * 0.92 + trim * (0.52 + (grain - 0.5) * 0.10) + paint * 0.20 + skin * 0.55
            }
        }
        var normal = [UInt8](repeating: 255, count: w * h * 4), orm = [UInt8](repeating: 255, count: w * h * 4)
        func at(_ x: Int, _ y: Int) -> Float { relief[min(max(y, 0), h - 1) * w + min(max(x, 0), w - 1)] }
        let strength: Float = 1.3
        for y in 0 ..< h {
            for x in 0 ..< w {
                let i = y * w + x
                let dx = (at(x + 1, y) - at(x - 1, y)) * 0.5, dy = (at(x, y + 1) - at(x, y - 1)) * 0.5
                let n = simd_normalize(SIMD3(-dx * strength, dy * strength, 1))
                normal[i * 4] = UInt8(min(max(((n.x + 1) * 127.5).rounded(), 0), 255))
                normal[i * 4 + 1] = UInt8(min(max(((n.y + 1) * 127.5).rounded(), 0), 255))
                normal[i * 4 + 2] = UInt8(min(max(((n.z + 1) * 127.5).rounded(), 0), 255))
                orm[i * 4] = 255
                orm[i * 4 + 1] = UInt8((min(max(rough[i], 0.05), 1) * 255).rounded())
                orm[i * 4 + 2] = 0
            }
        }
        return (normal, orm, w, h)
    }
}
