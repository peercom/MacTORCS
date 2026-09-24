// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd
import TORCSAssets
import TORCSTrackMesh

/// Solid trees in unit tree space, built from a species' own atlas region.
///
/// A trunk, branches, and a crown of small individually oriented leaf cards
/// that fill a volume; each card samples a small foliage-dense patch of the
/// atlas rather than the whole tree, which keeps the source colours without
/// the horizontal rings a whole-tree wrap produces. The result reads as a
/// solid at driving and overhead angles, and because every card is an alpha
/// cutout, the cascades see leaves, not sheets.
///
/// Per-vertex attributes: x is height in the tree (0 at the base, 1 at the
/// top), which the vertex shader sways by; y the sway amplitude at the top
/// in quarter-millimetres over 255 (see Forward.metal); w a leaf tint.
public enum TreeMeshes {
    /// - Parameter middle: a lighter build for distant trees.
    public static func mesh(family: Int, variant: Int, middle: Bool, atlas: TextureImage) -> GeneratedGeometry {
        let descriptor = TreeForest.families[family], range = descriptor.ranges[0], rgba = atlas.rgba8
        // A foliage-dense patch inside this tree's own atlas region.
        let x0 = max(1, Int(range.x * Float(atlas.width)) + 1), x1 = min(atlas.width - 2, Int(range.y * Float(atlas.width)) - 1)
        let y0 = max(1, Int(descriptor.top * 0.25 * Float(atlas.height))), y1 = min(atlas.height - 2, Int(descriptor.top * 0.82 * Float(atlas.height)))
        let tile = max(1, min(24, min(x1 - x0, y1 - y0)))
        var best = SIMD2(x0, y0), bestScore = -Float.infinity
        if x1 - x0 >= tile, y1 - y0 >= tile {
            for y in stride(from: y0, through: y1 - tile, by: 3) {
                for x in stride(from: x0, through: x1 - tile, by: 3) {
                    var score: Float = 0
                    for yy in stride(from: y, to: y + tile, by: 2) {
                        for xx in stride(from: x, to: x + tile, by: 2) {
                            let i = (yy * atlas.width + xx) * 4
                            score += Float(rgba[i + 3]) * (1 + max(0, Float(rgba[i + 1]) - Float(rgba[i])) / 64)
                        }
                    }
                    if score > bestScore { bestScore = score; best = SIMD2(x, y) }
                }
            }
        }
        let uvLow = SIMD2((Float(best.x) + 0.5) / Float(atlas.width), (Float(best.y) + 0.5) / Float(atlas.height))
        let uvSpan = SIMD2(Float(tile - 1) / Float(atlas.width), Float(tile - 1) / Float(atlas.height))
        func sourceRadius(_ z: Float) -> Float {
            let y = min(atlas.height - 1, max(0, Int(z * descriptor.top * Float(atlas.height))))
            var radius: Float = 0.025
            if x0 <= x1 {
                for yy in max(0, y - 1) ... min(atlas.height - 1, y + 1) {
                    for x in x0 ... x1 where rgba[(yy * atlas.width + x) * 4 + 3] > 96 {
                        radius = max(radius, abs((Float(x) / Float(atlas.width) - range.x) / (range.y - range.x) - 0.5))
                    }
                }
            }
            return min(0.49, radius)
        }

        var out = GeneratedGeometry()
        var serial = 0
        func append(_ position: SIMD3<Float>, _ normal: SIMD3<Float>, _ uv: SIMD2<Float>, tint: Float) {
            out.positions.append(position)
            out.normals.append(normal)
            out.uv0.append(uv)
            out.attributes.append(SIMD4(UInt8(min(max(position.z, 0), 1) * 255), 184, 0, UInt8(min(max(tint, 0), 1) * 255)))
        }
        // Bark: the atlas's trunk column, a narrow strip at the base of the region.
        let barkUV = SIMD2((range.x + range.y) * 0.5, descriptor.top * 0.97)
        func cylinder(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ radius: Float) {
            let direction = simd_normalize(b - a)
            let axis = abs(direction.z) > 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 0, 1)
            let right = simd_normalize(simd_cross(direction, axis)), forward = simd_cross(direction, right)
            let sides = middle ? 5 : 7, first = UInt32(out.positions.count)
            for row in 0 ... 1 {
                for side in 0 ... sides {
                    let angle = Float(side) * 2 * Float.pi / Float(sides), n = right * cos(angle) + forward * sin(angle)
                    append((row == 0 ? a : b) + n * radius * (row == 0 ? 1 : 0.35), n, barkUV, tint: 0.55)
                }
            }
            for side in 0 ..< sides {
                let p = first + UInt32(side), q = p + UInt32(sides + 1)
                out.indices += [p, p + 1, q, p + 1, q + 1, q]
            }
        }
        func cluster(_ centre: SIMD3<Float>, _ scale: SIMD3<Float>, _ shade: Float) {
            var seed = UInt64(1 + family * 100_003 + variant * 10_007 + serial * 503)
            serial += 1
            func random() -> Float {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Float((seed >> 40) & 0xFFFFFF) / 16777216
            }
            let count = middle ? (family == 2 ? 24 : 20) : (family == 2 ? 64 : 48)
            let size: Float = middle ? 0.42 : 0.30
            for _ in 0 ..< count {
                let z = random() * 2 - 1, angle = random() * 2 * Float.pi
                let radial = sqrt(max(0, 1 - z * z))
                let outward = SIMD3(radial * cos(angle), radial * sin(angle), z)
                let origin = outward * pow(random(), 1.0 / 3.0) * 0.82
                let turn = random() * 2 * Float.pi
                let reference = abs(outward.z) > 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 0, 1)
                let tangent = simd_normalize(simd_cross(outward, reference)), bitangent = simd_cross(outward, tangent)
                let along = tangent * cos(turn) + bitangent * sin(turn)
                let across = simd_cross(outward, along)
                let width = size * (0.65 + random() * 0.55), length = size * (0.9 + random() * 0.6)
                let fold = simd_cross(along, across) * size * 0.16
                let offsets = [-along * length, across * width + fold, along * length, -across * width + fold]
                let uv = [SIMD2<Float>(0, 0.5), SIMD2(0.45, 0), SIMD2(1, 0.5), SIMD2(0.45, 1)]
                let leafScale = SIMD3(scale.x, scale.y, max(scale.z, min(scale.x, scale.y) * 0.55))
                let points = offsets.map { centre + origin * scale + $0 * leafScale }
                let normal = simd_normalize(simd_cross(points[1] - points[0], points[2] - points[0]))
                let tint = shade * (0.78 + random() * 0.27), first = UInt32(out.positions.count)
                for i in 0 ..< 4 { append(points[i], normal, uvLow + uvSpan * uv[i], tint: tint) }
                out.indices += [first, first + 1, first + 2, first, first + 2, first + 3]
            }
        }
        cylinder(.zero, SIMD3(0, 0, family == 2 ? 0.88 : 0.97), family == 2 ? 0.029 : 0.023)
        if family < 2 {
            let layers = middle ? 7 : 11, branches = middle ? 3 : 5
            for layer in 0 ..< layers {
                let fraction = Float(layer) / Float(layers - 1), z: Float = 0.15 + fraction * 0.78
                let radius: Float = family == 0 ? 0.39 * pow(1 - fraction, 0.85) + 0.02 : sourceRadius(z) * 0.72
                let phase = Float(layer) * 2.399 + Float(variant) * 1.71
                for branch in 0 ..< branches {
                    let angle = phase + Float(branch) * 2 * Float.pi / Float(branches)
                    let reach = radius * (family == 0 ? 0.55 : 0.82)
                    let centre = SIMD3(cos(angle) * reach, sin(angle) * reach, z + 0.038 * sin(angle * 3 + Float(layer)))
                    let scale = SIMD3(radius * (family == 0 ? 0.65 : 0.58), radius * 0.60,
                                      family == 0 ? max(0.009, radius * 0.12) : max(0.006, radius * 0.17))
                    if !middle { cylinder(SIMD3(0, 0, z - 0.05), centre, 0.005 * (1 - fraction * 0.7)) }
                    cluster(centre, scale, 0.88 + fraction * 0.12)
                }
                if family == 0 { cluster(SIMD3(0, 0, z), SIMD3(radius * 0.55, radius * 0.55, 0.02 + radius * 0.10), 0.92) }
            }
        } else {
            cluster(SIMD3(0, 0, 0.59), SIMD3(0.25, 0.25, 0.30), 0.86)
            let layers = middle ? 3 : 4, branches = middle ? 5 : 7
            for layer in 0 ..< layers {
                let fraction = Float(layer) / Float(layers - 1), z: Float = 0.34 + fraction * 0.50
                let reach: Float = 0.22 * sin((0.22 + fraction * 0.65) * Float.pi)
                for branch in 0 ..< branches {
                    let angle = Float(branch) * 2 * Float.pi / Float(branches) + Float(layer) * 2.399 + Float(variant) * 1.71
                    let centre = SIMD3(cos(angle) * reach, sin(angle) * reach, z + 0.025 * sin(angle * 3))
                    if !middle { cylinder(SIMD3(0, 0, z - 0.13), centre, 0.008) }
                    cluster(centre, SIMD3(0.17, 0.17, 0.125), 0.88 + fraction * 0.12)
                }
            }
        }
        // Keep the card's extents, including its tilt.
        for i in out.positions.indices {
            out.positions[i].x = min(0.5, max(-0.5, out.positions[i].x))
            out.positions[i].y = min(0.5, max(-0.5, out.positions[i].y))
            out.positions[i].z = min(1, max(0, out.positions[i].z))
        }
        return out
    }
}
