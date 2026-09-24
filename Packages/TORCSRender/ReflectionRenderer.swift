// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Metal
import simd

/// Screen-space reflections: a march through the depth buffer for the sharp
/// white lobe, and an additive composite that swaps the sky probe for what
/// the march found.
///
/// Runs after the opaque and transparent draws, since it reads the finished
/// scene colour, and before the upscaler and bloom, which should see the
/// reflections. The composite adds `confidence · weight · (found − probe)`
/// onto the colour target with one/one blending: no second colour texture,
/// and a probe that overstated the reflection is taken back exactly.
public final class ReflectionRenderer {
    public static let format: MTLPixelFormat = .rgba16Float

    private let device: MTLDevice
    private let trace: MTLRenderPipelineState
    private let composite: MTLRenderPipelineState
    private var traced: MTLTexture?
    private var frameIndex: UInt32 = 0

    /// How far a ray is followed, in metres. Beyond this the probe is close
    /// enough, and the march's cost is linear in it.
    public var maxDistance: Float = 60
    /// Depth gap above which a ray is behind something thin rather than
    /// inside a surface. Small: at 0.6 m every wheel arch a ray passed behind
    /// counted as a hit and the car reflected itself. Grows with distance in
    /// the shader.
    public var thickness: Float = 0.15

    public private(set) var result: MTLTexture?
    public var noisePhase: UInt32 { frameIndex }

    public init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device
        let traceDescriptor = MTLRenderPipelineDescriptor()
        traceDescriptor.label = "reflectionFragment"
        traceDescriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        traceDescriptor.fragmentFunction = library.makeFunction(name: "reflectionFragment")
        traceDescriptor.colorAttachments[0].pixelFormat = Self.format
        trace = try device.makeRenderPipelineState(descriptor: traceDescriptor)

        let compositeDescriptor = MTLRenderPipelineDescriptor()
        compositeDescriptor.label = "reflectionCompositeFragment"
        compositeDescriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        compositeDescriptor.fragmentFunction = library.makeFunction(name: "reflectionCompositeFragment")
        let attachment = compositeDescriptor.colorAttachments[0]!
        attachment.pixelFormat = FrameTargets.colourFormat
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .one
        attachment.alphaBlendOperation = .add
        attachment.sourceAlphaBlendFactor = .zero
        attachment.destinationAlphaBlendFactor = .one
        composite = try device.makeRenderPipelineState(descriptor: compositeDescriptor)
    }

    public var byteCount: Int { traced.map { $0.width * $0.height * 8 } ?? 0 }

    private func target(width: Int, height: Int) -> MTLTexture? {
        if let traced, traced.width == width, traced.height == height { return traced }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.format, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)
        texture?.label = "Reflections traced"
        traced = texture
        return texture
    }

    @discardableResult
    public func encode(into commands: MTLCommandBuffer, targets: FrameTargets,
                       projection: simd_float4x4, view: simd_float4x4, sunDirection: SIMD3<Float>,
                       roughnessCutoff: Float, quality: RenderSettings.Quality,
                       skyView: MTLTexture) -> MTLTexture? {
        guard quality != .off, targets.reflections else { result = nil; return nil }
        let divisor = quality == .half ? 2 : 1
        guard let traced = target(width: max(1, targets.renderWidth / divisor),
                                  height: max(1, targets.renderHeight / divisor)) else {
            result = nil
            return nil
        }
        let sunView = view * SIMD4(simd_normalize(sunDirection), 0)
        var uniforms = ReflectionUniforms(
            projection: projection, inverseProjection: projection.inverse, view: view,
            sunDirectionView: SIMD4(sunView.x, sunView.y, sunView.z, 0),
            depthSize: SIMD4(Float(targets.renderWidth), Float(targets.renderHeight),
                             1 / Float(targets.renderWidth), 1 / Float(targets.renderHeight)),
            parameters: SIMD4(maxDistance, thickness, roughnessCutoff, Float(frameIndex % 64)))
        frameIndex &+= 1

        let tracePass = MTLRenderPassDescriptor()
        tracePass.colorAttachments[0].texture = traced
        tracePass.colorAttachments[0].loadAction = .dontCare
        tracePass.colorAttachments[0].storeAction = .store
        if let encoder = commands.makeRenderCommandEncoder(descriptor: tracePass) {
            encoder.label = "Screen-space reflections"
            encoder.setRenderPipelineState(trace)
            encoder.setFragmentTexture(targets.depth, index: 0)
            encoder.setFragmentTexture(targets.reflectionSurface, index: 1)
            encoder.setFragmentTexture(targets.colour, index: 2)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ReflectionUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        let compositePass = MTLRenderPassDescriptor()
        compositePass.colorAttachments[0].texture = targets.colour
        compositePass.colorAttachments[0].loadAction = .load
        compositePass.colorAttachments[0].storeAction = .store
        if let encoder = commands.makeRenderCommandEncoder(descriptor: compositePass) {
            encoder.label = "Reflection composite"
            encoder.setRenderPipelineState(composite)
            encoder.setFragmentTexture(traced, index: 0)
            encoder.setFragmentTexture(targets.reflectionSurface, index: 1)
            encoder.setFragmentTexture(targets.depth, index: 2)
            encoder.setFragmentTexture(skyView, index: 3)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ReflectionUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        result = traced
        return traced
    }

    public func discard() { result = nil }
    public func resetNoise() { frameIndex = 0 }
}

/// Mirrors `ReflectionUniforms` in `Reflections.metal`.
struct ReflectionUniforms {
    var projection: simd_float4x4
    var inverseProjection: simd_float4x4
    var view: simd_float4x4
    var sunDirectionView: SIMD4<Float>
    var depthSize: SIMD4<Float>
    var parameters: SIMD4<Float>
}
