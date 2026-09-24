// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import CReference
import TORCSRaceEngine
@testable import TORCSAssets
@testable import TORCSMetal

final class CarLightRenderingTests:XCTestCase {
    static func light(_ type:CarLightType = .brake,car:Int=0,position:SIMD3<Float>=SIMD3(0,0,0.1),size:Float=0.9,on:Bool=true) throws -> SceneCarLight {
        SceneCarLight(carIndex:car,light:try CarLightInstance(definition:CarLightDefinition(type:type,position:position,size:size),body:matrix_identity_float4x4,brakeCommand:on ? 1:0,lightCommand:on ? 3:0))
    }
    func testPointFrustumAgainstOriginalPLIB() throws {
        var cases=0
        for i in 0..<30 {
            let n:Float=0.01+Float(i)*0.03,f:Float=80+Float(i)*10,r:Float=n*(0.1+Float(i)*0.07),t:Float=n*(0.3+Float(i)*0.013)
            let native=try CarLightFrustum(near:n,far:f,right:r,top:t)
            let view=matrix_identity_float4x4
            let values=withUnsafeBytes(of:view) { Array($0.bindMemory(to:Float.self)) }
            for depth in [n.nextDown,n,n.nextUp,(n+f)/2,f.nextDown,f,f.nextUp] {
                let x=depth*r/n,y=depth*t/n
                for px in [-x.nextUp,-x,-x.nextDown,0,x.nextDown,x,x.nextUp] { for py in [-y.nextUp,-y,-y.nextDown,0,y.nextDown,y,y.nextUp] {
                    let point=SIMD3(px,py,-depth)
                    XCTAssertEqual(native.contains(point,view:view),ref_carlight_frustum(n,f,r,t,values,[px,py,-depth]) != 0);cases += 1
                } }
            }
        }
        print("CAR_LIGHT_FRUSTUM cases=\(cases) originalPointSphereClassification=exact")
    }
    func testGPUOrderedBlendDepthOcclusionAndAtomicFailure() async throws {
        let red=try Self.light(),blue=try Self.light(.brake2,car:1),off=try Self.light(on:false)
        try await MainActor.run {
            let renderer=try SceneRenderer(scene:SceneRenderingTests.loaded([SceneRenderingTests.quad()]))
            renderer.camera=SceneCamera(eye:SIMD3(0,0,3),target:.zero,fieldOfView:.pi/2,near:1,far:100,up:SIMD3(0,1,0))
            let redTexture=try CarReflectionTests.texture("red") { _,_ in [255,0,0,255] },blueTexture=try CarReflectionTests.texture("blue") { _,_ in [0,0,255,255] }
            try renderer.setCarLightTextures(["breaklight1.rgb":redTexture,"breaklight2.rgb":blueTexture,"rearlight1.rgb":redTexture]);XCTAssertEqual(renderer.lightTextureCount,2)
            for quality in [false,true] {
                renderer.smoothEdges=quality;renderer.enhancedFiltering=quality
                try renderer.setCarLights([red,blue]);let first=Array(try renderer.render(width:64,height:64,captureCommands:true)),digest=renderer.lastSubmissionSHA256,draws=renderer.lightRandomDraws
                XCTAssertEqual(renderer.lastLightDrawCount,2)
                for (a,b) in zip(SceneRenderingTests.pixel(first).prefix(3),[54,16,169]) { XCTAssertEqual(Int(a),b,accuracy:1) }
                for _ in 0..<3 { XCTAssertEqual(Array(try renderer.render(width:64,height:64,captureCommands:true)),first);XCTAssertEqual(renderer.lastSubmissionSHA256,digest);XCTAssertEqual(renderer.lightRandomDraws,draws) }
                XCTAssertThrowsError(try renderer.setCarLights([Self.light(car:-1)]));XCTAssertThrowsError(try renderer.setCarLights(Array(repeating:red,count:15)))
                XCTAssertThrowsError(try renderer.setCarLightTextures(["breaklight1.rgb":redTexture]))
                XCTAssertEqual(Array(try renderer.render(width:64,height:64,captureCommands:true)),first);XCTAssertEqual(renderer.lightRandomDraws,draws)
                try renderer.setCarLights([blue,red]);let reversed=Array(try renderer.render(width:64,height:64))
                for (a,b) in zip(SceneRenderingTests.pixel(reversed).prefix(3),[169,16,54]) { XCTAssertEqual(Int(a),b,accuracy:1) }
                try renderer.setCarLights([off]);let before=renderer.lightRandomDraws
                _=try renderer.render(width:64,height:64);XCTAssertEqual(renderer.lastLightDrawCount,0);XCTAssertEqual(renderer.lightRandomDraws,before)
                try renderer.setCarLights([Self.light(position:SIMD3(20,0,0.1),size:30)])
                _=try renderer.render(width:64,height:64);XCTAssertEqual(renderer.lastLightDrawCount,0);XCTAssertEqual(renderer.lightRandomDraws,before)
            }
            let occluder=try SceneRenderer(scene:SceneRenderingTests.loaded([SceneRenderingTests.quad(z:0.5,color:[0,1,0,1])]))
            occluder.camera=renderer.camera;try occluder.setCarLightTextures(["breaklight1.rgb":redTexture]);try occluder.setCarLights([red])
            XCTAssertEqual(SceneRenderingTests.pixel(Array(try occluder.render(width:64,height:64))),[0,255,0,255])
            let glass=try SceneRenderer(scene:SceneRenderingTests.loaded([SceneRenderingTests.quad(),SceneRenderingTests.quad(z:0.05,color:[0,1,0,0.5],flags:1|32)]))
            glass.camera=renderer.camera;try glass.setCarLightTextures(["breaklight1.rgb":redTexture]);try glass.setCarLights([red])
            for (a,b) in zip(SceneRenderingTests.pixel(Array(try glass.render(width:64,height:64))).prefix(3),[108,159,32]) { XCTAssertEqual(Int(a),b,accuracy:1) }
            print("CAR_LIGHT_GPU blendOrder=1 depthOcclusion=1 noDepthWrites=1 textureDeduplication=1 atomicFailure=1 pointCulling=1 qualityModes=2 repeatPairs=6")
        }
    }
    func testGPUClampBorderAndOriginalModulation() async throws {
        let item=try Self.light(position:.zero)
        try await MainActor.run {
            let renderer=try SceneRenderer(scene:SceneRenderingTests.loaded([SceneRenderingTests.quad(z:-0.1)]))
            renderer.camera=SceneCamera(eye:SIMD3(0,0,3),target:.zero,fieldOfView:.pi/2,near:1,far:100,up:SIMD3(0,1,0))
            try renderer.setCarLightTextures(["breaklight1.rgb":CarReflectionTests.texture("white") { _,_ in [255,255,255,255] }]);try renderer.setCarLights([item])
            let pixels=Array(try renderer.render(width:64,height:64))
            var random=try CarLightDrawing();let quad=try XCTUnwrap(random.draw(item.light,view:renderer.camera.view()))
            var count=0,border=0,maximum=0
            for y in 23...40 { for x in 23...40 {
                let wx=(Float(x)+0.5)/64*6-3,wy=3-(Float(y)+0.5)/64*6
                let base=SIMD4((wy+0.9)/1.8,(wx+0.9)/1.8,0,1),uv=quad.textureMatrix*base
                func edge(_ u:Float)->Float { let c=min(1,max(0,u));return min(1,8*c+0.5)*min(1,8*(1-c)+0.5) }
                let w=edge(uv.x)*edge(uv.y),expected=Int((255*(1-0.75*w+0.6*w*w)).rounded())
                let pixel=SceneRenderingTests.pixel(pixels,x,y)
                maximum=max(maximum,abs(Int(pixel[0])-expected));XCTAssertEqual(Int(pixel[0]),expected,accuracy:2)
                XCTAssertEqual(pixel[0],pixel[1]);XCTAssertEqual(pixel[1],pixel[2]);count += 1;if w<1 { border += 1 }
            } }
            XCTAssertGreaterThan(border,0)
            print("CAR_LIGHT_CLAMP pixels=\(count) borderPixels=\(border) maximumByteError=\(maximum) originalColorAndAlphaModulation=1")
        }
    }
    func testLightPointHeightBoundsAgainstOriginal() throws {
        var cases=0
        for count in 0...14 {
            var points:[SIMD3<Float>]=[]
            for i in 0..<count { points.append(SIMD3(Float(i)*0.31-2,Float(i%3)*0.73,Float(i)*0.02+0.8)) }
            let native=try SceneHeightQuery(lightPositions:points)
            let handle=try XCTUnwrap(ref_scene_height_create());defer { ref_scene_height_destroy(handle) }
            XCTAssertEqual(ref_scene_height_add(handle,-1,1,nil,0,0,nil,0),1);let root:Int32=0
            for p in points { XCTAssertEqual(ref_scene_height_add(handle,root,2,nil,5,0,[p.x,p.y,p.z],1),1) }
            var spheres=[Float](repeating:0,count:(count+1)*4);ref_scene_height_spheres(handle,&spheres)
            let actual=native.referenceSpheres.flatMap { [$0.x,$0.y,$0.z,$0.w] };XCTAssertEqual(actual,spheres)
            for x in -5...5 { let p=SIMD2(Float(x),0),result=try native.query(x:p.x,y:p.y)
                var height:Float=0,hits:Int32=0,triangles:Int32=0;ref_scene_height_query(handle,[p.x,p.y],1,&height,&hits,&triangles)
                XCTAssertEqual(result.height,height);XCTAssertEqual(result.retainedHits,Int(hits));XCTAssertEqual(result.testedTriangles,Int(triangles));cases += 1
            }
        }
        print("CAR_LIGHT_HEIGHT lightCounts=15 queries=\(cases) spheresHeightsHitsTriangles=exact")
    }
    func testGPUMirrorExcludesCurrentCarAndKeepsOtherLights() async throws {
        let red=try Self.light(car:7,position:SIMD3(-0.35,0,0.1),size:0.22),blue=try Self.light(.brake2,car:2,position:SIMD3(0.35,0,0.1),size:0.22)
        try await MainActor.run {
            var changed=0
            let textures=["breaklight1.rgb":try CarReflectionTests.texture("red") { _,_ in [255,0,0,255] },"breaklight2.rgb":try CarReflectionTests.texture("blue") { _,_ in [0,0,255,255] }]
            for quality in [false,true] { for (w,h) in [(96,72),(192,144)] {
                let scene=SceneRenderingTests.loaded([SceneRenderingTests.quad()])
                let reference=try SceneRenderer(scene:scene),renderer=try SceneRenderer(scene:scene)
                let body=simd_float4x4(SIMD4(0,0,1,0),SIMD4(1,0,0,0),SIMD4(0,1,0,0),SIMD4(0,0,2,1))
                let mirror=RearViewMirror(body:body,bonnetPosition:.zero,hiddenInstances:[],currentCar:7)
                for r in [reference,renderer] { r.camera=try mirror.camera(width:w,height:h);r.smoothEdges=quality;try r.setCarLightTextures(textures);try r.setCarLights([red,blue]) }
                reference.lightView=ShadowView(currentCar:7,drawsCurrentCar:false)
                let rear=Array(try reference.render(width:w,height:h))
                renderer.mirror=mirror
                let actual=Array(try renderer.render(width:w,height:h,captureCommands:true)),digest=renderer.lastSubmissionSHA256
                XCTAssertEqual(renderer.lastLightDrawCount,3);XCTAssertEqual(renderer.lightRandomDraws,3)
                let layout=MirrorLayout(width:w,height:h)
                for y in 0..<layout.height { for x in 0..<layout.width {
                    let i=((y+layout.y)*w+x+layout.x)*4,j=((layout.sourceY+y)*w+layout.sourceX+layout.width-1-x)*4
                    for c in 0..<3 { XCTAssertEqual(actual[i+c],rear[j+c]) }
                    XCTAssertEqual(actual[i+3],255)
                    if rear[j] != 255 || rear[j+1] != 255 { changed += 1 }
                } }
                XCTAssertEqual(Array(try renderer.render(width:w,height:h,captureCommands:true)),actual);XCTAssertEqual(renderer.lastSubmissionSHA256,digest);XCTAssertEqual(renderer.lightRandomDraws,3)
            } }
            XCTAssertGreaterThan(changed,0)
            print("CAR_LIGHT_MIRROR sizeQualityCases=4 visibleOtherLightPixels=\(changed) currentExcluded=1 rearBeforeMainRandomSchedule=1 repeatPairs=4")
        }
    }

}
