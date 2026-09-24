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
    private let blur: MTLRenderPipelineState
    private let composite: MTLRenderPipelineState
    private let resolve: MTLRenderPipelineState
    private var traced: MTLTexture?
    private var smoothed: MTLTexture?
    /// Two resolved textures alternate: one is last frame's history, the
    /// other receives this frame's blend and becomes the next history.
    private var resolved: [MTLTexture] = []
    private var resolvedIndex = 0
    private var frameIndex: UInt32 = 0
    /// Whether the history texture holds a frame the next one may reuse.
    public private(set) var historyValid = false
    /// Whether the last encode actually blended a history in: false on a
    /// cold frame even with the reuse enabled.
    public private(set) var lastFrameReusedHistory = false

    /// Weight of the current frame in the temporal blend; zero disables
    /// the reuse. Lower is smoother and slower to follow a change.
    public var temporalWeight: Float = 0.15

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

        let blurDescriptor = MTLRenderPipelineDescriptor()
        blurDescriptor.label = "reflectionBlurFragment"
        blurDescriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        blurDescriptor.fragmentFunction = library.makeFunction(name: "reflectionBlurFragment")
        blurDescriptor.colorAttachments[0].pixelFormat = Self.format
        blur = try device.makeRenderPipelineState(descriptor: blurDescriptor)

        let resolveDescriptor = MTLRenderPipelineDescriptor()
        resolveDescriptor.label = "reflectionResolveFragment"
        resolveDescriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        resolveDescriptor.fragmentFunction = library.makeFunction(name: "reflectionResolveFragment")
        resolveDescriptor.colorAttachments[0].pixelFormat = Self.format
        resolve = try device.makeRenderPipelineState(descriptor: resolveDescriptor)

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

    public var byteCount: Int { [traced, smoothed].compactMap { $0 }.reduce(0) { $0 + $1.width * $1.height * 8 } }

    private func targets(width: Int, height: Int) -> (MTLTexture, MTLTexture)? {
        if let traced, let smoothed, traced.width == width, traced.height == height { return (traced, smoothed) }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.format, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let a = device.makeTexture(descriptor: descriptor), let b = device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        a.label = "Reflections traced"
        b.label = "Reflections smoothed"
        traced = a
        smoothed = b
        // The history pair, at the same size; a size change starts cold.
        if let h0 = device.makeTexture(descriptor: descriptor), let h1 = device.makeTexture(descriptor: descriptor) {
            h0.label = "Reflections history A"; h1.label = "Reflections history B"
            resolved = [h0, h1]
        } else {
            resolved = []
        }
        resolvedIndex = 0
        historyValid = false
        return (a, b)
    }

    @discardableResult
    public func encode(into commands: MTLCommandBuffer, targets: FrameTargets,
                       projection: simd_float4x4, view: simd_float4x4, sunDirection: SIMD3<Float>,
                       roughnessCutoff: Float, quality: RenderSettings.Quality,
                       skyView: MTLTexture,
                       viewProjection: simd_float4x4? = nil, previousViewProjection: simd_float4x4? = nil,
                       temporal: Bool = false) -> MTLTexture? {
        guard quality != .off, targets.reflections else { result = nil; historyValid = false; return nil }
        let divisor = quality == .half ? 2 : 1
        let width = max(1, targets.renderWidth / divisor), height = max(1, targets.renderHeight / divisor)
        guard let pair = self.targets(width: width, height: height) else {
            result = nil
            historyValid = false
            return nil
        }
        let (traced, smoothed) = pair
        let sunView = view * SIMD4(simd_normalize(sunDirection), 0)
        let current = viewProjection ?? (projection * view)
        let reuse = temporal && temporalWeight > 0 && historyValid && resolved.count == 2
        lastFrameReusedHistory = reuse
        var uniforms = ReflectionUniforms(
            projection: projection, inverseProjection: projection.inverse, view: view,
            sunDirectionView: SIMD4(sunView.x, sunView.y, sunView.z, 0),
            depthSize: SIMD4(Float(targets.renderWidth), Float(targets.renderHeight),
                             1 / Float(targets.renderWidth), 1 / Float(targets.renderHeight)),
            parameters: SIMD4(maxDistance, thickness, roughnessCutoff, Float(frameIndex % 64)),
            viewProjection: current, previousViewProjection: previousViewProjection ?? current,
            inverseViewProjection: current.inverse,
            temporal: SIMD4(reuse ? temporalWeight : 0, targets.velocity == nil ? 0 : 1,
                            1 / Float(targets.renderWidth), 1 / Float(targets.renderHeight)))
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

        let blurPass = MTLRenderPassDescriptor()
        blurPass.colorAttachments[0].texture = smoothed
        blurPass.colorAttachments[0].loadAction = .dontCare
        blurPass.colorAttachments[0].storeAction = .store
        if let encoder = commands.makeRenderCommandEncoder(descriptor: blurPass) {
            encoder.label = "Reflection blur"
            encoder.setRenderPipelineState(blur)
            encoder.setFragmentTexture(traced, index: 0)
            encoder.setFragmentTexture(targets.depth, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ReflectionUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        // Temporal resolve into the other of the two resolved textures; the
        // composite reads it and it becomes the next frame's history.
        var compositeSource = smoothed
        if temporal, temporalWeight > 0, resolved.count == 2 {
            let history = resolved[resolvedIndex]
            let output = resolved[1 - resolvedIndex]
            let resolvePass = MTLRenderPassDescriptor()
            resolvePass.colorAttachments[0].texture = output
            resolvePass.colorAttachments[0].loadAction = .dontCare
            resolvePass.colorAttachments[0].storeAction = .store
            if let encoder = commands.makeRenderCommandEncoder(descriptor: resolvePass) {
                encoder.label = "Reflection temporal resolve"
                encoder.setRenderPipelineState(resolve)
                encoder.setFragmentTexture(smoothed, index: 0)
                encoder.setFragmentTexture(history, index: 1)
                encoder.setFragmentTexture(targets.depth, index: 2)
                encoder.setFragmentTexture(targets.velocity ?? smoothed, index: 3)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ReflectionUniforms>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
            resolvedIndex = 1 - resolvedIndex
            compositeSource = output
            historyValid = true
        } else {
            historyValid = false
        }

        let compositePass = MTLRenderPassDescriptor()
        compositePass.colorAttachments[0].texture = targets.colour
        compositePass.colorAttachments[0].loadAction = .load
        compositePass.colorAttachments[0].storeAction = .store
        if let encoder = commands.makeRenderCommandEncoder(descriptor: compositePass) {
            encoder.label = "Reflection composite"
            encoder.setRenderPipelineState(composite)
            encoder.setFragmentTexture(compositeSource, index: 0)
            encoder.setFragmentTexture(targets.reflectionSurface, index: 1)
            encoder.setFragmentTexture(targets.depth, index: 2)
            encoder.setFragmentTexture(skyView, index: 3)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ReflectionUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        result = compositeSource
        return compositeSource
    }

    public func discard() { result = nil; historyValid = false }
    /// Restarts the noise phase and forgets the history: a verification
    /// render is one frame from a cold state, so two calls with the same
    /// inputs produce the same pixels.
    public func resetNoise() { frameIndex = 0; historyValid = false }
}

/// Mirrors `ReflectionUniforms` in `Reflections.metal`.
struct ReflectionUniforms {
    var projection: simd_float4x4
    var inverseProjection: simd_float4x4
    var view: simd_float4x4
    var sunDirectionView: SIMD4<Float>
    var depthSize: SIMD4<Float>
    var parameters: SIMD4<Float>
    var viewProjection: simd_float4x4
    var previousViewProjection: simd_float4x4
    var inverseViewProjection: simd_float4x4
    var temporal: SIMD4<Float>
}
