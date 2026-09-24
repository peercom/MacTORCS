// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import CReference
import TORCSSimulation
@testable import TORCSAssets
@testable import TORCSPresentation

final class SurveyCameraTests:XCTestCase {
    func compare(_ camera:SceneCamera,_ reference:[Float],_ preset:DrivingCameraPreset) -> Float {
        let values=[camera.eye.x,camera.eye.y,camera.eye.z,camera.target.x,camera.target.y,camera.target.z,camera.up.x,camera.up.y,camera.up.z]
        var maximum:Float=0
        for (a,b) in zip(values,reference) { maximum=max(maximum,abs(a-b));XCTAssertEqual(a,b,accuracy:0.00001) }
        XCTAssertEqual(camera.fieldOfView,reference[9] * .pi/180,accuracy:0.000001)
        XCTAssertEqual(camera.fogRange,SIMD2(reference[12],reference[13]))
        XCTAssertEqual(preset.drawsCar,reference[14]==1);XCTAssertEqual(preset.drawsDriver,reference[15]==1);XCTAssertEqual(camera.drawsBackground,reference[16]==1)
        let expected=SceneCamera(eye:SIMD3(reference[0],reference[1],reference[2]),target:SIMD3(reference[3],reference[4],reference[5]),fieldOfView:reference[9] * .pi/180,near:reference[10],far:reference[11],up:SIMD3(reference[6],reference[7],reference[8]))
        for aspect:Float in [1,1.5,2.1] {
            let a=camera.viewProjection(aspect:aspect),b=expected.viewProjection(aspect:aspect)
            for i in 0..<4 { for j in 0..<4 { XCTAssertTrue(a[i][j].isFinite);XCTAssertEqual(a[i][j],b[i][j],accuracy:0.001) } }
        }
        return maximum
    }
    func testSurveyFactoriesUpdatesAndIntegerWorldBounds() throws {
        let presets:[DrivingCameraPreset]=[.circuit,.panorama1,.panorama2,.panorama3,.panorama4,.panorama5]
        var maximum:Float=0
        for i in 0..<600 {
            let t=Float(i),bounds=SIMD3(301.1+t*1.003,427.7+t*0.573,12.3+t*0.037)
            let world=try CameraWorld(bounds:bounds),position=SIMD3(350*sin(t*0.07),450*cos(t*0.03),2+t*0.29)
            var body=matrix_identity_float4x4;body[3]=SIMD4(position,1)
            for (kind,preset) in presets.enumerated() {
                var rig=DrivingCameraRig(),reference=[Float](repeating:0,count:21)
                let camera=try rig.view(preset:preset,body:body,bonnetPosition:.zero,world:world,yaw:0,trackHeading:0) { _ in XCTFail("Survey camera queried track height");return 0 }
                ref_camera_survey([bounds.x,bounds.y,bounds.z],[position.x,position.y,position.z],Int32(kind),&reference)
                maximum=max(maximum,compare(camera,reference,preset))
                XCTAssertEqual([Float(world.x),Float(world.y),Float(world.z),Float(world.maximum)],Array(reference[17...20]))
            }
        }
        for bounds:SIMD3<Float> in [SIMD3(-1,2,3),SIMD3(.nan,2,3),SIMD3(40000,40000,2),SIMD3(.infinity,2,3)] { XCTAssertThrowsError(try CameraWorld(bounds:bounds)) }
        var rig=DrivingCameraRig()
        XCTAssertThrowsError(try rig.view(preset:.circuit,body:matrix_identity_float4x4,bonnetPosition:.zero,yaw:0,trackHeading:0) { _ in 0 })
        print("SURVEY_CAMERAS presets=6 updates=3600 worldAndPoseMaximum=\(maximum) integerRounding=1 projectionAspects=3 flagsVerified=1")
    }
    func testDriverCameraAgainstOriginalWithBodyRoll() throws {
        var maximum:Float=0
        for i in 0..<1200 {
            let t=Float(i),pose=CollisionTransform(position:SIMD3(t*0.031,-t*0.023,5*sin(t*0.03)),orientation:SIMD3(0.4*sin(t*0.011),0.5*cos(t*0.019),t*0.01))
            let body=VehiclePresentation.matrix(pose),position=SIMD3<Float>(-0.09,0.36,0.86)
            var rig=DrivingCameraRig(),reference=[Float](repeating:0,count:17)
            let camera=try rig.view(preset:.driver,body:body,bonnetPosition:SIMD3(0.6,0,1),driverPosition:position,yaw:0,trackHeading:0) { _ in XCTFail("Driver camera queried ground");return 0 }
            ref_camera_driver((0..<4).flatMap{[body[$0].x,body[$0].y,body[$0].z,body[$0].w]},[position.x,position.y,position.z],&reference)
            maximum=max(maximum,compare(camera,reference,.driver));XCTAssertEqual(camera.up,SIMD3(0,0,1))
        }
        var rig=DrivingCameraRig()
        XCTAssertThrowsError(try rig.view(preset:.driver,body:matrix_identity_float4x4,bonnetPosition:.zero,yaw:0,trackHeading:0){_ in 0})
        print("DRIVER_CAMERA updates=1200 maximum=\(maximum) worldUp=1 driverHidden=1 nearPointOne=1")
    }}
