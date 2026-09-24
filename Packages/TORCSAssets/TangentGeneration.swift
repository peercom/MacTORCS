// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd

/// Per-vertex tangent frames for normal mapping.
///
/// AC3D carries no tangents, so they are derived from positions, the base UV
/// layer and the stored normals. This is the standard area-weighted
/// accumulation (Lengyel) followed by Gram-Schmidt orthonormalization against
/// the vertex normal, which is what MikkTSpace reduces to when the source has
/// one UV per vertex rather than one per corner — the case here, because the AC
/// loader stores UVs per indexed vertex.
///
/// Consequence worth knowing: a UV seam that shares vertices cannot be resolved
/// into two frames without splitting the vertex. The AC loader already keeps
/// the last-referenced UV per vertex, so such seams are pre-broken in the
/// source data and this function inherits whatever the source encoded.
public enum TangentGeneration {
    public struct Frame: Sendable, Equatable {
        /// Unit tangent in the same space as the supplied positions and normals.
        public var tangent: SIMD3<Float>
        /// +1 or -1. The bitangent is `handedness * cross(normal, tangent)`.
        public var handedness: Float
        public init(tangent: SIMD3<Float>, handedness: Float) {
            self.tangent = tangent
            self.handedness = handedness
        }
    }

    /// Any unit vector perpendicular to `n`, chosen branchlessly and stably so
    /// that untextured or UV-degenerate geometry still gets a usable frame
    /// rather than a zero tangent that would produce NaNs in the shader.
    public static func arbitraryTangent(perpendicularTo n: SIMD3<Float>) -> SIMD3<Float> {
        // Hughes-Möller: cross with whichever axis is least aligned with n.
        let axis: SIMD3<Float> = abs(n.x) <= abs(n.y) && abs(n.x) <= abs(n.z)
            ? SIMD3(1, 0, 0)
            : (abs(n.y) <= abs(n.z) ? SIMD3(0, 1, 0) : SIMD3(0, 0, 1))
        let t = simd_cross(n, axis)
        let length = simd_length(t)
        return length > 1e-8 ? t / length : SIMD3(1, 0, 0)
    }

    /// - Parameters:
    ///   - positions: one entry per vertex.
    ///   - normals: one entry per vertex, expected normalized but not required.
    ///   - uvs: base-layer UV per vertex. Empty yields arbitrary stable frames.
    ///   - indices: triangle list, a multiple of three. Out-of-range or
    ///     degenerate triangles are skipped rather than trapping, matching the
    ///     loader's tolerance for degenerate source surfaces.
    public static func frames(positions: [SIMD3<Float>], normals: [SIMD3<Float>],
                              uvs: [SIMD2<Float>], indices: [UInt32]) -> [Frame] {
        let count = positions.count
        guard count > 0 else { return [] }
        precondition(normals.count == count, "normals must be per-vertex")

        var tangentSum = [SIMD3<Float>](repeating: .zero, count: count)
        var bitangentSum = [SIMD3<Float>](repeating: .zero, count: count)

        if uvs.count == count {
            var triangle = 0
            while triangle + 2 < indices.count {
                let i0 = Int(indices[triangle]), i1 = Int(indices[triangle + 1]), i2 = Int(indices[triangle + 2])
                triangle += 3
                guard i0 < count, i1 < count, i2 < count else { continue }

                let e1 = positions[i1] - positions[i0], e2 = positions[i2] - positions[i0]
                let d1 = uvs[i1] - uvs[i0], d2 = uvs[i2] - uvs[i0]
                let determinant = d1.x * d2.y - d2.x * d1.y
                // A zero-area UV triangle carries no direction information.
                guard abs(determinant) > 1e-12, determinant.isFinite else { continue }
                let r = 1 / determinant

                // Deliberately left unnormalized: magnitude scales with the
                // triangle's area-to-UV-area ratio, which is the area weighting.
                let t = (e1 * d2.y - e2 * d1.y) * r
                let b = (e2 * d1.x - e1 * d2.x) * r
                guard t.x.isFinite, t.y.isFinite, t.z.isFinite,
                      b.x.isFinite, b.y.isFinite, b.z.isFinite else { continue }

                for i in [i0, i1, i2] {
                    tangentSum[i] += t
                    bitangentSum[i] += b
                }
            }
        }

        return (0 ..< count).map { i in
            let rawNormal = normals[i]
            let normalLength = simd_length(rawNormal)
            let n = normalLength > 1e-8 ? rawNormal / normalLength : SIMD3<Float>(0, 0, 1)

            // Gram-Schmidt: remove the normal component so the frame is orthogonal.
            let projected = tangentSum[i] - n * simd_dot(n, tangentSum[i])
            let length = simd_length(projected)
            guard length > 1e-8, projected.x.isFinite, projected.y.isFinite, projected.z.isFinite else {
                return Frame(tangent: arbitraryTangent(perpendicularTo: n), handedness: 1)
            }
            let tangent = projected / length
            // Mirrored UVs flip the bitangent relative to cross(n, t).
            let handedness: Float = simd_dot(simd_cross(n, tangent), bitangentSum[i]) < 0 ? -1 : 1
            return Frame(tangent: tangent, handedness: handedness)
        }
    }
}
