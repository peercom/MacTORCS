// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Metal
import simd
import TORCSMath
import TORCSAssets

/// GPU buffers for one flattened scene, built once at load.
///
/// `MetalTextureUpload` in the classic package carried the same rule and it
/// still holds: prepare everything during content loading, never inside the
/// draw loop.
public final class SceneResources {
    struct Batch {
        let vertices: MTLBuffer
        let indices: MTLBuffer
        let indexCount: Int
        let draw: DrawUniforms
        let needsAlphaTest: Bool
        let culls: Bool
        let isDriver: Bool
        let isTranslucent: Bool
        let albedo: MTLTexture?
        /// World-space bounds for shadow cascade culling.
        let worldCentre: SIMD3<Float>
        let worldRadius: Float
    }

    let batches: [Batch]
    public let minimum: SIMD3<Float>, maximum: SIMD3<Float>
    public var triangleCount: Int { batches.reduce(0) { $0 + $1.indexCount / 3 } }
    public private(set) var bufferBytes = 0
    public private(set) var texturedBatches = 0
    /// Number of drawable batches, for diagnostics and budget reporting.
    public var batchCount: Int { batches.count }

    public init(device: MTLDevice, scene: RenderScene, textures: TextureStore? = nil) throws {
        var built: [Batch] = []
        var bytes = 0
        for batch in scene.batches {
            guard !batch.mesh.vertices.isEmpty, !batch.mesh.indices.isEmpty else { continue }
            let vertexLength = batch.mesh.vertices.count * MemoryLayout<PackedVertex>.stride
            let indexLength = batch.mesh.indices.count * MemoryLayout<UInt32>.stride
            guard let vertices = batch.mesh.vertices.withUnsafeBytes({
                      device.makeBuffer(bytes: $0.baseAddress!, length: vertexLength, options: .storageModeShared) }),
                  let indices = batch.mesh.indices.withUnsafeBytes({
                      device.makeBuffer(bytes: $0.baseAddress!, length: indexLength, options: .storageModeShared) })
            else { throw RenderError.unavailable("Could not allocate geometry buffers") }
            bytes += vertexLength + indexLength

            // Transform the local bounding sphere into world space. Scale can
            // be non-uniform, so take the largest axis scale.
            let transform = batch.mesh.transform
            let centre4 = transform * SIMD4(batch.mesh.center, 1)
            let worldCentre = SIMD3(centre4.x, centre4.y, centre4.z)
            let scale = max(simd_length(SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)),
                        max(simd_length(SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)),
                            simd_length(SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))))
            let worldRadius = batch.mesh.radius * max(scale, 1e-4)

            let material = batch.material
            // Only bind a base map when one actually resolved: a missing
            // texture must read as an obvious untextured surface, never as a
            // silently substituted stand-in.
            let albedo = batch.baseTexture.flatMap {
                textures?.albedo(named: $0, isCutout: batch.alphaTestThreshold != nil)
            }
            built.append(Batch(
                vertices: vertices, indices: indices, indexCount: batch.mesh.indices.count,
                draw: DrawUniforms(model: batch.mesh.transform,
                                   baseColour: material.baseColour,
                                   roughness: material.roughness,
                                   metallic: material.metallic,
                                   clearcoat: material.clearcoat,
                                   clearcoatRoughness: material.clearcoatRoughness,
                                   normalStrength: material.normalStrength,
                                   alphaThreshold: batch.alphaTestThreshold ?? 0,
                                   maps: SIMD4(albedo == nil ? 0 : 1, 0, 0, 0)),
                needsAlphaTest: batch.alphaTestThreshold != nil,
                culls: batch.culls,
                isDriver: batch.isDriver,
                isTranslucent: batch.isTranslucent,
                albedo: albedo,
                worldCentre: worldCentre,
                worldRadius: worldRadius))
        }
        guard !built.isEmpty else { throw RenderError.unavailable("Scene has no drawable batches") }
        batches = built
        texturedBatches = built.filter { $0.albedo != nil }.count
        bufferBytes = bytes
        minimum = scene.minimum
        maximum = scene.maximum
    }
}

/// Linear-HDR forward renderer.
///
/// Two passes for now: forward opaque into an `rgba16Float` target, then a
/// tonemapping resolve. The depth prepass, shadow cascades, ambient occlusion,
/// reflections and temporal upscaling insert into this structure in later
/// phases; the pass order is the one documented in the plan.
public final class ForwardRenderer {
    public let device: MTLDevice
    let queue: MTLCommandQueue
    let opaque: MTLRenderPipelineState
    let opaqueCutout: MTLRenderPipelineState
    let resolve: MTLRenderPipelineState
    let sky: MTLRenderPipelineState
    let depthState: MTLDepthStencilState
    /// Sky writes no depth and ignores it: it is drawn first and everything
    /// else lands on top. One fullscreen pass of overdraw is cheaper than the
    /// depth-equal trickery needed to draw it last.
    let skyDepthState: MTLDepthStencilState
    public let atmosphere: AtmosphereResources
    public let shadows: ShadowRenderer
    /// Distance beyond which nothing casts. Beyond this the cascades would be
    /// too coarse to read as shadows anyway, and aerial perspective has taken over.
    public var shadowDistance: Float = 400
    let sampler: MTLSamplerState
    public var settings: RenderSettings
    private var targets: FrameTargets?

