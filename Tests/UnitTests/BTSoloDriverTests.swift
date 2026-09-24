// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSReferenceSupport
import TORCSConfiguration
import TORCSSimulation
import TORCSTrack
@testable import TORCSRobots

final class BTSoloDriverTests: XCTestCase {
    func parameters(_ content: ReferenceContent) throws -> ParameterDocument {
        try ParameterDocument.parse(Data(contentsOf:content.category)).merging(ParameterDocument.parse(Data(contentsOf:content.car)))
    }
    func observation(_ o: RefBTObservation,road: TrackRoad) throws -> BTObservation {
        let index=try XCTUnwrap(road.geometry.mainSegments.first { road.geometry.segments[$0].upstreamID==Int(o.segmentID) })
        return BTObservation(position:.init(segment:index,toStart:o.toStart,toRight:o.toRight,toMiddle:o.toMiddle,toLeft:o.toLeft),
            worldPosition:SIMD2(o.x,o.y),worldVelocity:SIMD2(o.vx,o.vy),yaw:o.yaw,speed:o.speed,fuel:o.fuel,rpm:o.rpm,
            wheelSpin:SIMD4(o.spin.0,o.spin.1,o.spin.2,o.spin.3),gear:Int(o.gear),laps:Int(o.laps),remainingLaps:Int(o.remainingLaps),
            distanceFromStart:o.distance,lapsBehindLeader:Int(o.lapsBehindLeader),damage:o.damage,pitFree:o.pitFree != 0)
    }
    func testFullOriginalLapCallbackCommandsAndLearning() throws {
        let content=try ReferenceContent(fixtures:XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)),bt:true)
        let world=try ReferenceWorld(track:content.track,car:content.car,category:content.category,btDirectory:content.directory,laps:1)
        defer { world.close() }
        let road=try ChassisTestContext.road()
        var driver=try BTSoloDriver(road:road,parameters:parameters(content),totalLaps:1,pitStall:0)
        XCTAssertEqual(driver.initialFuel,try world.parameterNumber(section:"Car",key:"initial fuel"))
        var callbacks: UInt64=0,maxError:Float=0,exact=0,terminal=false
        for _ in 0..<60000 {
            let state=try world.stepRobot()
            if state.driveCalls>callbacks {
                let input=try observation(world.robotObservation(),road:road),actual=try driver.drive(input).command
                let comparisons=[("throttle",actual.throttle,state.throttle),("brake",actual.brake,state.brake),
                    ("steering",actual.steering,state.steering),("clutch",actual.clutch,state.clutch)]
                for (name,a,b) in comparisons {
                    let error=abs(a-b);maxError=max(maxError,error);if a==b { exact += 1 }
                    guard a.isFinite,error<=0.000002 else {
                        XCTFail("BT \(name) tick=\(world.tick) callback=\(state.driveCalls) native=\(a) original=\(b) error=\(error) segment=\(input.position.segment)")
                        return
                    }
                }
                XCTAssertEqual(actual.gear,Int(state.gear));callbacks=state.driveCalls
            }
            if state.raceState==4 { terminal=true;break }
        }
        XCTAssertTrue(terminal);XCTAssertGreaterThan(callbacks,4000);XCTAssertEqual(driver.calls,callbacks)
        world.close()
        let karma=try Data(contentsOf:content.directory.appendingPathComponent("user/drivers/bt/0/race/aalborg.karma"))
        let original=try BTLearning(road:road,karma:karma)
        XCTAssertEqual(driver.learning.updateIDs,original.updateIDs)
        var learningError:Float=0
        for (a,b) in zip(driver.learning.radius,original.radius) { learningError=max(learningError,abs(a-b));XCTAssertEqual(a,b,accuracy:0.000002) }
        print("NATIVE_BT_CALLBACKS ticks=\(world.tick) callbacks=\(callbacks) controls=\(callbacks*5) exactFloatControls=\(exact) maxAbsolute=\(maxError) learningMax=\(learningError) originalInputs=1 nativePhysics=0")
    }
    func testKarmaRoundTripAndRejectsCorruptData() throws {
        let road=try ChassisTestContext.road(),original=try BTLearning(road:road),data=original.encodedKarma()
        let parsed=try BTLearning(road:road,karma:data)
        XCTAssertEqual(parsed.radius,original.radius);XCTAssertEqual(parsed.updateIDs,original.updateIDs)
        XCTAssertEqual(parsed.encodedKarma(),data)
        let prefixed=Data([0])+data
        XCTAssertEqual(try BTLearning(road:road,karma:prefixed.dropFirst()).encodedKarma(),data)
        for length in [0,12,17,data.count-1] { XCTAssertThrowsError(try BTLearning(road:road,karma:Data(data.prefix(length)))) }
        var bad=data;bad[0]=0;XCTAssertThrowsError(try BTLearning(road:road,karma:bad))
        bad=data;for i in 18..<22 { bad[i]=255 };XCTAssertThrowsError(try BTLearning(road:road,karma:bad))
        bad=data;bad[22]=0;bad[23]=0;bad[24]=128;bad[25]=127;XCTAssertThrowsError(try BTLearning(road:road,karma:bad))
    }
}

