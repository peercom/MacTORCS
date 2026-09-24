// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import CReference
import TORCSSimulation
@testable import TORCSAssets
@testable import TORCSMetal

final class RearViewMirrorTests:XCTestCase {
    func testOriginalCameraCropDisplayAndResize() throws {
        var maximum:Float=0
        for i in 0..<1200 {
            let t=Float(i),w=320+i%701,h=180+i%301
            let transform=CollisionTransform(position:SIMD3(t*0.01,-t*0.025,2+sin(t)),orientation:SIMD3(sin(t)*0.4,cos(t)*0.3,t*0.02))
            let body=VehiclePresentation.matrix(transform),bonnet=SIMD3<Float>(0.6,0,1)
            let mirror=RearViewMirror(body:body,bonnetPosition:bonnet,hiddenInstances:[])
            let camera=try mirror.camera(width:w,height:h),layout=MirrorLayout(width:w,height:h)
            var original=[Float](repeating:0,count:45)
            ref_camera_mirror((0..<4).flatMap{[body[$0].x,body[$0].y,body[$0].z,body[$0].w]},[bonnet.x,bonnet.y,bonnet.z],Int32(w),Int32(h),&original)
            let values=[camera.eye.x,camera.eye.y,camera.eye.z,camera.target.x,camera.target.y,camera.target.z,camera.up.x,camera.up.y,camera.up.z]
            for (a,b) in zip(values,original) { maximum=max(maximum,abs(a-b));XCTAssertEqual(a,b,accuracy:0.00001) }
            XCTAssertEqual(camera.fieldOfView,original[9] * .pi/180);XCTAssertEqual(camera.fogRange,SIMD2(original[12],original[13]))
            XCTAssertEqual(Array(original[14...16]),[0,1,1])
            let expected=SceneCamera(eye:SIMD3(original[0],original[1],original[2]),target:SIMD3(original[3],original[4],original[5]),fieldOfView:original[9] * .pi/180,near:original[10],far:original[11],up:SIMD3(original[6],original[7],original[8]))
            let a=camera.viewProjection(aspect:Float(w)/Float(h)),b=expected.viewProjection(aspect:Float(w)/Float(h))
            for c in 0..<4 { for r in 0..<4 { XCTAssertEqual(a[c][r],b[c][r],accuracy:0.0001) } }
            XCTAssertEqual(Array(original[17...20]),[0,0,Float(w),Float(h)])
            XCTAssertEqual(Array(original[21...24]),[Float(layout.sourceX),Float(h-layout.sourceY-layout.height),Float(layout.width),Float(layout.height)])
            XCTAssertEqual(Array(original[21...24]),Array(original[25...28]))
            let x=Float(layout.x),bottom=Float(h-layout.y-layout.height),mw=Float(layout.width),mh=Float(layout.height)
            XCTAssertEqual(Array(original[29...36]),[x,bottom,x,bottom+mh,x+mw,bottom,x+mw,bottom+mh])
            XCTAssertEqual(Array(original[37...44]),[mw,0,mw,mh,0,0,0,mh])
        }
        var flags=[Int32](repeating:0,count:4);ref_camera_mirror_flags(&flags);XCTAssertEqual(flags,[1,1,0,0])
        XCTAssertEqual(Set(DrivingCameraPreset.allCases.filter(\.allowsMirror)),[.driver,.bonnet,.road])
        let mirror=RearViewMirror(body:matrix_identity_float4x4,bonnetPosition:.zero,hiddenInstances:[])
        XCTAssertThrowsError(try mirror.camera(width:100,height:200));XCTAssertThrowsError(try mirror.camera(width:1,height:1))
        print("MIRROR_CAMERA updates=1200 poseMaximum=\(maximum) cropAndFlipExact=1 factoryFlags=1")
    }

