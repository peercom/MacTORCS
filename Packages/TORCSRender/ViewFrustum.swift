// SPDX-License-Identifier: GPL-2.0-only
import simd

/// The view frustum as clip planes, for rejecting whole batches before they
/// are submitted.
///
/// A driver's-eye view has half the circuit's trees behind it, and until this
/// existed every one of them was transformed and clipped each frame: the
/// forward pass faded batches by distance only. The planes come from the
/// rows of the view-projection matrix (Gribb and Hartmann); a plane whose
/// normal vanishes — the far plane of the reversed infinite projection — is
/// simply absent, which is correct: nothing is too far for it.
public struct ViewFrustum: Sendable, Equatable {
    /// `xyz` unit normal pointing inward, `w` offset: inside when
    /// `dot(xyz, p) + w >= 0`.
    public let planes: [SIMD4<Float>]

    public init(viewProjection m: simd_float4x4) {
        func row(_ i: Int) -> SIMD4<Float> {
            SIMD4(m.columns.0[i], m.columns.1[i], m.columns.2[i], m.columns.3[i])
        }
        let x = row(0), y = row(1), z = row(2), w = row(3)
        // Metal clip space: -w <= x <= w, -w <= y <= w, 0 <= z <= w.
        planes = [w + x, w - x, w + y, w - y, w - z, z].compactMap { plane in
            let length = simd_length(SIMD3(plane.x, plane.y, plane.z))
            return length > 1e-12 ? plane / length : nil
        }
    }

    /// Whether any part of the sphere may be inside. Conservative: a sphere
    /// outside two planes' corner can pass, which only costs a draw.
    public func mayContain(sphereAt centre: SIMD3<Float>, radius: Float) -> Bool {
        for plane in planes where simd_dot(SIMD3(plane.x, plane.y, plane.z), centre) + plane.w < -radius {
            return false
        }
        return true
    }
}
