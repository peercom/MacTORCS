// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd
import TORCSMath
import TORCSMaterials

/// A tyre's own texture coordinates.
///
/// A modelled wheel is textured from a picture of a wheel seen from its
/// side: the rim, the sidewall round it, and the tread, which from the side
/// is the picture's last ring of texels and one colour. Nothing drawn in
/// that picture can put a groove on the tread. So the tyre's coordinates
/// are made again from its shape, as a tyre is made: `u` round the wheel,
/// twice round to the texture's width, and `v` across its section from one
/// bead over the tread to the other, the tread always the same band of `v`
/// (`MaterialRecipes.tyreTread`) whatever the tyre's proportions. The
/// `car-tyre` set is drawn to that.
public enum TyreUnwrap {
    /// How many times the texture goes round the wheel.
    public static let repeats: Float = 2

    /// The texture a tyre takes at a wheel's speed level: standing, or drawn out by turning.
    public static func texture(level: Int) -> String { level <= 0 ? "car-tyre.rgb" : "car-tyre-rolling.rgb" }

    /// The speed level of the wheel scene at a session resource index, or
    /// nil for a resource that is not a wheel: the first car's wheels are
    /// resources 1 to 4, and each further model's the same within its
    /// seventeen.
    public static func wheelLevel(resource index: Int) -> Int? {
        let slot = index < 18 ? index : (index - 18) % 17
        return (1 ... 4).contains(slot) ? slot - 1 : nil
    }

    /// The scene with every tyre batch unwrapped and named for `texture`.
    public static func unwrapped(_ scene: RenderScene, texture: String) -> RenderScene {
        var batches = scene.batches
        var changed = false
        for (index, batch) in batches.enumerated() where batch.carPart == .tyre {
            guard let mesh = unwrapped(batch.mesh) else { continue }
            batches[index] = RenderBatch(
                mesh: mesh, baseTexture: texture, blends: batch.blends, isDeferred: batch.isDeferred,
                alphaTestThreshold: batch.alphaTestThreshold, culls: batch.culls, isDriver: batch.isDriver,
                sourceMaterial: batch.sourceMaterial, material: batch.material, uvInMetres: false,
                paintsRoadMarkings: batch.paintsRoadMarkings, swaysInWind: batch.swaysInWind,
                detailRange: batch.detailRange, castsShadow: batch.castsShadow, prepass: batch.prepass,
                receivesWeather: batch.receivesWeather, carPart: batch.carPart)
            changed = true
        }
        return changed ? RenderScene(batches: batches, minimum: scene.minimum, maximum: scene.maximum, warnings: scene.warnings) : scene
    }

    /// Where a point of a tyre is on it: the angle round the axle as a
    /// fraction of a turn, and the place across the section, 0 at one bead,
    /// the tread between `tyreTread`'s bounds, 1 at the other bead.
    struct Shape {
        var centre: SIMD3<Float>, axle: SIMD3<Float>, first: SIMD3<Float>, second: SIMD3<Float>
        var inner: Float, outer: Float, half: Float

