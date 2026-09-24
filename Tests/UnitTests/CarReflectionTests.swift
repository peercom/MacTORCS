// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import CReference
@testable import TORCSAssets
@testable import TORCSMetal

final class CarReflectionTests:XCTestCase {
    func testTextureTransformsAgainstOriginal() throws {
        var maximum:Float=0
        for i in 0..<2000 {
            let yaw=Float(i-1000)*0.0712345,distance=Float(i-50)*2.9187
            let native=try CarReflection(distanceFromStart:distance,yaw:yaw).coordinates
            for level:Int32 in [-1,-2,-3] {
                var original=[Float](repeating:0,count:32)
                ref_car_reflections(distance,yaw,level,&original)
                XCTAssertEqual(native.x,original[12])
                if level <= -2 {
                    for (a,b) in [(native.y,original[16]),(native.z,original[17]),(-native.z,original[20]),(native.y,original[21])] {
                        maximum=max(maximum,abs(a-b));XCTAssertEqual(a,b,accuracy:0.000001)
                    }
                } else { XCTAssertEqual(original[16],1);XCTAssertEqual(original[17],0) }
            }
        }
        XCTAssertThrowsError(try CarReflection(distanceFromStart:.nan,yaw:0))
        XCTAssertThrowsError(try CarReflection(distanceFromStart:0,yaw:.infinity))
        XCTAssertThrowsError(try CarReflection(distanceFromStart:0,yaw:.greatestFiniteMagnitude))
        print("CAR_REFLECTION_TRANSFORMS cases=6000 maximum=\(maximum)")
    }
    static func texture(_ name:String,_ pixel:(Int,Int)->[UInt8]) throws -> CompiledTexture {
        let bytes=(0..<8).flatMap { y in (0..<8).flatMap { x in pixel(x,y) } }
        let options=TextureCompileOptions(mipmaps:false)
        return CompiledTexture(sourceSHA256:"authored",cacheKey:"authored",filename:name,options:options,pyramid:try TexturePyramid(image:TextureImage(width:8,height:8,channels:4,pixels:bytes),filename:name,options:options))
    }
    func testGPUCarMapSelectionMotionAndIsolation() async throws {
        try await MainActor.run {
            let env=try Self.texture("env") { x,_ in x<4 ? [128,255,255,255]:[255,128,255,255] }
            let shade=try Self.texture("shade") { x,_ in x<4 ? [255,255,128,255]:[255,255,255,255] }
            var mesh=SceneRenderingTests.quad()
            mesh.uv=Array(repeating:Array(repeating:[Float(0.125),0.125],count:4).flatMap{$0},count:4)
            for level in [-1,-2,-3,1] {
                mesh.mapLevel=level
                let r=try SceneRenderer(scene:SceneRenderingTests.loaded([mesh]))
                r.camera=SceneCamera(eye:SIMD3(0,0,2),target:.zero,up:SIMD3(0,1,0))
                try r.setCarEnvironment(reflection:env,shade:shade)
                @MainActor func pixel(_ distance:Float,_ yaw:Float) throws -> [UInt8] {
                    try r.setInstances([SceneInstance(resource:0,reflection:CarReflection(distanceFromStart:distance,yaw:yaw))])
                    return SceneRenderingTests.pixel(Array(try r.render(width:64,height:64)))
                }
                XCTAssertEqual(try pixel(0,0),level>=0 ? [255,255,255,255]:level == -1 ? [128,255,255,255]:[128,255,128,255])
                XCTAssertEqual(try pixel(25,0),level>=0 ? [255,255,255,255]:level == -1 ? [255,128,255,255]:[255,128,128,255])
                XCTAssertEqual(try pixel(50,0),try pixel(0,0))
                XCTAssertEqual(try pixel(0,.pi/2),level>=0 ? [255,255,255,255]:[128,255,255,255])
                r.carReflectionsEnabled=false
                XCTAssertEqual(try pixel(0,0),[255,255,255,255])
                r.carReflectionsEnabled=true
                try r.setInstances([SceneInstance(resource:0)])
                XCTAssertEqual(SceneRenderingTests.pixel(Array(try r.render(width:64,height:64))),[255,255,255,255])
                try r.setCarEnvironment(reflection:nil,shade:nil)
                XCTAssertEqual(try pixel(0,0),[255,255,255,255])
            }
            // Two instances of the same mesh retain independent car state.
            mesh.mapLevel = -2
            let r=try SceneRenderer(scene:SceneRenderingTests.loaded([mesh]))
            r.camera=SceneCamera(eye:SIMD3(0,0,2),target:.zero,up:SIMD3(0,1,0))
            try r.setCarEnvironment(reflection:env,shade:shade)
            var behind=matrix_identity_float4x4;behind[3].z = -0.5
            try r.setInstances([SceneInstance(resource:0,reflection:CarReflection(distanceFromStart:25,yaw:.pi/2)),SceneInstance(resource:0,transform:behind,reflection:CarReflection(distanceFromStart:0,yaw:0))])
            XCTAssertEqual(SceneRenderingTests.pixel(Array(try r.render(width:64,height:64))),[255,128,255,255])
            // Environment RGBA is modulated before the existing alpha cutoff.
            let alpha=try Self.texture("alpha") { _,_ in [255,255,255,102] }
            mesh.states[0]!.flags=16;mesh.mapLevel = -1
            let cut=try SceneRenderer(scene:SceneRenderingTests.loaded([mesh,SceneRenderingTests.quad(z:-0.5,color:[0,0,1,1])]))
            cut.camera=r.camera;try cut.setCarEnvironment(reflection:alpha,shade:nil)
            try cut.setInstances([SceneInstance(resource:0,reflection:CarReflection(distanceFromStart:0,yaw:0))])
            XCTAssertEqual(SceneRenderingTests.pixel(Array(try cut.render(width:64,height:64))),[0,0,255,255])
            print("CAR_REFLECTION_GPU mapLevels=4 scrolling=1 wrap=1 yaw=1 toggle=1 instanceIsolation=1 alphaCutoff=1")
        }
    }
}
