// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSCore
import TORCSAssets
import TORCSRaceEngine
import TORCSConfiguration
import TORCSTrack
import TORCSTelemetry
import TORCSReferenceSupport
import TORCSSimulation
import TORCSMetal
import simd

final class DrivingRuntimeTests: XCTestCase {
    func makeRuntime() throws -> DrivingRuntime {
        let content=try ReferenceContent(fixtures:XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)))
        let car=try ParameterDocument.parse(Data(contentsOf:content.car))
        let category=try ParameterDocument.parse(Data(contentsOf:content.category))
        let definition=try VehicleDynamicsDefinition(parameters:category.merging(car))
        var simulation=try SingleVehicleSimulation(definition:definition,road:ChassisTestContext.road())
        try simulation.settle()
        return try DrivingRuntime(simulation:simulation)
    }
    func testDrivingCadencesMatchDirectFixedSteps() throws {
        let initial=try makeRuntime(),command=DriverCommand(throttle:0.65,gear:1)
        var direct=initial.simulation
        for _ in 0..<2000 { try direct.step(command:command) }
        let expected=VehicleTelemetry.values(direct.vehicle,track:direct.road.geometry)
        for hz in [60,120,144,240] {
            var runtime=initial
            for _ in 0..<(hz*4) { try runtime.advance(elapsed:1/Double(hz),command:command) }
            XCTAssertEqual(runtime.clock.tick,2000);XCTAssertEqual(runtime.simulation.tick,2000)
            XCTAssertEqual(VehicleTelemetry.values(runtime.simulation.vehicle,track:runtime.simulation.road.geometry),expected)
            XCTAssertEqual(runtime.previous.tick,1999);XCTAssertEqual(runtime.current.tick,2000)
        }
        print("DRIVING_CLOCK cadences=4 ticksEach=2000 telemetryFields=\(expected.count) exact=1")
    }
    func testPauseAndCatchUpPreserveState() throws {
        var runtime=try makeRuntime();let command=DriverCommand(throttle:0.5,gear:1)
        try runtime.advance(elapsed:0.08,command:command,maximumSteps:5)
        XCTAssertEqual(runtime.clock.tick,5);XCTAssertTrue(runtime.frame.behind)
        let position=runtime.frame.current.body.position
        try runtime.advance(elapsed:600,command:command,paused:true)
        XCTAssertEqual(runtime.clock.tick,5);XCTAssertEqual(runtime.frame.current.body.position,position)
        try runtime.advance(elapsed:0,command:command)
        XCTAssertEqual(runtime.clock.tick,40);XCTAssertFalse(runtime.frame.behind)
        let tick=runtime.clock.tick
        for value in [Double.nan,.infinity,-1] { XCTAssertThrowsError(try runtime.advance(elapsed:value,command:command)) }
        XCTAssertEqual(runtime.clock.tick,tick)
        print("DRIVING_PAUSE pausedSeconds=600 retainedBacklogTicks=35 invalidTimes=3")
    }
    func testPreparedSessionLoadsAndRejectsUnsafeReferences() throws {
        let source=try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil))
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        for name in ["155-DTM.xml","Track-4WD-GrB.xml","aalborg.xml","surfaces.xml","objects.xml"] {
            try FileManager.default.copyItem(at:source.appendingPathComponent(name),to:folder.appendingPathComponent(name))
        }
        try CompiledScene.compile(input:source.appendingPathComponent("Artwork/155-DTM/155-DTM.acc"),output:folder.appendingPathComponent("model"),roots:[source.appendingPathComponent("Artwork/155-DTM")],options:.init(car:true))
        var index:[String:Any]=["version":1,"name":"Selected session","car":"155-DTM.xml","category":"Track-4WD-GrB.xml","track":"aalborg.xml","surfaces":"surfaces.xml","objects":"objects.xml","body":"model/scene.json","scenery":"model/scene.json","wheels":Array(repeating:"model/scene.json",count:4)]
        func write() throws { try JSONSerialization.data(withJSONObject:index).write(to:folder.appendingPathComponent("driving.json")) }
        try write()
        let loaded=try DrivingContent.load(folder)
        XCTAssertEqual(loaded.scenes.count,6);XCTAssertEqual(loaded.simulation.settlingTicks,501)
        XCTAssertEqual(loaded.simulation.tick,0);XCTAssertGreaterThan(loaded.maximumGear,1)
        index["version"]=2;try write();XCTAssertThrowsError(try DrivingContent.load(folder))
        index["version"]=1;index["wheels"]=["model/scene.json"];try write();XCTAssertThrowsError(try DrivingContent.load(folder))
        index["wheels"]=Array(repeating:"model/scene.json",count:4);index["car"]="../155-DTM.xml";try write();XCTAssertThrowsError(try DrivingContent.load(folder))
        index["car"]="155-DTM.xml";index["scenery"]="missing/scene.json";try write();XCTAssertThrowsError(try DrivingContent.load(folder))
        print("DRIVING_CONTENT models=6 settlingTicks=501 invalidPackages=4")
    }
    func testBehindCameraAgainstOriginalSequence() throws {
        var input:[Float]=[],camera=DrivingCamera(),actual:[Float]=[]
        for i in 0..<1000 {
            let yaw:Float=i%10==0 ? -3.13:i%10==1 ? 3.13:Float(i)*0.017
            let position=SIMD3<Float>(Float(i)*0.3,Float(i%17)-8,Float(i%7)),height=Float(i%9)*0.7
            input += [position.x,position.y,position.z,yaw,height]
            let view=camera.update(position:position,yaw:yaw) { _ in height }
            actual += [view.eye.x,view.eye.y,view.eye.z,view.target.x,view.target.y,view.target.z]
        }
        var expected=[Float](repeating:0,count:6000)
        ref_camera_behind(input,1000,&expected)
        var maximum:Float=0
        for (a,b) in zip(actual,expected) { maximum=max(maximum,abs(a-b));XCTAssertEqual(a,b,accuracy:0.0001) }
        print("DRIVING_CAMERA updates=1000 scalars=6000 maxAbsolute=\(maximum)")
    }
}

