// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import CReference
import TORCSTrack
@testable import TORCSAssets
@testable import TORCSSimulation
@testable import TORCSMetal

final class DrivingFlyCameraTests: XCTestCase {
    private func snapshot(_ definition: VehicleDynamicsDefinition,x: Float=0,z: Float=0) -> VehicleVisualSnapshot {
        var published=VehicleRemovalState(trackPosition:TrackLocalPosition(segment:0,toStart:0,toRight:0))
        published.publicTransform=CollisionTransform(position:SIMD3(x,0,z),orientation:.zero)
        for i in 0..<4 { published.publishedWheelPose[i]=WheelVisualPose(position:SIMD3(10+Float(i),10,0),orientation:.zero) }
        return VehicleVisualSnapshot(tick:0,published:published,configuration:definition.chassis.runningGear)
    }
    private func scenes(wide: Bool=false) -> [ACScene] {
        func scene(_ z: Float) -> ACScene {
            var mesh=SceneRenderingTests.quad(z:z)
            if wide { for i in mesh.vertices.indices where i%3 != 2 { mesh.vertices[i] *= 1000 } }
            return SceneRenderingTests.loaded([mesh]).asset.scene
        }
        return [scene(20),scene(0),scene(0),scene(0),scene(0),scene(0)]
    }
    private func shadow(_ z: Float=2) throws -> [ShadowVertex] { try CarShadow(dimensions:SIMD2(2,2)).project(body:matrix_identity_float4x4) { _ in z } }
    func testOriginalFlyZoomFactoryCommandsAndKeys() throws {
        let commands: [Int32]=[-1]+Array(repeating:0,count:200)+Array(repeating:1,count:200)+[2,0,3,1,4]
        let preset=DrivingCameraPreset.fly
        for saved: Float in [.nan,1.5,179] {
            var result=Array(repeating:Float(0),count:commands.count*7)
            ref_camera_fly_zoom(saved,commands,Int32(commands.count),&result)
            var value=saved.isNaN ? preset.zoomLimits.standard:saved
            for (i,command) in commands.enumerated() {
                if command>=0 { value=try preset.adjustedZoom(value,command:CameraZoomCommand(rawValue:Int(command))!) }
                XCTAssertEqual(value,result[i*7]);XCTAssertEqual(value,result[i*7+1])
                XCTAssertEqual(preset.zoomLimits.standard,result[i*7+2]);XCTAssertEqual(preset.zoomLimits.minimum,result[i*7+3]);XCTAssertEqual(preset.zoomLimits.maximum,result[i*7+4])
                XCTAssertEqual(result[i*7+5],1);XCTAssertEqual(result[i*7+6],1)
            }
        }
        XCTAssertEqual(preset.preferenceKey,"fovy-8-0")
        print("FLY_ZOOM updates=\(commands.count*3) factoryAndKeys=exact")
    }
    func testMovingNativeSceneVisibilityAndFailedPublication() throws {
        let (content,definition)=try VehiclePresentationTests().setup();defer { withExtendedLifetime(content) {} }
        let initial=snapshot(definition),vertices=try shadow()
        var height=try DrivingSceneHeight(scenes:scenes(),snapshot:initial,shadowVertices:vertices)
        let point=SIMD2<Float>(0.1,0.2)
        XCTAssertEqual(try height.query(point).height,20)
        try height.update(snapshot:snapshot(definition,x:5),drawsCar:true,drawsDriver:true,shadowVertices:vertices)
        XCTAssertEqual(try height.query(point).height,2)
        XCTAssertEqual(try height.query(SIMD2(5.1,0.2)).height,20)
        try height.update(snapshot:initial,drawsCar:false,drawsDriver:true,shadowVertices:vertices)
        XCTAssertEqual(try height.query(point).height,0)
        XCTAssertEqual(height.referenceShadowSphere.w,-1)
        try height.update(snapshot:initial,drawsCar:true,drawsDriver:true,shadowVertices:[])
        XCTAssertEqual(height.referenceShadowSphere.w,-1)
        let before=try height.query(point)
        XCTAssertThrowsError(try height.update(snapshot:snapshot(definition,x:5),drawsCar:true,drawsDriver:true,shadowVertices:Array(vertices.prefix(5))))
        XCTAssertEqual(try height.query(point),before)
        XCTAssertThrowsError(try DrivingSceneHeight(scenes:[],snapshot:initial,shadowVertices:vertices))
        print("DRIVING_HEIGHT bodyMovement=1 carShadowVisibility=1 failedPublicationRollback=1")
    }
    func testFlyQueriesPreviousDrawAndRetainsStateAcrossPickerChanges() throws {
        let (content,definition)=try VehiclePresentationTests().setup();defer { withExtendedLifetime(content) {} }
        let initial=snapshot(definition,z:180),vertices=try shadow()
        let height=try DrivingSceneHeight(scenes:scenes(wide:true),snapshot:initial,shadowVertices:vertices)
        var fly=try DrivingFlyCamera(height:height),expected=try FlyCamera()
        let current=snapshot(definition)
        XCTAssertNil(try fly.draw(time:1,selected:true,snapshot:current,drawsCar:true,drawsDriver:true,shadowVertices:vertices))
        // Publish a tall body while not advancing F10, then hide it in this draw.
        _=try fly.draw(time:1.01,selected:false,snapshot:initial,drawsCar:true,drawsDriver:true,shadowVertices:vertices)
        try expected.update(time:1,carIndex:0,position:current.body.position) { _ in 0 }
        try expected.update(time:1.02,carIndex:0,position:current.body.position) { try height.query($0).height }
        let view=try XCTUnwrap(fly.draw(time:1.02,selected:true,snapshot:current,drawsCar:false,drawsDriver:true,shadowVertices:[]))
        XCTAssertEqual(view.eye.z,201);XCTAssertEqual(view.eye,expected.eye)
        XCTAssertEqual(fly.motion.randomDraws,expected.randomDraws)
        XCTAssertEqual(try fly.height.query(SIMD2(view.eye.x,view.eye.y)).height,0)
        let paused=try XCTUnwrap(fly.draw(time:1.02,selected:true,snapshot:current,drawsCar:true,drawsDriver:true,shadowVertices:vertices,zoom:30))
        XCTAssertEqual(paused.eye,view.eye);XCTAssertEqual(paused.fieldOfView,30 * .pi/180)
        let before=fly.motion
        _=try fly.draw(time:9,selected:false,snapshot:current,drawsCar:true,drawsDriver:true,shadowVertices:vertices)
        XCTAssertEqual(fly.motion.currentTime,before.currentTime);XCTAssertEqual(fly.motion.randomDraws,before.randomDraws)
        let previousHeight=fly.height
        try expected.update(time:9.01,carIndex:0,position:current.body.position) { try previousHeight.query($0).height }
        let resumed=try XCTUnwrap(fly.draw(time:9.01,selected:true,snapshot:current,drawsCar:true,drawsDriver:true,shadowVertices:vertices))
        XCTAssertEqual(resumed.eye,expected.eye);XCTAssertEqual(fly.motion.randomDraws,expected.randomDraws)
        let state=fly.motion
        XCTAssertThrowsError(try fly.draw(time:9.02,selected:true,snapshot:current,drawsCar:true,drawsDriver:true,shadowVertices:Array(vertices.prefix(5))))
        XCTAssertEqual(fly.motion.eye,state.eye);XCTAssertEqual(fly.motion.randomDraws,state.randomDraws);XCTAssertEqual(fly.motion.currentTime,state.currentTime)
        XCTAssertTrue(DrivingCameraPreset.fly.drawsCar);XCTAssertTrue(DrivingCameraPreset.fly.drawsDriver);XCTAssertFalse(DrivingCameraPreset.fly.allowsMirror)
        print("DRIVING_FLY previousDrawClearance=201 equalTimeHeld=1 pickerPreservesState=1 gapReset=1 failedDrawRollsBackMotion=1")
    }
}