import TORCSRaceEngine
import TORCSTelemetry
extension BTSoloDriverTests {
    func testNativePhysicsCompletesAutonomousLapAndRepeats() throws {
        let content=try ReferenceContent(fixtures:XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)),bt:true)
        let road=try ChassisTestContext.road(),p=try parameters(content)
        var outcomes:[[String:Double]]=[]
        for _ in 0..<2 {
            var runtime=try BTSoloRuntime(road:road,parameters:p,laps:1)
            XCTAssertEqual(runtime.simulation.tick,0);XCTAssertEqual(runtime.simulation.settlingTicks,501)
            for _ in 0..<60000 {
                try runtime.step()
                if runtime.finished || runtime.retired { break }
            }
            XCTAssertTrue(runtime.finished);XCTAssertFalse(runtime.retired)
            XCTAssertEqual(runtime.completedLaps.count,1)
            XCTAssertEqual(runtime.pitCalls,0)
            XCTAssertEqual(runtime.timing.lastLapTime,87.38799999997774,accuracy:0.5)
            var record=VehicleTelemetry.values(runtime.simulation.cars[0],track:road.geometry)
            record["robot.calls"]=Double(runtime.driver.calls);record["race.time"]=runtime.clock.time
            record["race.ticks"]=Double(runtime.simulation.tick)
            outcomes.append(record)
            print("NATIVE_BT_PHYSICAL_LAP ticks=\(runtime.simulation.tick) callbacks=\(runtime.driver.calls) time=\(runtime.clock.time) fuel=\(runtime.simulation.cars[0].fuel) damage=\(runtime.simulation.cars[0].damage) valid=\(runtime.completedLaps.first?.valid ?? false) nativePhysics=1")
        }
        XCTAssertEqual(outcomes[0],outcomes[1])
    }
}

extension BTSoloDriverTests {
    func testOriginalPitRunCommandsAndRefuelling() throws {
        let content=try ReferenceContent(fixtures:XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)),bt:true)
        let world=try ReferenceWorld(track:content.track,car:content.car,category:content.category,btDirectory:content.directory,laps:3)
        defer { world.close() }
        let road=try ChassisTestContext.road()
        var driver=try BTSoloDriver(road:road,parameters:parameters(content),totalLaps:3,pitStall:0)
        var callbacks:UInt64=0,pits:Int32=0,finished=false,requested=false,maxError:Float=0
        for tick in 1...180000 {
            if tick==8000 { try world.updateCarStatus(car:0,fuel:2.5,maximumDamage:10000) }
            let state=try world.stepRobot()
            if state.driveCalls>callbacks {
                let decision=try driver.drive(observation(world.robotObservation(),road:road)),a=decision.command
                requested = requested || decision.pitRequested
                for (x,y) in [(a.throttle,state.throttle),(a.brake,state.brake),(a.steering,state.steering),(a.clutch,state.clutch)] {
                    maxError=max(maxError,abs(x-y))
                    guard x.isFinite,abs(x-y)<=0.000002 else { XCTFail("Pit run command mismatch tick=\(tick): \(x) != \(y)");return }
                }
                XCTAssertEqual(a.gear,Int(state.gear));callbacks=state.driveCalls
            }
            if state.pitCalls>pits {
                let original=try world.robotPitDecision(),actual=driver.pitCommand(try observation(original.input,road:road))
                XCTAssertEqual(actual.fuel,original.fuel);XCTAssertEqual(actual.repair,original.repair)
                pits=state.pitCalls
            }
            if state.raceState==4 { finished=true;break }
        }
        XCTAssertTrue(finished);XCTAssertTrue(requested);XCTAssertGreaterThan(pits,0)
        print("NATIVE_BT_PIT_CALLBACKS ticks=\(world.tick) calls=\(callbacks) pits=\(pits) maxAbsolute=\(maxError) originalInputs=1")
    }
    func testNativeFiveLapsAndForcedPitComplete() throws {
        let content=try ReferenceContent(fixtures:XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)),bt:true)
        let road=try ChassisTestContext.road()
        var runtime=try BTSoloRuntime(road:road,parameters:parameters(content),laps:5)
        for tick in 1...300000 {
            if tick==8000 { try runtime.updateCarStatus(fuel:2.5) }
            try runtime.step()
            if runtime.finished || runtime.retired { break }
        }
        XCTAssertTrue(runtime.finished);XCTAssertFalse(runtime.retired)
        XCTAssertEqual(runtime.completedLaps.count,5);XCTAssertGreaterThan(runtime.pitCalls,0)
        XCTAssertThrowsError(try runtime.step())
        print("NATIVE_BT_FIVE_LAPS ticks=\(runtime.simulation.tick) calls=\(runtime.driver.calls) time=\(runtime.clock.time) pits=\(runtime.pitCalls) fuel=\(runtime.simulation.cars[0].fuel) damage=\(runtime.simulation.cars[0].damage) finished=\(runtime.finished)")
    }
}
