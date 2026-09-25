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

        /// The bounding sphere's centre under an instance transform.
        func worldCentre(under transform: simd_float4x4) -> SIMD3<Float> {
            let centre = transform * SIMD4(worldCentre, 1)
            return SIMD3(centre.x, centre.y, centre.z)
        }

        /// How this batch draws for a camera at `eye`, under `transform`:
        /// fully, not at all, or dithered through a detail switch.
        func fade(from eye: SIMD3<Float>, transform: simd_float4x4) -> LevelOfDetail.Fade {
            guard let range = detailRange else { return .full }
            let centre = transform * SIMD4(worldCentre, 1)
            return LevelOfDetail.fade(distance: simd_distance(eye, SIMD3(centre.x, centre.y, centre.z)), range: range)
        }
    }

    let batches: [Batch]
    public let minimum: SIMD3<Float>, maximum: SIMD3<Float>
    public var triangleCount: Int { batches.reduce(0) { $0 + $1.indexCount / 3 } }
    public private(set) var bufferBytes = 0
    public private(set) var texturedBatches = 0
    /// Batches carrying a generated normal and ORM, substituted or as detail.
    public private(set) var structuredBatches = 0
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
                // Painted content is composited over a generated set only for
                // a road that paints markings. Compositing a wall's original
                // artwork treated its grey as paint and turned the wall dark.
                generated = materials.resolve(texture: texture, directory: materialDirectory,
                                              original: batch.paintsRoadMarkings ? originalImage?(texture) : nil)
            }
            // A car part takes a detail set — normal and ORM only — under its
            // own painted atlas, tiled across the atlas at the part's scale.
            var detail: MaterialLibrary.Binding? = nil
            var detailScale: Float = 1
            if generated == nil, let part = batch.carPart, let materials, let materialDirectory,
               let choice = MaterialLibrary.detail(for: part) {
                detail = materials.detailBinding(choice.material, directory: materialDirectory)
                detailScale = choice.uvScale
            }
            let albedo = generated?.albedo ?? batch.baseTexture.flatMap {
                resolveTexture($0, batch.alphaTestThreshold != nil)
            }
            let structure = generated ?? detail
            built.append(Batch(
                vertices: vertices, indices: indices, indexCount: batch.mesh.indices.count,
                draw: DrawUniforms(model: batch.mesh.transform,
                                   baseColour: material.baseColour,
                                   roughness: material.roughness,
                                   metallic: generated?.metallic == true ? 1 : material.metallic,
                                   clearcoat: material.clearcoat,
                                   clearcoatRoughness: material.clearcoatRoughness,
                                   normalStrength: material.normalStrength,
                                   alphaThreshold: batch.alphaTestThreshold ?? 0,
                                   maps: SIMD4(albedo == nil ? 0 : 1,
                                               structure == nil ? 0 : 1,
                                               structure == nil ? 0 : 1,
                                               (batch.isDeferred ? 0 : 1) | (batch.paintsRoadMarkings ? 2 : 0)
                                                   | (batch.swaysInWind ? 4 : 0) | (batch.receivesWeather ? 8 : 0)),
                                   uvScale: batch.uvInMetres ? 1 / max(generated?.worldSize ?? 1, 1e-3) : 1,
                                   uvPeriod: batch.uvInMetres ? RenderMesh.metresPeriod : 0,
                                   emissive: material.emissive, emissiveChannel: material.emissiveChannel,
                                   structureScale: detailScale),
                needsAlphaTest: batch.alphaTestThreshold != nil,
                normal: structure?.normal,
                orm: structure?.orm,
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
        structuredBatches = built.filter { $0.normal != nil }.count
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
    /// Smoke and dust. Presentation fills `particles.sources` and calls
    /// `advance` once per frame; the mirror renderer draws the same system.
    public var particles: ParticleSystem
    public let particleRenderer: ParticleRenderer
    /// Rubber on the road, laid from the same skid signal; the mirror
    /// renderer draws the same ring.
    public var skidMarks: SkidMarks
    public let skidMarkRenderer: SkidMarkRenderer
    /// Painted boxes on the road (the starting grid); the mirror renderer
    /// draws the same set.
    public var roadPaint: RoadPaint
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
    public private(set) var dynamicResolution = DynamicResolutionController(initialScale: 1.0, warmupFrames: ForwardRenderer.resolutionWarmupFrames)
    /// Frames the resolution controller ignores after a reset: the material
    /// and atlas uploads and first pipeline uses of a session's start spike
    /// the frame time, and the controller stepped down on them and stayed.
    public static let resolutionWarmupFrames = 180
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
    /// Rain on the windscreen, 0 to 1: drops refracting the picture at the
    /// resolve. The presentation sets it for the view from inside the cabin
    /// when it rains, and nothing else; a chase camera has no glass.
    public var windscreenRain: Float = 0
    /// Cloud coverage, 0 clear to 1 overcast: drawn as a layer in the sky
    /// pass and hiding the sun disc and its glare. The lighting is the
    /// caller's: see `SunLighting.overcast(_:)`.
    public var overcast: Float = 0
    /// The lens for a television or photo view; nil for every driver's view
    /// and in the race. Applied only when `settings.depthOfField` allows.
    public var depthOfField: DepthOfField?
    public let depthOfFieldRenderer: DepthOfFieldRenderer
    /// Skip batches whose bounding sphere lies outside the view. On by
    /// default; off only to measure what it saves.
    public var frustumCulling = true
    /// Batches the frustum rejected in the last frame, across the passes.
    public private(set) var lastCulledCount = 0
    /// Samplers for the normal and roughness maps, one per anisotropy the
    /// settings have asked for; see `RenderSettings.detailAnisotropy`.
    private var detailSamplers: [Int: MTLSamplerState] = [:]
    /// Mutable so a benchmark can alternate configurations within one process.
    public var settings: RenderSettings
    /// Seconds driving vertex animation (foliage). Presentation advances it;
    /// offscreen renders leave it at zero so they repeat.
    public var animationTime: Double = 0
    /// How wet the ground is, 0 dry to 1 soaked: darkens and glosses the
    /// road and terrain, and fills puddles. A scene condition, not a
    /// quality setting, so it lives here rather than in `RenderSettings`.
    public var wetness: Float = 0
    /// How hard it is raining, 0 to 1. A scene condition the presentation
    /// turns into rain particles around the camera and a dimmer sun; the
    /// renderer keeps it so the mirror and diagnostics see the same value.
    public var rain: Float = 0
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
        let shaders = try ShaderLibrary(device: device)
        let library = shaders.library
        shadersPrebuilt = shaders.prebuilt

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
        depthOfFieldRenderer = try DepthOfFieldRenderer(device: device, library: library)
        occlusion = try OcclusionRenderer(device: device, library: library)
        reflections = try ReflectionRenderer(device: device, library: library)
        motionBlur = try MotionBlurRenderer(device: device, library: library)
        particles = try ParticleSystem(device: device)
        particleRenderer = try ParticleRenderer(device: device, library: library)
        skidMarks = try SkidMarks(device: device)
        skidMarkRenderer = try SkidMarkRenderer(device: device, library: library)
        roadPaint = RoadPaint(device: device)
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
        resolveDescriptor.vertexFunction = library.makeFunction(name: "resolveVertex")
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

    /// The largest axis scale of a transform, to grow a bounding radius by.
    static func maxScale(of transform: simd_float4x4) -> Float {
        max(simd_length(SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)),
            simd_length(SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)),
            simd_length(SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z)), 1e-4)
    }

    /// The sampler for the normal and roughness maps at the settings' detail
    /// anisotropy: the surface sampler's filtering at a lower anisotropy. The
    /// sampler is immutable once made, so one is kept per value used.
    func detailSampler() -> MTLSamplerState {
        let anisotropy = min(max(settings.detailAnisotropy, 1), 16)
        if let cached = detailSamplers[anisotropy] { return cached }
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear
        descriptor.sAddressMode = .repeat
        descriptor.tAddressMode = .repeat
        descriptor.maxAnisotropy = anisotropy
        let made = device.makeSamplerState(descriptor: descriptor) ?? sampler
        detailSamplers[anisotropy] = made
        return made
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
    public func resetDynamicResolution() {
        dynamicResolution = DynamicResolutionController(initialScale: 1.0, warmupFrames: Self.resolutionWarmupFrames)
    }

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
        if resetsHistoryPerRender {
            occlusion.resetNoise()
            reflections.resetNoise()
            shadows.invalidate()
        }
        encodeFrame(into: commands, targets: targets, resources: resources, instances: instances,
                    camera: camera, lighting: lighting, aspect: Float(width) / Float(max(height, 1)))
        encodeResolve(into: commands, source: tonemapSource(targets), destination: targets.display,
                      lighting: lighting, depthOfField: depthOfFieldRenderer.result)
        if let mirror, let mirrorView {
            encodeMirrorComposite(into: commands, mirror: mirrorView, destination: targets.display, rect: mirror.rect)
        }
        commands.commit()
        commands.waitUntilCompleted()
        if let error = commands.error { throw RenderError.unavailable("GPU error: \(error)") }
        lastGPUTime = commands.gpuEndTime - commands.gpuStartTime
        lastPassTimes = passTimer?.resolve() ?? []

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            targets.display.getBytes(raw.baseAddress!, bytesPerRow: width * 4,
                                    from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return pixels
    }

    /// Renders one frame offscreen and returns as soon as it is committed,
    /// like presentation does, so several frames can be in flight and the
    /// GPU stays busy: an idle GPU lowers its clock, and a harness that
    /// renders a frame and waits for it measures that lowered clock. The
    /// per-frame buffers are ring-buffered for `maximumFramesInFlight`, which
    /// callers must not exceed. `completion` runs on the completion handler's
    /// thread with the frame's GPU time, which is also recorded for dynamic
    /// resolution. No history reset and no readback: this is an interactive
    /// frame, not a verification render.
    public func submit(resources: [SceneResources], instances: [RenderInstance],
                       camera: RenderCamera, lighting: SunLighting,
                       width: Int, height: Int, mirror: MirrorRequest? = nil,
                       completion: @escaping @Sendable (Double) -> Void) throws {
        let targets = try targets(outputWidth: width, outputHeight: height)
        guard let commands = queue.makeCommandBuffer() else {
            throw RenderError.unavailable("Could not create a command buffer")
        }
        commands.label = "Submitted frame"
        let mirrorView = try mirror.map { try encodeMirrorView(into: commands, $0, lighting: lighting) }
        encodeFrame(into: commands, targets: targets, resources: resources, instances: instances,
                    camera: camera, lighting: lighting, aspect: Float(width) / Float(max(height, 1)))
        encodeResolve(into: commands, source: tonemapSource(targets), destination: targets.display,
                      lighting: lighting, depthOfField: depthOfFieldRenderer.result)
        if let mirror, let mirrorView {
            encodeMirrorComposite(into: commands, mirror: mirrorView, destination: targets.display, rect: mirror.rect)
        }
        commands.addCompletedHandler { [weak self] buffer in
            let seconds = buffer.gpuEndTime - buffer.gpuStartTime
            if seconds > 0 { self?.recordFrameTime(seconds) }
            completion(seconds)
        }
        commands.commit()
    }

    /// Frames that may be in flight at once through `submit`: the depth of
    /// the per-frame buffer rings.
    public static let maximumFramesInFlight = 3

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
        passTimer?.beginFrame()
        atmosphere.update(into: commands, lighting: lighting, cameraAltitude: camera.eye.z, timer: passTimer)
        let cascades = ShadowCascades(camera: camera, sunDirection: lighting.direction,
                                      aspect: aspect, count: settings.shadowCascades,
                                      resolution: shadows.resolution,
                                      shadowDistance: shadowDistance).cascades
        // The far cascades refresh on a cadence; the frame samples each slice
        // with the matrix it was actually rendered with.
        let sampled = shadows.encode(into: commands, resources: resources, instances: instances, cascades: cascades,
                                     animationTime: Float(animationTime),
                                     refreshInterval: settings.staticShadowRefreshInterval, timer: passTimer)
        encode(into: commands, targets: targets, resources: resources, instances: instances,
               camera: camera, lighting: lighting, cascades: sampled, aspect: aspect)

        if targets.upscaled != nil && settings.upscalingMode == .spatial {
            // Blur before the scaler: a quarter of the pixels, and the scaler
            // keeps no history the blur could corrupt.
            if settings.motionBlur, targets.postAtRenderResolution, targets.velocity != nil, targets.postColour != nil {
                postProduced = motionBlur.encode(into: commands, targets: targets, source: targets.colour, timer: passTimer) != nil
            }
            do {
                let key = SIMD2(targets.renderWidth, targets.renderHeight)
                if spatialUpscalers[key]?.matches(renderWidth: targets.renderWidth, renderHeight: targets.renderHeight,
                                                 outputWidth: targets.outputWidth, outputHeight: targets.outputHeight) != true {
                    spatialUpscalers[key] = try SpatialUpscaler(device: device,
                                                                renderWidth: targets.renderWidth, renderHeight: targets.renderHeight,
                                                                outputWidth: targets.outputWidth, outputHeight: targets.outputHeight)
                    upscalerBuildCount += 1
                }
                spatialUpscaler = spatialUpscalers[key]
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
            postProduced = motionBlur.encode(into: commands, targets: targets, source: source, timer: passTimer) != nil
        } else if !settings.motionBlur {
            motionBlur.discard()
        }

        // The lens blur, on the image the tonemapper will see, before the
        // bloom so the glow is of the blurred picture.
        if settings.depthOfField, let lens = depthOfField {
            depthOfFieldRenderer.encode(into: commands, source: tonemapSource(targets), depth: targets.depth,
                                        lens: lens, near: camera.near, timer: passTimer)
        } else {
            depthOfFieldRenderer.discard()
        }

        // After the upscaler, so the pyramid is built at output resolution from
        // the image that will actually be tonemapped. Building it at render
        // resolution instead would be cheaper but would feed the upscaler a
        // glow it then has to track temporally.
        if settings.bloom && settings.bloomStrength > 0 {
            bloom.encode(into: commands, source: tonemapSource(targets),
                         threshold: settings.bloomThreshold, exposureScale: lighting.exposureScale, timer: passTimer)
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
        shadows.invalidate()
    }

    public private(set) var lastUpscalerError: String?
    /// Diagnostic: how many times a scaler has been constructed. Should be
    /// one per resolution, not one per frame.
    public private(set) var upscalerBuildCount = 0
    /// Whether the shaders came from a prebuilt library rather than source.
    public private(set) var shadersPrebuilt = false
    /// Per-pass GPU timing for diagnostics; nil in ordinary use. Set it,
    /// render offscreen, and read `lastPassTimes`.
    public var passTimer: PassTimer?
    public private(set) var lastPassTimes: [PassTimer.Sample] = []
    /// Offscreen `render` calls start each frame from a cold noise phase and
    /// history so they repeat exactly. Tests of temporal accumulation turn
    /// this off to render a sequence.
    public var resetsHistoryPerRender = true
    /// The sun's position in uv space for the last encoded frame, when it is
    /// in front of the camera; the resolve draws the glare there.
    public private(set) var sunScreenPosition: SIMD2<Float>?
    /// The depth target of the last encoded frame, for the glare's occlusion
    /// and the heat haze, and that frame's projection near.
    private var lastDepth: MTLTexture?
    private var lastNear: Float = 0.25
    /// Spatial scalers by render size, kept so a dynamic-resolution step
    /// never constructs one mid-race; `prewarmSpatialScalers` fills it.
    private var spatialUpscalers: [SIMD2<Int>: SpatialUpscaler] = [:]
    private var prewarmedOutput: SIMD2<Int>?

    /// Builds the spatial scaler for every step of the resolution ladder at
    /// this output size, so the first frame at a new scale does not stall.
    /// Returns how many it built.
    @discardableResult
    public func prewarmSpatialScalers(outputWidth: Int, outputHeight: Int) throws -> Int {
        guard settings.upscaling, settings.upscalingMode == .spatial else { return 0 }
        var built = 0
        for scale in DynamicResolutionController.ladder where scale < 0.999 && scale <= settings.renderScale + 1e-4 {
            let render = settings.renderSize(output: (outputWidth, outputHeight), scale: scale)
            let key = SIMD2(render.width, render.height)
            if spatialUpscalers[key]?.matches(renderWidth: render.width, renderHeight: render.height,
                                             outputWidth: outputWidth, outputHeight: outputHeight) == true { continue }
            spatialUpscalers[key] = try SpatialUpscaler(device: device, renderWidth: render.width, renderHeight: render.height,
                                                        outputWidth: outputWidth, outputHeight: outputHeight)
            upscalerBuildCount += 1
            built += 1
        }
        prewarmedOutput = SIMD2(outputWidth, outputHeight)
        return built
    }

    /// Pre-warms once per output size; presentation calls this every frame.
    func prewarmIfNeeded(outputWidth: Int, outputHeight: Int) throws {
        guard prewarmedOutput != SIMD2(outputWidth, outputHeight) else { return }
        try prewarmSpatialScalers(outputWidth: outputWidth, outputHeight: outputHeight)
    }

    public func encode(into commands: MTLCommandBuffer, targets: FrameTargets,
                       resources: [SceneResources], instances: [RenderInstance],
                       camera: RenderCamera, lighting: SunLighting,
                       cascades: [ShadowCascades.Cascade], aspect: Float) {
        let unjittered = camera.viewProjection(aspect: aspect)
        let projection = RenderCamera.jittered(camera.projection(aspect: aspect), jitter: currentJitter,
                                               renderWidth: targets.renderWidth,
                                               renderHeight: targets.renderHeight)
        // Where the sun is on screen, for the glare. A direction, so w = 0.
        let sunClip = unjittered * SIMD4(lighting.direction, 0)
        if sunClip.w > 1e-4 {
            let ndc = SIMD2(sunClip.x, sunClip.y) / sunClip.w
            sunScreenPosition = SIMD2(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5)
        } else {
            sunScreenPosition = nil
        }
        lastDepth = targets.depth
        lastNear = camera.near
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
            animationTime: Float(animationTime), wetness: min(max(wetness, 0), 1), overcast: overcast)

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
        lastCulledCount = 0
        // The unjittered frustum: the jitter is a fraction of a pixel and the
        // sphere test is conservative by a whole batch.
        let frustum: ViewFrustum? = frustumCulling ? ViewFrustum(viewProjection: unjittered) : nil

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
            passTimer?.attach(prepass, "Depth prepass")
            if let encoder = commands.makeRenderCommandEncoder(descriptor: prepass) {
                encoder.label = "Depth prepass"
                encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
                encoder.setFragmentSamplerState(sampler, index: 0)
                encodePrepassDraws(on: encoder, resources: resources, instances: instances, eye: camera.eye, frustum: frustum)
                encoder.endEncoding()
            }
            occlusion.encode(into: commands, depth: targets.depth, projection: projection,
                             view: camera.view(), sunDirection: lighting.direction,
                             ambient: settings.ambientOcclusion, contact: settings.contactShadows, timer: passTimer)
            scenePass.depthAttachment.loadAction = .load
        } else {
            occlusion.discard()
            scenePass.depthAttachment.loadAction = .clear
        }
        frame.renderSize.w = occlusion.result == nil ? 0 : 1

        passTimer?.attach(scenePass, "Sky and forward opaque")
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: scenePass) else { return }
        encoder.label = "Sky and forward opaque"
        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 1)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentSamplerState(detailSampler(), index: 2)
        encoder.setFragmentTexture(occlusion.result ?? neutralOcclusion, index: 7)

        // Optional depth-only prepass. Everything that will shade writes depth
        // first, so the shading pass touches each visible pixel once.
        if usesPrepass && !wantsOcclusion {
            encodePrepassDraws(on: encoder, resources: resources, instances: instances, eye: camera.eye, frustum: frustum)
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

            let instanceScale = Self.maxScale(of: instance.transform)
            for (batchIndex, batch) in scene.batches.enumerated() {
                if batch.isDriver && !instance.drawsDriver { continue }
                let fade = batch.fade(from: camera.eye, transform: instance.transform)
                if !fade.visible { continue }
                if let frustum, !frustum.mayContain(sphereAt: batch.worldCentre(under: instance.transform),
                                                    radius: batch.worldRadius * instanceScale) {
                    lastCulledCount += 1
                    continue
                }
                // A batch the prepass skipped has no depth to match; it tests
                // and writes depth here like a frame without a prepass.
                if usesPrepass { encoder.setDepthStencilState(batch.prepass ? equalDepthState : depthState) }
                if batch.isDeferred {
                    let centre = instance.transform * SIMD4(batch.worldCentre, 1)
                    deferred.append(DeferredDraw(instance: instanceIndex, batch: batchIndex,
                                                 distance: simd_length(SIMD3(centre.x, centre.y, centre.z) - camera.eye)))
                    continue
                }
                draw(batch, on: encoder, blendOverride: nil, mirroredInstance: instanceMirrored, fade: fade)
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

        // Skid marks darken the road before the reflections trace reads it,
        // so a mark shows in the paint of a car standing on it.
        if settings.skidMarks {
            skidMarkRenderer.encodePaint(into: commands, targets: targets, paint: roadPaint, frame: &frame, timer: passTimer)
            skidMarkRenderer.encode(into: commands, targets: targets, marks: skidMarks, frame: &frame, timer: passTimer)
        }

        if settings.screenSpaceReflections != .off {
            reflections.encode(into: commands, targets: targets, projection: projection, view: camera.view(),
                               sunDirection: lighting.direction, roughnessCutoff: settings.reflectionRoughnessCutoff,
                               quality: settings.screenSpaceReflections, skyView: atmosphere.skyView,
                               viewProjection: unjittered, previousViewProjection: previousViewProjection ?? unjittered,
                               temporal: settings.reflectionTemporal, timer: passTimer)
        } else {
            reflections.discard()
        }

        // Smoke and dust over the opaque scene, after the reflections so a
        // puff never leaves a ghost in the road: depth-tested by hand against
        // the stored opaque depth, colour only.
        if settings.particles {
            particleRenderer.encode(into: commands, targets: targets, system: particles, frame: &frame, near: camera.near, timer: passTimer)
        }
    }

    /// Depth-only draws of everything opaque that will later shade. Shared by
    /// the in-encoder prepass and the standalone one so the two write the
    /// same depth.
    private func encodePrepassDraws(on encoder: MTLRenderCommandEncoder,
                                    resources: [SceneResources], instances: [RenderInstance],
                                    eye: SIMD3<Float>, frustum: ViewFrustum?) {
        encoder.setDepthStencilState(prepassDepthState)
        encoder.setFrontFacing(.counterClockwise)
        for instance in instances {
            guard resources.indices.contains(instance.resource) else { continue }
            let scene = resources[instance.resource]
            var instanceUniforms = InstanceUniforms(model: instance.transform)
            encoder.setVertexBytes(&instanceUniforms, length: MemoryLayout<InstanceUniforms>.stride, index: 5)
            let instanceMirrored = simd_determinant(instance.transform) < 0
            let instanceScale = Self.maxScale(of: instance.transform)
            for batch in scene.batches {
                if batch.isDeferred { continue }
                if batch.isDriver && !instance.drawsDriver { continue }
                let fade = batch.fade(from: eye, transform: instance.transform)
                if !fade.visible { continue }
                if !batch.prepass { continue }
                if let frustum, !frustum.mayContain(sphereAt: batch.worldCentre(under: instance.transform),
                                                    radius: batch.worldRadius * instanceScale) {
                    lastCulledCount += 1
                    continue
                }
                encoder.setRenderPipelineState(batch.needsAlphaTest ? depthOnlyCutout : depthOnly)
                let mirrored = batch.mirrored != instanceMirrored
                encoder.setCullMode(batch.culls ? (mirrored ? .front : .back) : .none)
                var draw = batch.draw
                draw.setFade(fade)
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
                      blendOverride: Bool?, mirroredInstance: Bool, forceTwoSided: Bool = false,
                      fade: LevelOfDetail.Fade = .full) {
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
        draw.setFade(fade)
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
        mirror.renderer.wetness = wetness
        mirror.renderer.rain = rain
        mirror.renderer.particles = particles
        mirror.renderer.skidMarks = skidMarks
        mirror.renderer.roadPaint = roadPaint
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
                              destination: MTLTexture, lighting: SunLighting,
                              depthOfField blurred: MTLTexture? = nil) {
        let resolvePass = MTLRenderPassDescriptor()
        resolvePass.colorAttachments[0].texture = destination
        resolvePass.colorAttachments[0].loadAction = .dontCare
        resolvePass.colorAttachments[0].storeAction = .store
        passTimer?.attach(resolvePass, "Tonemap resolve")
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
            // Sun glare: only when the setting is on, the sun is in front of
            // the camera and within a frame's width of the view. Occlusion is
            // decided in the shader from the depth around the sun.
            var glare = GlareUniforms(sun: .zero, colour: .zero, haze: .zero, focus: .zero, rain: .zero)
            // Rain on the glass: only a view from inside the cabin asks for it.
            if windscreenRain > 0 {
                glare.rain = SIMD4(min(windscreenRain, 1), Float(animationTime),
                                   Float(destination.width) / Float(max(destination.height, 1)), 0)
            }
            // Heat haze grows with the sun's height: nothing below 17°, full
            // above 53°. Needs the depth, like the glare and the lens blur.
            let wantsHaze = settings.heatHaze && settings.heatHazeStrength > 0
            let lens = blurred != nil ? depthOfField : nil
            if let depth = lastDepth, wantsHaze || lens != nil {
                let heat = wantsHaze ? min(max((lighting.direction.z - 0.3) / 0.5, 0), 1) * settings.heatHazeStrength : 0
                glare.haze = SIMD4(heat, Float(animationTime), lastNear, 1 / Float(max(destination.height, 1)))
                encoder.setFragmentTexture(depth, index: 2)
            } else {
                encoder.setFragmentTexture(source, index: 2)
            }
            if let lens, let blurred {
                let dof = DepthOfFieldRenderer.uniforms(lens, near: lastNear, targetWidth: blurred.width, targetHeight: blurred.height)
                glare.focus = SIMD4(dof.focus.x, dof.focus.y, dof.focus.z, 1)
                encoder.setFragmentTexture(blurred, index: 3)
            } else {
                encoder.setFragmentTexture(source, index: 3)
            }
            if settings.sunGlare, settings.sunGlareStrength > 0, let sun = sunScreenPosition, let depth = lastDepth,
               sun.x > -0.5, sun.x < 1.5, sun.y > -0.5, sun.y < 1.5 {
                // Under cloud the disc is hidden and its glare goes with it.
                glare.sun = SIMD4(sun.x, sun.y, Float(destination.width) / Float(max(destination.height, 1)),
                                  settings.sunGlareStrength * (1 - min(max(overcast, 0), 1)))
                glare.colour = SIMD4(lighting.illuminance * lighting.exposureScale, 0)
                encoder.setVertexTexture(depth, index: 2)
            } else {
                encoder.setVertexTexture(source, index: 2)
            }
            encoder.setVertexBytes(&glare, length: MemoryLayout<GlareUniforms>.stride, index: 2)
            encoder.setFragmentBytes(&glare, length: MemoryLayout<GlareUniforms>.stride, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
    }
}

/// Mirrors `GlareUniforms` in `Resolve.metal`.
struct GlareUniforms {
    var sun: SIMD4<Float>
    var colour: SIMD4<Float>
    var haze: SIMD4<Float>
    var focus: SIMD4<Float>
    var rain: SIMD4<Float>
}
