// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import CReference
@testable import TORCSPresentation

final class ExteriorCameraTests:XCTestCase {
    let presets:[DrivingCameraPreset]=[.trackAligned,.reverse,.side1,.side2,.side3,.side4,.side5,.side6,.side7,.side8,.overhead1,.overhead2,.overhead3,.overhead4]
    func testExteriorCamerasAgainstOriginalFactoryAndUpdates() throws {
        var maxPosition:Float=0,maxMatrix:Float=0
        for (kind,preset) in presets.enumerated() {
            var rig=DrivingCameraRig(),samples:[Float]=[],actual:[SceneCamera]=[]
            for i in 0..<1200 {
                let t=Float(i),p=SIMD3(500*sin(t*0.013),120*cos(t*0.017),8*sin(t*0.011))
                // Heading and yaw differ deliberately; include repeated wrap crossings.
                let yaw=atan2(sin(t*0.079),cos(t*0.079)),heading=atan2(sin(t*0.041),cos(t*0.041)),ground=3*sin(t*0.022)
                var body=matrix_identity_float4x4;body[3]=SIMD4(p,1)
                samples += [p.x,p.y,p.z,yaw,heading,ground]
                var queries:[SIMD2<Float>]=[]
                let camera=try rig.view(preset:preset,body:body,bonnetPosition:.zero,yaw:yaw,trackHeading:heading) { queries.append($0);return ground }
                XCTAssertEqual(queries.count,preset == .trackAligned || preset == .reverse ? 1:0)
                if let query=queries.first { XCTAssertEqual(query,SIMD2(camera.eye.x,camera.eye.y)) }
                actual.append(camera)
            }
            var original=[Float](repeating:0,count:1200*14)
            ref_camera_exterior(Int32(kind),samples,1200,&original)
            for (i,c) in actual.enumerated() {
                let o=Array(original[i*14..<(i+1)*14])
                let values=[c.eye.x,c.eye.y,c.eye.z,c.target.x,c.target.y,c.target.z,c.up.x,c.up.y,c.up.z]
                for (a,b) in zip(values,o) { maxPosition=max(maxPosition,abs(a-b));XCTAssertEqual(a,b,accuracy:0.00001) }
                XCTAssertEqual(c.fieldOfView*180 / .pi,o[9],accuracy:0.00001)
                XCTAssertEqual(c.fogRange,SIMD2(o[12],o[13]))
                let expected=SceneCamera(eye:SIMD3(o[0],o[1],o[2]),target:SIMD3(o[3],o[4],o[5]),fieldOfView:o[9] * .pi/180,near:o[10],far:o[11],up:SIMD3(o[6],o[7],o[8]))
                let matrix=c.viewProjection(aspect:1.5),reference=expected.viewProjection(aspect:1.5)
                for col in 0..<4 { for row in 0..<4 {
                    XCTAssertTrue(matrix[col][row].isFinite)
                    maxMatrix=max(maxMatrix,abs(matrix[col][row]-reference[col][row]))
                    XCTAssertEqual(matrix[col][row],reference[col][row],accuracy:0.0001)
                } }
            }
        }
        print("EXTERIOR_CAMERAS presets=14 updates=16800 positionScalars=151200 maxPosition=\(maxPosition) maxProjection=\(maxMatrix) fovClippingFog=verified")
    }
    func testCameraSwitchingRetainsIndependentRelaxation() throws {
        var rig=DrivingCameraRig(),chase=DrivingCamera(),trackOnly=DrivingCameraRig()
        let body=matrix_identity_float4x4
        for i in 0..<500 {
            let yaw=Float(i)*0.01
            let expected=chase.update(position:.zero,yaw:yaw) { _ in 0 }
            let actual=try rig.view(preset:.chase,body:body,bonnetPosition:.zero,yaw:yaw,trackHeading:0) { _ in 0 }
            XCTAssertEqual(actual.eye,expected.eye);XCTAssertEqual(actual.target,expected.target)
            let track=try rig.view(preset:.trackAligned,body:body,bonnetPosition:.zero,yaw:-yaw,trackHeading:yaw) { _ in 0 }
            let reference=try trackOnly.view(preset:.trackAligned,body:body,bonnetPosition:.zero,yaw:-yaw,trackHeading:yaw) { _ in 0 }
            XCTAssertEqual(track.eye,reference.eye)
            for preset in DrivingCameraPreset.allCases where preset != .chase && preset != .trackAligned && preset != .fly && preset != .television {
                _=try rig.view(preset:preset,body:body,bonnetPosition:SIMD3(0.6,0,1),driverPosition:.zero,world:CameraWorld(bounds:SIMD3(800,900,30)),yaw:2,trackHeading:-1) { _ in 5 }
            }
        }
        XCTAssertEqual(DrivingCameraPreset.allCases.count,31)
        XCTAssertEqual(DrivingCameraPreset.allCases.filter { !$0.drawsCar },[.road])
        print("CAMERA_SWITCH cycles=500 independentRelaxation=1 presets=31 roadOnlyHidesCar=1")
    }
}
