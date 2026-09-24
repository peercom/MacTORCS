// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import CReference
import TORCSTrack
@testable import TORCSAssets
@testable import TORCSSimulation
@testable import TORCSPresentation

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
    func testBrakeAttachmentDoesNotSpinWithWheel() throws {
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
        print("BRAKE_ATTACHMENT originalSteeringCamberTransform=1 spinIndependent=1")
    }}

extension BrakeGeometryTests {}
