// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Metal
import simd

/// Per-pixel motion blur from the velocity buffer, applied after the
/// upscaler and before bloom so both the glow and the tonemapper see the
/// blurred image.
///
/// Reads the tonemap source and writes `FrameTargets.postColour`; the
/// tonemap source then becomes that texture. One gather along the centre
/// pixel's velocity, jittered to avoid banding.
public final class MotionBlurRenderer {
    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState

    /// Fraction of the frame interval the shutter is open. Half is the film
    /// convention (a 180° shutter) and reads as motion without smearing the
    /// frame into soup.
    public var shutter: Float = 0.5
    /// Longest blur, as a fraction of the output height. Wheels and close
    /// barriers can exceed a whole frame of motion; past this they smear
    /// into mush rather than read faster.
    public var maximumRadius: Float = 0.03
    public var taps: Int = 8

    public private(set) var result: MTLTexture?

    public init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "motionBlurFragment"
        descriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "motionBlurFragment")
        descriptor.colorAttachments[0].pixelFormat = FrameTargets.colourFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Blurs `source` (at the output resolution) by `velocity` (at the render
    /// resolution) into `targets.postColour`. Returns nil, and clears
    /// `result`, when the targets carry no velocity or post texture.
    @discardableResult
    public func encode(into commands: MTLCommandBuffer, targets: FrameTargets, source: MTLTexture) -> MTLTexture? {
        guard let velocity = targets.velocity, let destination = targets.postColour else {
            result = nil
            return nil
        }
        var uniforms = MotionBlurUniforms(
            parameters: SIMD4(1 / Float(destination.width), 1 / Float(destination.height),
                              shutter, maximumRadius * Float(destination.height)),
            scale: SIMD4(Float(destination.width) / Float(velocity.width),
                         Float(destination.height) / Float(velocity.height), Float(taps), 0))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { result = nil; return nil }
        encoder.label = "Motion blur"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentTexture(velocity, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<MotionBlurUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        result = destination
        return destination
    }

    public func discard() { result = nil }
}

/// Mirrors `MotionBlurUniforms` in `MotionBlur.metal`.
struct MotionBlurUniforms {
    var parameters: SIMD4<Float>
    var scale: SIMD4<Float>
}
