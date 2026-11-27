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
    /// Each cascade as seen from the first: xyz take the first cascade's
    /// clip position to this one's shadow-map uv and depth, by a scale and
    /// an offset. See `ShadowCascades.shareOrientation` for when this
    /// holds. The spare lanes are the cascade's biases, multiplied out so
    /// the shader does not do it for every pixel: the scale's w the step
    /// along the normal in metres (texel world size by the normal bias),
    /// the offset's w the depth bias in the cascade's normalized depth
    /// (bias in texels, by the texel's world size, over the depth range).
    public var cascadeScale: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    public var cascadeOffset: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)
    /// x the view distance where the last cascade starts to fade out, y the
    /// reciprocal of the distance it fades over, z the filter's radius in
    /// the map's uv, w unused.
    public var filter: SIMD4<Float>

    /// - Parameter depthBias: in shadow texels, not metres. A cascade's texel
    ///   is what sets how much depth can change between neighbouring samples,
    ///   so expressing bias relative to it makes one value correct for all four
    ///   cascades even though their texels differ by more than tenfold.
    /// - Parameter resolution: the shadow map's side in texels, which turns
    ///   the filter radius from texels into the map's uv.
    public init(cascades: [ShadowCascades.Cascade], depthBias: Float, normalBias: Float, filterRadius: Float,
                resolution: Int) {
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
        // Cascade i's clip position is the first's, scaled and moved: both
        // are orthographic views along the same light. In double precision,
        // because the first's inverse puts a point back hundreds of metres
        // out before the other brings it in again.
        func relative(_ i: Int) -> (scale: SIMD4<Float>, offset: SIMD4<Float>) {
            guard i < cascades.count, let first = cascades.first else {
                return (SIMD4(0.5, -0.5, 1, 0), SIMD4(0.5, 0.5, 0, 0))
            }
            let between = Self.double(cascades[i].viewProjection) * Self.double(first.viewProjection).inverse
            let scale = SIMD3(between.columns.0.x, between.columns.1.y, between.columns.2.z)
            let offset = SIMD3(between.columns.3.x, between.columns.3.y, between.columns.3.z)
            // And on to the map: clip x and y of -1 to 1 are u and v of 0 to
            // 1, v downward.
            return (SIMD4(Float(scale.x * 0.5), Float(scale.y * -0.5), Float(scale.z), texel(i) * normalBias),
                    SIMD4(Float(offset.x * 0.5 + 0.5), Float(offset.y * -0.5 + 0.5), Float(offset.z),
                          depthBias * texel(i) / range(i)))
        }
        let all = (0 ..< 4).map(relative)
        cascadeScale = (all[0].scale, all[1].scale, all[2].scale, all[3].scale)
        cascadeOffset = (all[0].offset, all[1].offset, all[2].offset, all[3].offset)
        // The last cascade fades out over the last 15% of its reach rather
        // than ending in a hard line.
        let last = cascades.prefix(4).last?.splitDistance ?? 0
        filter = SIMD4(last * 0.85, 1 / max(last * 0.15, 1e-3), filterRadius / Float(max(resolution, 1)), 0)
    }

    static func double(_ m: simd_float4x4) -> simd_double4x4 {
        simd_double4x4(SIMD4<Double>(m.columns.0), SIMD4<Double>(m.columns.1),
                       SIMD4<Double>(m.columns.2), SIMD4<Double>(m.columns.3))
    }
}

/// Shadow map array and its depth-only pass.
public final class ShadowRenderer {
    public let map: MTLTexture
    public let resolution: Int
    public let cascadeCount: Int
    let pipeline: MTLRenderPipelineState
    /// For foliage: the same sway as the forward vertex shader, so a tree's
    /// shadow moves with the tree.
    let swayPipeline: MTLRenderPipelineState
    let cutoutPipeline, swayCutoutPipeline: MTLRenderPipelineState
    let depthState: MTLDepthStencilState
    public let comparisonSampler: MTLSamplerState
    public private(set) var lastDrawCount = 0
    /// The cascades as last rendered into each slice. A slice not refreshed
    /// this frame keeps its depth and the matrix it was rendered with, and
    /// sampling must use that matrix, not the freshly fitted one.
    public private(set) var renderedCascades: [ShadowCascades.Cascade] = []
    /// Which slices were rendered by the last encode, for diagnostics.
    public private(set) var lastRefreshedSlices: [Int] = []
    private var frameCounter = 0

    /// `depth16Unorm` rather than `depth32Float`: an orthographic cascade has
    /// uniform depth precision, so 16 bits is ample over a few hundred metres,
    /// and it halves both the memory and the bandwidth of the pass that is
    /// about to run four times per frame.
    public static let format: MTLPixelFormat = .depth16Unorm

