// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import simd
@testable import TORCSAssets
@testable import TORCSMetal

final class SceneAlphaStateTests:XCTestCase {
    func testOriginalPartialStateAndFrameReset() throws {
        var care:[Int32]=[],enabled:[Int32]=[],clamps:[Float]=[]
        let thresholds:[Float]=[-1,0,0.01,0.65,0.7,0.75,1,2]
        for i in 0..<1024 { care.append(i%31==0 ? -1:Int32(i%4));enabled.append(Int32(i/4%2));clamps.append(thresholds[i/8%thresholds.count]) }
        var output=[Float](repeating:-1,count:(care.count+1)*2)
        XCTAssertEqual(ref_alpha_state(care,enabled,clamps,Int32(care.count),&output),Int32(care.count+1))
        var state=SceneAlphaState()
        XCTAssertEqual(output[0],state.enabled ? 1:0);XCTAssertEqual(output[1],state.threshold)
        for i in care.indices {
            if care[i]<0 { state=SceneAlphaState() }
            else { state.apply(ACRenderState(material:[],texture:nil,flags:enabled[i]==1 ? 16:0,alphaClamp:clamps[i],alphaCare:UInt32(care[i]))) }
            XCTAssertEqual(output[(i+1)*2],state.enabled ? 1:0,"step \(i)")
            XCTAssertEqual(output[(i+1)*2+1],state.threshold,"step \(i)")
        }
        print("SCENE_ALPHA_REFERENCE sequentialUpdates=1024 resetEvery=31 enableAndClampCareIndependent=1 capturedOriginalApplyForce=exact")
    }
    func testConservativeTextureAlphaBoundsAndDiscardElision() throws {
        for channels in 1...4 {
            let pixels=(0..<16).flatMap { i in Array(repeating:UInt8(i==0 ? 0:128),count:channels) }
            let image=try TextureImage(width:4,height:4,channels:channels,pixels:pixels)
            let pyramid=try TexturePyramid(image:image,filename:"test.rgb")
            let expected=pyramid.levels.flatMap { level in stride(from:3,to:level.rgba8.count,by:4).map { level.rgba8[$0] } }.min()!
            XCTAssertEqual(SceneAlphaState.minimumAlpha(pyramid),Float(expected)/255)
        }
        var state=SceneAlphaState()
        let on=SIMD4<UInt32>(repeating:1),all=SIMD4<Float>(repeating:1)
        state.apply(ACRenderState(material:[],texture:nil,flags:16,alphaClamp:0))
        XCTAssertFalse(state.needsTest(colorAlpha:0.5,minimumTextureAlpha:SIMD4(repeating:0.2),maps:on))
        for i in 0..<4 {
            var bounds=all;bounds[i]=0
            XCTAssertTrue(state.needsTest(colorAlpha:1,minimumTextureAlpha:bounds,maps:on))
            var maps=on;maps[i]=0
            XCTAssertFalse(state.needsTest(colorAlpha:1,minimumTextureAlpha:bounds,maps:maps))
        }
        for alpha:Float in [0,-1,Float.leastNonzeroMagnitude] { XCTAssertTrue(state.needsTest(colorAlpha:alpha,minimumTextureAlpha:all,maps:on)) }
        state.apply(ACRenderState(material:[],texture:nil,flags:16,alphaClamp:0.5))
        for alpha:Float in [0.4,0.5,Float(0.5).nextUp] { XCTAssertTrue(state.needsTest(colorAlpha:alpha,minimumTextureAlpha:all,maps:on)) }
        XCTAssertFalse(state.needsTest(colorAlpha:0.6,minimumTextureAlpha:all,maps:on))
        print("SCENE_ALPHA_BOUNDS channels=4 allUploadedMips=1 activeTextureLayers=4 boundaryCasesRetainTest=1 positiveProductElision=1")
    }
    func testCompiledLoaderMetadataAndGeneratedBrakeInheritance() throws {
        let fixtures=try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil))
        var states=0,inherited=0
        for (path,car) in [("155-DTM/155-DTM",true),("aalborg/aalborg",false)]+(0..<4).map({ ("trb1-3/wheel\($0)",true) }) {
            let data=try Data(contentsOf:fixtures.appendingPathComponent("Artwork/"+path+".acc"))
            let scene=try ACScene.parse(data,car:car)
            let cached=try ACMeshCache.decode(ACMeshCache.compile(data,options:.init(car:car))).scene
            XCTAssertEqual(cached,scene)
            for mesh in scene.nodes.compactMap(\.mesh) { for (layer,state) in mesh.states.enumerated() { if let state {
                XCTAssertEqual(state.alphaCare,layer==0 ? (state.flags&16 != 0 ? 3:2):(state.flags&16 != 0 ? 3:0))
                states += 1;if state.alphaCare&1==0 { inherited += 1 }
            } } }
        }
        var invalid=try ACScene.parse(ACSceneTests.fixture());invalid.nodes[invalid.nodes.count-1].mesh!.states[0]!.alphaCare=4
        XCTAssertThrowsError(try invalid.validate())
        // The original grInitCommonState sets lighting/texture only. Brake scene
        // construction is also exercised by the independent original geometry tests.
        for wheel in 0..<4 {
            let brakes=try BrakeGeometry(wheel:wheel,radius:0.15,width:0.25)
            for part in brakes.parts { XCTAssertEqual(part.asset.scene.nodes.last?.mesh?.states[0]?.alphaCare,0) }
        }
        print("SCENE_ALPHA_ASSETS files=6 states=\(states) inheritedEnable=\(inherited) cacheMetadataExact=1 invalidCareRejected=1")
    }
    func testGPUInheritedMeshAlphaDiscardPreventsDepthOcclusion() async throws {
        try await MainActor.run {
            for enabled in [false,true] {
                var base=SceneRenderingTests.quad(z:-0.1,flags:enabled ? 16:0)
                base.states[0]!.alphaClamp=0.65
                var transparent=SceneRenderingTests.quad(z:0.1,color:[0,1,0,0])
                transparent.states[0]!.alphaCare=2;transparent.states[0]!.alphaClamp=0
                var behind=SceneRenderingTests.quad(color:[0,0,1,1]);behind.states[0]!.alphaCare=0
                let renderer=try SceneRenderer(scene:SceneRenderingTests.loaded([base,transparent,behind]))
                renderer.camera=SceneCamera(eye:SIMD3(0,0,3),target:.zero,up:SIMD3(0,1,0))
                for quality in [false,true] {
                    renderer.smoothEdges=quality
                    let data=try renderer.render(width:64,height:64)
                    XCTAssertEqual(Array(SceneRenderingTests.pixel(Array(data)).prefix(3)),enabled ? [0,0,255]:[0,255,0])
                    XCTAssertEqual(try renderer.render(width:64,height:64),data)
                }
            }
        }
        print("SCENE_ALPHA_MESH inheritedEnableAndExplicitZeroClamp=1 discardedAlphaZeroDoesNotOcclude=1 qualityModes=2 repeatPairs=4")
    }
    func testGPUShadowAndLightThresholdAfterTextureModulation() async throws {
        let shadow=try CarShadow(dimensions:SIMD2(2,2)).project(body:matrix_identity_float4x4) { _ in 0 }
        let light=try CarLightRenderingTests.light(position:SIMD3(0,0,0.06))
        try await MainActor.run {
            for threshold:Float in [0.4,0.6,Float(0.75).nextDown,0.75,0.8] {
                var base=SceneRenderingTests.quad(z:-0.1,flags:16);base.states[0]!.alphaClamp=threshold
                let renderer=try SceneRenderer(scene:SceneRenderingTests.loaded([base]))
                renderer.camera=SceneCamera(eye:SIMD3(0,0,3),target:.zero,up:SIMD3(0,1,0))
                try renderer.setShadowTexture(CarReflectionTests.texture("shadow") { _,_ in [0,0,0,128] });try renderer.setShadow(shadow)
                try renderer.setCarLightTextures(["breaklight1.rgb":CarReflectionTests.texture("light") { _,_ in [255,255,255,255] }]);try renderer.setCarLights([light])
                let expected=threshold<0.5 ? 185:(threshold<0.75 ? 217:255)
                for quality in [false,true] {
                    renderer.smoothEdges=quality
                    let data=try renderer.render(width:64,height:64)
                    for c in SceneRenderingTests.pixel(Array(data)).prefix(3) { XCTAssertEqual(Int(c),expected,accuracy:1) }
                    XCTAssertEqual(renderer.lastShadowDrawCount,1);XCTAssertEqual(renderer.lastLightDrawCount,1)
                    XCTAssertEqual(try renderer.render(width:64,height:64),data)
                }
            }
        }
        print("SCENE_ALPHA_EFFECTS thresholds=5 shadowTextureAlpha=1 lightModulatedAlpha=1 strictGreaterBoundary=1 qualityModes=2 repeatPairs=10")
    }
    func testGPUZeroThresholdEffectsPreserveColorAndDepth() async throws {
        let shadow=try CarShadow(dimensions:SIMD2(2,2)).project(body:matrix_identity_float4x4) { _ in 0 }
        let light=try CarLightRenderingTests.light(position:SIMD3(0,0,0.06))
        try await MainActor.run {
            for alpha:UInt8 in [0,1,128,255] {
                var base=SceneRenderingTests.quad(z:-0.1,flags:16)
                base.states[0]!.alphaClamp=0
                let renderer=try SceneRenderer(scene:SceneRenderingTests.loaded([base]))
                renderer.camera=SceneCamera(eye:SIMD3(0,0,3),target:.zero,up:SIMD3(0,1,0))
                try renderer.setShadowTexture(CarReflectionTests.texture("shadow") { _,_ in [0,0,0,alpha] })
                try renderer.setCarLightTextures(["breaklight1.rgb":CarReflectionTests.texture("light") { _,_ in [255,255,255,alpha] }])
                for quality in [false,true] {
                    renderer.smoothEdges=quality
                    try renderer.setShadows([]);try renderer.setCarLights([])
                    let baseline=try renderer.render(width:64,height:64)
                    try renderer.setShadow(shadow);try renderer.setCarLights([light])
                    let data=try renderer.render(width:64,height:64)
                    if alpha==0 { XCTAssertEqual(data,baseline) }
                    else { XCTAssertNotEqual(data,baseline) }
                    XCTAssertEqual(try renderer.render(width:64,height:64),data)
                }
            }
        }
        var state=SceneAlphaState()
        XCTAssertTrue(state.needsBlendedEffectTest)
        for threshold:Float in [0,Float.leastNonzeroMagnitude,0.4] {
            state.apply(ACRenderState(material:[],texture:nil,flags:16,alphaClamp:threshold))
            XCTAssertEqual(state.needsBlendedEffectTest,threshold>0)
        }
        state.apply(ACRenderState(material:[],texture:nil,flags:0,alphaClamp:0.4))
        XCTAssertFalse(state.needsBlendedEffectTest)
        print("SCENE_ALPHA_EFFECT_ZERO alphaValues=4 qualityModes=2 repeatPairs=8 zeroAlphaPreservesDestination=1 positiveThresholdRetainsTest=1")
    }
    func testGPUActualBoundTexturesKeepCutoutDepthRejection() async throws {
        try await MainActor.run {
            let white=try CarReflectionTests.texture("white") { _,_ in [255,255,255,255] }
            var cases=0
            for layer in 0..<3 { for alpha:UInt8 in [0,128,255] {
                let cutout=try CarReflectionTests.texture("cutout") { _,_ in [255,255,255,alpha] }
                var mesh=SceneRenderingTests.quad(z:0.1,color:[1,0,0,1],flags:16,texture:"base")
                mesh.mapCount=3;mesh.mapLevel=3;mesh.states[0]!.alphaClamp=0.6
                mesh.states[1]=ACRenderState(material:Array(repeating:0,count:13),texture:"detail",flags:8,alphaClamp:0)
                mesh.states[2]=ACRenderState(material:Array(repeating:0,count:13),texture:"overlay",flags:8,alphaClamp:0)
                let names=["base","detail","overlay"]
                var textures=Dictionary(uniqueKeysWithValues:names.map { ($0,white) });textures[names[layer]]=cutout
                let renderer=try SceneRenderer(scene:SceneRenderingTests.loaded([mesh,SceneRenderingTests.quad(color:[0,0,1,1])],textures:textures))
                renderer.camera=SceneCamera(eye:SIMD3(0,0,3),target:.zero,up:SIMD3(0,1,0))
                for quality in [false,true] {
                    renderer.smoothEdges=quality
                    let data=try renderer.render(width:64,height:64)
                    XCTAssertEqual(Array(SceneRenderingTests.pixel(Array(data)).prefix(3)),alpha>153 ? [255,0,0]:[0,0,255])
                    XCTAssertEqual(try renderer.render(width:64,height:64),data);cases += 1
                }
            } }
            let transparent=try CarReflectionTests.texture("transparent") { _,_ in [255,255,255,0] }
            let mapping=try CarTrackShadowMapping(trackBounds:ACLoaderBounds(minimumX:0,maximumX:4,minimumY:0,maximumY:4),carBounds:ACLoaderBounds(minimumX:-1,maximumX:1,minimumY:-1,maximumY:1))
            for layer in 1...3 {
                var mesh=SceneRenderingTests.quad(z:0.1,color:[1,0,0,1],flags:16,texture:"base")
                mesh.states[0]!.alphaClamp=0.6;mesh.indexed=true;mesh.primitive=5;mesh.indices=[0,1,3,2];mesh.strips=[4];mesh.mapLevel = -3
                let renderer=try SceneRenderer(scene:SceneRenderingTests.loaded([mesh,SceneRenderingTests.quad(color:[0,0,1,1])],textures:["base":white]))
                renderer.camera=SceneCamera(eye:SIMD3(0,0,3),target:.zero,up:SIMD3(0,1,0))
                try renderer.setCarEnvironment(reflection:layer==1 ? transparent:white,shade:layer==2 ? transparent:white,trackShadow:layer==3 ? transparent:white)
                try renderer.setInstances([SceneInstance(resource:0,reflection:CarReflection(distanceFromStart:0,yaw:0,position:.zero,trackShadow:mapping))])
                for quality in [false,true] {
                    renderer.smoothEdges=quality
                    let data=try renderer.render(width:64,height:64)
                    XCTAssertEqual(Array(SceneRenderingTests.pixel(Array(data)).prefix(3)),[0,0,255])
                    XCTAssertEqual(try renderer.render(width:64,height:64),data);cases += 1
                }
            }
            print("SCENE_ALPHA_BINDINGS gpuCases=\(cases) baseDetailOverlay=1 externalReflectionShadeShadow=1 discardedDepthPreserved=1 repeatPairs=\(cases)")
        }
    }
    func testGPUMirrorStateFollowsItsVisibleDraws() async throws {
        let light=try CarLightRenderingTests.light(car:2,position:SIMD3(10,0,0.1))
        try await MainActor.run {
            let scenes=[Float(0),0.8].map { threshold -> LoadedScene in
                var mesh=SceneRenderingTests.quad(z:-0.1,flags:16)
                for j in mesh.vertices.indices where j%3 != 2 { mesh.vertices[j] *= 20 }
                mesh.states[0]!.alphaClamp=threshold
                return SceneRenderingTests.loaded([mesh])
            }
            let renderer=try SceneRenderer(scenes:scenes)
            renderer.camera=SceneCamera(eye:SIMD3(10,0,3),target:SIMD3(10,0,0),up:SIMD3(0,1,0))
            let body=simd_float4x4(SIMD4(0,0,1,0),SIMD4(1,0,0,0),SIMD4(0,1,0,0),SIMD4(10,0,2,1))
            renderer.mirror=RearViewMirror(body:body,bonnetPosition:.zero,hiddenInstances:[1],currentCar:1)
            try renderer.setCarLightTextures(["breaklight1.rgb":CarReflectionTests.texture("light") { _,_ in [255,255,255,255] }]);try renderer.setCarLights([light])
            for quality in [false,true] {
                renderer.smoothEdges=quality
                let data=try renderer.render(width:96,height:72),bytes=Array(data),layout=MirrorLayout(width:96,height:72)
                let mirrorPixel=((layout.y+layout.height/2)*96+layout.x+layout.width/2)*4
                for c in 0..<3 { XCTAssertEqual(Int(bytes[mirrorPixel+c]),217,accuracy:1);XCTAssertEqual(bytes[(48*96+48)*4+c],255) }
                XCTAssertEqual(try renderer.render(width:96,height:72),data)
            }
        }
        print("SCENE_ALPHA_MIRROR visibleStateOrderIndependent=1 hiddenMeshDoesNotApply=1 qualityModes=2 repeatPairs=2")
    }
}
