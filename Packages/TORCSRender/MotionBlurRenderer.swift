// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Metal
import simd

/// Per-pixel motion blur from the velocity buffer: its settings, the
/// half-resolution copy of the scene its long streaks are gathered from, and
/// the uniforms the tonemap pass reads the scene through.
///
/// The blur itself is not a pass. One gather along the centre pixel's
/// velocity, jittered to avoid banding, taken by the resolve as it samples
/// the scene (see MotionBlur.metal); a pass of its own wrote a second
/// scene-sized HDR target only for the resolve to read it back. The bloom
/// and the lens blur are therefore built from the unblurred scene, which at
/// their widths cannot be told apart.
public final class MotionBlurRenderer {
    private let device: MTLDevice
    private let halve: MTLRenderPipelineState
    private var half: MTLTexture?

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
    /// Streak lengths, in scene pixels, between which the gather moves from
    /// the scene to its half-resolution copy. Below the first a copy at
    /// half size would soften more than the motion does.
    public var halfResolutionStreak: ClosedRange<Float> = 4 ... 8
    /// Whether the long streaks use the half-resolution copy at all. Off,
    /// no copy is made and every streak is gathered from the scene.
    public var usesHalfResolution = true

    /// The half-resolution copy made for this frame, or nil when there is
    /// none: blur off, or the copy could not be allocated. Then every
    /// streak is gathered from the scene itself.
    public private(set) var halfScene: MTLTexture?

    public init(device: MTLDevice, library: MTLLibrary, archive: PipelineArchive? = nil) throws {
        self.device = device
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "sceneHalveFragment"
        descriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "sceneHalveFragment")
        descriptor.colorAttachments[0].pixelFormat = FrameTargets.colourFormat
        halve = try PipelineArchive.make(descriptor, device: device, archive: archive)
    }

    /// Copies `scene`, the texture the resolve will tonemap, to half its
    /// size each way for the long streaks.
    @discardableResult
    public func encodeHalf(into commands: MTLCommandBuffer, scene: MTLTexture, timer: PassTimer? = nil) -> MTLTexture? {
        halfScene = nil
        guard usesHalfResolution else { return nil }
        let width = max(1, scene.width / 2), height = max(1, scene.height / 2)
        if half?.width != width || half?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: FrameTargets.colourFormat,
                                                                      width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            half = device.makeTexture(descriptor: descriptor)
            half?.label = "Scene at half resolution"
        }
        guard let half else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = half
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        timer?.attach(pass, "Scene half")
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.label = "Scene half"
        encoder.setRenderPipelineState(halve)
        encoder.setFragmentTexture(scene, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        halfScene = half
        return half
    }

    public func discard() { halfScene = nil }

    /// Bytes the half-resolution copy occupies, for the memory budget.
    public var byteCount: Int { half.map { $0.width * $0.height * 8 } ?? 0 }

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
            scale: SIMD4(ratio.x, ratio.y, velocity == nil ? 0 : Float(taps), smaller ? 1 : 0),
            half: SIMD4(velocity != nil && halfScene != nil ? 1 : 0,
                        halfResolutionStreak.lowerBound, halfResolutionStreak.upperBound, 0))
    }
}

/// Mirrors `MotionBlurUniforms` in `MotionBlur.metal`.
struct MotionBlurUniforms {
    var parameters: SIMD4<Float>
    var scale: SIMD4<Float>
    var half: SIMD4<Float>
}
