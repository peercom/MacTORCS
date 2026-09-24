// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import CReference
import TORCSTrack
@testable import TORCSAssets
@testable import TORCSSimulation
@testable import TORCSMetal

final class BrakeGeometryTests:XCTestCase {
    func testGeneratedGeometryAgainstOriginalInitWheel() throws {
        var maximum:Float=0,scalars=0
        for wheel in 0..<4 { for sample in 0..<240 {
            let radius=Float(0.04+Double(sample)*0.0017),width=Float(0.09+Double(sample%63)*0.013)
            let geometry=try BrakeGeometry(wheel:wheel,radius:radius,width:width)
            var vertices=Array(repeating:Float(0),count:147),normals=Array(repeating:Float(0),count:9),colors=Array(repeating:Float(0),count:12),metadata=Array(repeating:Int32(0),count:12)
            ref_brake_geometry(Int32(wheel),radius,width,&vertices,&normals,&colors,&metadata)
            var offset=0
            for part in 0..<3 {
                let mesh=try XCTUnwrap(geometry.parts[part].asset.scene.nodes.last?.mesh)
                XCTAssertEqual(mesh.primitive,Int(metadata[part*4]));XCTAssertEqual(mesh.vertices.count/3,Int(metadata[part*4+1]));XCTAssertFalse(mesh.cull);XCTAssertEqual(metadata[part*4+2],0)
                XCTAssertEqual(metadata[part*4+3],part==1 ? 1:0)
                XCTAssertEqual(mesh.normals,Array(normals[part*3..<part*3+3]));XCTAssertEqual(mesh.colors,Array(colors[part*4..<part*4+4]))
                XCTAssertEqual(mesh.states[0]?.flags,part==1 ? 0:4);XCTAssertTrue(geometry.parts[part].textures.isEmpty)
                for (a,b) in zip(mesh.vertices,vertices[offset..<offset+mesh.vertices.count]) { maximum=max(maximum,abs(a-b));XCTAssertEqual(a,b);scalars += 1 }
                offset += mesh.vertices.count
            }
            XCTAssertEqual(offset,147)
        } }
        for wheel in [-1,4] { XCTAssertThrowsError(try BrakeGeometry(wheel:wheel,radius:0.15,width:0.25)) }
        for value:Float in [0,-1,.nan,.infinity] { XCTAssertThrowsError(try BrakeGeometry(wheel:0,radius:value,width:0.25)) }
        print("BRAKE_GEOMETRY cases=960 parts=2880 vertexScalars=\(scalars) maximum=\(maximum) primitiveNormalsColorsCulling=exact")
    }
    func testBrakeAttachmentDoesNotSpinWithWheelAndInstancesCarryOnlyDiscHeat() throws {
        let (content,definition)=try VehiclePresentationTests().setup();defer { withExtendedLifetime(content){} }
        var state=VehicleRemovalState(trackPosition:TrackLocalPosition(segment:0,toStart:0,toRight:0))
        for i in 0..<4 { state.publishedWheelPose[i]=WheelVisualPose(position:SIMD3(Float(i),Float(i%2),1),orientation:SIMD3(0.02,0,0.3));state.publishedBrakeTemperature[i]=Float(i)*0.5 }
        let snapshot=VehicleVisualSnapshot(tick:0,published:state,configuration:definition.chassis.runningGear),first=try VehiclePresentation(snapshot)
        for i in 0..<4 { state.publishedWheelPose[i]=WheelVisualPose(position:state.publishedWheelPose[i].position,orientation:SIMD3(0.02,2,0.3)) }
        let second=try VehiclePresentation(VehicleVisualSnapshot(tick:1,published:state,configuration:definition.chassis.runningGear))
        for i in 0..<4 {
            XCTAssertEqual(first.wheels[i].brakeTransform,second.wheels[i].brakeTransform)
            XCTAssertNotEqual(first.wheels[i].transform,second.wheels[i].transform)
            XCTAssertEqual(snapshot.wheels[i].brakeRadius,definition.chassis.runningGear.wheels[i].brake.radius)
        }
        let instances=try second.instances(bodyResource:0,wheelResources:[1,2,3,4],brakeResources:Array(6..<18))
        XCTAssertEqual(instances.count,17)
        for i in 0..<4 {
            let offset=1+i*4
            XCTAssertEqual(instances[offset].resource,6+i*3);XCTAssertNil(instances[offset].colorOverride)
            XCTAssertEqual(instances[offset+1].colorOverride,SIMD4(second.wheels[i].brakeColor,1));XCTAssertNil(instances[offset+2].colorOverride)
            XCTAssertEqual(instances[offset].transform,second.wheels[i].brakeTransform)
        }
        XCTAssertThrowsError(try first.instances(bodyResource:0,wheelResources:[1,2,3,4],brakeResources:[6]))
        print("BRAKE_ATTACHMENT originalSteeringCamberTransform=1 spinIndependent=1 partsPerWheel=3 perDiscHeatOnly=1")
    }
    func testGPUOriginalUnlitDiscColorAndInstanceIsolation() async throws {
        let geometry=try BrakeGeometry(wheel:1,radius:0.5,width:0.3)
        try await MainActor.run {
            let renderer=try SceneRenderer(scenes:geometry.parts)
            renderer.camera=SceneCamera(eye:SIMD3(0,2,0),target:.zero,near:0.01,up:SIMD3(0,0,1))
            var cold:Data?,hot:Data?
            for temperature:Float in [0,0.5,1,2] {
                let t=Double(temperature),color=SIMD4<Float>(Float(0.1+t*1.5),Float(0.1+t*0.3),Float(0.1-t*0.3),1)
                try renderer.setInstances([SceneInstance(resource:1,colorOverride:color)])
                let pixels=try renderer.render(width:128,height:128,captureCommands:true),digest=renderer.lastSubmissionSHA256
                XCTAssertEqual(try renderer.render(width:128,height:128,captureCommands:true),pixels);XCTAssertEqual(renderer.lastSubmissionSHA256,digest)
                let bytes=Array(pixels),expected=[color.x,color.y,color.z].map { Int((min(1,max(0,$0))*255).rounded()) }
                var matches=0
                for i in stride(from:0,to:bytes.count,by:4) { if (0..<3).allSatisfy({ abs(Int(bytes[i+$0])-expected[$0])<=1 }) { matches += 1 } }
                XCTAssertGreaterThan(matches,200)
                if temperature==0 { cold=pixels };if temperature==1 { hot=pixels }
            }
            XCTAssertNotEqual(cold,hot)
            try renderer.setInstances([SceneInstance(resource:0),SceneInstance(resource:2)])
            let fixed=try renderer.render(width:128,height:128)
            XCTAssertThrowsError(try renderer.setInstances([SceneInstance(resource:1,colorOverride:SIMD4(.nan,0,0,1))]))
            XCTAssertEqual(try renderer.render(width:128,height:128),fixed)
            print("BRAKE_GPU temperatures=4 unlitColorClamp=1 fixedPartsUnaffected=1 repeatPairs=4 invalidColorAtomic=1")
        }
    }
}

