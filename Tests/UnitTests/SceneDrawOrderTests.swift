// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import CReference
@testable import TORCSAssets
@testable import TORCSMetal

final class SceneDrawOrderTests:XCTestCase {
    static func reference(_ parents:[Int32],_ flags:[Int32],visible:[Int32]?=nil,names:[Int32]?=nil,wrap:Bool=false) -> [Int] {
        var output=[Int32](repeating:-1,count:parents.count)
        let count=ref_draw_order(parents,flags,visible ?? Array(repeating:1,count:parents.count),names ?? Array(repeating:0,count:parents.count),Int32(parents.count),wrap ? 1:0,&output,Int32(output.count))
        XCTAssertGreaterThanOrEqual(count,0);return output.prefix(max(0,Int(count))).map(Int.init)
    }
    func testOriginalAnchorsNestedTraversalAndDriverWrapper() throws {
        var anchors=[Int32](repeating:-1,count:8)
        XCTAssertEqual(ref_scene_anchor_order(&anchors),8)
        XCTAssertEqual(SceneAnchor.allCases.map { Int32($0.rawValue) },anchors)
        let parents:[Int32]=[-1,0,0,1,0,2,5,2,1,0]
        let base=SceneRenderingTests.loaded([SceneRenderingTests.quad()]).asset.scene.nodes[0]
        var cases=0
        for mask in 0..<64 { for wrap in [false,true] { for hidden in [false,true] {
            let driver=mask%2==0 ? 1:5
            var flags=[Int32](repeating:-1,count:parents.count),names=[Int32](repeating:0,count:parents.count)
            names[driver]=1;if driver==1 { names[5]=1 }
            let nodes=parents.indices.map { i -> ACNode in
                if [0,1,2,5].contains(i) { var n=base;n.parent=Int(parents[i]);n.name=names[i]==1 ? "DRIVER":"branch";return n }
                flags[i]=(mask & (1<<(i%6)))==0 ? 0:33
                var mesh=SceneRenderingTests.quad(flags:UInt32(flags[i]));mesh.states[0]!.material[12]=Float(i)
                return ACNode(parent:Int(parents[i]),kind:2,name:"",matrix:[],mesh:mesh)
            }
            let geometry=try SceneGeometry(ACScene(nodes:nodes),driverSelector:wrap)
            let visible=geometry.batches.filter { !hidden || !$0.isDriver }
            let native=(visible.filter { $0.mesh.states[0]!.flags&32==0 }+visible.filter { $0.mesh.states[0]!.flags&32 != 0 }).map { Int($0.mesh.states[0]!.material[12]) }
            var visibility=[Int32](repeating:1,count:parents.count);if hidden { visibility[driver]=0 }
            XCTAssertEqual(native,Self.reference(parents,flags,visible:visibility,names:names,wrap:wrap));cases += 1
        } } }
        print("DRAW_ORDER_TRAVERSAL anchorCount=8 nestedCases=\(cases) breadthFirstStorage=1 firstDriverWrapper=1 originalQueue=exact")
    }
    func testOriginalStatefulWholeCarOrderingAndInvalidPublication() throws {
        var cases=0
        for count in [1,2,3,8,17,64,128] {
            var planner=SceneDrawOrder(),original=(0..<count).map(Int32.init)
            for frame in 0..<60 {
                let positions=(0..<count).map { i -> SIMD3<Float> in
                    let x:Float,y:Float
                    if frame%3==0 { x=Float(i%5);y=0 }
                    else if frame%3==1 { x=Float(i*13%37-18)/7.13;y=Float(i*7%19-9)/3.2 }
                    else { x=Float(bitPattern:0x43000000+UInt32(i));y=Float(bitPattern:0x43000000-UInt32(i)) }
                    return SIMD3(x,y,Float(i)*100)
                }
                var instances=[SceneInstance(resource:0,anchor:.sun)]
                for i in 0..<count { for _ in 0..<2 { instances.append(SceneInstance(resource:0,car:SceneCarPlacement(index:i,position:positions[i]))) } }
                instances.append(SceneInstance(resource:0,anchor:.land));try planner.publish(instances)
                for mirror in [true,false] {
                    let eye=SIMD3<Float>(frame%3 != 1 ? 0:Float(frame%11-5)/2.7,frame%3 != 1 ? 0:Float(frame%7-3)/1.3,mirror ? -500:500)
                    var distances=[Float](repeating:0,count:count)
                    XCTAssertEqual(ref_car_draw_order(positions.flatMap { [$0.x,$0.y,$0.z] },[eye.x,eye.y,eye.z],&original,Int32(count),&distances),1)
                    let actual=try planner.prepare(eye:eye,mirror:mirror)
                    XCTAssertEqual(actual.first,instances.count-1);XCTAssertEqual(actual.last,0)
                    let ids=actual.compactMap { instances[$0].car?.index }
                    XCTAssertEqual(ids,original.flatMap { [Int($0),Int($0)] })
                    XCTAssertEqual(try planner.prepare(eye:eye,mirror:mirror),actual)
                    XCTAssertThrowsError(try planner.prepare(eye:SIMD3(.nan,0,0),mirror:mirror))
                    XCTAssertEqual(try planner.prepare(eye:eye,mirror:mirror),actual);cases += 1
                }
            }
        }
        var planner=SceneDrawOrder();let valid=[SceneInstance(resource:0,car:SceneCarPlacement(index:1,position:.zero))]
        try planner.publish(valid);let before=try planner.prepare(eye:.zero,mirror:false)
        for invalid in [SceneInstance(resource:0,anchor:.shadows),SceneInstance(resource:0,anchor:.carLights),SceneInstance(resource:0,anchor:.land,car:SceneCarPlacement(index:1,position:.zero)),SceneInstance(resource:0,car:SceneCarPlacement(index:-1,position:.zero)),SceneInstance(resource:0,car:SceneCarPlacement(index:1,position:SIMD3(1,0,0)))] {
            XCTAssertThrowsError(try planner.publish(valid+[invalid]));XCTAssertEqual(try planner.prepare(eye:.zero,mirror:false),before)
        }
        print("DRAW_ORDER_CARS viewUpdates=\(cases) counts=1,2,3,8,17,64,128 horizontalDistance=1 equalDistanceHostQsort=exact fractionalAndAdjacentFloatCases=1 cachedRepeats=exact invalidPublicationRollback=1")
    }
    func testSelectedOriginalContentTraversal() throws {
        let fixtures=try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil))
        var nodes=0,leaves=0
        for (path,car) in [("155-DTM/155-DTM",true),("aalborg/aalborg",false)]+(0..<4).map({ ("trb1-3/wheel\($0)",true) }) {
            var scene=try ACScene.parse(Data(contentsOf:fixtures.appendingPathComponent("Artwork/"+path+".acc")),car:car)
            let parents=scene.nodes.map { Int32($0.parent) },names=scene.nodes.map { Int32($0.name=="DRIVER" ? 1:0) }
            var flags=[Int32](repeating:-1,count:scene.nodes.count),visible=[Int32](repeating:1,count:scene.nodes.count)
            for i in scene.nodes.indices {
                if var mesh=scene.nodes[i].mesh {
                    flags[i]=Int32(mesh.states[0]!.flags)
                    if try mesh.triangleIndices().isEmpty { visible[i]=0 }
                    // Test identifier only; draw-order flags/hierarchy are unchanged.
                    mesh.states[0]!.material[12]=Float(i);scene.nodes[i].mesh=mesh
                }
            }
            let geometry=try SceneGeometry(scene,driverSelector:car)
            let order=(geometry.batches.filter { $0.mesh.states[0]!.flags&32==0 }+geometry.batches.filter { $0.mesh.states[0]!.flags&32 != 0 }).map { Int($0.mesh.states[0]!.material[12]) }
            XCTAssertEqual(order,Self.reference(parents,flags,visible:visible,names:names,wrap:car),path)
            nodes += scene.nodes.count;leaves += order.count
        }
        print("DRAW_ORDER_CONTENT files=6 nodes=\(nodes) drawableLeaves=\(leaves) originalQueue=exact")
    }
    func testGPUOriginalDeferredAnchorsAndWholeCarOrder() async throws {
        let shadow=try CarShadow(dimensions:SIMD2(2,2)).project(body:matrix_identity_float4x4) { _ in 0 }
        let light=try CarLightRenderingTests.light(position:SIMD3(0,0,0.06))
        try await MainActor.run {
            let meshes=[SceneRenderingTests.quad(z:-0.1),SceneRenderingTests.quad(z:-0.03,color:[0,1,0,0.5],flags:33),SceneRenderingTests.quad(z:0.04,color:[1,0,0,0.5],flags:33),SceneRenderingTests.quad(z:0.02,color:[0,0,1,0.5],flags:33)]
            let renderer=try SceneRenderer(scenes:meshes.map { SceneRenderingTests.loaded([$0]) })
            renderer.camera=SceneCamera(eye:SIMD3(0,0,3),target:.zero,up:SIMD3(0,1,0))
            let instances=[SceneInstance(resource:3,car:SceneCarPlacement(index:1,position:SIMD3(1,0,0))),SceneInstance(resource:1,anchor:.land),SceneInstance(resource:2,car:SceneCarPlacement(index:0,position:SIMD3(8,0,0))),SceneInstance(resource:0,anchor:.land)]
            try renderer.setInstances(instances)
            try renderer.setShadowTexture(CarReflectionTests.texture("shadow") { _,_ in [0,0,0,128] })
            try renderer.setShadow(shadow)
            try renderer.setCarLightTextures(["breaklight1.rgb":CarReflectionTests.texture("light") { _,_ in [255,255,255,255] }]);try renderer.setCarLights([light])
            // Nodes 1...8 are actual grscene anchors, 9...14 are leaves.
            let parents:[Int32]=[-1]+Array(repeating:0,count:8)+[1,1,4,5,6,6]
            let flags:[Int32]=Array(repeating:-1,count:9)+[0,33,33,33,33,33]
            let map:[Int:SceneDrawCommand]=[9:.mesh(instance:3,batch:0),10:.mesh(instance:1,batch:0),11:.shadow(car:0),12:.light(car:0),13:.mesh(instance:2,batch:0),14:.mesh(instance:0,batch:0)]
            let expected=Self.reference(parents,flags).map { map[$0]! }
            var color=SIMD3<Float>(repeating:1)
            // The final blue mesh is submitted but fails depth behind red.
            for (rgb,alpha) in [(SIMD3<Float>(0,1,0),Float(0.5)),(.zero,Float(128)/255),(SIMD3<Float>(repeating:0.8),Float(0.75)),(SIMD3<Float>(1,0,0),Float(0.5))] { color=rgb*alpha+color*(1-alpha) }
            for quality in [false,true] {
                renderer.smoothEdges=quality
                let pixels=try renderer.render(width:64,height:64,captureCommands:true),digest=renderer.lastSubmissionSHA256,random=renderer.lightRandomDraws
                XCTAssertEqual(renderer.lastSceneCommands,expected)
                for c in 0..<3 { XCTAssertEqual(Float(SceneRenderingTests.pixel(Array(pixels))[c]),color[c]*255,accuracy:2) }
                for _ in 0..<4 { XCTAssertEqual(try renderer.render(width:64,height:64,captureCommands:true),pixels);XCTAssertEqual(renderer.lastSceneCommands,expected);XCTAssertEqual(renderer.lastSubmissionSHA256,digest);XCTAssertEqual(renderer.lightRandomDraws,random) }
            }
            print("DRAW_ORDER_GPU anchors=land,shadow,light,cars originalQueueSubmission=exact analyticAlpha=1 wholeCarsNotMeshDepth=1 qualityModes=2 repeatPairs=8")
        }
    }
    func testOriginalDepthStateAndGPUOverlappingTranslucentMeshes() async throws {
        for write in [Int32(0),1] {
            var original=[Int32](repeating:-1,count:10)
            XCTAssertEqual(ref_scene_depth_state(write,&original,10),10)
            XCTAssertEqual(original[0],0x0203) // Original GL_LEQUAL.
            XCTAssertEqual(Array(original.dropFirst()),Array(repeating:write,count:9))
        }
        try await MainActor.run {
            // White backdrop, near red, then either farther or coplanar blue.
            // Farther blue must fail after red writes depth; equal blue must pass.
            for blueZ:Float in [0,0.1] {
                let meshes=[SceneRenderingTests.quad(z:-0.1),SceneRenderingTests.quad(z:0.1,color:[1,0,0,0.5],flags:33),SceneRenderingTests.quad(z:blueZ,color:[0,0,1,0.5],flags:33)]
                let renderer=try SceneRenderer(scenes:[SceneRenderingTests.loaded(meshes)])
                renderer.camera=SceneCamera(eye:SIMD3(0,0,3),target:.zero,up:SIMD3(0,1,0))
                let expected=blueZ==0 ? [255,128,128]:[128,64,191]
                for quality in [false,true] {
                    renderer.smoothEdges=quality
                    let pixels=try renderer.render(width:64,height:64,captureCommands:true)
                    XCTAssertEqual(renderer.lastSceneCommands,[.mesh(instance:0,batch:0),.mesh(instance:0,batch:1),.mesh(instance:0,batch:2)])
                    for c in 0..<3 { XCTAssertEqual(Int(SceneRenderingTests.pixel(Array(pixels))[c]),expected[c],accuracy:1) }
                    XCTAssertEqual(try renderer.render(width:64,height:64),pixels)
                }
            }
        }
        print("DRAW_ORDER_DEPTH originalComparison=LEQUAL originalDispatchCases=16 inheritedMaskPreserved=1 gpuTranslucentWritesDepth=1 gpuEqualDepthPasses=1 qualityModes=2 repeatPairs=4")
    }
    func testGPUMirrorUsesIndependentWholeCarOrderAndOriginalIndices() async throws {
        try await MainActor.run {
            let colors:[[Float]]=[[1,1,1,1],[1,0,0,0.5],[0,1,0,0.5],[0,0,1,0.5]]
            let scenes=colors.enumerated().map { i,c -> LoadedScene in
                var mesh=SceneRenderingTests.quad(z:i==0 ? -0.1:0.1,color:c,flags:i==0 ? 0:33,cull:false)
                for j in mesh.vertices.indices where j%3 != 2 { mesh.vertices[j] *= 20 }
                return SceneRenderingTests.loaded([mesh])
            }
            let renderer=try SceneRenderer(scenes:scenes)
            renderer.camera=SceneCamera(eye:SIMD3(0,0,3),target:.zero,up:SIMD3(0,1,0))
            let positions:[SIMD3<Float>]=[SIMD3(0,0,0),SIMD3(8,0,0),SIMD3(4,0,0)]
            let instances=[SceneInstance(resource:0,anchor:.land)]+positions.enumerated().map { SceneInstance(resource:$0.offset+1,car:SceneCarPlacement(index:$0.offset,position:$0.element)) }
            let body=simd_float4x4(SIMD4(0,0,1,0),SIMD4(1,0,0,0),SIMD4(0,1,0,0),SIMD4(10,0,2,1))
            let mirror=RearViewMirror(body:body,bonnetPosition:.zero,hiddenInstances:[2],currentCar:1)
            renderer.mirror=mirror
            for quality in [false,true] {
                try renderer.setInstances(instances);renderer.smoothEdges=quality
                let first=try renderer.render(width:96,height:72,captureCommands:true),digest=renderer.lastSubmissionSHA256
                XCTAssertEqual(renderer.lastSceneCommands,[.mesh(instance:0,batch:0),.mesh(instance:2,batch:0),.mesh(instance:3,batch:0),.mesh(instance:1,batch:0)])
                XCTAssertEqual(renderer.lastMirrorCommands,[.mesh(instance:0,batch:0),.mesh(instance:1,batch:0),.mesh(instance:3,batch:0)])
                let layout=MirrorLayout(width:96,height:72),x=layout.x+layout.width/2,y=layout.y+layout.height/2,pixels=Array(first)
                for (i,value) in [128,64,191].enumerated() { XCTAssertEqual(Int(pixels[(y*96+x)*4+i]),value,accuracy:1) }
                for _ in 0..<3 { XCTAssertEqual(try renderer.render(width:96,height:72,captureCommands:true),first);XCTAssertEqual(renderer.lastSubmissionSHA256,digest) }
            }
            print("DRAW_ORDER_MIRROR mainAndRearWholeCarOrders=exact hiddenOriginalInstanceIndices=1 analyticCropPixel=1 qualityModes=2 repeatPairs=6")
        }
    }
}
