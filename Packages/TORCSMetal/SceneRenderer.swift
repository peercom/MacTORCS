// SPDX-License-Identifier: GPL-2.0-only
// Material/state interpretation follows TORCS grloadac/grvtxtable/grscene and
// PLIB ssgSimpleState. Copyright (C) 2001 Steve Baker, Christophe Guionneau;
// TORCS contributors' notices remain in the pinned reference sources.
// Derived PLIB scheduling portions converted from LGPL-2.0-or-later to GPL v2
// under LGPL v2 section 3, effective 2026-09-23; original notices in Upstream.
import Foundation
import MetalKit
import simd
import TORCSAssets
import TORCSTrack
import os
import CryptoKit

public struct SceneInstance: Sendable {
    public let resource: Int
    public let transform: simd_float4x4
    public let reflection: CarReflection?
    public let hidesDriver: Bool
    public let colorOverride: SIMD4<Float>?
    public let anchor:SceneAnchor
    public let car:SceneCarPlacement?
    public init(resource: Int,transform: simd_float4x4 = matrix_identity_float4x4,reflection: CarReflection? = nil,hidesDriver: Bool=false,colorOverride: SIMD4<Float>?=nil,anchor:SceneAnchor = .cars,car:SceneCarPlacement?=nil) { self.colorOverride=colorOverride;self.resource=resource;self.transform=transform;self.reflection=reflection;self.hidesDriver=hidesDriver;self.anchor=anchor;self.car=car }
}

