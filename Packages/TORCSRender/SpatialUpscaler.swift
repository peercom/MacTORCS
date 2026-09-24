// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Metal
import MetalFX

/// MetalFX spatial upscaling: a single-frame scaler with no history, no
/// jitter and no motion vectors.
///
/// The temporal scaler measured as a net loss on this GPU because its fixed
/// cost at 2560x1664 exceeds what a half-resolution render saves. The spatial
/// scaler is a fraction of that cost at lower quality — a sharpening
/// upsample rather than a reconstruction — and so is the fallback when
/// native cannot hold the frame sustained.
public final class SpatialUpscaler {
    private let scaler: MTLFXSpatialScaler
    public let renderWidth: Int, renderHeight: Int
    public let outputWidth: Int, outputHeight: Int

    public init(device: MTLDevice, renderWidth: Int, renderHeight: Int,
                outputWidth: Int, outputHeight: Int) throws {
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = renderWidth
        descriptor.inputHeight = renderHeight
        descriptor.outputWidth = outputWidth
        descriptor.outputHeight = outputHeight
        descriptor.colorTextureFormat = FrameTargets.colourFormat
        descriptor.outputTextureFormat = FrameTargets.colourFormat
        // The scene target is linear radiance; the tonemapper runs after.
        descriptor.colorProcessingMode = .linear
        guard let scaler = descriptor.makeSpatialScaler(device: device) else {
            throw RenderError.unavailable("MetalFX spatial upscaling is unavailable on this device")
        }
        self.scaler = scaler
        self.renderWidth = renderWidth
        self.renderHeight = renderHeight
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
    }

    public func matches(renderWidth: Int, renderHeight: Int, outputWidth: Int, outputHeight: Int) -> Bool {
        self.renderWidth == renderWidth && self.renderHeight == renderHeight
            && self.outputWidth == outputWidth && self.outputHeight == outputHeight
    }

    /// - Parameter source: the render-resolution image to scale; the scene
    ///   colour, or the motion-blurred copy of it.
    public func encode(into commands: MTLCommandBuffer, targets: FrameTargets, source: MTLTexture? = nil) throws {
        guard let output = targets.upscaled else {
            throw RenderError.unavailable("Spatial upscaling needs an output target")
        }
        scaler.colorTexture = source ?? targets.colour
        scaler.outputTexture = output
        scaler.inputContentWidth = targets.renderWidth
        scaler.inputContentHeight = targets.renderHeight
        scaler.encode(commandBuffer: commands)
    }
}
