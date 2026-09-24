// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd

/// Colour-space conversion for the linear-HDR render path.
///
/// The classic raster path did all of its lighting arithmetic directly on
/// stored sRGB bytes and clamped to `[0, 1]`, which is what TORCS 1.3.9 did
/// through fixed-function OpenGL. Physically based shading requires linear
/// radiance, so every albedo texture is decoded on the way in and the frame is
/// encoded once on the way out.
public enum ColorSpace {
    /// Exact sRGB EOTF (IEC 61966-2-1), not the 2.2 power approximation. The
    /// linear toe matters for dark asphalt, which is most of a racing frame.
    public static func linear(fromSRGB c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    public static func srgb(fromLinear c: Float) -> Float {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    public static func linear(fromSRGB c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(linear(fromSRGB: c.x), linear(fromSRGB: c.y), linear(fromSRGB: c.z))
    }

    public static func srgb(fromLinear c: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(srgb(fromLinear: c.x), srgb(fromLinear: c.y), srgb(fromLinear: c.z))
    }

    /// Rec. 709 luminance weights, matching the working primaries.
    public static func luminance(_ linear: SIMD3<Float>) -> Float {
        simd_dot(linear, SIMD3(0.2126, 0.7152, 0.0722))
    }
}

/// Photometric exposure, so sun and lights can be authored in real units
/// instead of the hand-tuned `0.2` ambient constants the classic path carried.
public enum Exposure {
    /// Saturation-based speed with the conventional ISO calibration K = 12.5.
    public static func ev100(luminance: Float) -> Float {
        log2(max(luminance, 1e-6) * 100 / 12.5)
    }

    /// Multiplier that maps scene radiance to the [0, 1] display range.
    public static func scale(ev100: Float) -> Float {
        1 / (1.2 * pow(2, ev100))
    }
}
