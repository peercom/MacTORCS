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
        /// Generated physically based maps, when one was substituted.
        let normal: MTLTexture?
        let orm: MTLTexture?
        let culls: Bool
        let isDriver: Bool
        let blends: Bool
        let isDeferred: Bool
        let albedo: MTLTexture?
        /// World-space bounds for shadow cascade culling.
        let worldCentre: SIMD3<Float>
        let worldRadius: Float
        /// True when the batch's own transform mirrors the geometry.
        ///
        /// A negative determinant reverses which side of every triangle faces
        /// the camera, so a mirrored mesh must cull the opposite face. The
        /// original wheel meshes are mirrored, which is why they vanished
        /// entirely once back-face culling was correct for everything else.
        let mirrored: Bool
        let detailRange: ClosedRange<Float>?
        let castsShadow: Bool
        let prepass: Bool

        /// Whether this batch draws for a camera at `eye`, under `transform`.
        func isVisible(from eye: SIMD3<Float>, transform: simd_float4x4) -> Bool {
            guard let range = detailRange else { return true }
            let centre = transform * SIMD4(worldCentre, 1)
            return range.contains(simd_distance(eye, SIMD3(centre.x, centre.y, centre.z)))
        }
    }

    let batches: [Batch]
    public let minimum: SIMD3<Float>, maximum: SIMD3<Float>
    public var triangleCount: Int { batches.reduce(0) { $0 + $1.indexCount / 3 } }
    public private(set) var bufferBytes = 0
    public private(set) var texturedBatches = 0
    /// Number of drawable batches, for diagnostics and budget reporting.
    public var batchCount: Int { batches.count }

    /// - Parameter resolveTexture: maps a batch's base-texture name and cutout
    ///   flag to an uploaded texture, or nil when the reference cannot be
    ///   satisfied. Injected rather than fixed so the same builder serves both
    ///   loose artwork on disk and already-decoded compiled session packages.
    public init(device: MTLDevice, scene: RenderScene,
                materials: MaterialLibrary? = nil, materialDirectory: URL? = nil,
                originalImage: ((String) -> TextureImage?)? = nil,
                resolveTexture: (String, Bool) -> MTLTexture?) throws {
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
            // A generated set replaces all three maps together. Mixing a
            // generated normal with an original albedo would light detail that
            // is not in the colour.
            var generated: MaterialLibrary.Binding? = nil
            if let texture = batch.baseTexture, let materials, let materialDirectory,
               batch.alphaTestThreshold == nil {
                generated = materials.resolve(texture: texture, directory: materialDirectory,
                                              original: originalImage?(texture))
            }
            let albedo = generated?.albedo ?? batch.baseTexture.flatMap {
                resolveTexture($0, batch.alphaTestThreshold != nil)
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
                                   maps: SIMD4(albedo == nil ? 0 : 1,
                                               generated == nil ? 0 : 1,
                                               generated == nil ? 0 : 1,
                                               (batch.isDeferred ? 0 : 1) | (batch.paintsRoadMarkings ? 2 : 0)
                                                   | (batch.swaysInWind ? 4 : 0)),
                                   uvScale: batch.uvInMetres ? 1 / max(generated?.worldSize ?? 1, 1e-3) : 1,
                                   uvPeriod: batch.uvInMetres ? RenderMesh.metresPeriod : 0,
                                   emissive: material.emissive, emissiveChannel: material.emissiveChannel),
                needsAlphaTest: batch.alphaTestThreshold != nil,
                normal: generated?.normal,
                orm: generated?.orm,
                culls: batch.culls,
                isDriver: batch.isDriver,
                blends: batch.blends,
                isDeferred: batch.isDeferred,
                albedo: albedo,
                worldCentre: worldCentre,
                worldRadius: worldRadius,
                mirrored: simd_determinant(transform) < 0,
                detailRange: batch.detailRange,
                castsShadow: batch.castsShadow,
                prepass: batch.prepass))
        }
        guard !built.isEmpty else { throw RenderError.unavailable("Scene has no drawable batches") }
        batches = built
        texturedBatches = built.filter { $0.albedo != nil }.count
        bufferBytes = bytes
        minimum = scene.minimum
        maximum = scene.maximum
    }

    /// Resolves textures by name against a store's search roots.
    public convenience init(device: MTLDevice, scene: RenderScene, textures: TextureStore? = nil,
                            materials: MaterialLibrary? = nil, materialDirectory: URL? = nil) throws {
        try self.init(device: device, scene: scene, materials: materials,
                      materialDirectory: materialDirectory,
                      originalImage: { textures?.image(named: $0) }) { name, isCutout in
            textures?.albedo(named: name, isCutout: isCutout)
        }
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
    let blended: MTLRenderPipelineState
    let blendedCutout: MTLRenderPipelineState
    /// Depth-only variants for the optional prepass. They reuse the forward
    /// vertex function rather than a simpler one: an equal-depth test in the
    /// shading pass requires bit-identical positions, which is only guaranteed
    /// if the same code computes them.
    let depthOnly: MTLRenderPipelineState
    let depthOnlyCutout: MTLRenderPipelineState
    /// Writes depth, for the prepass.
    let prepassDepthState: MTLDepthStencilState
    /// Passes only where the prepass already wrote this exact depth.
    let equalDepthState: MTLDepthStencilState
    /// Depth tested but not written, for the sorted transparent phase. Glass
    /// that wrote depth would hide whatever is behind it, including the rest of
    /// the same window.
    let readOnlyDepthState: MTLDepthStencilState
    let resolve: MTLRenderPipelineState
    /// Draws a rendered mirror view into a rectangle of a display target.
    let mirrorComposite: MTLRenderPipelineState
    let sky: MTLRenderPipelineState
    let depthState: MTLDepthStencilState
    /// Sky writes no depth and ignores it: it is drawn first and everything
    /// else lands on top. One fullscreen pass of overdraw is cheaper than the
    /// depth-equal trickery needed to draw it last.
    let skyDepthState: MTLDepthStencilState
    public let atmosphere: AtmosphereResources
    public let bloom: BloomRenderer
    public let occlusion: OcclusionRenderer
    public let reflections: ReflectionRenderer
    public let motionBlur: MotionBlurRenderer
    /// Whether motion blur wrote the post-colour target this frame.
    private var postProduced = false
    /// Bound at the occlusion slot when the pass is off, so the shader never
    /// samples an unbound texture. White: nothing occluded.
    private let neutralOcclusion: MTLTexture
    /// Whether the last frame ran a depth prepass, whether from the setting or
    /// because screen-space occlusion required one.
    public private(set) var lastFrameUsedDepthPrepass = false
    private var upscaler: TemporalUpscaler?
    private var spatialUpscaler: SpatialUpscaler?
    /// Drives the render scale from measured GPU time when the settings ask
    /// for it. Only presentation records into it; offscreen renders stay at
    /// the settings' scale so they are repeatable.
    public private(set) var dynamicResolution = DynamicResolutionController(initialScale: 1.0)
    /// Whether the upscaler actually wrote its output this frame. The fallback
    /// on upscaler failure cannot be expressed by which textures exist — the
    /// output texture is still allocated — so the tonemap source is chosen from
    /// what ran, not from what is available.
    private var upscaleProduced = false
    private var jitterSequence = JitterSequence()
    /// Unjittered view-projection from the previous frame, for motion vectors.
    private var previousViewProjection: simd_float4x4?
    /// Previous instance transforms, keyed by resource. Static geometry keeps
    /// its own transform, so only moving instances need tracking.
    private var previousInstanceTransforms: [Int: simd_float4x4] = [:]
    /// Jitter applied this frame, in render pixels.
    public private(set) var currentJitter = SIMD2<Float>(0, 0)
    public let shadows: ShadowRenderer
    /// Distance beyond which nothing casts. Beyond this the cascades would be
    /// too coarse to read as shadows anyway, and aerial perspective has taken over.
    public var shadowDistance: Float = 400
    let sampler: MTLSamplerState
    /// Mutable so a benchmark can alternate configurations within one process.
    public var settings: RenderSettings
    /// Seconds driving vertex animation (foliage). Presentation advances it;
    /// offscreen renders leave it at zero so they repeat.
    public var animationTime: Double = 0
    private var cachedTargets: FrameTargets?

    public private(set) var lastGPUTime: Double = 0
    /// Rolling GPU time, written from the command buffer completion handler and
    /// therefore off the main thread.
    private let frameTimeLock = NSLock()
    private var measuredGPUTime: Double = 0

    /// Most recent measured GPU time, in seconds.
    public var gpuTime: Double {
        frameTimeLock.lock()
        defer { frameTimeLock.unlock() }
        return measuredGPUTime
    }

    func recordFrameTime(_ seconds: Double) {
        frameTimeLock.lock()
        measuredGPUTime = seconds
        frameTimeLock.unlock()
    }
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

        func forwardPipeline(alphaTest: Bool, blend: Bool) throws -> MTLRenderPipelineState {
            let constants = MTLFunctionConstantValues()
            var enabled = alphaTest
            constants.setConstantValue(&enabled, type: .bool, index: 0)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = try library.makeFunction(name: "forwardVertex", constantValues: constants)
            descriptor.fragmentFunction = try library.makeFunction(name: "forwardFragment", constantValues: constants)
            let colour = descriptor.colorAttachments[0]!
            colour.pixelFormat = FrameTargets.colourFormat
            // Motion vectors ride alongside scene colour. Blended draws must
            // not blend into it: a velocity is a coordinate, not a quantity
            // that can be averaged with what is behind it.
            descriptor.colorAttachments[1].pixelFormat = FrameTargets.velocityFormat
            if blend { descriptor.colorAttachments[1].writeMask = [] }
            // The reflection surface is written, never blended: glass writes
            // its own normal and weight over what is behind it.
            descriptor.colorAttachments[2].pixelFormat = FrameTargets.reflectionSurfaceFormat
            if blend {
                // Straight (non-premultiplied) source-alpha blending, matching
                // what the original fixed-function path set up.
                colour.isBlendingEnabled = true
                colour.rgbBlendOperation = .add
                colour.alphaBlendOperation = .add
                colour.sourceRGBBlendFactor = .sourceAlpha
                colour.sourceAlphaBlendFactor = .sourceAlpha
                colour.destinationRGBBlendFactor = .oneMinusSourceAlpha
                colour.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            descriptor.depthAttachmentPixelFormat = FrameTargets.depthFormat
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        // Specialized rather than branched: RASTER_STABILITY.md documents an M2
        // repeat-render instability caused by an inactive discard path.
        opaque = try forwardPipeline(alphaTest: false, blend: false)
        opaqueCutout = try forwardPipeline(alphaTest: true, blend: false)
        blended = try forwardPipeline(alphaTest: false, blend: true)
        blendedCutout = try forwardPipeline(alphaTest: true, blend: true)

        func depthPipeline(alphaTest: Bool) throws -> MTLRenderPipelineState {
            let constants = MTLFunctionConstantValues()
            var enabled = alphaTest
            constants.setConstantValue(&enabled, type: .bool, index: 0)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = try library.makeFunction(name: "forwardVertex", constantValues: constants)
            // Opaque geometry needs no fragment stage at all; cutouts need one
            // that samples and discards.
            descriptor.fragmentFunction = alphaTest ? library.makeFunction(name: "depthOnlyFragment") : nil
            descriptor.colorAttachments[0].pixelFormat = FrameTargets.colourFormat
            descriptor.colorAttachments[0].writeMask = []
            descriptor.colorAttachments[1].pixelFormat = FrameTargets.velocityFormat
            descriptor.colorAttachments[1].writeMask = []
            descriptor.colorAttachments[2].pixelFormat = FrameTargets.reflectionSurfaceFormat
            descriptor.colorAttachments[2].writeMask = []
            descriptor.depthAttachmentPixelFormat = FrameTargets.depthFormat
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        depthOnly = try depthPipeline(alphaTest: false)
        depthOnlyCutout = try depthPipeline(alphaTest: true)

        let skyDescriptor = MTLRenderPipelineDescriptor()
        skyDescriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        skyDescriptor.fragmentFunction = library.makeFunction(name: "skyFragment")
        skyDescriptor.colorAttachments[0].pixelFormat = FrameTargets.colourFormat
        skyDescriptor.colorAttachments[1].pixelFormat = FrameTargets.velocityFormat
        skyDescriptor.colorAttachments[2].pixelFormat = FrameTargets.reflectionSurfaceFormat
        skyDescriptor.colorAttachments[2].writeMask = []
        skyDescriptor.depthAttachmentPixelFormat = FrameTargets.depthFormat
        sky = try device.makeRenderPipelineState(descriptor: skyDescriptor)
        atmosphere = try AtmosphereResources(device: device, library: library)
        bloom = try BloomRenderer(device: device, library: library)
        occlusion = try OcclusionRenderer(device: device, library: library)
        reflections = try ReflectionRenderer(device: device, library: library)
        motionBlur = try MotionBlurRenderer(device: device, library: library)
        let neutral = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: OcclusionRenderer.format,
                                                                width: 1, height: 1, mipmapped: false)
        neutral.usage = .shaderRead
        guard let neutralOcclusion = device.makeTexture(descriptor: neutral) else {
            throw RenderError.unavailable("Could not allocate the neutral occlusion texture")
        }
        var white: [UInt8] = [255, 255]
        neutralOcclusion.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 2)
        self.neutralOcclusion = neutralOcclusion
        shadows = try ShadowRenderer(device: device, library: library,
                                     resolution: settings.shadowResolution,
                                     cascadeCount: settings.shadowCascades)

        let resolveDescriptor = MTLRenderPipelineDescriptor()
        resolveDescriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        resolveDescriptor.fragmentFunction = library.makeFunction(name: "resolveFragment")
        resolveDescriptor.colorAttachments[0].pixelFormat = FrameTargets.displayFormat
        resolve = try device.makeRenderPipelineState(descriptor: resolveDescriptor)

        let mirrorDescriptor = MTLRenderPipelineDescriptor()
        mirrorDescriptor.label = "mirrorComposite"
        mirrorDescriptor.vertexFunction = library.makeFunction(name: "mirrorVertex")
        mirrorDescriptor.fragmentFunction = library.makeFunction(name: "mirrorFragment")
        mirrorDescriptor.colorAttachments[0].pixelFormat = FrameTargets.displayFormat
        mirrorComposite = try device.makeRenderPipelineState(descriptor: mirrorDescriptor)

        let depth = MTLDepthStencilDescriptor()
        // Reversed depth: near is 1, far is 0.
        depth.depthCompareFunction = .greater
        depth.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depth) else {
            throw RenderError.unavailable("Could not create a depth state")
        }
        self.depthState = depthState

        let readOnlyDepth = MTLDepthStencilDescriptor()
        readOnlyDepth.depthCompareFunction = .greater
        readOnlyDepth.isDepthWriteEnabled = false
        guard let readOnlyDepthState = device.makeDepthStencilState(descriptor: readOnlyDepth) else {
            throw RenderError.unavailable("Could not create the transparent depth state")
        }
        self.readOnlyDepthState = readOnlyDepthState

        // The prepass writes; the shading pass then matches exactly.
        let prepassDepth = MTLDepthStencilDescriptor()
        prepassDepth.depthCompareFunction = .greater
        prepassDepth.isDepthWriteEnabled = true
        let equalDepth = MTLDepthStencilDescriptor()
        equalDepth.depthCompareFunction = .equal
        equalDepth.isDepthWriteEnabled = false
        guard let prepassDepthState = device.makeDepthStencilState(descriptor: prepassDepth),
              let equalDepthState = device.makeDepthStencilState(descriptor: equalDepth) else {
            throw RenderError.unavailable("Could not create the prepass depth states")
        }
        self.prepassDepthState = prepassDepthState
        self.equalDepthState = equalDepthState

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

    /// Allocates or reuses targets for an output size, deriving the render
    /// size from the current settings.
    /// The render scale in force: the settings' scale, lowered by dynamic
    /// resolution when that is on.
    public var effectiveRenderScale: Float {
        guard settings.upscaling else { return 1 }
        return settings.dynamicResolution ? min(dynamicResolution.scale, settings.renderScale) : settings.renderScale
    }

    /// Feeds one frame's GPU time to the dynamic resolution controller.
    /// Presentation calls this with the previous frame's measured time.
    @discardableResult
    public func recordDynamicResolution(gpuTime: Double) -> Bool {
        guard settings.dynamicResolution, settings.upscaling else { return false }
        return dynamicResolution.record(gpuTime: gpuTime)
    }

    /// Returns to native and forgets the history, for a settings change.
    public func resetDynamicResolution() { dynamicResolution = DynamicResolutionController(initialScale: 1.0) }

    public func targets(outputWidth: Int, outputHeight: Int) throws -> FrameTargets {
        let scale = effectiveRenderScale
        // At full scale the scaler has nothing to do and is bypassed entirely.
        let upscaling = settings.upscaling && scale < 0.999
        let render = settings.renderSize(output: (outputWidth, outputHeight), scale: scale)
        let renderWidth = upscaling ? render.width : outputWidth
        let renderHeight = upscaling ? render.height : outputHeight
        let reflections = settings.screenSpaceReflections != .off
        let postEarly = upscaling && settings.upscalingMode == .spatial
        if let existing = cachedTargets, existing.matches(renderWidth: renderWidth, renderHeight: renderHeight,
                                                    outputWidth: outputWidth, outputHeight: outputHeight,
                                                    upscaling: upscaling, reflections: reflections,
                                                    motionBlur: settings.motionBlur, postAtRenderResolution: postEarly) {
            return existing
        }
        let fresh = try FrameTargets(device: device, renderWidth: renderWidth, renderHeight: renderHeight,
                                     outputWidth: outputWidth, outputHeight: outputHeight, upscaling: upscaling,
                                     reflections: reflections, motionBlur: settings.motionBlur,
                                     postAtRenderResolution: postEarly)
        cachedTargets = fresh
        // Resolution changes invalidate the accumulated history.
        upscaler = nil
        return fresh
    }

    /// Discards temporal history. Call on a camera cut, where reprojection has
    /// nothing meaningful to say and would smear the old view into the new one.
    public func resetTemporalHistory() {
        upscaler?.needsReset = true
        previousViewProjection = nil
        previousInstanceTransforms.removeAll()
        jitterSequence.reset()
    }

    /// Renders a single scene offscreen and returns sRGB-encoded RGBA bytes.
    ///
    /// The verification entry point, matching the classic path's offscreen
    /// smoke renders. Interactive presentation uses `draw(in:)`.
    public func render(scene: SceneResources, camera: RenderCamera, lighting: SunLighting,
                       width: Int, height: Int, includeDriver: Bool = true,
                       lightState: SIMD4<Float> = .zero) throws -> [UInt8] {
        try render(resources: [scene],
                   instances: [RenderInstance(resource: 0, drawsDriver: includeDriver, lightState: lightState)],
                   camera: camera, lighting: lighting, width: width, height: height)
    }

    public func render(resources: [SceneResources], instances: [RenderInstance],
                       camera: RenderCamera, lighting: SunLighting,
                       width: Int, height: Int, mirror: MirrorRequest? = nil) throws -> [UInt8] {
        let targets = try targets(outputWidth: width, outputHeight: height)
        guard let commands = queue.makeCommandBuffer() else {
            throw RenderError.unavailable("Could not create a command buffer")
        }
        let mirrorView = try mirror.map { try encodeMirrorView(into: commands, $0, lighting: lighting) }
        // A verification render is one frame from a cold state, so the
        // per-frame noise rotation starts over: two calls with the same inputs
        // produce the same pixels, which the repeat-render discipline needs.
        // Interactive frames go through encodeFrame directly and keep rotating.
        occlusion.resetNoise()
        reflections.resetNoise()
        encodeFrame(into: commands, targets: targets, resources: resources, instances: instances,
                    camera: camera, lighting: lighting, aspect: Float(width) / Float(max(height, 1)))
        encodeResolve(into: commands, source: tonemapSource(targets), destination: targets.display,
                      lighting: lighting)
        if let mirror, let mirrorView {
            encodeMirrorComposite(into: commands, mirror: mirrorView, destination: targets.display, rect: mirror.rect)
        }
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

    /// Everything up to but not including the tonemapping resolve: atmosphere
    /// tables, shadow cascades, sky and forward opaque.
    ///
    /// Split from the resolve so interactive presentation can tonemap straight
    /// into the drawable, and so the offscreen path can reuse the identical
    /// scene encoding rather than a parallel copy of it.
    public func encodeFrame(into commands: MTLCommandBuffer, targets: FrameTargets,
                            resources: [SceneResources], instances: [RenderInstance],
                            camera: RenderCamera, lighting: SunLighting, aspect: Float) {
        currentJitter = targets.upscaled != nil && settings.upscalingMode == .temporal
            ? jitterSequence.next() : SIMD2(0, 0)
        upscaleProduced = false
        postProduced = false
        atmosphere.update(into: commands, lighting: lighting, cameraAltitude: camera.eye.z)
        let cascades = ShadowCascades(camera: camera, sunDirection: lighting.direction,
                                      aspect: aspect, count: settings.shadowCascades,
                                      resolution: shadows.resolution,
                                      shadowDistance: shadowDistance).cascades
        shadows.encode(into: commands, resources: resources, instances: instances, cascades: cascades)
        encode(into: commands, targets: targets, resources: resources, instances: instances,
               camera: camera, lighting: lighting, cascades: cascades, aspect: aspect)

        if targets.upscaled != nil && settings.upscalingMode == .spatial {
            // Blur before the scaler: a quarter of the pixels, and the scaler
            // keeps no history the blur could corrupt.
            if settings.motionBlur, targets.postAtRenderResolution, targets.velocity != nil, targets.postColour != nil {
                postProduced = motionBlur.encode(into: commands, targets: targets, source: targets.colour) != nil
            }
            do {
                if spatialUpscaler?.matches(renderWidth: targets.renderWidth, renderHeight: targets.renderHeight,
                                            outputWidth: targets.outputWidth, outputHeight: targets.outputHeight) != true {
                    spatialUpscaler = try SpatialUpscaler(device: device,
                                                          renderWidth: targets.renderWidth, renderHeight: targets.renderHeight,
                                                          outputWidth: targets.outputWidth, outputHeight: targets.outputHeight)
                    upscalerBuildCount += 1
                }
                try spatialUpscaler?.encode(into: commands, targets: targets,
                                            source: postProduced ? targets.postColour! : targets.colour)
                upscaleProduced = spatialUpscaler != nil
            } catch {
                spatialUpscaler = nil
                lastUpscalerError = String(describing: error)
            }
        } else if targets.upscaled != nil {
            do {
                if upscaler == nil || upscaler?.matches(renderWidth: targets.renderWidth,
                                                        renderHeight: targets.renderHeight,
                                                        outputWidth: targets.outputWidth,
                                                        outputHeight: targets.outputHeight) != true {
                    upscaler = try TemporalUpscaler(device: device,
                                                    renderWidth: targets.renderWidth,
                                                    renderHeight: targets.renderHeight,
                                                    outputWidth: targets.outputWidth,
                                                    outputHeight: targets.outputHeight)
                    upscalerBuildCount += 1
                }
                try upscaler?.encode(into: commands, targets: targets, jitter: currentJitter)
                upscaleProduced = upscaler != nil
            } catch {
                // Upscaling is an optimization, not a requirement. Falling back
                // to the render-resolution image keeps a frame on screen rather
                // than failing the session, and the tonemap source follows.
                upscaler = nil
                lastUpscalerError = String(describing: error)
            }
        }

        // Motion blur after the upscaler and before bloom: the glow should
        // streak with the object, and the tonemapper should see the blur.
        if settings.motionBlur, !targets.postAtRenderResolution, targets.velocity != nil, targets.postColour != nil {
            let source = upscaleProduced ? (targets.upscaled ?? targets.colour) : targets.colour
            postProduced = motionBlur.encode(into: commands, targets: targets, source: source) != nil
        } else if !settings.motionBlur {
            motionBlur.discard()
        }

        // After the upscaler, so the pyramid is built at output resolution from
        // the image that will actually be tonemapped. Building it at render
        // resolution instead would be cheaper but would feed the upscaler a
        // glow it then has to track temporally.
        if settings.bloom && settings.bloomStrength > 0 {
            bloom.encode(into: commands, source: tonemapSource(targets),
                         threshold: settings.bloomThreshold, exposureScale: lighting.exposureScale)
        } else {
            bloom.discard()
        }

        // Remember this frame's transforms so the next one can reproject.
        previousViewProjection = camera.viewProjection(aspect: aspect)
        previousInstanceTransforms = Dictionary(instances.map { ($0.resource, $0.transform) },
                                                uniquingKeysWith: { first, _ in first })
    }

    /// Forgets the previous frame's transforms, so the next frame has zero
    /// motion: for a camera cut, or a diagnostic that renders unrelated
    /// views in sequence and must not blur one against the last.
    public func resetHistory() {
        previousViewProjection = nil
        previousInstanceTransforms = [:]
        upscaler?.needsReset = true
    }

    public private(set) var lastUpscalerError: String?
    /// Diagnostic: how many times the scaler has been constructed. Should be
    /// one per resolution, not one per frame.
    public private(set) var upscalerBuildCount = 0

    public func encode(into commands: MTLCommandBuffer, targets: FrameTargets,
                       resources: [SceneResources], instances: [RenderInstance],
                       camera: RenderCamera, lighting: SunLighting,
                       cascades: [ShadowCascades.Cascade], aspect: Float) {
        let unjittered = camera.viewProjection(aspect: aspect)
        let projection = RenderCamera.jittered(camera.projection(aspect: aspect), jitter: currentJitter,
                                               renderWidth: targets.renderWidth,
                                               renderHeight: targets.renderHeight)
        var frame = FrameUniforms(
            viewProjection: projection * camera.view(),
            view: camera.view(),
            cameraPosition: camera.eye,
            sunDirection: lighting.direction,
            sunIlluminance: lighting.illuminance,
            exposureScale: lighting.exposureScale,
            ambientIrradiance: lighting.ambient,
            unjitteredViewProjection: unjittered,
            // No history on the first frame: reprojecting against the current
            // transform yields zero motion, which is what a cold history wants.
            previousViewProjection: previousViewProjection ?? unjittered,
            renderSize: SIMD2(Float(targets.renderWidth), Float(targets.renderHeight)),
            mipBias: settings.upscaling
                ? RenderCamera.mipBias(renderWidth: targets.renderWidth, outputWidth: targets.outputWidth)
                : 0,
            animationTime: Float(animationTime))

        let scenePass = MTLRenderPassDescriptor()
        scenePass.colorAttachments[0].texture = targets.colour
        // The sky pass covers every pixel, so the clear is only a safety net.
        scenePass.colorAttachments[0].loadAction = .clear
        scenePass.colorAttachments[0].storeAction = .store
        scenePass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        scenePass.colorAttachments[1].texture = targets.velocityAttachment
        scenePass.colorAttachments[1].loadAction = .clear
        scenePass.colorAttachments[1].storeAction = targets.velocity != nil ? .store : .dontCare
        scenePass.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        scenePass.colorAttachments[2].texture = targets.reflectionSurface
        scenePass.colorAttachments[2].loadAction = .clear
        scenePass.colorAttachments[2].storeAction = targets.reflections ? .store : .dontCare
        scenePass.colorAttachments[2].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        scenePass.depthAttachment.texture = targets.depth
        // Reversed depth clears to 0, the far plane.
        scenePass.depthAttachment.clearDepth = 0
        scenePass.depthAttachment.storeAction = .store

        lastDrawCount = 0
        lastTriangleCount = 0

        // Screen-space occlusion reads the opaque depth of this frame before
        // anything shades, which means the prepass has to finish — as its own
        // encoder, stored — before the scene pass begins. Without occlusion the
        // prepass stays inside the scene encoder, where the tile memory never
        // leaves the chip.
        let wantsOcclusion = settings.ambientOcclusion != .off || settings.contactShadows
        let usesPrepass = settings.depthPrepass || wantsOcclusion
        lastFrameUsedDepthPrepass = usesPrepass
        if wantsOcclusion {
            let prepass = MTLRenderPassDescriptor()
            // The depth-only pipelines declare the scene's colour formats with
            // an empty write mask; the attachments are listed to match and
            // discarded, not written.
            prepass.colorAttachments[0].texture = targets.colour
            prepass.colorAttachments[0].loadAction = .dontCare
            prepass.colorAttachments[0].storeAction = .dontCare
            prepass.colorAttachments[1].texture = targets.velocityAttachment
            prepass.colorAttachments[1].loadAction = .dontCare
            prepass.colorAttachments[1].storeAction = .dontCare
            prepass.colorAttachments[2].texture = targets.reflectionSurface
            prepass.colorAttachments[2].loadAction = .dontCare
            prepass.colorAttachments[2].storeAction = .dontCare
            prepass.depthAttachment.texture = targets.depth
            prepass.depthAttachment.loadAction = .clear
            prepass.depthAttachment.clearDepth = 0
            prepass.depthAttachment.storeAction = .store
            if let encoder = commands.makeRenderCommandEncoder(descriptor: prepass) {
                encoder.label = "Depth prepass"
                encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
                encoder.setFragmentSamplerState(sampler, index: 0)
                encodePrepassDraws(on: encoder, resources: resources, instances: instances, eye: camera.eye)
                encoder.endEncoding()
            }
            occlusion.encode(into: commands, depth: targets.depth, projection: projection,
                             view: camera.view(), sunDirection: lighting.direction,
                             ambient: settings.ambientOcclusion, contact: settings.contactShadows)
            scenePass.depthAttachment.loadAction = .load
        } else {
            occlusion.discard()
            scenePass.depthAttachment.loadAction = .clear
        }
        frame.renderSize.w = occlusion.result == nil ? 0 : 1

        guard let encoder = commands.makeRenderCommandEncoder(descriptor: scenePass) else { return }
        encoder.label = "Sky and forward opaque"
        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentTexture(occlusion.result ?? neutralOcclusion, index: 7)

        // Optional depth-only prepass. Everything that will shade writes depth
        // first, so the shading pass touches each visible pixel once.
        if usesPrepass && !wantsOcclusion {
            encodePrepassDraws(on: encoder, resources: resources, instances: instances, eye: camera.eye)
        }

        encoder.setDepthStencilState(usesPrepass ? equalDepthState : depthState)
        // AC/TORCS geometry comes from OpenGL, whose front face is
        // counter-clockwise. Metal defaults to clockwise, so without this
        // every culled mesh keeps its back faces and discards its front ones.
        encoder.setFrontFacing(.counterClockwise)
        encoder.setFragmentTexture(atmosphere.transmittance, index: 3)
        encoder.setFragmentTexture(atmosphere.multiScatter, index: 4)
        encoder.setFragmentTexture(atmosphere.skyView, index: 5)
        encoder.setFragmentBuffer(atmosphere.irradiance, offset: 0, index: 3)
        encoder.setFragmentTexture(shadows.map, index: 6)
        encoder.setFragmentSamplerState(shadows.comparisonSampler, index: 1)
        // Bias in shadow texels. Hardware slope-scaled bias handles the
        // gradient during the depth write; this covers the residual.
        var shadowUniforms = ShadowUniforms(cascades: cascades, depthBias: 3.0,
                                            normalBias: 1.5, filterRadius: 1.5)
        encoder.setFragmentBytes(&shadowUniforms, length: MemoryLayout<ShadowUniforms>.stride, index: 4)

        // Opaque first, then the deferred transparent phase sorted back to
        // front. One pass rather than two encoders: the transparent draws need
        // the same depth buffer the opaque ones just wrote.
        struct DeferredDraw {
            let instance: Int
            let batch: Int
            let distance: Float
        }
        var deferred: [DeferredDraw] = []

        for (instanceIndex, instance) in instances.enumerated() {
            guard resources.indices.contains(instance.resource) else { continue }
            let scene = resources[instance.resource]
            var instanceUniforms = InstanceUniforms(
                model: instance.transform,
                previousModel: previousInstanceTransforms[instance.resource] ?? instance.transform,
                lightState: instance.lightState)
            encoder.setVertexBytes(&instanceUniforms, length: MemoryLayout<InstanceUniforms>.stride, index: 5)
            // Mirroring composes: a mirrored mesh inside a mirrored instance
            // faces the original way again. The left and right wheels differ by
            // exactly such a flip.
            let instanceMirrored = simd_determinant(instance.transform) < 0

            for (batchIndex, batch) in scene.batches.enumerated() {
                if batch.isDriver && !instance.drawsDriver { continue }
                if !batch.isVisible(from: camera.eye, transform: instance.transform) { continue }
                // A batch the prepass skipped has no depth to match; it tests
                // and writes depth here like a frame without a prepass.
                if usesPrepass { encoder.setDepthStencilState(batch.prepass ? equalDepthState : depthState) }
                if batch.isDeferred {
                    let centre = instance.transform * SIMD4(batch.worldCentre, 1)
                    deferred.append(DeferredDraw(instance: instanceIndex, batch: batchIndex,
                                                 distance: simd_length(SIMD3(centre.x, centre.y, centre.z) - camera.eye)))
                    continue
                }
                draw(batch, on: encoder, blendOverride: nil, mirroredInstance: instanceMirrored)
            }
        }

        // Sky last among the opaque work. The fullscreen triangle sits at the
        // far plane, so an equal test against the cleared depth passes exactly
        // where no geometry wrote — the sky shades only the pixels it actually
        // covers instead of every pixel and then being overdrawn. It still
        // precedes the transparent phase so glass blends over it.
        encoder.setRenderPipelineState(sky)
        encoder.setDepthStencilState(equalDepthState)
        encoder.setCullMode(.none)
        encoder.setFragmentTexture(atmosphere.skyView, index: 0)
        encoder.setFragmentTexture(atmosphere.transmittance, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        if !deferred.isEmpty {
            encoder.setDepthStencilState(readOnlyDepthState)
            // Farthest first. Sorting per batch rather than per triangle is the
            // usual compromise; it is correct here because the transparent
            // surfaces on a car do not interpenetrate.
            for item in deferred.sorted(by: { $0.distance > $1.distance }) {
                let instance = instances[item.instance]
                let scene = resources[instance.resource]
                var instanceUniforms = InstanceUniforms(model: instance.transform, lightState: instance.lightState)
                encoder.setVertexBytes(&instanceUniforms, length: MemoryLayout<InstanceUniforms>.stride, index: 5)
                // Glass is see-through from both sides, and culling it leaves
                // the far side of a windscreen missing.
                draw(scene.batches[item.batch], on: encoder, blendOverride: true,
                     mirroredInstance: simd_determinant(instance.transform) < 0, forceTwoSided: true)
            }
        }
        encoder.endEncoding()

        if settings.screenSpaceReflections != .off {
            reflections.encode(into: commands, targets: targets, projection: projection, view: camera.view(),
                               sunDirection: lighting.direction, roughnessCutoff: settings.reflectionRoughnessCutoff,
                               quality: settings.screenSpaceReflections, skyView: atmosphere.skyView)
        } else {
            reflections.discard()
        }
    }

    /// Depth-only draws of everything opaque that will later shade. Shared by
    /// the in-encoder prepass and the standalone one so the two write the
    /// same depth.
    private func encodePrepassDraws(on encoder: MTLRenderCommandEncoder,
                                    resources: [SceneResources], instances: [RenderInstance],
                                    eye: SIMD3<Float>) {
        encoder.setDepthStencilState(prepassDepthState)
        encoder.setFrontFacing(.counterClockwise)
        for instance in instances {
            guard resources.indices.contains(instance.resource) else { continue }
            let scene = resources[instance.resource]
            var instanceUniforms = InstanceUniforms(model: instance.transform)
            encoder.setVertexBytes(&instanceUniforms, length: MemoryLayout<InstanceUniforms>.stride, index: 5)
            let instanceMirrored = simd_determinant(instance.transform) < 0
            for batch in scene.batches {
                if batch.isDeferred { continue }
                if batch.isDriver && !instance.drawsDriver { continue }
                if !batch.isVisible(from: eye, transform: instance.transform) { continue }
                if !batch.prepass { continue }
                encoder.setRenderPipelineState(batch.needsAlphaTest ? depthOnlyCutout : depthOnly)
                let mirrored = batch.mirrored != instanceMirrored
                encoder.setCullMode(batch.culls ? (mirrored ? .front : .back) : .none)
                var draw = batch.draw
                if let albedo = batch.albedo { encoder.setFragmentTexture(albedo, index: 0) }
                encoder.setVertexBuffer(batch.vertices, offset: 0, index: 0)
                encoder.setVertexBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                encoder.setFragmentBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: 2)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: batch.indexCount,
                                              indexType: .uint32, indexBuffer: batch.indices,
                                              indexBufferOffset: 0)
            }
        }
    }

    /// Copies a private texture back to the CPU, for verification tools. Not
    /// a frame-path operation: it waits for the GPU.
    public func readback(_ texture: MTLTexture, bytesPerPixel: Int) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat,
                                                                  width: texture.width, height: texture.height,
                                                                  mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let staging = device.makeTexture(descriptor: descriptor),
              let commands = queue.makeCommandBuffer(),
              let blit = commands.makeBlitCommandEncoder() else {
            throw RenderError.unavailable("Could not stage a readback")
        }
        blit.copy(from: texture, to: staging)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * bytesPerPixel)
        bytes.withUnsafeMutableBytes { raw in
            staging.getBytes(raw.baseAddress!, bytesPerRow: texture.width * bytesPerPixel,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return bytes
    }

    /// Submits one batch. Shared by the opaque and transparent phases so the
    /// two cannot drift apart in how they bind material state.
    private func draw(_ batch: SceneResources.Batch, on encoder: MTLRenderCommandEncoder,
                      blendOverride: Bool?, mirroredInstance: Bool, forceTwoSided: Bool = false) {
        let blends = blendOverride ?? batch.blends
        switch (blends, batch.needsAlphaTest) {
        case (false, false): encoder.setRenderPipelineState(opaque)
        case (false, true): encoder.setRenderPipelineState(opaqueCutout)
        case (true, false): encoder.setRenderPipelineState(blended)
        case (true, true): encoder.setRenderPipelineState(blendedCutout)
        }
        let mirrored = batch.mirrored != mirroredInstance
        encoder.setCullMode(forceTwoSided || !batch.culls ? .none : (mirrored ? .front : .back))
        var draw = batch.draw
        if let albedo = batch.albedo { encoder.setFragmentTexture(albedo, index: 0) }
        if let normal = batch.normal { encoder.setFragmentTexture(normal, index: 1) }
        if let orm = batch.orm { encoder.setFragmentTexture(orm, index: 2) }
        encoder.setVertexBuffer(batch.vertices, offset: 0, index: 0)
        encoder.setVertexBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: 2)
        encoder.setFragmentBytes(&draw, length: MemoryLayout<DrawUniforms>.stride, index: 2)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: batch.indexCount,
                                      indexType: .uint32, indexBuffer: batch.indices,
                                      indexBufferOffset: 0)
        lastDrawCount += 1
        lastTriangleCount += batch.indexCount / 3
    }

    /// The texture the resolve should tonemap: the upscaler's output when it
    /// ran this frame, otherwise the render-resolution scene colour.
    public func tonemapSource(_ targets: FrameTargets) -> MTLTexture {
        // A post target at render resolution has already been scaled.
        if postProduced, !targets.postAtRenderResolution, let post = targets.postColour { return post }
        if upscaleProduced, let upscaled = targets.upscaled { return upscaled }
        if postProduced, let post = targets.postColour { return post }
        return targets.colour
    }

    /// A rear-view mirror to render alongside a frame: its own renderer (a
    /// lighter preset, its own targets), the same resources, the instances it
    /// shows, a backward camera, and the pixel rectangle of the display it
    /// lands in, top-down.
    public struct MirrorRequest {
        public var renderer: ForwardRenderer
        public var resources: [SceneResources]
        public var instances: [RenderInstance]
        public var camera: RenderCamera
        public var width: Int, height: Int
        public var rect: (x: Int, y: Int, width: Int, height: Int)
        public init(renderer: ForwardRenderer, resources: [SceneResources], instances: [RenderInstance],
                    camera: RenderCamera, width: Int, height: Int, rect: (x: Int, y: Int, width: Int, height: Int)) {
            self.renderer = renderer; self.resources = resources; self.instances = instances
            self.camera = camera; self.width = width; self.height = height; self.rect = rect
        }
    }

    /// Renders the mirror's view with its own renderer into that renderer's
    /// display target and returns the target. Encoded before the main frame
    /// so the two share one command buffer.
    public func encodeMirrorView(into commands: MTLCommandBuffer, _ mirror: MirrorRequest,
                                 lighting: SunLighting) throws -> MTLTexture {
        let targets = try mirror.renderer.targets(outputWidth: mirror.width, outputHeight: mirror.height)
        mirror.renderer.animationTime = animationTime
        mirror.renderer.encodeFrame(into: commands, targets: targets, resources: mirror.resources,
                                    instances: mirror.instances, camera: mirror.camera, lighting: lighting,
                                    aspect: Float(mirror.width) / Float(max(mirror.height, 1)))
        mirror.renderer.encodeResolve(into: commands, source: mirror.renderer.tonemapSource(targets),
                                      destination: targets.display, lighting: lighting)
        return targets.display
    }

    /// The quad for a pixel rectangle, in normalized device coordinates:
    /// x, y of the lower-left corner, then width and height.
    public static func mirrorQuad(rect: (x: Int, y: Int, width: Int, height: Int),
                                  displayWidth: Int, displayHeight: Int) -> SIMD4<Float> {
        let w = Float(max(displayWidth, 1)), h = Float(max(displayHeight, 1))
        let x = Float(rect.x) / w * 2 - 1
        // Top-down pixels to y-up device coordinates.
        let y = 1 - Float(rect.y + rect.height) / h * 2
        return SIMD4(x, y, Float(rect.width) / w * 2, Float(rect.height) / h * 2)
    }

    /// Composites a rendered mirror onto a display target, which keeps its
    /// contents elsewhere.
    public func encodeMirrorComposite(into commands: MTLCommandBuffer, mirror: MTLTexture,
                                      destination: MTLTexture, rect: (x: Int, y: Int, width: Int, height: Int)) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = destination
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Mirror composite"
        encoder.setRenderPipelineState(mirrorComposite)
        var quad = Self.mirrorQuad(rect: rect, displayWidth: destination.width, displayHeight: destination.height)
        encoder.setVertexBytes(&quad, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentTexture(mirror, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    /// Tonemaps HDR scene colour into a display-format target.
    public func encodeResolve(into commands: MTLCommandBuffer, source: MTLTexture,
                              destination: MTLTexture, lighting: SunLighting) {
        let resolvePass = MTLRenderPassDescriptor()
        resolvePass.colorAttachments[0].texture = destination
        resolvePass.colorAttachments[0].loadAction = .dontCare
        resolvePass.colorAttachments[0].storeAction = .store
        if let encoder = commands.makeRenderCommandEncoder(descriptor: resolvePass) {
            encoder.label = "Tonemap resolve"
            encoder.setRenderPipelineState(resolve)
            encoder.setFragmentTexture(source, index: 0)
            var exposure = lighting.exposureScale
            encoder.setFragmentBytes(&exposure, length: MemoryLayout<Float>.stride, index: 0)
            // Strength stays zero unless a pyramid was actually built, so a
            // bloom target that failed to allocate resolves to a clean frame
            // instead of sampling an unwritten texture.
            var strength: Float = 0
            if settings.bloom, let pyramid = bloom.result {
                encoder.setFragmentTexture(pyramid, index: 1)
                strength = settings.bloomStrength
            } else {
                encoder.setFragmentTexture(source, index: 1)
            }
            encoder.setFragmentBytes(&strength, length: MemoryLayout<Float>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
    }
}