    public private(set) var lastGPUTime: Double = 0
    public private(set) var lastDrawCount = 0
    public private(set) var lastTriangleCount = 0

    public init(device: MTLDevice? = nil, settings: RenderSettings = .init()) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw RenderError.unavailable("Metal device unavailable")
        }
        self.device = device
        self.queue = queue
        self.settings = settings
        let library = try ShaderLibrary(device: device).library

        func forwardPipeline(alphaTest: Bool) throws -> MTLRenderPipelineState {
            let constants = MTLFunctionConstantValues()
            var enabled = alphaTest
            constants.setConstantValue(&enabled, type: .bool, index: 0)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = try library.makeFunction(name: "forwardVertex", constantValues: constants)
            descriptor.fragmentFunction = try library.makeFunction(name: "forwardFragment", constantValues: constants)
            descriptor.colorAttachments[0].pixelFormat = FrameTargets.colourFormat
            descriptor.depthAttachmentPixelFormat = FrameTargets.depthFormat
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        // Specialized rather than branched: RASTER_STABILITY.md documents an M2
        // repeat-render instability caused by an inactive discard path.
        opaque = try forwardPipeline(alphaTest: false)
        opaqueCutout = try forwardPipeline(alphaTest: true)

        let skyDescriptor = MTLRenderPipelineDescriptor()
        skyDescriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        skyDescriptor.fragmentFunction = library.makeFunction(name: "skyFragment")
        skyDescriptor.colorAttachments[0].pixelFormat = FrameTargets.colourFormat
        skyDescriptor.depthAttachmentPixelFormat = FrameTargets.depthFormat
        sky = try device.makeRenderPipelineState(descriptor: skyDescriptor)
        atmosphere = try AtmosphereResources(device: device, library: library)
        shadows = try ShadowRenderer(device: device, library: library,
                                     resolution: settings.shadowResolution,
                                     cascadeCount: settings.shadowCascades)

        let resolveDescriptor = MTLRenderPipelineDescriptor()
        resolveDescriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        resolveDescriptor.fragmentFunction = library.makeFunction(name: "resolveFragment")
        resolveDescriptor.colorAttachments[0].pixelFormat = FrameTargets.displayFormat
        resolve = try device.makeRenderPipelineState(descriptor: resolveDescriptor)

        let depth = MTLDepthStencilDescriptor()
        // Reversed depth: near is 1, far is 0.
        depth.depthCompareFunction = .greater
        depth.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depth) else {
            throw RenderError.unavailable("Could not create a depth state")
        }
        self.depthState = depthState

        let skyDepth = MTLDepthStencilDescriptor()
        skyDepth.depthCompareFunction = .always
        skyDepth.isDepthWriteEnabled = false
        guard let skyDepthState = device.makeDepthStencilState(descriptor: skyDepth) else {
            throw RenderError.unavailable("Could not create the sky depth state")
        }
        self.skyDepthState = skyDepthState

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .linear
        samplerDescriptor.sAddressMode = .repeat
        samplerDescriptor.tAddressMode = .repeat
        // Road surfaces are viewed at extreme grazing angles; without this they
        // blur to mush a few car lengths ahead.
        samplerDescriptor.maxAnisotropy = 8
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw RenderError.unavailable("Could not create a sampler")
        }
        self.sampler = sampler
    }

    func targets(width: Int, height: Int) throws -> FrameTargets {
        if let existing = targets, existing.matches(width: width, height: height) { return existing }
        let fresh = try FrameTargets(device: device, width: width, height: height)
        targets = fresh
        return fresh
    }

    /// Renders offscreen and returns sRGB-encoded RGBA bytes.
    ///
    /// This is the verification entry point, matching the classic path's
    /// offscreen smoke renders. Interactive presentation reuses `encode`.
    public func render(scene: SceneResources, camera: RenderCamera, lighting: SunLighting,
                       width: Int, height: Int, includeDriver: Bool = true) throws -> [UInt8] {
        let targets = try targets(width: width, height: height)
        guard let commands = queue.makeCommandBuffer() else {
            throw RenderError.unavailable("Could not create a command buffer")
        }
        atmosphere.update(into: commands, lighting: lighting, cameraAltitude: camera.eye.z)
        let cascades = ShadowCascades(camera: camera, sunDirection: lighting.direction,
                                      aspect: Float(width) / Float(max(height, 1)),
                                      count: settings.shadowCascades, resolution: shadows.resolution,
                                      shadowDistance: shadowDistance).cascades
        shadows.encode(into: commands, scene: scene, cascades: cascades)
        encode(into: commands, targets: targets, scene: scene, camera: camera,
               lighting: lighting, cascades: cascades, includeDriver: includeDriver)
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw RenderError.unavailable("GPU error: \(error)") }
        lastGPUTime = commands.gpuEndTime - commands.gpuStartTime

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            targets.display.getBytes(raw.baseAddress!, bytesPerRow: width * 4,
                                    from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return pixels
    }

    public func encode(into commands: MTLCommandBuffer, targets: FrameTargets,
                       scene: SceneResources, camera: RenderCamera, lighting: SunLighting,
                       cascades: [ShadowCascades.Cascade], includeDriver: Bool = true) {
        let aspect = Float(targets.width) / Float(max(targets.height, 1))
        var frame = FrameUniforms(
            viewProjection: camera.viewProjection(aspect: aspect),
            view: camera.view(),
            cameraPosition: camera.eye,
            sunDirection: lighting.direction,
            sunIlluminance: lighting.illuminance,
            exposureScale: lighting.exposureScale,
            ambientIrradiance: lighting.ambient)

        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = targets.colour
        // The sky pass covers every pixel, so the clear is only a safety net.
        scenePass.colorAttachments[0].loadAction = .clear
        scenePass.colorAttachments[0].storeAction = .store
        scenePass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        scenePass.depthAttachment.texture = targets.depth
        scenePass.depthAttachment.loadAction = .clear
        // Reversed depth clears to 0, the far plane.
        scenePass.depthAttachment.clearDepth = 0
        scenePass.depthAttachment.storeAction = .store

        lastDrawCount = 0
        lastTriangleCount = 0
        if let encoder = commands.makeRenderCommandEncoder(descriptor: scenePass) {
            encoder.label = "Sky and forward opaque"
            encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            encoder.setFragmentSamplerState(sampler, index: 0)

            encoder.setRenderPipelineState(sky)
            encoder.setDepthStencilState(skyDepthState)
            encoder.setFragmentTexture(atmosphere.skyView, index: 0)
            encoder.setFragmentTexture(atmosphere.transmittance, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            encoder.setDepthStencilState(depthState)
            // AC/TORCS geometry comes from OpenGL, whose front face is
            // counter-clockwise. Metal defaults to clockwise, so without this
            // every culled mesh keeps its back faces and discards its front
            // ones. Generated geometry follows the same convention.
            encoder.setFrontFacing(.counterClockwise)
            // Aerial perspective in the forward pass reads the same tables the
            // sky does, so haze and sky agree at the horizon.
            encoder.setFragmentTexture(atmosphere.transmittance, index: 3)
            encoder.setFragmentTexture(atmosphere.multiScatter, index: 4)
            encoder.setFragmentTexture(atmosphere.skyView, index: 5)
            encoder.setFragmentBuffer(atmosphere.irradiance, offset: 0, index: 3)
            encoder.setFragmentTexture(shadows.map, index: 6)
            encoder.setFragmentSamplerState(shadows.comparisonSampler, index: 1)
            // Bias in normalized depth. Cascades are orthographic over a few
            // hundred metres, so a small constant plus a slope term suffices;
            // the normal offset in the shader does the rest of the work.
            // Bias in shadow texels. Hardware slope-scaled bias handles the
            // gradient during the depth write; this covers the residual.
            var shadowUniforms = ShadowUniforms(cascades: cascades, depthBias: 3.0,
                                                normalBias: 1.5, filterRadius: 1.5)
            encoder.setFragmentBytes(&shadowUniforms, length: MemoryLayout<ShadowUniforms>.stride, index: 4)

            // Translucent batches are deferred to a blended pass in the next
            // phase; drawing them opaque here is wrong but visible, which is
            // preferable to dropping them silently.
            for batch in scene.batches {
                if batch.isDriver && !includeDriver { continue }
                encoder.setRenderPipelineState(batch.needsAlphaTest ? opaqueCutout : opaque)
                encoder.setCullMode(batch.culls ? .back : .none)
                var draw = batch.draw
                if let albedo = batch.albedo { encoder.setFragmentTexture(albedo, index: 0) }
                encoder.setVertexBuffer(batch.vertices, offset: 0, index: 0)
                encoder.setVertexBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                encoder.setFragmentBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: batch.indexCount,
                                              indexType: .uint32, indexBuffer: batch.indices,
                                              indexBufferOffset: 0)
                lastDrawCount += 1
                lastTriangleCount += batch.indexCount / 3
            }
            encoder.endEncoding()
        }

        let resolvePass = MTLRenderPassDescriptor()
        resolvePass.colorAttachments[0].texture = targets.display
        resolvePass.colorAttachments[0].loadAction = .dontCare
        resolvePass.colorAttachments[0].storeAction = .store
        if let encoder = commands.makeRenderCommandEncoder(descriptor: resolvePass) {
            encoder.label = "Tonemap resolve"
            encoder.setRenderPipelineState(resolve)
            encoder.setFragmentTexture(targets.colour, index: 0)
            var exposure = lighting.exposureScale
            encoder.setFragmentBytes(&exposure, length: MemoryLayout<Float>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
    }
}
