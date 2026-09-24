// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import CReference
import TORCSSimulation
@testable import TORCSAssets
@testable import TORCSMetal

final class DrivingVisualTests:XCTestCase {
    func testAllChasePresetsAgainstOriginal() {
        for preset in DrivingCameraPreset.allCases where preset.isChase {
            var camera=DrivingCamera();camera.preset=preset
            var samples:[Float]=[],actual:[Float]=[]
            for i in 0..<1000 {
                let t=Float(i),p=SIMD3(20*sin(t*0.03),15*cos(t*0.07),t*0.001),yaw=atan2(sin(t*0.09),cos(t*0.09)),height=sin(t*0.02)
                samples += [p.x,p.y,p.z,yaw,height]
                let c=camera.update(position:p,yaw:yaw) { _ in height }
                actual += [c.eye.x,c.eye.y,c.eye.z,c.target.x,c.target.y,c.target.z]
            }
            var expected=[Float](repeating:0,count:actual.count)
            ref_camera_chase(samples,1000,preset.distance,preset.height,&expected)
            XCTAssertEqual(actual,expected)
        }
        print("CAMERA_CHASE presets=4 updatesEach=1000 scalars=24000 exact=1")
    }
    func testBonnetAndShadowAgainstOriginalTransforms() throws {
        var maxCamera:Float=0,maxShadow:Float=0
        for i in 0..<1000 {
            let t=Float(i),body=VehiclePresentation.matrix(CollisionTransform(position:SIMD3(t*0.1,-8,1),orientation:SIMD3(t*0.006,t*0.003,t*0.01)))
            let matrix=(0..<4).flatMap { column in (0..<4).map { body[column][$0] } }
            let bonnet=SIMD3<Float>(0.6,0,1),camera=DrivingCamera.bonnet(body:body,position:bonnet)
            var expected=[Float](repeating:0,count:9)
            ref_camera_bonnet(matrix,[bonnet.x,bonnet.y,bonnet.z],&expected)
            let actual=[camera.eye.x,camera.eye.y,camera.eye.z,camera.target.x,camera.target.y,camera.target.z,camera.up.x,camera.up.y,camera.up.z]
            for (a,b) in zip(actual,expected) { maxCamera=max(maxCamera,abs(a-b));XCTAssertEqual(a,b,accuracy:0.00002) }
            let length:Float=4.8+t*0.001,width:Float=1.92
            var original=[Float](repeating:0,count:30)
            ref_shadow_vertices(length,width,matrix,&original)
            var points:[SIMD2<Float>]=[]
            let shadow=try CarShadow(dimensions:SIMD2(length,width)).project(body:body) { p in points.append(p);return p.x*0.03+p.y*0.02 }
            XCTAssertEqual(points.count,6)
            for v in 0..<6 {
                let p=shadow[v].position,uv=shadow[v].uv
                for (a,b) in zip([p.x,p.y,uv.x,uv.y],[original[v*5],original[v*5+1],original[v*5+3],original[v*5+4]]) {
                    maxShadow=max(maxShadow,abs(a-b));XCTAssertEqual(a,b,accuracy:0.00002)
                }
                XCTAssertEqual(p.z,points[v].x*0.03+points[v].y*0.02)
            }
        }
        XCTAssertThrowsError(try CarShadow(dimensions:SIMD2(.nan,1)))
        XCTAssertThrowsError(try CarShadow(dimensions:SIMD2(0,1)))
        print("CAMERA_BONNET updates=1000 maxAbsolute=\(maxCamera); SHADOW_GEOMETRY cases=1000 vertices=6000 maxAbsolute=\(maxShadow)")
    }
    func testGPUShadowBlendOcclusionAndTransparencyOrder() async throws {
        try await MainActor.run {
            let pyramid=try TexturePyramid(image:TextureImage(width:1,height:1,channels:4,pixels:[0,0,0,128]),filename:"shadow",options:.init(mipmaps:false))
            let texture=CompiledTexture(sourceSHA256:"test",cacheKey:"test",filename:"shadow",options:.init(mipmaps:false),pyramid:pyramid)
            let shadow=try CarShadow(dimensions:SIMD2(2,2)).project(body:matrix_identity_float4x4) { _ in 0 }
            @MainActor func renderer(_ meshes:[ACMesh]) throws -> SceneRenderer {
                let r=try SceneRenderer(scene:SceneRenderingTests.loaded(meshes))
                r.camera=SceneCamera(eye:SIMD3(0,0,3),target:.zero,up:SIMD3(0,1,0))
                try r.setShadowTexture(texture);try r.setShadow(shadow);return r
            }
            let r=try renderer([SceneRenderingTests.quad()])
            let shaded=Array(try r.render(width:64,height:64))
            XCTAssertEqual(Array(SceneRenderingTests.pixel(shaded).prefix(3)),[127,127,127])
            let inverted=try CarShadow(dimensions:SIMD2(2,2)).project(body:simd_float4x4(diagonal:SIMD4(1,-1,-1,1))) { _ in 0 }
            try r.setShadow(inverted)
            XCTAssertEqual(SceneRenderingTests.pixel(Array(try r.render(width:64,height:64))),[255,255,255,255])
            try r.setShadow([])
            XCTAssertEqual(SceneRenderingTests.pixel(Array(try r.render(width:64,height:64))),[255,255,255,255])
            let occluded=try renderer([SceneRenderingTests.quad(),SceneRenderingTests.quad(z:0.4,color:[1,0,0,1])])
            XCTAssertEqual(SceneRenderingTests.pixel(Array(try occluded.render(width:64,height:64))),[255,0,0,255])
            let translucent=try renderer([SceneRenderingTests.quad(),SceneRenderingTests.quad(z:0.4,color:[0,0,1,0.5],flags:33)])
            let pixel=SceneRenderingTests.pixel(Array(try translucent.render(width:64,height:64)))
            XCTAssertEqual(pixel[0],64,accuracy:1);XCTAssertEqual(pixel[1],64,accuracy:1);XCTAssertEqual(pixel[2],191,accuracy:1)
            XCTAssertThrowsError(try r.setShadow(Array(shadow.prefix(5))))
            print("SHADOW_GPU groundBlend=1 opaqueOcclusion=1 transparentOrder=1 toggle=1 backfaceCull=1")
        }
    }
}
