// SPDX-License-Identifier: GPL-2.0-only
// Draw ordering and state follow TORCS grcarlight, Copyright (C) 2001
// Christophe Guionneau; original GPL-2.0-or-later attribution retained.
import Metal
import simd
import CryptoKit
import TORCSAssets
import TORCSRaceEngine

@MainActor final class CarLightRenderState {
    struct Draw { let name:String;let carIndex:Int;let vertices:[ShadowVertex] }
    struct Uniforms { var viewProjection,view:simd_float4x4 }
    private struct Plan { let key:[Float];let draws:[Draw] }
    let device:MTLDevice
    private(set) var textures:[String:MTLTexture]=[:]
    private var lights:[SceneCarLight]=[]
    private var drawing:CarLightDrawing
    private var plans:[Bool:Plan]=[:]
    var randomDraws:UInt64 { drawing.randomDraws }
    var textureCount:Int { Set(textures.values.map(ObjectIdentifier.init)).count }
    init(device:MTLDevice) throws { self.device=device;drawing=try CarLightDrawing() }
    func resetRandom(seed:UInt32) throws {
        drawing=try CarLightDrawing(seed:seed);plans.removeAll(keepingCapacity:true)
    }
    func setTextures(_ values:[String:CompiledTexture]) throws {
        let names=Set(CarLightType.allCases.map(\.textureName))
        guard values.count<=5,Set(values.keys).isSubset(of:names),values.values.allSatisfy({ $0.pyramid.levels.count==1 }),
              lights.allSatisfy({ values[$0.light.definition.type.textureName] != nil }) else { throw ACError.invalid("Invalid car light texture resources") }
        var result:[String:MTLTexture]=[:],shared:[SHA256.Digest:MTLTexture]=[:]
        for (name,texture) in values {
            let level=texture.pyramid.levels[0]
            var digest=SHA256(),layout=SIMD4<Int>(level.width,level.height,level.channels,level.pixels.count)
            withUnsafeBytes(of:&layout) { digest.update(data:Data($0)) };digest.update(data:Data(level.pixels))
            let key=digest.finalize()
            if let gpu=shared[key] { result[name]=gpu } else { let gpu=try MetalTextureUpload.make(device:device,pyramid:texture.pyramid);result[name]=gpu;shared[key]=gpu }
        }
        textures=result;plans.removeAll(keepingCapacity:true)
    }
    func setLights(_ values:[SceneCarLight]) throws {
        var counts:[Int:Int]=[:]
        for item in values {
            guard (0..<1024).contains(item.carIndex),textures[item.light.definition.type.textureName] != nil else { throw ACError.invalid("Missing light texture or invalid car index") }
            counts[item.carIndex,default:0] += 1
            guard counts[item.carIndex]!<=14 else { throw ACError.invalid("More than fourteen car lights") }
        }
        lights=values;plans.removeAll(keepingCapacity:true)
    }
    func prepare(camera:SceneCamera,aspect:Float,visibility:ShadowView,mirror:Bool) throws -> [Draw] {
        guard !lights.isEmpty else { return [] }
        let view=camera.view(),range=camera.clippingRange
        let key:[Float]=(0..<4).flatMap { [view[$0].x,view[$0].y,view[$0].z,view[$0].w] }+[aspect,camera.fieldOfView,range.x,range.y,Float(visibility.currentCar ?? -1),visibility.drawsCurrentCar ? 1:0]
        guard key.allSatisfy(\.isFinite) else { throw ACError.invalid("Invalid light camera") }
        if let cached=plans[mirror],cached.key==key { return cached.draws }
        let frustum=try CarLightFrustum(camera:camera,aspect:aspect)
        var next=drawing,draws:[Draw]=[]
        for item in lights where visibility.isVisible(carIndex:item.carIndex) && frustum.contains(item.light.position,view:view) {
            if let quad=try next.draw(item.light,view:view) {
                let uv=quad.rotatedTextureCoordinates
                draws.append(Draw(name:item.light.definition.type.textureName,carIndex:item.carIndex,vertices:quad.positions.enumerated().map { ShadowVertex(position:SIMD4($0.element,1),uv:SIMD4(uv[$0.offset].x,uv[$0.offset].y,0,0)) }))
            }
        }
        drawing=next;plans[mirror]=Plan(key:key,draws:draws)
        return draws
    }
    static func pipeline(device:MTLDevice,library:MTLLibrary,samples:Int,alphaTest:Bool) throws -> MTLRenderPipelineState {
        let p=MTLRenderPipelineDescriptor()
        p.vertexFunction=library.makeFunction(name:"lightVertex")
        var enabled=alphaTest;let constants=MTLFunctionConstantValues();constants.setConstantValue(&enabled,type:.bool,index:0)
        p.fragmentFunction=try library.makeFunction(name:"lightFragment",constantValues:constants)
        p.colorAttachments[0].pixelFormat = .rgba8Unorm;p.depthAttachmentPixelFormat = .depth32Float;p.rasterSampleCount=samples
        let a=p.colorAttachments[0]!
        a.isBlendingEnabled=true;a.sourceRGBBlendFactor = .sourceAlpha;a.destinationRGBBlendFactor = .oneMinusSourceAlpha
        a.sourceAlphaBlendFactor = .sourceAlpha;a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor:p)
    }
}
