// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Metal
import MetalFX
import simd

/// MetalFX temporal upscaling.
///
/// The single largest performance lever available: rendering at half linear
/// resolution is a quarter of the shaded pixels, and shaded pixels are what
/// actually dominates this renderer's cost — the depth prepass measurement
/// established that overdraw does not.
///
/// It needs three things the renderer would not otherwise produce: a subpixel
/// jitter applied to the projection each frame, per-pixel motion vectors, and a
/// texture mip bias so the upscaled image resolves detail rather than
/// reproducing a blurry half-resolution one.
public final class TemporalUpscaler {
    private let scaler: MTLFXTemporalScaler
    public let renderWidth: Int, renderHeight: Int
    public let outputWidth: Int, outputHeight: Int
    /// Set for the first frame and after a camera cut, so the history is
    /// discarded rather than smeared across the change.
    public var needsReset = true

    public init(device: MTLDevice, renderWidth: Int, renderHeight: Int,
                outputWidth: Int, outputHeight: Int) throws {
        let descriptor = MTLFXTemporalScalerDescriptor()
        descriptor.inputWidth = renderWidth
        descriptor.inputHeight = renderHeight
        descriptor.outputWidth = outputWidth
        descriptor.outputHeight = outputHeight
        descriptor.colorTextureFormat = FrameTargets.colourFormat
        descriptor.depthTextureFormat = FrameTargets.depthFormat
        descriptor.motionTextureFormat = FrameTargets.velocityFormat
        descriptor.outputTextureFormat = FrameTargets.colourFormat
        // The scene target holds unbounded radiance and the tonemapper runs
        // after upscaling, so let MetalFX derive its own exposure.
        descriptor.isAutoExposureEnabled = true

        guard let scaler = descriptor.makeTemporalScaler(device: device) else {
            throw RenderError.unavailable("MetalFX temporal upscaling is unavailable on this device")
        }
        self.scaler = scaler
        self.renderWidth = renderWidth
        self.renderHeight = renderHeight
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight

        // Reversed depth: this renderer maps the near plane to 1 and the far
        // plane to 0, and MetalFX has to be told or it reads every surface as
        // being at the opposite distance.
        scaler.isDepthReversed = true
    }

    public func matches(renderWidth: Int, renderHeight: Int, outputWidth: Int, outputHeight: Int) -> Bool {
        self.renderWidth == renderWidth && self.renderHeight == renderHeight
            && self.outputWidth == outputWidth && self.outputHeight == outputHeight
    }

    /// - Parameter jitter: the subpixel offset applied to the projection this
    ///   frame, in render pixels.
    public func encode(into commands: MTLCommandBuffer, targets: FrameTargets, jitter: SIMD2<Float>) throws {
        guard let velocity = targets.velocity, let output = targets.upscaled else {
            throw RenderError.unavailable("Temporal upscaling needs velocity and output targets")
        }
        scaler.colorTexture = targets.colour
        scaler.depthTexture = targets.depth
        scaler.motionTexture = velocity
        scaler.outputTexture = output
        scaler.inputContentWidth = targets.renderWidth
        scaler.inputContentHeight = targets.renderHeight

        // The header defines this as "the pixel offset this scaler samples to
        // return to the frame's reference frame" — the offset that undoes the
        // jitter, hence the negation.
        scaler.jitterOffsetX = -jitter.x
        scaler.jitterOffsetY = -jitter.y
        // Motion vectors are already written in render pixels.
        scaler.motionVectorScaleX = 1
        scaler.motionVectorScaleY = 1
        scaler.reset = needsReset
        needsReset = false

        scaler.encode(commandBuffer: commands)
    }
}

/// Subpixel sample positions for temporal accumulation.
///
/// Halton rather than random: it is low-discrepancy, so a short sequence covers
/// the pixel evenly instead of clustering, and it is deterministic, which is
/// what lets a golden-image test render frame N of a cold history and get the
/// same picture every time.
public struct JitterSequence {
    public let length: Int
    private var index = 0

    public init(length: Int = 16) {
        self.length = max(1, length)
    }

    static func halton(index: Int, base: Int) -> Float {
        var result: Float = 0, fraction: Float = 1, i = index
        while i > 0 {
            fraction /= Float(base)
            result += fraction * Float(i % base)
            i /= base
        }
        return result
    }

    /// Next offset, in pixels, centred on zero.
    public mutating func next() -> SIMD2<Float> {
        let offset = Self.offset(at: index, length: length)
        index += 1
        return offset
    }

    /// Offset for an explicit index, so a test can pin the phase.
    public static func offset(at index: Int, length: Int = 16) -> SIMD2<Float> {
        let i = index % max(1, length) + 1
        return SIMD2(halton(index: i, base: 2) - 0.5, halton(index: i, base: 3) - 0.5)
    }

    public mutating func reset() { index = 0 }
}
