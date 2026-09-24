// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd

/// Octahedral unit-vector packing (Cigolle et al. 2014, "A Survey of Efficient
/// Representations for Independent Unit Vectors").
///
/// A normalized direction costs four bytes as two `Int16` snorm components
/// instead of twelve as three `Float`. Worst-case angular error at 16 bits per
/// component is well under a milliradian, which is far below the shading error
/// of the interpolated per-vertex normals it replaces.
///
/// Encoding is coordinate-system agnostic, so TORCS's right-handed Z-up frame
/// needs no special handling here.
public enum OctahedralPacking {
    /// `sign` that returns +1 for zero, matching the reference formulation.
    /// `simd.sign` returns 0 for 0 and would collapse the fold at the axes.
    @inline(__always) static func signNotZero(_ v: SIMD2<Float>) -> SIMD2<Float> {
        SIMD2(v.x >= 0 ? 1 : -1, v.y >= 0 ? 1 : -1)
    }

    /// Projects a normalized direction onto the `[-1, 1]` octahedral square.
    public static func project(_ n: SIMD3<Float>) -> SIMD2<Float> {
        let l1 = abs(n.x) + abs(n.y) + abs(n.z)
        guard l1 > 0 else { return SIMD2(0, 0) }
        let p = SIMD2(n.x, n.y) / l1
        // Lower hemisphere folds outward across the diagonals.
        return n.z <= 0 ? (SIMD2(1, 1) - abs(SIMD2(p.y, p.x))) * signNotZero(p) : p
    }

    /// Inverse of `project`. Returns a normalized direction.
    public static func unproject(_ e: SIMD2<Float>) -> SIMD3<Float> {
        var v = SIMD3(e.x, e.y, 1 - abs(e.x) - abs(e.y))
        if v.z < 0 {
            let folded = (SIMD2(1, 1) - abs(SIMD2(v.y, v.x))) * signNotZero(SIMD2(v.x, v.y))
            v.x = folded.x
            v.y = folded.y
        }
        let length = simd_length(v)
        return length > 0 ? v / length : SIMD3(0, 0, 1)
    }

    @inline(__always) static func quantize(_ value: Float) -> Int16 {
        // Round-to-nearest over the symmetric snorm range. Clamping to -32767
        // keeps decode exactly symmetric; -32768 has no positive counterpart.
        let scaled = (value.isFinite ? value : 0).clamped(to: -1 ... 1) * 32767
        return Int16(scaled.rounded())
    }

    @inline(__always) static func dequantize(_ value: Int16) -> Float {
        max(Float(value) / 32767, -1)
    }

    /// Packs a normal into two `Int16` snorm components.
    public static func encodeNormal(_ n: SIMD3<Float>) -> SIMD2<Int16> {
        let p = project(n)
        return SIMD2(quantize(p.x), quantize(p.y))
    }

    public static func decodeNormal(_ e: SIMD2<Int16>) -> SIMD3<Float> {
        unproject(SIMD2(dequantize(e.x), dequantize(e.y)))
    }

    /// Packs a tangent plus its bitangent handedness into the same four bytes.
    ///
    /// The handedness sign lives in the low bit of the second component. That
    /// costs one bit of precision on one axis — about 3e-5 of snorm range,
    /// which is irrelevant for a direction vector — and avoids spending a
    /// fifth byte and the padding it would drag in.
    public static func encodeTangent(_ t: SIMD3<Float>, handedness: Float) -> SIMD2<Int16> {
        let p = project(t)
        let x = quantize(p.x)
        // Reserve the low bit: quantize to 15 bits, then shift up.
        let magnitude = Int16((p.y.clamped(to: -1 ... 1) * 16383).rounded())
        let y = Int16(clamping: Int(magnitude) << 1 | (handedness < 0 ? 1 : 0))
        return SIMD2(x, y)
    }

    public static func decodeTangent(_ e: SIMD2<Int16>) -> (tangent: SIMD3<Float>, handedness: Float) {
        let handedness: Float = (e.y & 1) != 0 ? -1 : 1
        let y = Float(e.y >> 1) / 16383
        let t = unproject(SIMD2(dequantize(e.x), max(y, -1)))
        return (t, handedness)
    }
}

extension Float {
    @inline(__always) func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