        init?(_ positions: [SIMD3<Float>]) {
            guard positions.count >= 3 else { return nil }
            var low = positions[0], high = positions[0]
            for p in positions { low = simd_min(low, p); high = simd_max(high, p) }
            let extent = high - low
            // The axle is the one way a tyre is not round. The wheel models
            // are a unit across every way, to be scaled to the car's own
            // wheel when drawn, so its width says nothing; but its points
            // are spread alike along the two ways it is round and otherwise
            // along the third.
            let middle = (low + high) * 0.5
            var spread = SIMD3<Float>(repeating: 0)
            for p in positions { spread += (p - middle) * (p - middle) }
            let odd = SIMD3(abs(spread.x - (spread.y + spread.z) * 0.5), abs(spread.y - (spread.x + spread.z) * 0.5),
                            abs(spread.z - (spread.x + spread.y) * 0.5))
            let axis = odd.x >= odd.y && odd.x >= odd.z ? 0 : (odd.y >= odd.z ? 1 : 2)
            var a = SIMD3<Float>(repeating: 0), e1 = SIMD3<Float>(repeating: 0), e2 = SIMD3<Float>(repeating: 0)
            a[axis] = 1; e1[(axis + 1) % 3] = 1; e2[(axis + 2) % 3] = 1
            centre = (low + high) * 0.5; axle = a; first = e1; second = e2
            half = extent[axis] * 0.5
            var nearest = Float.greatestFiniteMagnitude, farthest: Float = 0
            for p in positions {
                let q = p - centre
                let r = simd_length(q - a * simd_dot(q, a))
                nearest = min(nearest, r); farthest = max(farthest, r)
            }
            inner = nearest; outer = farthest
            guard half > 1e-4, outer - inner > 1e-4 else { return nil }
        }

        func turn(_ p: SIMD3<Float>) -> Float {
            let q = p - centre
            return atan2(simd_dot(q, second), simd_dot(q, first)) / (2 * .pi)
        }

        func across(_ p: SIMD3<Float>) -> Float {
            let q = p - centre
            let along = simd_dot(q, axle)
            let r = simd_length(q - axle * along)
            // The angle round the bead's own circle, from one side's bead
            // through the tread's middle to the other's; and the angle at
            // which the sidewall gives way to the tread on this tyre.
            let angle = atan2(along, max(r - inner, 0))
            let shoulder = atan2(half, outer - inner)
            let tread = MaterialRecipes.tyreTread
            let middle = (tread.lowerBound + tread.upperBound) * 0.5, reach = (tread.upperBound - tread.lowerBound) * 0.5
            if abs(angle) <= shoulder { return middle + reach * angle / shoulder }
            let wall = (abs(angle) - shoulder) / max(.pi / 2 - shoulder, 1e-4)
            return angle > 0 ? tread.upperBound + (1 - tread.upperBound) * wall : tread.lowerBound * (1 - wall)
        }
    }

    /// The mesh with its coordinates made again. A triangle that crosses
    /// the line where the angle wraps keeps its own corners, moved a turn,
    /// so nothing is drawn backwards across the tyre there.
    static func unwrapped(_ mesh: RenderMesh) -> RenderMesh? {
        let source = mesh.vertices.map(\.position)
        guard let shape = Shape(source) else { return nil }
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uv: [SIMD2<Float>] = [], indices: [UInt32] = []
        // A corner is its vertex and how many turns it was moved to stay
        // with its triangle: the same two make the same corner, so the mesh
        // keeps its shared vertices everywhere but along the wrap.
        var made: [SIMD2<Int32>: UInt32] = [:]
        let turnOf = source.map(shape.turn), acrossOf = source.map(shape.across)
        for triangle in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            let corners = (0 ..< 3).map { Int(mesh.indices[triangle + $0]) }
            var moved: [Int32] = [0, 0, 0]
            for k in 1 ..< 3 {
                let apart = turnOf[corners[k]] - turnOf[corners[0]]
                if apart > 0.5 { moved[k] = -1 } else if apart < -0.5 { moved[k] = 1 }
            }
            for k in 0 ..< 3 {
                let key = SIMD2(Int32(corners[k]), moved[k])
                if let index = made[key] { indices.append(index); continue }
                let index = UInt32(positions.count)
                made[key] = index
                indices.append(index)
                positions.append(source[corners[k]])
                normals.append(OctahedralPacking.decodeNormal(mesh.vertices[corners[k]].normal))
                uv.append(SIMD2((turnOf[corners[k]] + Float(moved[k])) * repeats, acrossOf[corners[k]]))
            }
        }
        return try? RenderMesh.build(positions: positions, normals: normals, uv0: uv, indices: indices, transform: mesh.transform)
    }
}
