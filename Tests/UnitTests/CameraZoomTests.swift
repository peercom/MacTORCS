// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import CReference
@testable import TORCSPresentation

final class CameraZoomTests:XCTestCase {
    func testAllFactoriesZoomCommandsSavedDefaultsAndDistanceUpdatesAgainstOriginal() throws {
        let commands:[Int32]=[-1]+Array(repeating:0,count:200)+Array(repeating:1,count:200)+[2,0,3,1,4,-1]+Array(repeating:[Int32(0),1,4],count:10).flatMap{$0}
        let positions=(0..<commands.count).map { i -> SIMD3<Float> in
            let t=Float(i);return SIMD3(150+90*sin(t*0.03),180+170*cos(t*0.02),8+t*0.01)
        }
        let world=try CameraWorld(bounds:SIMD3(901.2,702.3,30))
        var updates=0,maximum:Float=0
        for preset in DrivingCameraPreset.allCases where preset != .fly && preset != .television {
            for saved:Float in [.nan,1.5,preset.distanceScaledZoom ? 200:179] {
                let id=preset.referenceID
                var original=[Float](repeating:0,count:commands.count*23)
                ref_camera_zoom(Int32(id.head),Int32(id.camera),saved,commands,positions.flatMap{[$0.x,$0.y,$0.z]},Int32(commands.count),&original)
                var value=saved.isNaN ? preset.zoomLimits.standard:saved,rig=DrivingCameraRig()
                for i in commands.indices {
                    if let command=CameraZoomCommand(rawValue:Int(commands[i])) { value=try preset.adjustedZoom(value,command:command) }
                    var body=matrix_identity_float4x4;body[3]=SIMD4(positions[i],1)
                    let camera=try rig.view(preset:preset,body:body,bonnetPosition:.zero,driverPosition:.zero,world:world,roadCameraPosition:SIMD3(25,35,10),zoomValue:value,yaw:0,trackHeading:0){_ in 5}
                    let base=i*23,expected=original[base+9] * .pi/180
                    maximum=max(maximum,abs(camera.fieldOfView-expected))
                    XCTAssertEqual(camera.fieldOfView,expected,"\(preset) saved=\(saved) command=\(commands[i]) step=\(i)")
                    XCTAssertEqual(value,original[base+17]);XCTAssertEqual(preset.zoomLimits.standard,original[base+18])
                    XCTAssertEqual(preset.zoomLimits.minimum,original[base+19]);XCTAssertEqual(preset.zoomLimits.maximum,original[base+20])
                    XCTAssertEqual(original[base+21],1);XCTAssertEqual(original[base+22],1)
                    if i%17==0 { _=SurveyCameraTests().compare(camera,Array(original[base..<(base+17)]),preset) }
                    updates += 1
                }
            }
        }
        XCTAssertEqual(Set(DrivingCameraPreset.allCases.map(\.preferenceKey)).count,31)
        print("CAMERA_ZOOM presets=29 updates=\(updates) savedCases=3 fieldOfViewMaximum=\(maximum) limitsAndPersistenceKeys=exact projectionAspects=3")
    }
    func testPerCameraPersistenceSwitchingAndRejectedFiles() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("camera-zoom-\(UUID().uuidString)")
        defer {try? FileManager.default.removeItem(at:directory)}
        let store=try CameraPreferencesStore(directory:directory)
        XCTAssertEqual(try store.load(),CameraPreferences())
        var preferences=CameraPreferences()
        for (i,preset) in DrivingCameraPreset.allCases.enumerated() {
            preferences.select(preset)
            for _ in 0...i {try preferences.adjust(.zoomIn,for:preset)}
        }
        try store.save(preferences);XCTAssertEqual(try store.load(),preferences)
        let path=directory.appendingPathComponent("cameras.json"),saved=try Data(contentsOf:path)
        for i in 0..<300 {let preset=DrivingCameraPreset.allCases[i%DrivingCameraPreset.allCases.count];preferences.select(preset);XCTAssertEqual(preferences.zoom(for:preset),try store.load().zoom(for:preset))}
        XCTAssertEqual(try Data(contentsOf:path),saved)
        var invalid=preferences;invalid.zoomValues["fovy-99-99"]=40
        XCTAssertThrowsError(try store.save(invalid));XCTAssertEqual(try Data(contentsOf:path),saved)
        invalid=preferences;invalid.selectedKey="missing";XCTAssertThrowsError(try store.save(invalid))
        invalid=preferences;invalid.version=2;XCTAssertThrowsError(try store.save(invalid))
        for value:Float in [0,-1,.infinity,.nan,180,.leastNonzeroMagnitude] {
            invalid=preferences;invalid.zoomValues[DrivingCameraPreset.chase.preferenceKey]=value
            XCTAssertThrowsError(try store.save(invalid));XCTAssertEqual(try Data(contentsOf:path),saved)
        }
        try Data("{}".utf8).write(to:path);XCTAssertThrowsError(try store.load())
        try Data(repeating:32,count:65537).write(to:path);XCTAssertThrowsError(try store.load())
        try store.save(preferences);XCTAssertEqual(try store.load(),preferences)
        print("CAMERA_PREFERENCES views=31 switchChecks=300 atomicRoundTrip=1 invalidWritesPreservePrevious=1 malformedAndOversizeRejected=1")
    }
    func testInvalidZoomDoesNotAdvanceCameraState() throws {
        var rig=DrivingCameraRig(),baseline=DrivingCameraRig()
        for value:Float in [.nan,.infinity,-1,0,180,.leastNonzeroMagnitude] {
            XCTAssertThrowsError(try rig.view(preset:.chase,body:matrix_identity_float4x4,bonnetPosition:.zero,zoomValue:value,yaw:2,trackHeading:0){_ in XCTFail("Invalid zoom advanced camera state");return 0})
        }
        let actual=try rig.view(preset:.chase,body:matrix_identity_float4x4,bonnetPosition:.zero,zoomValue:40,yaw:2,trackHeading:0){_ in 0}
        let expected=try baseline.view(preset:.chase,body:matrix_identity_float4x4,bonnetPosition:.zero,yaw:2,trackHeading:0){_ in 0}
        XCTAssertEqual(actual.eye,expected.eye)
        XCTAssertThrowsError(try rig.view(preset:.tracksideZoom,body:matrix_identity_float4x4,bonnetPosition:.zero,world:CameraWorld(bounds:SIMD3(800,900,30)),zoomValue:.leastNonzeroMagnitude,yaw:0,trackHeading:0){_ in 0})
    }}
