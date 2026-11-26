// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Metal
import simd

/// Per-pixel motion blur from the velocity buffer: its settings, and the
/// uniforms the tonemap pass reads the scene through.
///
/// It is not a pass. One gather along the centre pixel's velocity, jittered
/// to avoid banding, taken by the resolve as it samples the scene (see
/// MotionBlur.metal); a pass of its own wrote a second scene-sized HDR
/// target only for the resolve to read it back. The bloom and the lens blur
/// are therefore built from the unblurred scene, which at their widths
/// cannot be told apart.
public final class MotionBlurRenderer {
    /// Fraction of the frame interval the shutter is open. Half is the film
    /// convention (a 180° shutter) and reads as motion without smearing the
    /// frame into soup.
    public var shutter: Float = 0.5
    /// The frame interval the shutter fraction refers to. A velocity is per
    /// frame; a shutter is a time. At a lower frame rate each frame covers
    /// more motion, and blurring by the frame would lengthen the streaks as
    /// the machine slows — the caller scales the shutter by this over the
    /// measured interval, so the exposure stays a sixtieth of a second.
    public static let nominalFrameInterval: Double = 1.0 / 60.0
    /// Longest blur, as a fraction of the scene's height. Wheels and close
    /// barriers can exceed a whole frame of motion; past this they smear
    /// into mush rather than read faster.
    public var maximumRadius: Float = 0.02
    public var taps: Int = 8

    public init() {}

    /// How the resolve is to read `scene` on its way to `destination`:
    /// blurred by `velocity` when there is one, and filtered up when the
    /// scene is the smaller of the two.
    func uniforms(scene: MTLTexture, velocity: MTLTexture?, destination: MTLTexture,
                  exposureScale: Float = 1) -> MotionBlurUniforms {
        let ratio = velocity.map { SIMD2(Float(scene.width) / Float($0.width), Float(scene.height) / Float($0.height)) }
            ?? SIMD2(1, 1)
        let smaller = scene.width < destination.width || scene.height < destination.height
        return MotionBlurUniforms(
            parameters: SIMD4(1 / Float(scene.width), 1 / Float(scene.height),
                              shutter * exposureScale, maximumRadius * Float(scene.height)),
            scale: SIMD4(ratio.x, ratio.y, velocity == nil ? 0 : Float(taps), smaller ? 1 : 0))
    }
}

/// Mirrors `MotionBlurUniforms` in `MotionBlur.metal`.
struct MotionBlurUniforms {
    var parameters: SIMD4<Float>
    var scale: SIMD4<Float>
}
