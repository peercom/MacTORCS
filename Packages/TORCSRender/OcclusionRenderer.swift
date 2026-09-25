// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Metal
import simd

/// Screen-space ambient occlusion and contact shadows from the depth prepass.
///
/// Produces one `rg8Unorm` texture at render resolution: red is the fraction
/// of the sky hemisphere visible from the pixel, green the fraction of the sun
/// visible over the first few decimetres toward it. The forward pass multiplies
/// its ambient and sun terms by them. Both come from the same depth fetches,
/// so one pass computes both; the blur that follows is what makes the per-pixel
/// rotation noise invisible.
public final class OcclusionRenderer {
    public static let format: MTLPixelFormat = .rg8Unorm

    private let device: MTLDevice
    private let occlusion: MTLRenderPipelineState
    private let blur: MTLRenderPipelineState
    private var raw: MTLTexture?
    private var smoothed: MTLTexture?
    /// Advances every frame to rotate the noise pattern, so a temporal history
    /// averages it rather than accumulating one fixed pattern.
    private var frameIndex: UInt32 = 0
    /// The rotation phase the next encode will use.
    public var noisePhase: UInt32 { frameIndex }

    /// World radius the ambient term searches for occluders, in metres. Cars
    /// and barriers are metre-scale; a much larger radius darkens whole valleys
    /// and starts to read as a lighting change rather than occlusion.
    public var ambientRadius: Float = 1.2
    /// How far toward the sun the contact ray marches, in metres. Enough to
    /// bridge a tyre to the tarmac and a car to a wall; a longer ray takes
    /// over work the cascades already do, at screen-space quality.
    public var contactLength: Float = 0.35
    /// Depth difference beyond which an occluder is assumed thin and passed
    /// behind, rather than a wall the ray is inside. Small: at half a metre
    /// the whole side of a car shadowed itself wherever the ray went behind
    /// the body.
    public var contactThickness: Float = 0.08
    /// Exponent on ambient visibility. One is the unshaped integral; two
    /// reads as occlusion rather than a faint tint.
    public var ambientPower: Float = 2.0

    /// The texture the forward pass should sample, valid until the next encode.
    public private(set) var result: MTLTexture?

    public init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        func pipeline(_ fragment: String) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = fragment
            descriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = Self.format
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        occlusion = try pipeline("occlusionFragment")
        blur = try pipeline("occlusionBlurFragment")
    }

    public var byteCount: Int {
        [raw, smoothed].compactMap { $0 }.reduce(0) { $0 + $1.width * $1.height * 2 }
    }

    private func targets(width: Int, height: Int) -> (MTLTexture, MTLTexture)? {
        if let raw, let smoothed, raw.width == width, raw.height == height {
            return (raw, smoothed)
        }
        let descriptor = MTLTextureDescriptor()
        descriptor.pixelFormat = Self.format
        descriptor.width = width
        descriptor.height = height
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let a = device.makeTexture(descriptor: descriptor),
              let b = device.makeTexture(descriptor: descriptor) else { return nil }
        a.label = "Occlusion raw"
        b.label = "Occlusion smoothed"
        raw = a
        smoothed = b
        return (a, b)
    }

    /// Computes occlusion from `depth`, which must already hold the frame's
    /// opaque depth. Returns nil (and clears `result`) when nothing was asked
    /// for or a target could not be allocated.
    @discardableResult
    public func encode(into commands: MTLCommandBuffer, depth: MTLTexture,
                       projection: simd_float4x4, view: simd_float4x4,
                       sunDirection: SIMD3<Float>, ambient: RenderSettings.Quality, contact: Bool) -> MTLTexture? {
        // Half resolution only when the ambient term asks for it: the noise is
        // blurred anyway, and the bilinear sample in the forward pass hides
        // the rest. Contact shadows on their own stay at full resolution —
        // keying this on `.full` made the contact edges change with the AO
        // setting, which showed up as pixels brightening when AO was enabled.
        let divisor = ambient.divisor
        guard ambient != .off || contact,
              let pair = targets(width: max(1, depth.width / divisor), height: max(1, depth.height / divisor)) else {
            result = nil
            return nil
        }
        let (raw, smoothed) = pair
        let sunView = view * SIMD4(simd_normalize(sunDirection), 0)
        var uniforms = OcclusionUniforms(
            projection: projection,
            inverseProjection: projection.inverse,
            sunDirectionView: SIMD4(sunView.x, sunView.y, sunView.z, 0),
            parameters: SIMD4(ambientRadius, contactLength, contactThickness, Float(frameIndex % 64)),
            depthSize: SIMD4(Float(depth.width), Float(depth.height),
                             1 / Float(depth.width), 1 / Float(depth.height)),
            shaping: SIMD4(ambientPower, 0, 0, 0))
        var features: UInt32 = (ambient != .off ? 1 : 0) | (contact ? 2 : 0)
        frameIndex &+= 1

        func pass(_ label: String, into destination: MTLTexture, state: MTLRenderPipelineState,
                  bind: (MTLRenderCommandEncoder) -> Void) {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = destination
            descriptor.colorAttachments[0].loadAction = .dontCare
            descriptor.colorAttachments[0].storeAction = .store
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            encoder.label = label
            encoder.setRenderPipelineState(state)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<OcclusionUniforms>.stride, index: 0)
            bind(encoder)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        pass("Screen-space occlusion", into: raw, state: occlusion) { encoder in
            encoder.setFragmentTexture(depth, index: 0)
            encoder.setFragmentBytes(&features, length: MemoryLayout<UInt32>.stride, index: 1)
        }
        pass("Occlusion blur", into: smoothed, state: blur) { encoder in
            encoder.setFragmentTexture(raw, index: 0)
            encoder.setFragmentTexture(depth, index: 1)
        }
        result = smoothed
        return smoothed
    }

    /// Drops the result so a frame with the pass disabled cannot sample last
    /// frame's occlusion. Targets are kept for when it is re-enabled.
    public func discard() { result = nil }

    /// Returns the noise rotation to its first phase, so a verification render
    /// is repeatable. Interactive frames never call this.
    public func resetNoise() { frameIndex = 0 }
}

/// Mirrors `OcclusionUniforms` in `Occlusion.metal`. All fields 16-byte
/// aligned, for the same reason as `FrameUniforms`.
struct OcclusionUniforms {
    var projection: simd_float4x4
    var inverseProjection: simd_float4x4
    var sunDirectionView: SIMD4<Float>
    var parameters: SIMD4<Float>
    var depthSize: SIMD4<Float>
    var shaping: SIMD4<Float>
}
