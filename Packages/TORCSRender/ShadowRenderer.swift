// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Metal
import simd

/// Mirrors `ShadowUniforms` in `Shaders/Shadow.metal`.
public struct ShadowUniforms {
    public var cascadeViewProjection: (simd_float4x4, simd_float4x4, simd_float4x4, simd_float4x4)
    public var splitDistances: SIMD4<Float>
    public var texelWorldSizes: SIMD4<Float>
    /// Metres per unit of normalized depth, per cascade.
    public var depthRanges: SIMD4<Float>
    /// x cascade count, y depth bias in shadow texels, z normal bias scale, w filter radius in texels.
    public var parameters: SIMD4<Float>

    /// - Parameter depthBias: in shadow texels, not metres. A cascade's texel
    ///   is what sets how much depth can change between neighbouring samples,
    ///   so expressing bias relative to it makes one value correct for all four
    ///   cascades even though their texels differ by more than tenfold.
    public init(cascades: [ShadowCascades.Cascade], depthBias: Float, normalBias: Float, filterRadius: Float) {
        func matrix(_ i: Int) -> simd_float4x4 {
            i < cascades.count ? cascades[i].viewProjection : matrix_identity_float4x4
        }
        cascadeViewProjection = (matrix(0), matrix(1), matrix(2), matrix(3))
        func split(_ i: Int) -> Float { i < cascades.count ? cascades[i].splitDistance : .greatestFiniteMagnitude }
        func texel(_ i: Int) -> Float { i < cascades.count ? cascades[i].texelWorldSize : 1 }
        splitDistances = SIMD4(split(0), split(1), split(2), split(3))
        texelWorldSizes = SIMD4(texel(0), texel(1), texel(2), texel(3))
        func range(_ i: Int) -> Float { i < cascades.count ? max(cascades[i].depthRange, 1e-3) : 1 }
        depthRanges = SIMD4(range(0), range(1), range(2), range(3))
        parameters = SIMD4(Float(min(cascades.count, 4)), depthBias, normalBias, filterRadius)
    }
}

/// Shadow map array and its depth-only pass.
public final class ShadowRenderer {
    public let map: MTLTexture
    public let resolution: Int
    public let cascadeCount: Int
    let pipeline: MTLRenderPipelineState
    let depthState: MTLDepthStencilState
    public let comparisonSampler: MTLSamplerState
    public private(set) var lastDrawCount = 0

    /// `depth16Unorm` rather than `depth32Float`: an orthographic cascade has
    /// uniform depth precision, so 16 bits is ample over a few hundred metres,
    /// and it halves both the memory and the bandwidth of the pass that is
    /// about to run four times per frame.
    public static let format: MTLPixelFormat = .depth16Unorm

    public init(device: MTLDevice, library: MTLLibrary, resolution: Int, cascadeCount: Int) throws {
        self.resolution = max(256, resolution)
        self.cascadeCount = max(1, min(cascadeCount, 4))

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = Self.format
        descriptor.width = self.resolution
        descriptor.height = self.resolution
        descriptor.arrayLength = self.cascadeCount
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        guard let map = device.makeTexture(descriptor: descriptor) else {
            throw RenderError.unavailable("Could not allocate a \(self.resolution) shadow map array")
        }
        self.map = map

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "shadowVertex")
        // No fragment function: depth only, which is the cheapest this pass can be.
        pipelineDescriptor.fragmentFunction = nil
        pipelineDescriptor.depthAttachmentPixelFormat = Self.format
        pipelineDescriptor.rasterSampleCount = 1
        pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