@MainActor public final class SceneRenderer: NSObject, MTKViewDelegate {
    struct Uniforms {
        var model,normalMatrix,viewProjection,view: simd_float4x4
        var color,specular,emission,ambient: SIMD4<Float>
        var parameters: SIMD4<Float> // shininess, alpha threshold, lighting, alpha test
        var maps: SIMD4<UInt32>
        var reflection,shadowLinear,shadowOffset: SIMD4<Float>
    }
    struct EnvironmentUniforms {
        var ambient,diffuse,specular,light,fogColor,fog: SIMD4<Float>
    }
    struct ShadowUniforms { var viewProjection,view: simd_float4x4;var normal: SIMD4<Float> }
    struct Draw {
        let vertex,index: MTLBuffer
        let batch: SceneBatch
        let textures: [MTLTexture]
        let minimumAlpha:SIMD4<Float>
        let resource,batchIndex: Int
    }
    public let geometries: [SceneGeometry]
    public var geometry: SceneGeometry { geometries[0] }
    public private(set) var instances: [SceneInstance]
    public var camera: SceneCamera
    public var mirror: RearViewMirror?
    public private(set) var lastRenderError: String?
    private var mirrorColor,mirrorDepth: MTLTexture?
    private(set) var mirrorAllocationCount=0
    public var warnings: [String] {
        var result=Set(geometries.flatMap(\.warnings))
        if geometries.contains(where: { $0.batches.contains(where: { $0.mesh.mapLevel<0 }) }) && (reflectionTexture == nil || environmentShadeTexture == nil || instances.contains(where: { $0.reflection == nil && geometries[$0.resource].batches.contains(where: { $0.mesh.mapLevel<0 }) })) {
            result.insert("Car environment maps require session textures and per-car reflection state.")
        }
        if instances.contains(where: { instance in
            geometries[instance.resource].batches.contains(where: { $0.mesh.indexed && $0.mesh.mapLevel <= -3 }) && (carTrackShadowTexture == nil || instance.reflection?.shadowOffset.w != 1)
        }) { result.insert("Track shadows on cars require the track texture and raw loader bounds; recompile older sessions to include bounds.") }
        return result.sorted()
    }
    public var triangleCount: Int { instances.reduce(0) { count,instance in count+geometries[instance.resource].batches.filter { !instance.hidesDriver || !$0.isDriver }.reduce(0) { $0+$1.indices.count/3 } } }
    let device: MTLDevice,queue: MTLCommandQueue
    struct Pipelines {
        let opaque,blended,opaqueAlphaTest,blendedAlphaTest,shadowPipeline,shadowAlphaTest,backgroundPipeline,mirrorPipeline,lightPipeline,lightAlphaTest: MTLRenderPipelineState
    }
    private let pipelines:[Int:Pipelines]
    public var smoothEdges=false
    public var supportsEdgeSmoothing:Bool { pipelines[4] != nil }
    public var rasterSampleCount:Int { smoothEdges && supportsEdgeSmoothing ? 4:1 }
    struct MultisampleTargets { let color,depth:MTLTexture }
    private var multisampleTargets:[Bool:MultisampleTargets]=[:]
    private(set) var multisampleAllocationCount=0
    public var usesMemorylessMultisampling:Bool { device.supportsFamily(.apple1) }
    let writeDepth,readDepth,backgroundDepth: MTLDepthStencilState
    let sampler,anisotropicSampler: MTLSamplerState
    public var enhancedFiltering=false
    public var enhancedVegetation=false
    private var vegetationState:VegetationRenderState?
    public var vegetationForest:VegetationForest? { vegetationState?.forest }
    public private(set) var lastVegetationDrawCount=0
    public private(set) var lastVegetationTriangleCount=0
    public var carReflectionsEnabled=true
    private var reflectionTexture,environmentShadeTexture,carTrackShadowTexture: MTLTexture?
    private var carEnvironmentMinimumAlpha=SIMD4<Float>(repeating:1)
    public var carTrackShadowsEnabled=true
    private var shadowTextures: [MTLTexture?]=[nil]
    private var sceneShadows: [SceneShadow]=[]
    public var shadowView=ShadowView()
    public private(set) var lastShadowDrawCount=0
    public var shadowTextureCount: Int { Set(shadowTextures.compactMap { $0.map(ObjectIdentifier.init) }).count }
    private let lightState:CarLightRenderState
    private var drawOrder=SceneDrawOrder()
    public var lightView=ShadowView()
    public private(set) var lastLightDrawCount=0
    public var lightRandomDraws:UInt64 { lightState.randomDraws }
    public var lightTextureCount:Int { lightState.textureCount }
    public private(set) var lastSubmissionSHA256: String?
    public private(set) var lastSceneCommands:[SceneDrawCommand]=[]
    public private(set) var lastMirrorCommands:[SceneDrawCommand]=[]
    public private(set) var lastGPUTime: Double=0
    private var graphics: TrackGraphics?
    private var backgroundTexture: MTLTexture?
    private var backgroundStrips: [(MTLBuffer,Int)]=[]
    private var draws: [Draw]=[]
    private var sceneTextures: [SHA256.Digest:MTLTexture]=[:]
    public var sceneTextureCount: Int { sceneTextures.count }
    /// Hash actual mip bytes and layout, not an untrusted cache identity string.
    private static func textureIdentity(_ texture: CompiledTexture) -> SHA256.Digest {
        var digest=SHA256()
        for level in texture.pyramid.levels {
            var layout=SIMD4<Int>(level.width,level.height,level.channels,level.pixels.count)
            withUnsafeBytes(of:&layout) { digest.update(data:Data($0)) }
            level.pixels.withUnsafeBytes { digest.update(data:Data($0)) }
        }
        return digest.finalize()
    }
    private func environmentTexture(_ texture: CompiledTexture) throws -> MTLTexture {
        // Reuse immutable scene textures. External environment replacements are
        // not retained in this cache, so repeated setters cannot grow it forever.
        if let shared=sceneTextures[Self.textureIdentity(texture)] { return shared }
        return try MetalTextureUpload.make(device:device,pyramid:texture.pyramid)
    }
    private let signposter=OSSignposter(subsystem:"org.torcs.mac",category:"Scene rendering")
    public convenience init(scene: LoadedScene,view: MTKView? = nil) throws { try self.init(scenes:[scene],view:view) }
    public init(scenes: [LoadedScene],view: MTKView? = nil,vegetationResource:Int?=nil) throws {
        guard !scenes.isEmpty,scenes.count<=128 else { throw ACError.invalid("Invalid scene resource count") }
        let geometryList=try scenes.map { try SceneGeometry($0.asset.scene,driverSelector:$0.asset.options.car) }
        geometries=geometryList;camera=SceneCamera(geometry:geometryList[0])
        instances=scenes.indices.map { SceneInstance(resource:$0) }
        try drawOrder.publish(instances)
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else { throw RendererError.unavailable("Metal device unavailable") }
        self.device=device;self.queue=queue;lightState=try CarLightRenderState(device:device)
        let bundle: Bundle
        if Bundle.main.bundleURL.pathExtension=="app" {
            guard let url=Bundle.main.url(forResource:"TORCSMac_TORCSMetal",withExtension:"bundle"),let b=Bundle(url:url) else { throw RendererError.unavailable("Packaged Metal shaders missing") };bundle=b
        } else { bundle = .module }
        guard let url=bundle.url(forResource:"Scene",withExtension:"metal") else { throw RendererError.unavailable("Scene shaders missing") }
        let options=MTLCompileOptions();options.preserveInvariance=true
        let library=try device.makeLibrary(source:String(contentsOf:url,encoding:.utf8),options:options)
        func makePipelines(samples:Int) throws -> Pipelines {
        func pipeline(blend: Bool,alphaTest: Bool) throws -> MTLRenderPipelineState {
            let p=MTLRenderPipelineDescriptor();p.vertexFunction=library.makeFunction(name:"assetVertex")
            var enabled=alphaTest;let constants=MTLFunctionConstantValues()
            constants.setConstantValue(&enabled,type:.bool,index:0)
            p.fragmentFunction=try library.makeFunction(name:"assetFragment",constantValues:constants)
            p.colorAttachments[0].pixelFormat = .rgba8Unorm;p.depthAttachmentPixelFormat = .depth32Float
            p.rasterSampleCount=samples
            let a=p.colorAttachments[0]!;a.isBlendingEnabled=blend
            a.sourceRGBBlendFactor = .sourceAlpha;a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.sourceAlphaBlendFactor = .sourceAlpha;a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor:p)
        }
        // Eliminate discard from materials that never alpha-test. Keeping an
        // inactive runtime discard caused sparse mip/blend repeat variance on M2.
        let opaque=try pipeline(blend:false,alphaTest:false),blended=try pipeline(blend:true,alphaTest:false)
        let opaqueAlphaTest=try pipeline(blend:false,alphaTest:true),blendedAlphaTest=try pipeline(blend:true,alphaTest:true)
        let shadowDescriptor=MTLRenderPipelineDescriptor()
        shadowDescriptor.vertexFunction=library.makeFunction(name:"shadowVertex")
        func shadowFunction(_ enabled:Bool) throws -> MTLFunction {
            var value=enabled;let constants=MTLFunctionConstantValues();constants.setConstantValue(&value,type:.bool,index:0)
            return try library.makeFunction(name:"shadowFragment",constantValues:constants)
        }
        shadowDescriptor.fragmentFunction=try shadowFunction(false)
        shadowDescriptor.colorAttachments[0].pixelFormat = .rgba8Unorm;shadowDescriptor.depthAttachmentPixelFormat = .depth32Float
        let attachment=shadowDescriptor.colorAttachments[0]!
        attachment.isBlendingEnabled=true;attachment.sourceRGBBlendFactor = .sourceAlpha;attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .sourceAlpha;attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        shadowDescriptor.rasterSampleCount=samples
        let shadowPipeline=try device.makeRenderPipelineState(descriptor:shadowDescriptor)
        shadowDescriptor.fragmentFunction=try shadowFunction(true)
        let shadowAlphaTest=try device.makeRenderPipelineState(descriptor:shadowDescriptor)
        let backgroundDescriptor=MTLRenderPipelineDescriptor()
        backgroundDescriptor.vertexFunction=library.makeFunction(name:"backgroundVertex");backgroundDescriptor.fragmentFunction=library.makeFunction(name:"backgroundFragment")
        backgroundDescriptor.colorAttachments[0].pixelFormat = .rgba8Unorm;backgroundDescriptor.depthAttachmentPixelFormat = .depth32Float
        let skyBlend=backgroundDescriptor.colorAttachments[0]!
        skyBlend.isBlendingEnabled=true;skyBlend.sourceRGBBlendFactor = .sourceAlpha;skyBlend.destinationRGBBlendFactor = .oneMinusSourceAlpha
        skyBlend.sourceAlphaBlendFactor = .sourceAlpha;skyBlend.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        backgroundDescriptor.rasterSampleCount=samples
        let backgroundPipeline=try device.makeRenderPipelineState(descriptor:backgroundDescriptor)
        let mirrorDescriptor=MTLRenderPipelineDescriptor()
        mirrorDescriptor.vertexFunction=library.makeFunction(name:"mirrorVertex");mirrorDescriptor.fragmentFunction=library.makeFunction(name:"mirrorFragment")
        mirrorDescriptor.colorAttachments[0].pixelFormat = .rgba8Unorm;mirrorDescriptor.depthAttachmentPixelFormat = .depth32Float
        mirrorDescriptor.rasterSampleCount=samples
        let mirrorPipeline=try device.makeRenderPipelineState(descriptor:mirrorDescriptor)
        return Pipelines(opaque:opaque,blended:blended,opaqueAlphaTest:opaqueAlphaTest,blendedAlphaTest:blendedAlphaTest,shadowPipeline:shadowPipeline,shadowAlphaTest:shadowAlphaTest,backgroundPipeline:backgroundPipeline,mirrorPipeline:mirrorPipeline,lightPipeline:try CarLightRenderState.pipeline(device:device,library:library,samples:samples,alphaTest:false),lightAlphaTest:try CarLightRenderState.pipeline(device:device,library:library,samples:samples,alphaTest:true))
        }
        // Compile both variants at load time, never when toggling during driving.
        var variants=[1:try makePipelines(samples:1)]
        if device.supportsTextureSampleCount(4) { variants[4]=try makePipelines(samples:4) }
        pipelines=variants
        let skyDepth=MTLDepthStencilDescriptor();skyDepth.depthCompareFunction = .always;skyDepth.isDepthWriteEnabled=false
        guard let skyState=device.makeDepthStencilState(descriptor:skyDepth) else { throw RendererError.unavailable("Background depth state unavailable") };backgroundDepth=skyState
        func depth(write: Bool) throws -> MTLDepthStencilState {
            let d=MTLDepthStencilDescriptor();d.depthCompareFunction = .lessEqual;d.isDepthWriteEnabled=write
            guard let state=device.makeDepthStencilState(descriptor:d) else { throw RendererError.unavailable("Depth state unavailable") };return state
        }
        writeDepth=try depth(write:true);readDepth=try depth(write:false)
        let s=MTLSamplerDescriptor();s.minFilter = .linear;s.magFilter = .linear;s.mipFilter = .linear
        s.sAddressMode = .repeat;s.tAddressMode = .repeat
        guard let sampler=device.makeSamplerState(descriptor:s) else { throw RendererError.unavailable("Sampler unavailable") };self.sampler=sampler
        s.maxAnisotropy=4
        guard let enhanced=device.makeSamplerState(descriptor:s) else { throw RendererError.unavailable("Anisotropic sampler unavailable") };anisotropicSampler=enhanced
        // White is the multiplicative identity for an intentionally absent layer.
        // A referenced but missing texture is always a load error.
        let white=try MetalTextureUpload.make(device:device,pyramid:TexturePyramid(image:TextureImage(width:1,height:1,channels:4,pixels:[255,255,255,255]),filename:"white",options:.init(mipmaps:false)))
        var sharedTextures: [SHA256.Digest:MTLTexture]=[:],sharedMinimumAlpha:[SHA256.Digest:Float]=[:]
        for (resource,scene) in scenes.enumerated() {
        var textures: [String:MTLTexture]=[:],minimumAlphas:[String:Float]=[:]
        for (name,texture) in scene.textures {
            let key=Self.textureIdentity(texture)
            let gpu:MTLTexture
            if let existing=sharedTextures[key] { gpu=existing } else { gpu=try MetalTextureUpload.make(device:device,pyramid:texture.pyramid);sharedTextures[key]=gpu;sharedMinimumAlpha[key]=SceneAlphaState.minimumAlpha(texture.pyramid) }
            textures[name]=gpu;minimumAlphas[name]=sharedMinimumAlpha[key]!
        }
        for (batchIndex,batch) in geometryList[resource].batches.enumerated() {
            guard let vertices=device.makeBuffer(bytes:batch.vertices,length:batch.vertices.count*MemoryLayout<SceneVertex>.stride),
                  let indices=device.makeBuffer(bytes:batch.indices,length:batch.indices.count*MemoryLayout<UInt32>.stride) else { throw RendererError.unavailable("Scene buffers unavailable") }
            var bound: [MTLTexture]=[];var minimumAlpha=SIMD4<Float>(repeating:1)
            for layer in 0..<4 {
                if let name=batch.mesh.states[layer]?.texture {
                    guard let texture=textures[name] else { throw ACError.invalid("Missing scene texture: \(name)") };bound.append(texture);minimumAlpha[layer]=minimumAlphas[name]!
                } else { bound.append(white) }
            }
            draws.append(Draw(vertex:vertices,index:indices,batch:batch,textures:bound,minimumAlpha:minimumAlpha,resource:resource,batchIndex:batchIndex))
        }
        }
        sceneTextures=sharedTextures
        if let resource=vegetationResource {
            guard scenes.indices.contains(resource) else { throw ACError.invalid("Invalid vegetation scene resource") }
            if let atlas=scenes[resource].textures[VegetationForest.textureName],let image=atlas.pyramid.levels.first,
               let texture=sharedTextures[Self.textureIdentity(atlas)] {
                let forest=VegetationForest(geometry:geometryList[resource],atlas:image)
                if !forest.placements.isEmpty { vegetationState=try VegetationRenderState(forest:forest,resource:resource,texture:texture,device:device,library:library) }
            }
        }
        super.init()
        if let view {
            view.device=device;view.colorPixelFormat = .rgba8Unorm;view.depthStencilPixelFormat = .depth32Float
            view.clearColor=MTLClearColor(red:0.16,green:0.22,blue:0.29,alpha:1);view.delegate=self
        }
    }
    /// Load track resources once; no asset decoding or GPU texture allocation per frame.
    public func setEnvironment(_ value: TrackGraphics?,background: CompiledTexture? = nil) throws {
        let texture=try background.map { try environmentTexture($0) }
        var buffers:[(MTLBuffer,Int)]=[]
        if let value,texture != nil {
            for strip in TrackBackground.strips(type:value.backgroundType) {
                guard let buffer=device.makeBuffer(bytes:strip,length:strip.count*MemoryLayout<ShadowVertex>.stride) else { throw RendererError.unavailable("Background buffer allocation failed") }
                buffers.append((buffer,strip.count))
            }
        }
        graphics=value;backgroundTexture=texture;backgroundStrips=buffers
    }
    /// Shared track environment textures, uploaded once. Both are optional for
    /// older prepared sessions; absent maps are reported through warnings.
    public func setCarEnvironment(reflection: CompiledTexture?,shade: CompiledTexture?,trackShadow: CompiledTexture? = nil) throws {
        let reflectionMap=try reflection.map { try environmentTexture($0) }
        let shadeMap=try shade.map { try environmentTexture($0) }
        let shadowMap=try trackShadow.map { try environmentTexture($0) }
        reflectionTexture=reflectionMap;environmentShadeTexture=shadeMap;carTrackShadowTexture=shadowMap
        carEnvironmentMinimumAlpha=SIMD4(1,reflection.map { SceneAlphaState.minimumAlpha($0.pyramid) } ?? 1,shade.map { SceneAlphaState.minimumAlpha($0.pyramid) } ?? 1,trackShadow.map { SceneAlphaState.minimumAlpha($0.pyramid) } ?? 1)
    }
    /// Texture slots may be shared by any number of cars. Nil preserves the
    /// existing no-shadow behavior for content without a shadow texture.
    public func setShadowTextures(_ textures: [CompiledTexture?]) throws {
        guard textures.count<=128,sceneShadows.allSatisfy({ textures.indices.contains($0.resource) }) else { throw ACError.invalid("Invalid shadow texture resources") }
        var shared: [SHA256.Digest:MTLTexture]=[:]
        let loaded=try textures.map { texture -> MTLTexture? in
            guard let texture else { return nil }
            let key=Self.textureIdentity(texture)
            if let cached=shared[key] { return cached }
            let gpu=try environmentTexture(texture);shared[key]=gpu;return gpu
        }
        shadowTextures=loaded
    }
    /// Compatibility entry point for the prepared single-car view (car ID zero).
    public func setShadowTexture(_ texture: CompiledTexture?) throws { try setShadowTextures([texture]) }
    public func setShadow(_ vertices: [ShadowVertex],normal: SIMD3<Float> = SIMD3(0,0,1)) throws {
        guard Self.validShadowNormal(normal) else { throw ACError.invalid("Invalid shadow normal") }
        try setShadows(vertices.isEmpty ? []:[SceneShadow(carIndex:0,resource:0,vertices:vertices,normal:normal)])
    }
    private static func validShadowNormal(_ normal: SIMD3<Float>) -> Bool {
        let length=simd_length_squared(normal)
        return normal.x.isFinite && normal.y.isFinite && normal.z.isFinite && length.isFinite && length>0
    }
    /// Supply original shadow-anchor initialization order, independently of race
    /// standings or camera distance. Validation is atomic across the whole batch.
    public func setShadows(_ shadows: [SceneShadow]) throws {
        guard shadows.count<=1024,Set(shadows.map(\.carIndex)).count==shadows.count,
              shadows.allSatisfy({ shadow in
                  (0..<1024).contains(shadow.carIndex) && shadowTextures.indices.contains(shadow.resource) && Self.validShadowNormal(shadow.normal) &&
                  shadow.vertices.count==6 && shadow.vertices.allSatisfy { v in
                      [v.position.x,v.position.y,v.position.z,v.position.w,v.uv.x,v.uv.y,v.uv.z,v.uv.w].allSatisfy(\.isFinite) && v.position.w==1
                  }
              }) else { throw ACError.invalid("Invalid car shadow batch") }
        sceneShadows=shadows
    }
    public func setCarLightTextures(_ textures:[String:CompiledTexture]) throws { try lightState.setTextures(textures) }
    /// Publish once per display update. Re-rendering a publication keeps its
    /// random choices; a new publication samples again, including while paused.
    public func setCarLights(_ lights:[SceneCarLight]) throws { try lightState.setLights(lights) }
    /// Start an independent deterministic presentation run; never reset per frame.
    public func resetCarLightRandom(seed:UInt32=12345) throws { try lightState.resetRandom(seed:seed) }
    public func setInstances(_ value: [SceneInstance]) throws {
        guard value.count<=4096 else { throw ACError.invalid("Scene instance count exceeded") }
        for instance in value {
            guard instance.colorOverride.map({ [$0.x,$0.y,$0.z,$0.w].allSatisfy(\.isFinite) }) ?? true else { throw ACError.invalid("Nonfinite instance color") }
            let m=instance.transform
            guard geometries.indices.contains(instance.resource),(0..<4).allSatisfy({ m[$0].x.isFinite && m[$0].y.isFinite && m[$0].z.isFinite && m[$0].w.isFinite }),
                  m[0].w==0,m[1].w==0,m[2].w==0,m[3].w==1,abs(simd_determinant(m))>1e-12 else { throw ACError.invalid("Invalid scene instance transform or resource") }
        }
        try drawOrder.publish(value);instances=value
    }
    public func mtkView(_ view: MTKView,drawableSizeWillChange size: CGSize) {}
    public func draw(in view: MTKView) {
        guard view.drawableSize.width>0,view.drawableSize.height>0,let pass=view.currentRenderPassDescriptor,let drawable=view.currentDrawable,let command=queue.makeCommandBuffer() else { return }
        do { try encode(pass:pass,command:command,size:view.drawableSize);lastRenderError=nil }
        catch { lastRenderError=String(describing:error);return }
        command.present(drawable);command.commit()
    }
    func encode(pass: MTLRenderPassDescriptor,command: MTLCommandBuffer,size: CGSize,captureCommands: Bool=false) throws {
        guard shadowView.currentCar.map({ (0..<1024).contains($0) }) ?? true,
              lightView.currentCar.map({ (0..<1024).contains($0) }) ?? true,
              mirror.map({ (0..<1024).contains($0.currentCar) }) ?? true else { throw RendererError.unavailable("Invalid shadow view car") }
        lastShadowDrawCount=0;lastLightDrawCount=0;lastVegetationDrawCount=0;lastVegetationTriangleCount=0;lastSceneCommands=[];lastMirrorCommands=[]
        var composite:(MTLTexture,MirrorLayout)?
        var mirrorDigest:String?
        if let mirror {
            let w=Int(size.width),h=Int(size.height),layout=MirrorLayout(width:w,height:h)
            let rear=try mirror.camera(width:w,height:h)
            guard mirror.hiddenInstances.allSatisfy({ instances.indices.contains($0) }) else { throw RendererError.unavailable("Invalid mirror instance selection") }
            if mirrorColor?.width != layout.width || mirrorColor?.height != layout.height {
                let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:layout.width,height:layout.height,mipmapped:false)
                d.storageMode = .private;d.usage = [.renderTarget,.shaderRead]
                guard let color=device.makeTexture(descriptor:d) else { throw RendererError.unavailable("Mirror color allocation failed") }
                d.pixelFormat = .depth32Float;d.usage = .renderTarget
                guard let depth=device.makeTexture(descriptor:d) else { throw RendererError.unavailable("Mirror depth allocation failed") }
                mirrorColor=color;mirrorDepth=depth;mirrorAllocationCount += 1
            }
            guard let color=mirrorColor,let depth=mirrorDepth else { throw RendererError.unavailable("Mirror targets unavailable") }
            let rearPass=MTLRenderPassDescriptor();rearPass.colorAttachments[0].texture=color
            rearPass.colorAttachments[0].loadAction = .clear;rearPass.colorAttachments[0].storeAction = .store
            rearPass.colorAttachments[0].clearColor=pass.colorAttachments[0].clearColor
            rearPass.depthAttachment.texture=depth;rearPass.depthAttachment.loadAction = .clear;rearPass.depthAttachment.storeAction = .dontCare;rearPass.depthAttachment.clearDepth=1
            // The original scissors a full-screen camera to its center, then
            // copies the crop. A translated viewport produces the same crop
            // directly in a 1/12-area texture, with no framebuffer copy.
            let viewport=MTLViewport(originX:Double(-layout.sourceX),originY:Double(-layout.sourceY),width:size.width,height:size.height,znear:0,zfar:1)
            try encodeScene(pass:rearPass,command:command,size:size,camera:rear,instances:instances,shadowView:ShadowView(currentCar:mirror.currentCar,drawsCurrentCar:false),hiddenInstances:mirror.hiddenInstances,viewport:viewport,captureCommands:captureCommands)
            mirrorDigest=lastSubmissionSHA256;composite=(color,layout)
        }
        try encodeScene(pass:pass,command:command,size:size,camera:camera,instances:instances,shadowView:shadowView,composite:composite,captureCommands:captureCommands)
        if let mirrorDigest,let main=lastSubmissionSHA256 {
            lastSubmissionSHA256=SHA256.hash(data:Data((mirrorDigest+main).utf8)).map { String(format:"%02x",$0) }.joined()
        }
    }
    private func multisamplePass(_ original:MTLRenderPassDescriptor,mirror:Bool) throws -> MTLRenderPassDescriptor {
        guard let resolve=original.colorAttachments[0].texture else { throw RendererError.unavailable("Missing resolve target") }
        if multisampleTargets[mirror]?.color.width != resolve.width || multisampleTargets[mirror]?.color.height != resolve.height {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:resolve.width,height:resolve.height,mipmapped:false)
            d.textureType = .type2DMultisample;d.sampleCount=4;d.usage = .renderTarget
            d.storageMode=usesMemorylessMultisampling ? .memoryless:.private
            guard let color=device.makeTexture(descriptor:d) else { throw RendererError.unavailable("Multisample color allocation failed") }
            d.pixelFormat = .depth32Float
            guard let depth=device.makeTexture(descriptor:d) else { throw RendererError.unavailable("Multisample depth allocation failed") }
            multisampleTargets[mirror]=MultisampleTargets(color:color,depth:depth);multisampleAllocationCount += 1
        }
        guard let targets=multisampleTargets[mirror],let pass=original.copy() as? MTLRenderPassDescriptor else { throw RendererError.unavailable("Multisample targets unavailable") }
        pass.colorAttachments[0].texture=targets.color;pass.colorAttachments[0].resolveTexture=resolve
        pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.texture=targets.depth;pass.depthAttachment.resolveTexture=nil
        pass.depthAttachment.loadAction = .clear;pass.depthAttachment.storeAction = .dontCare
        return pass
    }
    private func encodeScene(pass: MTLRenderPassDescriptor,command: MTLCommandBuffer,size: CGSize,camera: SceneCamera,instances: [SceneInstance],shadowView: ShadowView,hiddenInstances:Set<Int>=[],viewport: MTLViewport? = nil,composite: (MTLTexture,MirrorLayout)? = nil,captureCommands: Bool=false) throws {
        let samples=rasterSampleCount,p=pipelines[rasterSampleCount]!
        let instanceOrder=try drawOrder.prepare(eye:camera.eye,mirror:viewport != nil)
        let lights=try lightState.prepare(camera:camera,aspect:Float(size.width/size.height),visibility:viewport != nil ? shadowView:lightView,mirror:viewport != nil)
        let pass=try samples==4 ? multisamplePass(pass,mirror:viewport != nil):pass
        var digest:SHA256?=captureCommands ? SHA256():nil
        var commands:[SceneDrawCommand]=[]
        func capture<T>(_ value:T) { if digest != nil { withUnsafeBytes(of:value) { digest!.update(data:Data($0)) } } }
        capture(samples)
        if let graphics {
            let c=graphics.backgroundColor
            pass.colorAttachments[0].clearColor=MTLClearColor(red:Double(c.x),green:Double(c.y),blue:Double(c.z),alpha:1)
        }
        guard let encoder=command.makeRenderCommandEncoder(descriptor:pass) else { throw RendererError.unavailable("Scene command encoder unavailable") }
        if let viewport { encoder.setViewport(viewport);capture(viewport) }
        let interval=signposter.beginInterval("Scene draw preparation")
        defer { signposter.endInterval("Scene draw preparation",interval) }
        encoder.setFrontFacing(.counterClockwise);encoder.setFragmentSamplerState(enhancedFiltering ? anisotropicSampler:sampler,index:0)
        let view=camera.view(),vp=camera.viewProjection(aspect:Float(size.width/size.height))
        let range=camera.fogRange ?? SIMD2(0,1)
        let fogEnabled=graphics != nil && camera.fogRange != nil && range.y>range.x
        var environment=EnvironmentUniforms(ambient:SIMD4(graphics?.ambient ?? SIMD3(repeating:0.2),1),
            diffuse:SIMD4(graphics?.diffuse ?? SIMD3(repeating:0.8),1),specular:SIMD4(graphics?.specular ?? SIMD3(repeating:0.3),1),
            light:SIMD4(normalize(graphics?.lightPosition ?? SIMD3(0,0,1)),0),fogColor:SIMD4(graphics?.fogColor ?? .zero,1),
            fog:SIMD4(range.x,range.y,fogEnabled ? 1:0,0))
        capture(environment)
        encoder.setVertexBytes(&environment,length:MemoryLayout<EnvironmentUniforms>.stride,index:2)
        encoder.setFragmentBytes(&environment,length:MemoryLayout<EnvironmentUniforms>.stride,index:2)
        if camera.drawsBackground,let backgroundTexture,!backgroundStrips.isEmpty {
            var backgroundMatrix=TrackBackground.camera(for:camera).viewProjection(aspect:Float(size.width/size.height))
            capture(backgroundMatrix)
            encoder.setRenderPipelineState(p.backgroundPipeline);encoder.setDepthStencilState(backgroundDepth);encoder.setCullMode(.none)
            encoder.setFragmentSamplerState(sampler,index:0);encoder.setFragmentTexture(backgroundTexture,index:0)
            encoder.setVertexBytes(&backgroundMatrix,length:MemoryLayout<simd_float4x4>.stride,index:1)
            for (buffer,count) in backgroundStrips { encoder.setVertexBuffer(buffer,offset:0,index:0);encoder.drawPrimitives(type:.triangleStrip,vertexStart:0,vertexCount:count) }
            encoder.setFragmentSamplerState(enhancedFiltering ? anisotropicSampler:sampler,index:0)
        }
        struct Item { let draw: Draw;let model: simd_float4x4;let instance:Int;let reflection: CarReflection?;let color: SIMD4<Float>? }
        var treeSelections:[Int:[Int]]=[:]
        if enhancedVegetation,let vegetationState {
            for index in instanceOrder where !hiddenInstances.contains(index) && instances[index].resource==vegetationState.resource {
                treeSelections[index]=vegetationState.selections(camera:camera,pixelHeight:Float(viewport?.height ?? size.height),transform:instances[index].transform)
            }
        }
        var opaque:[Item]=[],deferred=Array(repeating:[Item](),count:SceneAnchor.allCases.count)
        for index in instanceOrder where !hiddenInstances.contains(index) {
            let instance=instances[index]
            for draw in draws where draw.resource==instance.resource && (!instance.hidesDriver || !draw.batch.isDriver) {
                let item=Item(draw:draw,model:instance.transform*draw.batch.transform,instance:index,reflection:instance.reflection,color:instance.colorOverride)
                if draw.batch.mesh.states[0]!.flags & 32 != 0 { deferred[instance.anchor.rawValue].append(item) } else { opaque.append(item) }
            }
        }
        var alphaState=SceneAlphaState()
        func drawShadow() {
            var began=false
            for shadow in sceneShadows where shadowView.isVisible(carIndex:shadow.carIndex) {
                guard let texture=shadowTextures[shadow.resource] else { continue }
                if !began {
                    encoder.setRenderPipelineState(alphaState.needsBlendedEffectTest ? p.shadowAlphaTest:p.shadowPipeline)
                    capture(alphaState.needsBlendedEffectTest)
                    var threshold=alphaState.threshold;capture(alphaState.enabled);capture(threshold)
                    encoder.setFragmentBytes(&threshold,length:MemoryLayout<Float>.stride,index:3)
                    encoder.setDepthStencilState(readDepth);encoder.setCullMode(.back)
                    // Original grshadow GL offset (-15 slope, -20 units). Metal
                    // depth units differ; exact GL raster parity is not asserted.
                    encoder.setDepthBias(-20,slopeScale:-15,clamp:0);began=true
                }
                var matrix=ShadowUniforms(viewProjection:vp,view:view,normal:SIMD4(shadow.normal,0))
                capture(matrix)
                if digest != nil { shadow.vertices.withUnsafeBytes { digest!.update(data:Data($0)) } }
                capture(shadow.carIndex);capture(shadow.resource)
                encoder.setVertexBytes(shadow.vertices,length:shadow.vertices.count*MemoryLayout<ShadowVertex>.stride,index:0)
                encoder.setVertexBytes(&matrix,length:MemoryLayout<ShadowUniforms>.stride,index:1)
                encoder.setFragmentTexture(texture,index:0)
                encoder.drawPrimitives(type:.triangleStrip,vertexStart:0,vertexCount:6)
                if captureCommands { commands.append(.shadow(car:shadow.carIndex)) }
                lastShadowDrawCount += 1
            }
            if began { encoder.setDepthBias(0,slopeScale:0,clamp:0) }
        }
        func drawLights() {
            guard !lights.isEmpty else { return }
            encoder.setRenderPipelineState(alphaState.needsBlendedEffectTest ? p.lightAlphaTest:p.lightPipeline)
            capture(alphaState.needsBlendedEffectTest)
            var threshold=alphaState.threshold;capture(alphaState.enabled);capture(threshold)
            encoder.setFragmentBytes(&threshold,length:MemoryLayout<Float>.stride,index:3)
            encoder.setDepthStencilState(readDepth);encoder.setCullMode(.none)
            encoder.setDepthBias(-20,slopeScale:-15,clamp:0)
            var matrix=CarLightRenderState.Uniforms(viewProjection:vp,view:view);capture(matrix)
            encoder.setVertexBytes(&matrix,length:MemoryLayout<CarLightRenderState.Uniforms>.stride,index:1)
            for light in lights {
                if digest != nil { light.vertices.withUnsafeBytes { digest!.update(data:Data($0)) };digest!.update(data:Data(light.name.utf8)) }
                encoder.setVertexBytes(light.vertices,length:light.vertices.count*MemoryLayout<ShadowVertex>.stride,index:0)
                encoder.setFragmentTexture(lightState.textures[light.name],index:0)
                encoder.drawPrimitives(type:.triangleStrip,vertexStart:0,vertexCount:4);lastLightDrawCount += 1
                if captureCommands { commands.append(.light(car:light.carIndex)) }
            }
            encoder.setDepthBias(0,slopeScale:0,clamp:0)
        }
        func drawMesh(_ item:Item) {
            let draw=item.draw,b=draw.batch,m=b.mesh,state=m.states[0]!,values=state.material
            alphaState.apply(state)
            if let selection=treeSelections[item.instance],let tree=vegetationState?.forest.batchPlacement[draw.batchIndex],selection[tree]<2 { return }
            func rgba(_ offset: Int) -> SIMD4<Float> { SIMD4(values[offset],values[offset+1],values[offset+2],values[offset+3]) }
            var maps=SIMD4<UInt32>(repeating:0)
            for layer in 0..<3 where ((layer==0 && state.flags & 8 != 0) || (layer>0 && m.mapLevel>=0 && m.mapCount>layer)) && m.states[layer]?.texture != nil { maps[layer]=1 }
            var coordinates=SIMD4<Float>.zero,shadowLinear=SIMD4<Float>.zero,shadowOffset=SIMD4<Float>.zero
            var textures=draw.textures,minimumAlpha=draw.minimumAlpha
            if m.mapLevel<0,carReflectionsEnabled,let reflection=item.reflection {
                coordinates=reflection.coordinates
                if m.indexed,m.mapLevel <= -3,carTrackShadowsEnabled,reflection.shadowOffset.w==1,let carTrackShadowTexture {
                    maps.w=1;textures[3]=carTrackShadowTexture;minimumAlpha.w=carEnvironmentMinimumAlpha.w
                    shadowLinear=reflection.shadowLinear;shadowOffset=reflection.shadowOffset
                }
                if let reflectionTexture { maps.y=1;textures[1]=reflectionTexture;minimumAlpha.y=carEnvironmentMinimumAlpha.y }
                if m.mapLevel <= -2,let environmentShadeTexture { maps.z=1;textures[2]=environmentShadeTexture;minimumAlpha.z=carEnvironmentMinimumAlpha.z }
            }
            var u=Uniforms(model:item.model,normalMatrix:item.model.inverse.transpose,viewProjection:vp,view:view,
                           color:item.color ?? SIMD4(m.colors[0],m.colors[1],m.colors[2],m.colors[3]),specular:rgba(0),emission:rgba(4),ambient:rgba(8),
                           parameters:SIMD4(values[12],alphaState.threshold,state.flags & 2 != 0 ? 1:0,alphaState.enabled ? 1:0),maps:maps,reflection:coordinates,shadowLinear:shadowLinear,shadowOffset:shadowOffset)
            capture(u);capture(state.flags);capture(ObjectIdentifier(draw.vertex).hashValue);capture(ObjectIdentifier(draw.index).hashValue)
            let alphaTest=alphaState.needsTest(colorAlpha:u.color.w,minimumTextureAlpha:minimumAlpha,maps:maps);capture(alphaTest)
            encoder.setRenderPipelineState(state.flags & 1 != 0 ? (alphaTest ? p.blendedAlphaTest:p.blended):(alphaTest ? p.opaqueAlphaTest:p.opaque))
            // SSG translucency defers a mesh; it does not disable depth writes.
            // Only explicit effects (shadow/light) temporarily mask depth writes.
            encoder.setDepthStencilState(writeDepth)
            encoder.setCullMode(m.cull ? .back:.none)
            encoder.setVertexBuffer(draw.vertex,offset:0,index:0)
            encoder.setVertexBytes(&u,length:MemoryLayout<Uniforms>.stride,index:1)
            encoder.setFragmentBytes(&u,length:MemoryLayout<Uniforms>.stride,index:1)
            for i in 0..<4 { encoder.setFragmentTexture(textures[i],index:i) }
            encoder.drawIndexedPrimitives(type:.triangle,indexCount:b.indices.count,indexType:.uint32,indexBuffer:draw.index,indexBufferOffset:0)
            if captureCommands { commands.append(.mesh(instance:item.instance,batch:draw.batchIndex)) }
        }
        // Complete the optional opaque block before the original draw stream.
        // Original states still apply in drawMesh, including replaced tree leaves.
        if let vegetationState {
            for index in instanceOrder {
                guard let selection=treeSelections[index] else { continue }
                encoder.setDepthStencilState(writeDepth)
                let result=vegetationState.encode(encoder,selection:selection,camera:camera,aspect:Float(size.width/size.height),transform:instances[index].transform,samples:rasterSampleCount)
                lastVegetationDrawCount += result.draws;lastVegetationTriangleCount += result.triangles
                if digest != nil { selection.withUnsafeBytes { digest!.update(data:Data($0)) } };capture(instances[index].transform)
                if captureCommands { commands.append(.vegetation(instance:index,trees:selection.filter { $0<2 }.count)) }
            }
        }
        for item in opaque { drawMesh(item) }
        for anchor in SceneAnchor.allCases {
            if anchor == .shadows { drawShadow() }
            if anchor == .carLights { drawLights() }
            for item in deferred[anchor.rawValue] { drawMesh(item) }
        }
        if let (texture,layout)=composite {
            var rect=SIMD4(Float(layout.x)/Float(size.width)*2-1,1-Float(layout.y)/Float(size.height)*2,Float(layout.width)/Float(size.width)*2,Float(layout.height)/Float(size.height)*2)
            capture(rect)
            encoder.setRenderPipelineState(p.mirrorPipeline);encoder.setDepthStencilState(backgroundDepth);encoder.setCullMode(.none)
            encoder.setVertexBytes(&rect,length:MemoryLayout<SIMD4<Float>>.stride,index:0)
            encoder.setFragmentTexture(texture,index:0)
            encoder.drawPrimitives(type:.triangleStrip,vertexStart:0,vertexCount:4)
        }
        encoder.endEncoding()
        if viewport != nil { lastMirrorCommands=commands } else { lastSceneCommands=commands }
        lastSubmissionSHA256=digest?.finalize().map { String(format:"%02x",$0) }.joined()
    }
    /// Renders real geometry offscreen. Output is top-first, straight RGBA8.
    public func render(width: Int = 960,height: Int = 640,captureCommands: Bool=false) throws -> Data {
        guard (1...4096).contains(width),(1...4096).contains(height) else { throw RendererError.unavailable("Invalid render dimensions") }
        func texture(_ format: MTLPixelFormat,_ storage: MTLStorageMode) -> MTLTexture? {
            let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:width,height:height,mipmapped:false)
            d.usage = .renderTarget;d.storageMode=storage;return device.makeTexture(descriptor:d)
        }
        guard let color=texture(.rgba8Unorm,.shared),let depth=texture(.depth32Float,.private),let command=queue.makeCommandBuffer() else { throw RendererError.unavailable("Offscreen scene allocation failed") }
        let pass=MTLRenderPassDescriptor();pass.colorAttachments[0].texture=color;pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor=MTLClearColor(red:0.16,green:0.22,blue:0.29,alpha:1)
        pass.depthAttachment.texture=depth;pass.depthAttachment.loadAction = .clear;pass.depthAttachment.clearDepth=1
        try encode(pass:pass,command:command,size:CGSize(width:width,height:height),captureCommands:captureCommands);command.commit();command.waitUntilCompleted()
        if let error=command.error { throw error }
        lastGPUTime=command.gpuEndTime-command.gpuStartTime
        var bytes=[UInt8](repeating:0,count:width*height*4)
        color.getBytes(&bytes,bytesPerRow:width*4,from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0)
        return Data(bytes)
    }
}