extension BrakeGeometryTests {
    func testGeneratedBrakesInDrivingHeightAgainstOriginalPLIB() throws {
        let (content,definition)=try VehiclePresentationTests().setup();defer { withExtendedLifetime(content){} }
        let empty=ACScene(nodes:[ACNode(parent:-1,kind:1,name:"empty",matrix:[],mesh:nil)])
        var floor=SceneRenderingTests.quad(z:-5)
        for i in floor.vertices.indices where i%3 != 2 { floor.vertices[i] *= 100 }
        let scenery=SceneRenderingTests.loaded([floor]).asset.scene
        let scenes=Array(repeating:empty,count:5)+[scenery]
        let brakes=try (0..<4).flatMap { i in try BrakeGeometry(wheel:i,radius:definition.chassis.runningGear.wheels[i].brake.radius,width:definition.chassis.runningGear.wheels[i].force.tireWidth).parts.map { $0.asset.scene } }
        func floats(_ m:simd_float4x4)->[Float] { (0..<4).flatMap { c in (0..<4).map { m[c][$0] } } }
        var queries=0,brakeHits=0,maximum:Float=0
        for step in 0..<32 {
            var published=VehicleRemovalState(trackPosition:TrackLocalPosition(segment:0,toStart:0,toRight:0))
            published.publicTransform=CollisionTransform(position:SIMD3(Float(step)*0.1,0,2),orientation:SIMD3(1.4,0.15,Float(step)*0.11))
            for i in 0..<4 { published.publishedWheelPose[i]=WheelVisualPose(position:SIMD3(i<2 ? 1.2:-1.2,i%2==0 ? -0.75:0.75,0),orientation:SIMD3(0.1,Float(step)*0.31,Float(i)*0.03)) }
            let snapshot=VehicleVisualSnapshot(tick:step,published:published,configuration:definition.chassis.runningGear),pose=try VehiclePresentation(snapshot)
            var height=try DrivingSceneHeight(scenes:scenes,snapshot:snapshot,shadowVertices:[],brakeScenes:brakes)
            let reference=try XCTUnwrap(ref_scene_height_create());defer { ref_scene_height_destroy(reference) }
            var nodeCount=0
            func add(parent:Int,kind:Int32,matrix:simd_float4x4=matrix_identity_float4x4,primitive:Int32=0,vertices:[Float]=[]) -> Int {
                let index=nodeCount;nodeCount += 1
                XCTAssertEqual(ref_scene_height_add(reference,Int32(parent),kind,floats(matrix),primitive,0,vertices,Int32(vertices.count/3)),1)
                return index
            }
            let root=add(parent:-1,kind:1)
            _=add(parent:root,kind:2,primitive:Int32(floor.primitive),vertices:floor.vertices)
            let body=add(parent:root,kind:0,matrix:pose.body),selector=add(parent:body,kind:3)
            let carGroup=add(parent:selector,kind:1)
            XCTAssertEqual(ref_scene_height_select(reference,Int32(selector),1),1)
            var points:[SIMD2<Float>]=[]
            for i in 0..<4 {
                let w=snapshot.wheels[i],a=w.pose.orientation
                let position=VehiclePresentation.matrix(CollisionTransform(position:w.pose.position,orientation:SIMD3(a.x,0,a.z)))
                let parent=add(parent:carGroup,kind:0,matrix:position)
                var vertices=Array(repeating:Float(0),count:147),normals=Array(repeating:Float(0),count:9),colors=Array(repeating:Float(0),count:12),metadata=Array(repeating:Int32(0),count:12)
                ref_brake_geometry(Int32(i),w.brakeRadius,w.width,&vertices,&normals,&colors,&metadata)
                var offset=0
                for part in 0..<3 { let n=Int(metadata[part*4+1])*3;_=add(parent:parent,kind:2,primitive:metadata[part*4],vertices:Array(vertices[offset..<offset+n]));offset += n }
                let center=pose.wheels[i].brakeTransform*SIMD4<Float>(0,i%2==0 ? 0.2-w.width/2:w.width/2-0.2,0,1)
                for x in -4...4 { for y in -4...4 { points.append(SIMD2(center.x+Float(x)*0.039,center.y+Float(y)*0.041)) } }
            }
            for visible in [true,false] {
                try height.update(snapshot:snapshot,drawsCar:visible,drawsDriver:true,shadowVertices:[])
                XCTAssertEqual(ref_scene_height_select(reference,Int32(selector),visible ? 1:0),1)
                var expected=Array(repeating:Float(0),count:points.count),hits=Array(repeating:Int32(0),count:points.count),triangles=hits
                ref_scene_height_query(reference,points.flatMap{[$0.x,$0.y]},Int32(points.count),&expected,&hits,&triangles)
                for (i,p) in points.enumerated() {
                    let actual=try height.query(p)
                    maximum=max(maximum,abs(actual.height-expected[i]));XCTAssertEqual(actual.height,expected[i])
                    XCTAssertEqual(actual.retainedHits,Int(hits[i]));XCTAssertEqual(actual.testedTriangles,Int(triangles[i]))
                    if actual.height>0 { brakeHits += 1 }
                    queries += 1
                }
            }
        }
        XCTAssertGreaterThan(brakeHits,100)
        print("BRAKE_HEIGHT poses=32 queries=\(queries) brakeHits=\(brakeHits) maximum=\(maximum) originalPLIBHitCountsTriangles=exact visibilityCases=2")
    }
}