    public init(device: MTLDevice, library: MTLLibrary, resolution: Int, cascadeCount: Int, archive: PipelineArchive? = nil) throws {
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
        pipeline = try PipelineArchive.make(pipelineDescriptor, device: device, archive: archive)
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "shadowSwayVertex")
        swayPipeline = try PipelineArchive.make(pipelineDescriptor, device: device, archive: archive)
        pipelineDescriptor.fragmentFunction = library.makeFunction(name: "shadowCutoutFragment")
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "shadowCutoutVertex")
        cutoutPipeline = try PipelineArchive.make(pipelineDescriptor, device: device, archive: archive)
        pipelineDescriptor.vertexFunction = library.makeFunction(name: "shadowSwayCutoutVertex")
        swayCutoutPipeline = try PipelineArchive.make(pipelineDescriptor, device: device, archive: archive)

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
        // Off the map is the far plane: nothing there casts, so a point a
        // cascade does not reach comes out lit without the shader asking.
        sampler.sAddressMode = .clampToBorderColor
        sampler.tAddressMode = .clampToBorderColor
        sampler.borderColor = .opaqueWhite
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
    /// Forgets the rendered cascades so the next encode refreshes every
    /// slice: for a camera cut, or a verification render from a cold state.
    public func invalidate() {
        renderedCascades = []
        frameCounter = 0
    }

    /// Whether slice `index` is refreshed this frame at `interval`. The near
    /// cascade every frame — the car's contact with the ground lives there —
    /// the second every other frame at most, the far ones every `interval`
    /// frames, staggered so no frame refreshes them all.
    public static func refreshes(slice index: Int, frame: Int, interval: Int) -> Bool {
        guard interval > 1, index > 0 else { return true }
        let stride = index == 1 ? min(2, interval) : interval
        return (frame + index) % stride == 0
    }

    /// Renders the cascades and returns the ones to sample with: the fresh
    /// fit for slices rendered this frame, the previous fit for the rest.
    @discardableResult
    public func encode(into commands: MTLCommandBuffer, resources: [SceneResources],
                       instances: [RenderInstance], cascades: [ShadowCascades.Cascade],
                       animationTime: Float = 0, refreshInterval: Int = 1,
                       timer: PassTimer? = nil) -> [ShadowCascades.Cascade] {
        lastDrawCount = 0
        lastRefreshedSlices = []
        let fitted = Array(cascades.prefix(cascadeCount))
        // A change in the cascade count, or nothing rendered yet, is a cold
        // start. So is a sun that has moved: a slice kept from an earlier
        // frame would look along the old light, and the shader takes every
        // cascade to be the first one scaled and moved.
        let cold = renderedCascades.count != fitted.count
            || !ShadowCascades.shareOrientation(renderedCascades + fitted)
        if cold { renderedCascades = fitted }
        defer { frameCounter &+= 1 }
        for (index, cascade) in fitted.enumerated() {
            if !cold, !Self.refreshes(slice: index, frame: frameCounter, interval: refreshInterval) { continue }
            renderedCascades[index] = cascade
            lastRefreshedSlices.append(index)
            let pass = MTLRenderPassDescriptor()
            pass.depthAttachment.texture = map
            pass.depthAttachment.slice = index
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.clearDepth = 1
            pass.depthAttachment.storeAction = .store
            timer?.attach(pass, "Shadow cascade \(index)")
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

            for instance in instances {
                guard instance.castsShadow, resources.indices.contains(instance.resource) else { continue }
                let scene = resources[instance.resource]
                let isMoving = instance.transform != matrix_identity_float4x4
                for batch in scene.batches {
                    if !instance.drawsDriver && batch.isDriver { continue }
                    // Transparent surfaces do not cast. Glass casting a solid
                    // shadow is the most obvious way to make a windscreen read
                    // as painted metal.
                    if batch.isDeferred { continue }
                    if !batch.castsShadow { continue }
                    // Cull against the batch's world bounds. A moving instance
                    // carries its own transform, so its cached bounds no longer
                    // describe where it is; those are left in rather than
                    // dropped, since a car is a handful of batches and a wrong
                    // cull deletes its shadow.
                    if !isMoving,
                       !Self.intersects(cascade: cascade, centre: batch.worldCentre, radius: batch.worldRadius) { continue }
                    encoder.setVertexBuffer(batch.vertices, offset: 0, index: 0)
                    if batch.draw.maps.w & 4 != 0 {
                        encoder.setRenderPipelineState(batch.needsAlphaTest ? swayCutoutPipeline : swayPipeline)
                        var uniforms = ShadowSwayUniforms(viewProjection: cascade.viewProjection,
                                                          model: instance.transform * batch.draw.model,
                                                          time: SIMD4(animationTime, 0, 0, 0))
                        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ShadowSwayUniforms>.stride, index: 1)
                    } else {
                        encoder.setRenderPipelineState(batch.needsAlphaTest ? cutoutPipeline : pipeline)
                        var modelViewProjection = cascade.viewProjection * instance.transform * batch.draw.model
                        encoder.setVertexBytes(&modelViewProjection, length: MemoryLayout<simd_float4x4>.stride, index: 1)
                    }
                    if batch.needsAlphaTest {
                        var cutout = SIMD4(batch.draw.parameters.y, batch.draw.baseColour.w,
                                           batch.draw.parameters.z, batch.albedo == nil ? Float(0) : Float(1))
                        encoder.setFragmentBytes(&cutout, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                        encoder.setFragmentTexture(batch.albedo, index: 0)
                    }
                    encoder.drawIndexedPrimitives(type: .triangle, indexCount: batch.indexCount,
                                                  indexType: .uint32, indexBuffer: batch.indices,
                                                  indexBufferOffset: 0)
                    lastDrawCount += 1
                }
            }
            encoder.endEncoding()
        }
        return renderedCascades
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

/// Mirrors `ShadowSwayUniforms` in `Shadow.metal`.
struct ShadowSwayUniforms {
    var viewProjection: simd_float4x4
    var model: simd_float4x4
    var time: SIMD4<Float>
}
