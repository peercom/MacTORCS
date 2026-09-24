// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import CReference
import TORCSTrack
import TORCSConfiguration
import TORCSReferenceSupport
@testable import TORCSMetal

final class TracksideCameraTests: XCTestCase {
    func testF8F9FactoriesAndUpdatesAgainstOriginal() throws {
        var maximum: Float = 0
        for i in 0..<1200 {
            let t=Float(i),bounds=SIMD3(701.3+t*0.17,853.7+t*0.57,40+t*0.1)
            let world=try CameraWorld(bounds:bounds)
            let car=SIMD3(450*sin(t*0.07),350*cos(t*0.03),5+t*0.04)
            // Include close approaches beyond nominal factory FOV limits.
            let roadside=i%3 == 0 ? nil : (i%3 == 1 ? car+SIMD3(0.01,0.03,0.1):SIMD3(3*t,57,10))
            var body=matrix_identity_float4x4;body[3]=SIMD4(car,1)
            for (kind,preset) in [DrivingCameraPreset.trackside,.tracksideZoom].enumerated() {
                var rig=DrivingCameraRig(),reference=[Float](repeating:0,count:17)
                let view=try rig.view(preset:preset,body:body,bonnetPosition:.zero,world:world,roadCameraPosition:roadside,yaw:0,trackHeading:0){_ in XCTFail("Trackside update queried ground");return 0}
                let b=[bounds.x,bounds.y,bounds.z],p=[car.x,car.y,car.z]
                if let eye=roadside { ref_camera_trackside(b,p,[eye.x,eye.y,eye.z],Int32(kind),&reference) }
                else { ref_camera_trackside(b,p,nil,Int32(kind),&reference) }
                maximum=max(maximum,SurveyCameraTests().compare(view,reference,preset))
                XCTAssertFalse(preset.allowsMirror)
                if kind==0,let eye=roadside { XCTAssertEqual(view.target.z,eye.z) }
            }
        }
        var rig=DrivingCameraRig()
        XCTAssertThrowsError(try rig.view(preset:.trackside,body:matrix_identity_float4x4,bonnetPosition:.zero,yaw:0,trackHeading:0){_ in 0})
        print("TRACKSIDE_CAMERAS updates=2400 poseMaximum=\(maximum) fallback=800 projectionAspects=3")
    }
    func fixture() throws -> URL { try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)) }
    func testAalborgCameraPositionsAndEverySegmentAssignment() throws {
        let fixture=try fixture(),content=try ReferenceContent(fixtures:fixture)
        let parameters=try ParameterDocument.parse(Data(contentsOf:fixture.appendingPathComponent("aalborg.xml")),entities:["default-surfaces":Data(contentsOf:fixture.appendingPathComponent("surfaces.xml")),"default-objects":Data(contentsOf:fixture.appendingPathComponent("objects.xml"))],allowLegacyLatin1:true)
        let road=try TrackBuilder.buildRoad(parameters:parameters)
        let world=try ReferenceWorld(track:content.track,car:content.car,category:content.category)
        defer {world.close();withExtendedLifetime(content){}}
        try compare(road,world)
        XCTAssertEqual(road.cameras.count,parameters.section("Cameras")!.sections.count)
        XCTAssertNil(road.camera(at:-1));XCTAssertNil(road.camera(at:road.geometry.segments.count))
    }
    func compare(_ road:TrackRoad,_ world:ReferenceWorld) throws {
        XCTAssertEqual(road.width,Float(world.trackWidth))
        var maximum:Float=0,assigned=0
        for index in road.geometry.segments.indices {
            let actual=road.camera(at:index),reference=world.trackCamera(at:index)
            XCTAssertEqual(actual?.name,reference?.name,"segment \(index)")
            if let actual,let reference {
                assigned += 1
                for axis in 0..<3 {
                    maximum=max(maximum,abs(actual.position[axis]-reference.position[axis]))
                    XCTAssertEqual(actual.position[axis],reference.position[axis],accuracy:0.00001,"\(actual.name) axis \(axis)")
                }
            }
        }
        print("TRACK_CAMERA_METADATA cameras=\(road.cameras.count) segments=\(road.geometry.segments.count) assigned=\(assigned) maximum=\(maximum)")
    }
    func camera(_ name:String,_ location:String,_ start:String,_ end:String)->String {
        """
        <section name="\(name)"><attstr name="segment" val="\(location)"/>
        <attnum name="to right" val="-2.7"/><attnum name="to start" val="0.31"/><attnum name="height" val="4.3"/>
        <attstr name="fov start" val="\(start)"/><attstr name="fov end" val="\(end)"/></section>
        """
    }
    func xml(_ cameras:String)->Data {
        Data("""
        <params name="authored-camera-test">
        <section name="Header"><attnum name="version" val="4"/></section>
        <section name="Main Track"><attnum name="width" val="9"/>
        <section name="Right Border"><attnum name="width" val="1"/><attnum name="height" val="0.1"/><attstr name="style" val="curb"/></section>
        <section name="Right Side"><attnum name="width" val="4"/></section>
        <section name="Track Segments">
        <section name="a"><attstr name="type" val="str"/><attnum name="lg" val="100"/><attnum name="profil steps" val="3"/><attnum name="z start" val="-3"/><attnum name="grade" val="0.03"/></section>
        <section name="b"><attstr name="type" val="lft"/><attnum name="radius" val="40"/><attnum name="arc" unit="deg" val="180"/><attnum name="profil steps" val="4"/><attnum name="banking end" unit="deg" val="-4"/></section>
        <section name="c"><attstr name="type" val="str"/><attnum name="lg" val="100"/><attnum name="profil steps" val="2"/></section>
        <section name="d"><attstr name="type" val="rgt"/><attnum name="radius" val="40"/><attnum name="arc" unit="deg" val="180"/><attnum name="profil steps" val="5"/></section>
        </section></section>\(cameras.isEmpty ? "" : "<section name=\"Cameras\">"+cameras+"</section>")</params>
        """.utf8)
    }
    func testWrappedOverlappingFullLapAndUnassignedRangesAgainstOriginal() throws {
        let content=try ReferenceContent(fixtures:fixture())
        for definitions in ["",camera("partial","b","b","c"),camera("all","d","c","c")+camera("wrap","b","d","b")+camera("override","a","a","b")] {
            let data=xml(definitions),road=try TrackBuilder.buildRoad(parameters:ParameterDocument.parse(data))
            let file=content.track.deletingLastPathComponent().appendingPathComponent("authored-camera-track.xml");try data.write(to:file)
            let world=try ReferenceWorld(track:file,car:content.car,category:content.category)
            try compare(road,world);world.close()
            let mains=road.geometry.mainSegments
            if road.cameras.count==3 {
                XCTAssertEqual(mains.map{road.camera(at:$0)?.name},Array(repeating:"override",count:3)+Array(repeating:"all",count:6)+Array(repeating:"wrap",count:5))
            }
        }
        withExtendedLifetime(content){}
    }
    /// Unresolvable camera references resolve the way the original does, and
    /// say so.
    ///
    /// This previously rejected them. That was stricter than upstream, and the
    /// strictness cost real content: a-speedway ships
    /// `fov start val="segment s2"`, where the value mistakenly includes the
    /// word "segment" and matches nothing, which made an otherwise valid track
    /// unloadable.
    ///
    /// The original resolves a camera's segment reference by reading that
    /// segment's id with `GfParmGetNum`, which returns its default of 0 when
    /// the name is absent, then scanning for the segment with that id. So an
    /// unknown name selects the first segment. The port now does the same, but
    /// records a warning, so the substitution is visible rather than silent —
    /// which is the property the previous behaviour was protecting.
    func testUnresolvableCameraReferencesResolveLikeTheOriginalAndWarn() throws {
        for definitions in [camera("bad","missing","a","b"), camera("bad","a","missing","b"),
                            camera("bad","a","a","missing"), "<section name=\"missing-fields\"/>"] {
            let road = try TrackBuilder.buildRoad(parameters: ParameterDocument.parse(xml(definitions)))
            XCTAssertFalse(road.warnings.isEmpty, "an unresolved reference must be reported")
            XCTAssertTrue(road.warnings.contains { $0.contains("unknown") },
                          "warning should name the unresolved reference: \(road.warnings)")
            // It still produces a usable camera rather than a broken one.
            XCTAssertEqual(road.cameras.count, 1)
        }
    }

    /// A well-formed track warns about nothing.
    func testValidCameraReferencesProduceNoWarnings() throws {
        let road = try TrackBuilder.buildRoad(parameters: ParameterDocument.parse(xml(camera("ok","a","a","b"))))
        XCTAssertTrue(road.warnings.isEmpty, "unexpected warnings: \(road.warnings)")
    }
}