extension DrivingRuntimeTests {
    func testPerTickTelemetryIncludesTimingAcrossPauseAndBacklog() throws {
        var runtime=try makeRuntime(),direct=runtime
        let destination=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".jsonl")
        defer { try? FileManager.default.removeItem(at:destination) }
        let writer=try TelemetryWriter(to:destination)
        try writer.append(DrivingTelemetry.record(runtime.simulation,timing:runtime.timing,raceTime:runtime.raceTime))
        let command=DriverCommand(throttle:0.65,gear:1)
        let capture: (SingleVehicleSimulation,RaceLapTiming,Double)throws->Void = { simulation,timing,time in
            try writer.append(DrivingTelemetry.record(simulation,timing:timing,raceTime:time))
        }
        try runtime.advance(elapsed:0.08,command:command,maximumSteps:5,didStep:capture)
        try runtime.advance(elapsed:600,command:command,paused:true,didStep:capture)
        try runtime.advance(elapsed:0,command:command,didStep:capture)
        for _ in 0..<115 { try runtime.advance(elapsed:1/120,command:command,didStep:capture) }
        try writer.finish()
        let records=try TelemetryIO.read(destination)
        XCTAssertEqual(records.count,Int(runtime.clock.tick)+1)
        for r in records {
            if r.tick>0 { try direct.advance(elapsed:0.002,command:command) }
            let expected=DrivingTelemetry.record(direct.simulation,timing:direct.timing,raceTime:direct.raceTime)
            XCTAssertEqual(r.tick,expected.tick);XCTAssertEqual(r.time,expected.time);XCTAssertEqual(r.values,expected.values)
            XCTAssertEqual(r.values.count,161)
        }
        print("DRIVING_CAPTURE records=\(records.count) fieldsEach=161 exact=1 pausedSeconds=600")
    }
    func testTerminalTickAndFailedObserverStopBatchImmediately() throws {
        var clock=FixedStepClock(),calls:[UInt64]=[]
        let count=clock.advanceContinuing(elapsed:0.1) { tick in calls.append(tick);return tick<3 }
        XCTAssertEqual(count,3);XCTAssertEqual(calls,[1,2,3]);XCTAssertEqual(clock.tick,3)
        XCTAssertEqual(clock.accumulator,0.094,accuracy:1e-12)
        var runtime=try makeRuntime(),captured=0
        XCTAssertThrowsError(try runtime.advance(elapsed:0.1,command:.init(),didStep:{ _,_,_ in
            captured += 1
            throw TelemetryError.invalid("Authored failed writer")
        }))
        XCTAssertEqual(captured,1);XCTAssertEqual(runtime.clock.tick,1);XCTAssertEqual(runtime.simulation.tick,1)
        XCTAssertEqual(runtime.current.tick,1)
    }
}

extension DrivingRuntimeTests {
    func testPresentationPublicationUsesEveryPhysicsStepAndOriginalClock() throws {
        var runtime=try makeRuntime(),expected=runtime.collisionHistory,time:Double=0,publications=0
        let road=runtime.simulation.road
        XCTAssertGreaterThan(road.width,0)
        for _ in 0..<240 {
            try runtime.advance(elapsed:1/60,command:.init(throttle:0.65,gear:1),didStep: { simulation,_,raceTime in
                time += 0.002;XCTAssertEqual(raceTime,time)
                let life=simulation.lifecycle
                try expected.observe(tick:simulation.tick,flags:life.flags,accumulatedCollision:life.publishedCollision,stepCollision:life.publishedSimCollision)
                publications += 1
            })
            let frame=runtime.frame
            XCTAssertEqual(frame.raceTime,time);XCTAssertEqual(frame.presentationCar.collisions,expected)
            XCTAssertEqual(frame.presentationCar.visual.tick,frame.current.tick)
            XCTAssertEqual(frame.presentationCar.remainingLaps,frame.timing.remainingLaps)
            XCTAssertEqual(frame.presentationCar.trackPosition.segment,runtime.simulation.lifecycle.trackPosition.segment)
            XCTAssertEqual(frame.presentationCar.trackPosition.toStart,runtime.simulation.lifecycle.trackPosition.toStart)
        }
        let before=runtime.frame
        try runtime.advance(elapsed:600,command:.init(),paused:true)
        XCTAssertEqual(runtime.frame.raceTime,before.raceTime);XCTAssertEqual(runtime.frame.presentationCar.collisions,before.presentationCar.collisions)
        XCTAssertNotEqual(runtime.frame.raceTime,runtime.frame.time)
        XCTAssertEqual(publications,2000)
        print("TV_RUNTIME_PUBLICATION physicsPublications=2000 displayFrames=240 repeatedAdditionClock=exact pauseStable=1")
    }
}
