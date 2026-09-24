// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd

/// TORCS right-handed, Z-up coordinates. Positive yaw turns forward X toward Y.
public enum Coordinates {
    public static func localToWorld(_ local: SIMD3<Float>, origin: SIMD3<Float>, yaw: Float) -> SIMD3<Float> {
        let c = cos(yaw), s = sin(yaw)
        return origin + SIMD3(c * local.x - s * local.y, s * local.x + c * local.y, local.z)
    }
    public static func worldToLocal(_ world: SIMD3<Float>, origin: SIMD3<Float>, yaw: Float) -> SIMD3<Float> {
        let d = world - origin, c = cos(yaw), s = sin(yaw)
        return SIMD3(c * d.x + s * d.y, -s * d.x + c * d.y, d.z)
    }
    public static func trackDistance(toStart: Float, radius: Float?) -> Float {
        radius.map { toStart * $0 } ?? toStart
    }
}