    func testGPUCropFlipInstanceExclusionRepeatAndTargetReuse() async throws {
        try await MainActor.run {
            let texture=try CarReflectionTests.texture("grid") { x,y in [UInt8(x*7),UInt8(y*7),UInt8((x+y)*3),255] }
            let track=SceneRenderingTests.loaded([SceneRenderingTests.quad(texture:"grid")],textures:["grid":texture])
            let car=SceneRenderingTests.loaded([SceneRenderingTests.quad(z:0.1,color:[1,0,0,1])])
            let renderer=try SceneRenderer(scenes:[track,car])
            let body=simd_float4x4(SIMD4(0,0,1,0),SIMD4(1,0,0,0),SIMD4(0,1,0,0),SIMD4(0,0,2,1))
            let mirror=RearViewMirror(body:body,bonnetPosition:.zero,hiddenInstances:[1])
            var maximum=0
            for (w,h) in [(96,72),(97,73),(192,144)] {
                renderer.mirror=nil;renderer.camera=try mirror.camera(width:w,height:h)
                try renderer.setInstances([SceneInstance(resource:0)])
                let rear=Array(try renderer.render(width:w,height:h))
                try renderer.setInstances([SceneInstance(resource:0),SceneInstance(resource:1)])
                let main=Array(try renderer.render(width:w,height:h))
                renderer.mirror=mirror
                let composed=Array(try renderer.render(width:w,height:h,captureCommands:true)),digest=renderer.lastSubmissionSHA256
                let layout=MirrorLayout(width:w,height:h)
                for y in 0..<h { for x in 0..<w {
                    let inside=x>=layout.x && x<layout.x+layout.width && y>=layout.y && y<layout.y+layout.height
                    let index=(y*w+x)*4
                    let source=inside ? ((layout.sourceY+y-layout.y)*w+layout.sourceX+layout.width-1-(x-layout.x))*4:index
                    for c in 0..<4 {
                        let expected=inside ? rear[source+c]:main[index+c]
                        let delta=abs(Int(composed[index+c])-Int(expected));maximum=max(maximum,delta)
                        XCTAssertLessThanOrEqual(delta,inside ? 1:0,"crop \(w)x\(h) at \(x),\(y),\(c)")
                    }
                } }
                let allocations=renderer.mirrorAllocationCount
                for _ in 0..<5 { XCTAssertEqual(Array(try renderer.render(width:w,height:h,captureCommands:true)),composed);XCTAssertEqual(renderer.lastSubmissionSHA256,digest) }
                XCTAssertEqual(renderer.mirrorAllocationCount,allocations)
                renderer.mirror=nil;XCTAssertEqual(Array(try renderer.render(width:w,height:h)),main)
            }
            // Adjacent odd/even drawable sizes share the same crop dimensions.
            XCTAssertEqual(renderer.mirrorAllocationCount,2)
            renderer.mirror=RearViewMirror(body:body,bonnetPosition:.zero,hiddenInstances:[5])
            XCTAssertThrowsError(try renderer.render(width:96,height:72))
            print("MIRROR_GPU sizes=3 repeats=15 outsideUnchanged=1 currentCarHidden=1 targetsReused=1 cropMaximum=\(maximum)")
        }
    }

    func testPlayerShadowIsAbsentFromMirror() async throws {
        try await MainActor.run {
            let renderer=try SceneRenderer(scene:SceneRenderingTests.loaded([SceneRenderingTests.quad(color:[0,0,1,1])]))
            let body=simd_float4x4(SIMD4(0,0,1,0),SIMD4(1,0,0,0),SIMD4(0,1,0,0),SIMD4(0,0,2,1))
            let mirror=RearViewMirror(body:body,bonnetPosition:.zero,hiddenInstances:[])
            renderer.camera=try mirror.camera(width:96,height:72);renderer.mirror=mirror
            let plain=Array(try renderer.render(width:96,height:72))
            try renderer.setShadowTexture(CarReflectionTests.texture("shadow") { _,_ in [0,255,0,255] })
            try renderer.setShadow(CarShadow(dimensions:SIMD2(4,4)).project(body:matrix_identity_float4x4) { _ in 0.2 })
            let shadow=Array(try renderer.render(width:96,height:72)),layout=MirrorLayout(width:96,height:72)
            var outsideChanges=0
            for y in 0..<72 { for x in 0..<96 {
                let i=(y*96+x)*4
                if x>=layout.x && x<layout.x+layout.width && y>=layout.y && y<layout.y+layout.height { XCTAssertEqual(Array(plain[i..<i+4]),Array(shadow[i..<i+4])) }
                else if plain[i..<i+4] != shadow[i..<i+4] { outsideChanges += 1 }
            } }
            XCTAssertGreaterThan(outsideChanges,100)
            print("MIRROR_SHADOW playerShadowAbsent=1 mainShadowVisible=1")
        }
    }
}
