// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import CReference
@testable import TORCSConfiguration
import TORCSTrack
@testable import TORCSAssets
@testable import TORCSMetal

final class TrackEnvironmentTests:XCTestCase {
    func configuration(_ values:[String:Float]=[:]) throws -> TrackGraphics {
        let xml="<params name=\"test\"><section name=\"Graphic\">"+values.sorted(by:{$0.key<$1.key}).map { "<attnum name=\"\($0.key)\" val=\"\($0.value)\"/>" }.joined()+"</section></params>"
        return try TrackGraphics(parameters:ParameterDocument.parse(Data(xml.utf8)))
    }
    func testConfigurationAgainstOriginal() throws {
        let root=try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil))
        let aalborg=try ParameterDocument.parse(Data(contentsOf:root.appendingPathComponent("aalborg.xml")),entities:["default-surfaces":Data(contentsOf:root.appendingPathComponent("surfaces.xml")),"default-objects":Data(contentsOf:root.appendingPathComponent("objects.xml"))],allowLegacyLatin1:true)
        var documents=[try ParameterDocument.parse(Data("<params name=\"defaults\"/>".utf8)),ParameterDocument(name:"aalborg-graphics",root:ParameterSection(name:"",parameters:[:],sections:[try XCTUnwrap(aalborg.section("Graphic"))]))]
        for i in 0..<40 {
            let fields=["background color R","ambient color G","diffuse color B","specular color R","light position x","background type"]
            let xml="<params name=\"sweep\"><section name=\"Graphic\">"+fields.enumerated().map { "<attnum name=\"\($0.element)\" val=\"\(Float(i+$0.offset)*0.13)\"/>" }.joined()+"</section></params>"
            documents.append(try ParameterDocument.parse(Data(xml.utf8)))
        }
        for doc in documents {
            let g=try TrackGraphics(parameters:doc)
            var original=[Float](repeating:0,count:18),kind:Int32=0
            XCTAssertEqual(ref_graphics_config_xml(String(decoding:doc.xmlData(),as:UTF8.self),&original,&kind),1)
            let native=[g.backgroundColor,g.ambient,g.diffuse,g.specular,g.lightPosition,g.fogColor].flatMap { [$0.x,$0.y,$0.z] }
            XCTAssertEqual(native,original);XCTAssertEqual(g.backgroundType,Int(kind))
        }
        XCTAssertEqual(try TrackGraphics(parameters:documents[0]).background,"background.png")
        XCTAssertThrowsError(try configuration(["light position z":0]))
        print("TRACK_GRAPHICS_CONFIG cases=42 scalars=756 exact=1")
    }
    func testBackgroundGeometryAndCameraAgainstOriginal() {
        var maximum:Float=0,total=0
        for type in [0,2,4,7] {
            let native=TrackBackground.strips(type:type).flatMap{$0}.flatMap{[$0.position.x,$0.position.y,$0.position.z,$0.uv.x,$0.uv.y]}
            var original=[Float](repeating:0,count:500)
            let count=ref_background_geometry(Int32(type),&original,500)
            XCTAssertEqual(native.count,Int(count)*5);total += Int(count)
            for (a,b) in zip(native,original) { maximum=max(maximum,abs(a-b));XCTAssertEqual(a,b,accuracy:0.000001) }
        }
        for i in 0..<200 {
            let t=Float(i),eye=SIMD3(t,-t,2),target=eye+SIMD3(cos(t),sin(t),0.25),up=SIMD3<Float>(0,0,1),fov:Float=30+t*0.25
            let source=SceneCamera(eye:eye,target:target,fieldOfView:fov * .pi/180,up:up),bg=TrackBackground.camera(for:source)
            var original=[Float](repeating:0,count:10)
            ref_background_camera([eye.x,eye.y,eye.z,target.x,target.y,target.z,up.x,up.y,up.z,fov],&original)
            let actual=[bg.eye.x,bg.eye.y,bg.eye.z,bg.target.x,bg.target.y,bg.target.z,bg.up.x,bg.up.y,bg.up.z,bg.fieldOfView*180 / .pi]
            for (a,b) in zip(actual,original) { XCTAssertEqual(a,b,accuracy:0.00001) }
        }
        print("BACKGROUND_GEOMETRY types=4 vertices=\(total) maximum=\(maximum) cameraCases=200")
    }
    func testBackgroundTextureAgainstOriginalPNG() throws {
        let path=try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)).appendingPathComponent("Artwork/aalborg/background.png")
        let image=try TextureImage.decodePNG(Data(contentsOf:path));var w:Int32=0,h:Int32=0,n:Int32=0
        let original=try XCTUnwrap(ref_png_load(path.path,2,&w,&h,&n))
        XCTAssertEqual(image.width,Int(w));XCTAssertEqual(image.height,Int(h));XCTAssertEqual(image.pixels,Array(UnsafeBufferPointer(start:original,count:Int(n))))
        let pyramid=try TexturePyramid(image:image,filename:path.lastPathComponent)
        var count:Int32=0,levels:Int32=0
        let mipBytes=ref_texture_mips(original,w,h,4,4096,1,&count,&levels)
        let originalMips=try TextureImageTests().original(mipBytes,count:count,levels:levels)
        XCTAssertEqual(pyramid.levels,originalMips)
        XCTAssertEqual(ref_texture_mipmap_rule(path.path,1),1)
        print("BACKGROUND_TEXTURE bytes=\(n) mipBytes=\(originalMips.reduce(0){$0+$1.pixels.count}) levels=\(levels) exact=1 gamma=2")
    }
    func testGPUTrackLightingFogAndBackgroundDepth() async throws {
        let light=try configuration(["ambient color R":0.1,"ambient color G":0.1,"ambient color B":0.1,"diffuse color R":0.5,"diffuse color G":0.5,"diffuse color B":0.5,"background color R":0.5,"background color G":0.5,"background color B":0.5])
        let unlit=try configuration(["background color R":0.5,"background color G":0.5,"background color B":0.5])
        try await MainActor.run {
            let r=try SceneRenderer(scene:SceneRenderingTests.loaded([SceneRenderingTests.quad(color:[1,0,0,1],flags:2)]))
            r.camera=SceneCamera(eye:SIMD3(0,0,2),target:.zero,up:SIMD3(0,1,0))
            try r.setEnvironment(light)
            XCTAssertEqual(SceneRenderingTests.pixel(Array(try r.render(width:64,height:64))),[204,0,0,255])
            let shadowTexture=CompiledTexture(sourceSHA256:"test",cacheKey:"test",filename:"shadow",options:.init(mipmaps:false),pyramid:try TexturePyramid(image:TextureImage(width:1,height:1,channels:4,pixels:[100,100,100,255]),filename:"shadow",options:.init(mipmaps:false)))
            let shadow=try CarShadow(dimensions:SIMD2(2,2)).project(body:matrix_identity_float4x4) { _ in 0 }
            try r.setShadowTexture(shadowTexture);try r.setShadow(shadow)
            XCTAssertEqual(SceneRenderingTests.pixel(Array(try r.render(width:64,height:64))),[80,80,80,255])
            try r.setShadow(shadow,normal:SIMD3(0,0,-1))
            XCTAssertEqual(SceneRenderingTests.pixel(Array(try r.render(width:64,height:64))),[30,30,30,255])
            let fogged=try SceneRenderer(scene:SceneRenderingTests.loaded([SceneRenderingTests.quad(color:[1,0,0,1])]))
            fogged.camera=r.camera;fogged.camera.fogRange=SIMD2(1,3);try fogged.setEnvironment(unlit)
            let pixel=SceneRenderingTests.pixel(Array(try fogged.render(width:64,height:64)))
            XCTAssertEqual(pixel[0],179,accuracy:1);XCTAssertEqual(pixel[1],51,accuracy:1);XCTAssertEqual(pixel[2],51,accuracy:1);XCTAssertEqual(pixel[3],255)
            let sky=CompiledTexture(sourceSHA256:"test",cacheKey:"test",filename:"background",options:.init(mipmaps:false),pyramid:try TexturePyramid(image:TextureImage(width:1,height:1,channels:4,pixels:[0,0,255,255]),filename:"sky",options:.init(mipmaps:false)))
            try fogged.setEnvironment(unlit,background:sky);fogged.camera.fogRange=nil
            XCTAssertEqual(SceneRenderingTests.pixel(Array(try fogged.render(width:64,height:64))),[255,0,0,255])
            try fogged.setInstances([]);fogged.camera=SceneCamera(eye:SIMD3(0,0,2),target:SIMD3(1,0,2))
            XCTAssertEqual(SceneRenderingTests.pixel(Array(try fogged.render(width:64,height:64))),[0,0,255,255])
            try fogged.setEnvironment(unlit)
            XCTAssertEqual(SceneRenderingTests.pixel(Array(try fogged.render(width:64,height:64))),[128,128,128,255])
            print("ENVIRONMENT_GPU lighting=1 shadowLighting=2 fog=1 sky=1 depth=1 clear=1")
        }
    }
}