        let depth = MTLDepthStencilDescriptor()
        depth.depthCompareFunction = .lessEqual
        depth.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depth) else {
            throw RenderError.unavailable("Could not create the shadow depth state")
        }
        self.depthState = depthState

        let sampler = MTLSamplerDescriptor()
        sampler.minFilter = .linear
        sampler.magFilter = .linear
        sampler.sAddressMode = .clampToEdge
        sampler.tAddressMode = .clampToEdge
        // Hardware comparison gives a free 2x2 percentage-closer result per tap.
        sampler.compareFunction = .lessEqual
        guard let comparisonSampler = device.makeSamplerState(descriptor: sampler) else {
            throw RenderError.unavailable("Could not create the shadow comparison sampler")
        }
        self.comparisonSampler = comparisonSampler
    }

    /// Renders every cascade.
    ///
    /// Batches are culled per cascade against the cascade's world-space bounds.
    /// Without it the whole scene is submitted four extra times, which on a
    /// 1,315-batch track costs far more than the shadows are worth.
    public func encode(into commands: MTLCommandBuffer, scene: SceneResources, cascades: [ShadowCascades.Cascade]) {
        lastDrawCount = 0
        for (index, cascade) in cascades.prefix(cascadeCount).enumerated() {
            let pass = MTLRenderPassDescriptor()
            pass.depthAttachment.texture = map
            pass.depthAttachment.slice = index
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = 1
            pass.depthAttachment.storeAction = .store
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { continue }
            encoder.label = "Shadow cascade \(index)"
            encoder.setRenderPipelineState(pipeline)
            encoder.setDepthStencilState(depthState)
            // No culling. Front-face culling is the usual acne remedy, but it
            // assumes closed geometry: a car's panels, barriers and foliage
            // cards are open surfaces, and culling their front faces leaves
            // only back faces in the map, which is what produced the mottling
            // on the body. Bias handles acne instead.
            encoder.setCullMode(.none)
            encoder.setFrontFacing(.counterClockwise)
            // Hardware slope-scaled depth bias, applied while the map is being
            // written. This is the right place for it: the hardware knows each
            // triangle's actual depth gradient, which a constant applied at
            // sample time can only approximate. Clamped so near-edge-on
            // polygons cannot push their shadow arbitrarily far away.
            encoder.setDepthBias(2.0, slopeScale: 3.0, clamp: 0.01)

            for batch in scene.batches {
                guard Self.intersects(cascade: cascade, centre: batch.worldCentre, radius: batch.worldRadius) else { continue }
                var modelViewProjection = cascade.viewProjection * batch.draw.model
                encoder.setVertexBuffer(batch.vertices, offset: 0, index: 0)
                encoder.setVertexBytes(&modelViewProjection, length: MemoryLayout<simd_float4x4>.stride, index: 1)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: batch.indexCount,
                                              indexType: .uint32, indexBuffer: batch.indices,
                                              indexBufferOffset: 0)
                lastDrawCount += 1
            }
            encoder.endEncoding()
        }
    }

    /// Bounding-sphere test against the cascade's clip volume.
    ///
    /// Only x and y are tested. A caster behind the cascade's near plane still
    /// has to be drawn — it is exactly what casts into the slice — so clipping
    /// on depth here would delete the shadows this pass exists to create.
    static func intersects(cascade: ShadowCascades.Cascade, centre: SIMD3<Float>, radius: Float) -> Bool {
        let clip = cascade.viewProjection * SIMD4(centre, 1)
        guard clip.w != 0 else { return true }
        // The projection is orthographic, so world radius scales linearly.
        let scaleX = simd_length(SIMD3(cascade.viewProjection.columns.0.x,
                                       cascade.viewProjection.columns.1.x,
                                       cascade.viewProjection.columns.2.x))
        let scaleY = simd_length(SIMD3(cascade.viewProjection.columns.0.y,
                                       cascade.viewProjection.columns.1.y,
                                       cascade.viewProjection.columns.2.y))
        let marginX = radius * scaleX, marginY = radius * scaleY
        return abs(clip.x) <= 1 + marginX && abs(clip.y) <= 1 + marginY && clip.z <= 1 + radius * scaleX
    }
}
