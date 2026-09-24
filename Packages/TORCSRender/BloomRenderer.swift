// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Metal

/// Bloom over a pyramid of progressively halved targets.
///
/// The chain is built from the tonemapper's input, so it works on linear
/// radiance rather than display values: what spreads is the light that was
/// actually bright, not the pixels that happened to survive tonemapping. That
/// ordering is why bloom belongs before the resolve and after the upscaler.
public final class BloomRenderer {
    /// One level per halving. Separate textures rather than mip levels of one
    /// texture: the upsample reads level *i* while blending into level *i−1*,
    /// and a texture cannot be sampled and used as an attachment in the same
    /// pass.
    final class Chain {
        let levels: [MTLTexture]
        let sourceWidth: Int, sourceHeight: Int

        init(device: MTLDevice, width: Int, height: Int) throws {
            sourceWidth = width
            sourceHeight = height
            var built: [MTLTexture] = []
            // The first level is a quarter of the source on each axis (see
            // bloomPrefilter); every level after it halves.
            var w = width / 2, h = height / 2
            // Stops at 8 px rather than 1: the last few levels contribute a
            // nearly uniform wash and cost a pass each.
            while built.count < Chain.maximumLevels {
                w = max(1, w / 2)
                h = max(1, h / 2)
                if w < 8 || h < 8 { break }
                let descriptor = MTLTextureDescriptor()
                descriptor.pixelFormat = FrameTargets.colourFormat
                descriptor.width = w
                descriptor.height = h
                descriptor.usage = [.renderTarget, .shaderRead]
                descriptor.storageMode = .private
                guard let texture = device.makeTexture(descriptor: descriptor) else {
                    throw RenderError.unavailable("Could not allocate a \(w)x\(h) bloom level")
                }
                texture.label = "Bloom level \(built.count)"
                built.append(texture)
            }
            levels = built
        }

        static let maximumLevels = 6

        func matches(width: Int, height: Int) -> Bool {
            sourceWidth == width && sourceHeight == height
        }

        var byteCount: Int {
            levels.reduce(0) { $0 + $1.width * $1.height * 8 }
        }
    }

    private let device: MTLDevice
    private let prefilter: MTLRenderPipelineState
    private let downsample: MTLRenderPipelineState
    /// Additive: each upsample adds its blur into the level above rather than
    /// replacing it, which is what accumulates the pyramid into one wide kernel.
    private let upsample: MTLRenderPipelineState
    private var chain: Chain?

    public init(device: MTLDevice, library: MTLLibrary) throws {
        self.device = device

        func pipeline(_ fragment: String, blending: Bool) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = fragment
            descriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = FrameTargets.colourFormat
            if blending {
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .one
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        prefilter = try pipeline("bloomPrefilter", blending: false)
        downsample = try pipeline("bloomDownsample", blending: false)
        upsample = try pipeline("bloomUpsample", blending: true)
    }

    /// The texture the resolve should read, valid until the next `encode`.
    public internal(set) var result: MTLTexture?

    public var byteCount: Int { chain?.byteCount ?? 0 }
    /// Number of halvings in the current pyramid; zero until the first encode.
    public var levelCount: Int { chain?.levels.count ?? 0 }

    /// Builds the pyramid from `source`. Returns nil when the source is too
    /// small to halve usefully, in which case the resolve skips bloom entirely
    /// rather than compositing a meaningless single level.
    @discardableResult
    public func encode(into commands: MTLCommandBuffer, source: MTLTexture,
                       threshold: Float, exposureScale: Float) -> MTLTexture? {
        if chain?.matches(width: source.width, height: source.height) != true {
            chain = try? Chain(device: device, width: source.width, height: source.height)
        }
        guard let chain, chain.levels.count >= 2 else {
            result = nil
            return nil
        }

        func pass(_ label: String, into destination: MTLTexture, load: MTLLoadAction,
                  state: MTLRenderPipelineState, reading input: MTLTexture) {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = destination
            descriptor.colorAttachments[0].loadAction = load
            descriptor.colorAttachments[0].storeAction = .store
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            encoder.label = label
            encoder.setRenderPipelineState(state)
            encoder.setFragmentTexture(input, index: 0)
            // Texel size of the *input*: every filter here samples its source,
            // so offsets are in source texels, not destination texels.
            var uniforms = BloomUniforms(parameters: SIMD4<Float>(1 / Float(input.width),
                                                                 1 / Float(input.height),
                                                                 threshold, exposureScale))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BloomUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        pass("Bloom prefilter", into: chain.levels[0], load: .dontCare,
             state: prefilter, reading: source)
        for level in 1..<chain.levels.count {
            pass("Bloom downsample \(level)", into: chain.levels[level], load: .dontCare,
                 state: downsample, reading: chain.levels[level - 1])
        }
        // Upward, adding each level into the one above. `.load` rather than
        // `.dontCare` because the additive blend needs what is already there.
        for level in stride(from: chain.levels.count - 1, to: 0, by: -1) {
            pass("Bloom upsample \(level)", into: chain.levels[level - 1], load: .load,
                 state: upsample, reading: chain.levels[level])
        }

        result = chain.levels[0]
        return chain.levels[0]
    }
}

/// Matches `BloomUniforms` in `Bloom.metal`.
struct BloomUniforms {
    var parameters: SIMD4<Float>
}

extension BloomRenderer {
    /// Drops the pyramid so a frame with bloom disabled cannot composite last
    /// frame's glow. The textures are kept: toggling the setting should not
    /// reallocate.
    public func discard() { result = nil }
}
