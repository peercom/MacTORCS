// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd

/// The form of a tree, read off the card it is painted on.
///
/// Away from Aalborg a tree is a photograph on a flat card, or two crossed.
/// A card has one normal, so the whole tree is lit as one plane: all of it
/// bright when the sun is before it and all of it black when the sun is
/// behind, where a tree is lit down one side and dark down the other and
/// never either all over. The card cannot be made round, but its normals
/// can. The cut-out says where the crown is; blown up like a balloon inside
/// that outline it gives every texel the way a crown that shape would face
/// there, and the photograph's own light and dark, which on a tree is its
/// clumps of leaf, gives the lumps on it.
public enum FoliageStructure {
    /// The normal map (x in red, y in green) and the ORM map (occlusion in
    /// red, roughness in green) of a tree card, from its picture.
    ///
    /// - Parameter rgba: bottom row first, as a `TextureImage` holds it.
    public static func derive(rgba: [UInt8], width: Int, height: Int) -> (normal: [UInt8], orm: [UInt8]) {
        precondition(rgba.count == width * height * 4)
        let count = width * height
        var cover = [Float](repeating: 0, count: count), light = [Float](repeating: 0, count: count)
        for i in 0 ..< count {
            cover[i] = rgba[i * 4 + 3] > 127 ? 1 : 0
            light[i] = (0.30 * Float(rgba[i * 4]) + 0.59 * Float(rgba[i * 4 + 1]) + 0.11 * Float(rgba[i * 4 + 2])) / 255 * cover[i]
        }
        // The balloon: how much leaf there is round a texel, broadly, for
        // the crown's roundness, and a little of it narrowly for a bough
        // that stands out. More of the narrow, or of the clumps below, and
        // every gap in the leaves tips the light its own way: a tree seen
        // close was smears of light and dark, like wet paint.
        let span = max(width, height)
        let broadRadius = max(span / 9, 2), narrowRadius = max(span / 28, 1)
        let broad = FacadeStructure.blurred(FacadeStructure.blurred(cover, width: width, height: height, radius: broadRadius),
                                            width: width, height: height, radius: broadRadius)
        let narrow = FacadeStructure.blurred(cover, width: width, height: height, radius: narrowRadius)
        // The clumps: light against the light round it, where there is leaf.
        let near = FacadeStructure.blurred(light, width: width, height: height, radius: 1)
        let far = FacadeStructure.blurred(light, width: width, height: height, radius: max(span / 24, 2))
        let leafFar = FacadeStructure.blurred(cover, width: width, height: height, radius: max(span / 24, 2))
        var form = [Float](repeating: 0, count: count)
        for i in 0 ..< count {
            let body: Float = broad[i] * 0.92 + narrow[i] * 0.08
            let clump: Float = cover[i] > 0 ? near[i] - far[i] / max(leafFar[i], 0.05) : 0
            form[i] = body + min(max(clump, -0.25), 0.25) * 0.015
        }
        // A crown's edge turns well away from whoever looks at it.
        let strength = Float(broadRadius) * 2.6
        var normal = [UInt8](repeating: 255, count: count * 4), orm = [UInt8](repeating: 255, count: count * 4)
        func at(_ x: Int, _ y: Int) -> Float { form[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)] }
        for y in 0 ..< height {
            for x in 0 ..< width {
                let i = y * width + x
                let dx = (at(x + 1, y) - at(x - 1, y)) * 0.5, dy = (at(x, y + 1) - at(x, y - 1)) * 0.5
                var n = SIMD3(-dx * strength, dy * strength, 1)
                // Never past the horizon: the card is still seen face on.
                let lean = (n.x * n.x + n.y * n.y).squareRoot()
                if lean > 1.2 { n.x *= 1.2 / lean; n.y *= 1.2 / lean }
                n = simd_normalize(n)
                normal[i * 4] = UInt8(min(max(((n.x + 1) * 127.5).rounded(), 0), 255))
                normal[i * 4 + 1] = UInt8(min(max(((n.y + 1) * 127.5).rounded(), 0), 255))
                normal[i * 4 + 2] = UInt8(min(max(((n.z + 1) * 127.5).rounded(), 0), 255))
                // Deep in the crown less of the sky gets in.
                let deep = min(max((broad[i] - 0.55) / 0.45, 0), 1)
                orm[i * 4] = UInt8(((1 - deep * 0.30) * 255).rounded())
                orm[i * 4 + 1] = 255
                orm[i * 4 + 2] = 0
            }
        }
        return (normal, orm)
    }

    /// The picture at half its size each way, alpha weighted so the
    /// cut-out's edge does not take the colour of what was cut away. The
    /// form of a crown has nothing in it finer than that.
    public static func halved(rgba: [UInt8], width: Int, height: Int) -> (rgba: [UInt8], width: Int, height: Int) {
        guard width >= 128, height >= 128, width % 2 == 0, height % 2 == 0 else { return (rgba, width, height) }
        let w = width / 2, h = height / 2
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0 ..< h {
            for x in 0 ..< w {
                var sum = SIMD3<Float>(repeating: 0), alpha: Float = 0
                for (ox, oy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                    let i = ((y * 2 + oy) * width + x * 2 + ox) * 4
                    let a = Float(rgba[i + 3])
                    sum += SIMD3(Float(rgba[i]), Float(rgba[i + 1]), Float(rgba[i + 2])) * a
                    alpha += a
                }
                let o = (y * w + x) * 4
                if alpha > 0 { sum /= alpha }
                out[o] = UInt8(sum.x.rounded()); out[o + 1] = UInt8(sum.y.rounded()); out[o + 2] = UInt8(sum.z.rounded())
                out[o + 3] = UInt8((alpha / 4).rounded())
            }
        }
        return (out, w, h)
    }
}
