// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import simd
@testable import TORCSAssets
@testable import TORCSMetal

final class MultiCarShadowTests: XCTestCase {
    func testVisibilityAgainstOriginalCurrentCarRule() {
        var cases=0
        for count in [1,2,3,16,32] { for current in -1..<count { for draw in [false,true] {
            let view=ShadowView(currentCar:current<0 ? nil:current,drawsCurrentCar:draw)
            for car in 0..<count {
                XCTAssertEqual(view.isVisible(carIndex:car),ref_shadow_visibility(Int32(car),Int32(current),draw ? 1:0) != 0);cases += 1
            }
        } } }
        print("MULTI_SHADOW_VISIBILITY originalCases=\(cases) absentCurrentAndMirrorExclusion=exact")
    }
    func vertices(x:Float=0,dimensions:SIMD2<Float>=SIMD2(2,2)) throws -> [ShadowVertex] {
        var body=matrix_identity_float4x4;body[3].x=x
        return try CarShadow(dimensions:dimensions).project(body:body) { _ in 0 }
    }
    func testGPUOrderedOverlapResourceSharingAndAtomicFailures() async throws {
        let vertices=try vertices()
        try await MainActor.run {
            let red=try CarReflectionTests.texture("red-shadow") { _,_ in [255,0,0,128] }
            let blue=try CarReflectionTests.texture("blue-shadow") { _,_ in [0,0,255,128] }
            let renderer=try SceneRenderer(scene:SceneRenderingTests.loaded([SceneRenderingTests.quad()]))
            renderer.camera=SceneCamera(eye:SIMD3(0,0,3),target:.zero,up:SIMD3(0,1,0))
            try renderer.setShadowTextures([red,blue,red,nil]);XCTAssertEqual(renderer.shadowTextureCount,2)
            let first=SceneShadow(carIndex:2,resource:0,vertices:vertices),second=SceneShadow(carIndex:0,resource:1,vertices:vertices)
            for quality in [false,true] {
                renderer.smoothEdges=quality;renderer.enhancedFiltering=quality
                try renderer.setShadows([first,second,SceneShadow(carIndex:1,resource:3,vertices:vertices)])
                let forward=Array(try renderer.render(width:64,height:64,captureCommands:true)),digest=renderer.lastSubmissionSHA256
                XCTAssertEqual(renderer.lastShadowDrawCount,2)
                let pixel=SceneRenderingTests.pixel(forward)
                for (a,b) in zip(pixel.prefix(3),[127,63,191]) { XCTAssertEqual(Int(a),b,accuracy:1) }
                for _ in 0..<5 { XCTAssertEqual(Array(try renderer.render(width:64,height:64,captureCommands:true)),forward);XCTAssertEqual(renderer.lastSubmissionSHA256,digest) }
                let invalid=[SceneShadow(carIndex:3,resource:5,vertices:vertices),SceneShadow(carIndex:-1,resource:0,vertices:vertices),SceneShadow(carIndex:1024,resource:0,vertices:vertices),SceneShadow(carIndex:3,resource:0,vertices:Array(vertices.prefix(5))),SceneShadow(carIndex:3,resource:0,vertices:vertices,normal:SIMD3(.infinity,0,1)),SceneShadow(carIndex:3,resource:0,vertices:vertices,normal:.zero)]
                for bad in invalid { XCTAssertThrowsError(try renderer.setShadows([first,bad])) }
                XCTAssertThrowsError(try renderer.setShadows([first,first]));XCTAssertThrowsError(try renderer.setShadowTextures([red]))
                XCTAssertEqual(Array(try renderer.render(width:64,height:64,captureCommands:true)),forward);XCTAssertEqual(renderer.lastSubmissionSHA256,digest)
                try renderer.setShadows([second,first]);let reverse=Array(try renderer.render(width:64,height:64))
                XCTAssertNotEqual(reverse,forward)
                for (a,b) in zip(SceneRenderingTests.pixel(reverse).prefix(3),[191,63,127]) { XCTAssertEqual(Int(a),b,accuracy:1) }
                renderer.shadowView=ShadowView(currentCar:2,drawsCurrentCar:false)
                _=try renderer.render(width:64,height:64);XCTAssertEqual(renderer.lastShadowDrawCount,1)
                renderer.shadowView=ShadowView()
            }
            // Two immutable resources with identical mip bytes share one GPU texture.
            try renderer.setShadows([]);try renderer.setShadowTextures([red,red,nil]);XCTAssertEqual(renderer.shadowTextureCount,1)
            try renderer.setShadowTextures([]);XCTAssertEqual(renderer.shadowTextureCount,0)
            XCTAssertThrowsError(try renderer.setShadows([first]))
            print("MULTI_SHADOW_GPU orderedAlphaOverlap=1 noDepthWrites=1 independentTextures=1 sharedMipBytes=1 atomicFailures=1 qualityModes=2 repeatPairs=10")
        }
    }
    func testGPUPerCarNormalsAndLegacySingleShadowIdentity() async throws {
        let left=try vertices(x:-0.5,dimensions:SIMD2(0.7,1)),right=try vertices(x:0.5,dimensions:SIMD2(0.7,1))
        try await MainActor.run {
            let renderer=try SceneRenderer(scene:SceneRenderingTests.loaded([SceneRenderingTests.quad()]))
            renderer.camera=SceneCamera(eye:SIMD3(0,0,3),target:.zero,up:SIMD3(0,1,0))
            try renderer.setShadowTexture(CarReflectionTests.texture("white-shadow") { _,_ in [255,255,255,255] })
            try renderer.setShadows([SceneShadow(carIndex:0,resource:0,vertices:left),SceneShadow(carIndex:1,resource:0,vertices:right,normal:SIMD3(0,0,-1))])
            let pixels=Array(try renderer.render(width:64,height:64))
            XCTAssertEqual(Array(pixels[(32*64+18)*4..<(32*64+18)*4+3]),[255,255,255])
            XCTAssertEqual(Array(pixels[(32*64+46)*4..<(32*64+46)*4+3]),[102,102,102])
            try renderer.setShadow(left);let legacy=try renderer.render(width:64,height:64)
            try renderer.setShadows([SceneShadow(carIndex:0,resource:0,vertices:left)])
            XCTAssertEqual(try renderer.render(width:64,height:64),legacy)
            renderer.shadowView=ShadowView(currentCar:1024);XCTAssertThrowsError(try renderer.render(width:64,height:64))
            print("MULTI_SHADOW_NORMALS perCarLighting=1 legacySetterRasterIdentity=1")
        }
    }
    func testMirrorKeepsOtherCarsShadowsAndHidesOnlyCurrentCar() async throws {
        let left=try vertices(x:-0.35,dimensions:SIMD2(0.5,2)),right=try vertices(x:0.35,dimensions:SIMD2(0.5,2))
        try await MainActor.run {
            let renderer=try SceneRenderer(scene:SceneRenderingTests.loaded([SceneRenderingTests.quad()]))
            try renderer.setShadowTextures([CarReflectionTests.texture("red") { _,_ in [255,0,0,255] },CarReflectionTests.texture("blue") { _,_ in [0,0,255,255] }])
            let body=simd_float4x4(SIMD4(0,0,1,0),SIMD4(1,0,0,0),SIMD4(0,1,0,0),SIMD4(0,0,2,1))
            let mirror=RearViewMirror(body:body,bonnetPosition:.zero,hiddenInstances:[],currentCar:7)
            let shadows=[SceneShadow(carIndex:7,resource:0,vertices:left),SceneShadow(carIndex:2,resource:1,vertices:right)]
            var comparisons=0
            for quality in [false,true] { for (w,h) in [(96,72),(192,144)] {
                renderer.smoothEdges=quality;renderer.enhancedFiltering=quality
                renderer.mirror=nil;renderer.camera=try mirror.camera(width:w,height:h)
                try renderer.setShadows([]);let plain=Array(try renderer.render(width:w,height:h))
                try renderer.setShadows(shadows)
                renderer.shadowView=ShadowView(currentCar:7,drawsCurrentCar:false)
                let rear=Array(try renderer.render(width:w,height:h))
                renderer.shadowView=ShadowView();let main=Array(try renderer.render(width:w,height:h))
                renderer.mirror=mirror
                let actual=Array(try renderer.render(width:w,height:h,captureCommands:true)),digest=renderer.lastSubmissionSHA256
                XCTAssertEqual(renderer.lastShadowDrawCount,3)
                let layout=MirrorLayout(width:w,height:h);var otherShadowPixels=0
                for y in 0..<h { for x in 0..<w {
                    let inside=x>=layout.x && x<layout.x+layout.width && y>=layout.y && y<layout.y+layout.height
                    let i=(y*w+x)*4,source=inside ? ((layout.sourceY+y-layout.y)*w+layout.sourceX+layout.width-1-(x-layout.x))*4:i
                    for c in 0..<4 { XCTAssertEqual(Int(actual[i+c]),Int(inside ? rear[source+c]:main[i+c]),accuracy:1) }
                    if inside && rear[source..<source+3] != plain[source..<source+3] { otherShadowPixels += 1 }
                } }
                XCTAssertGreaterThan(otherShadowPixels,20)
                XCTAssertEqual(Array(try renderer.render(width:w,height:h,captureCommands:true)),actual);XCTAssertEqual(renderer.lastSubmissionSHA256,digest)
                comparisons += 1
            } }
            print("MULTI_SHADOW_MIRROR comparisons=\(comparisons) otherCarShadowsVisible=1 currentCarShadowHidden=1 cropFlipRepeat=1")
        }
    }
}
