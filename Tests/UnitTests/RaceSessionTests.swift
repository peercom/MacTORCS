// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSCore
import TORCSRaceEngine
import TORCSSimulation
import TORCSTelemetry
import TORCSTrack

final class RaceSessionTests: XCTestCase {
    func testPublishedFinishAtCrossingEndsFieldAgainstOriginal() throws {
        let context=try RacePitTests.Context(count:3);defer { context.close() }
        let g=context.road.geometry
        let last=try XCTUnwrap(g.mainSegments.last { g.segments[$0].raceFlags & 1 != 0 })
        let start=try XCTUnwrap(g.mainSegments.first { g.segments[$0].raceFlags & 2 != 0 })
        var race=try RaceProgress(positions:Array(repeating:.init(segment:last,toStart:0,toRight:5),count:3),targetLaps:5)
        try context.world.initializeProgress(segments:[last,last,last],target:5)
        let p=TrackLocalPosition(segment:start,toStart:0,toRight:5)
        let samples=(0..<3).map { RaceLapSample(position:p,speed:10,width:1.9,flags:$0==1 ? 0x100:0) }
        let original=try context.world.manageProgress(samples:samples.map { s in
            .init(position:.init(segment:Int32(start),mode:0,toStart:0,toRight:5,toMiddle:0,toLeft:0),speed:10,width:1.9,flags:s.flags,collision:0)
        },time:1)
        try race.update(samples:samples,time:1,road:context.road)
        XCTAssertTrue(race.ended);XCTAssertEqual(original.state,4)
        for id in 0..<3 { RaceLapTimingTests.check(race.timing[id],original.cars[id].timing) }
        XCTAssertEqual(race.order.indices,original.order)
    }
    func testFieldTimingReversalsGapsAndValidityAgainstOriginal() throws {
        let context=try RacePitTests.Context(count:8);defer { context.close() }
        let road=context.road,g=road.geometry
        let last=try XCTUnwrap(g.mainSegments.last { g.segments[$0].raceFlags & 1 != 0 })
        let start=try XCTUnwrap(g.mainSegments.first { g.segments[$0].raceFlags & 2 != 0 })
        let middle=try XCTUnwrap(g.mainSegments.first { g.segments[$0].raceFlags == 0 })
        let initial=Array(repeating:TrackLocalPosition(segment:last,toStart:0,toRight:5),count:8)
        var race=try RaceProgress(positions:initial,targetLaps:3),seed:UInt64=9,time:Double=0,finishes=0,invalid=0
        func draw()->UInt64 { seed=seed &* 2862933555777941757 &+ 3037000493;return seed>>32 }
        try context.world.initializeProgress(segments:initial.map(\.segment),target:3)
        for _ in 0..<500 {
            if race.ended {
                finishes += 1;invalid += race.laps.flatMap { $0 }.filter { !$0.valid }.count
                race=try RaceProgress(positions:initial,targetLaps:3);time=0
                try context.world.initializeProgress(segments:initial.map(\.segment),target:3)
            }
            time += 0.317
            let samples=(0..<8).map { id -> RaceLapSample in
                let segment=[last,start,middle][Int(draw()%3)]
                var p=TrackLocalPosition(segment:segment,toStart:0.2,toRight:5);p.toLeft=g.segments[segment].width-5
                return .init(position:p,speed:Float(Int(draw()%60)-10),width:1.9,flags:race.timing[id].flags,collision:draw()%7==0 ? 2:0)
            }
            let original=try context.world.manageProgress(samples:samples.map { s in
                let p=s.position
                return RefRaceProgressSample(position:.init(segment:Int32(p.segment),mode:Int32(p.mode.rawValue),toStart:p.toStart,toRight:p.toRight,toMiddle:p.toMiddle,toLeft:p.toLeft),speed:s.speed,width:s.width,flags:s.flags,collision:s.collision)
            },time:time)
            try race.update(samples:samples,time:time,road:road)
            XCTAssertEqual(race.order.indices,original.order);XCTAssertEqual(race.ended,original.state==4)
            if !race.ended { XCTAssertEqual(race.finishing,original.state==2) }
            for id in 0..<8 {
                let n=race.gaps[id],r=original.cars[id]
                RaceLapTimingTests.check(race.timing[id],r.timing)
                XCTAssertEqual(n.behindLeader,r.behindLeader);XCTAssertEqual(n.behindPrevious,r.behindPrevious)
                XCTAssertEqual(n.beforeNext,r.beforeNext);XCTAssertEqual(n.lapsBehindLeader,Int(r.lapsBehindLeader))
                XCTAssertEqual(race.order.indices.firstIndex(of:id)!+1,Int(r.position))
            }
        }
        XCTAssertGreaterThan(finishes,0);XCTAssertGreaterThan(invalid,0)
        print("RACE_FIELD originalSteps=500 cars=8 fieldsPerCar=23 finishedSessions=\(finishes) invalidLaps=\(invalid)")
    }
    func testCountdownClockMatchesOriginalAcrossStart() throws {
        let count=10000
        var times=[Double](repeating:0,count:count),states=[Int32](repeating:0,count:count)
        XCTAssertEqual(ref_race_start_clock(Int32(count),&times,&states),1)
        var clock=RaceStartClock(countdown:true),zeroTicks=0
        XCTAssertEqual(clock.time,-2)
        for i in 0..<count {
            clock.step();XCTAssertEqual(clock.time,times[i],"tick \(i+1)")
            XCTAssertEqual(clock.prestart,states[i]==16)
            if clock.time==0 { zeroTicks += 1;XCTAssertEqual(i,999) }
        }
        XCTAssertEqual(zeroTicks,1)
        print("RACE_START originalTicks=10000 exactTimes=10000 greenTick=1000")
    }
    func testStandingsAgainstOriginalWithTiesFinishesAndChangingOrder() throws {
        var random:UInt64=12345,cases=0
        func draw()->UInt64 { random=random &* 6364136223846793005 &+ 1;return random>>32 }
        for count in [1,2,3,8,16] {
            var native=try RaceOrder(carCount:count),order=Array(0..<Int32(count))
            for step in 0..<1000 {
                let distances=(0..<count).map { _ in Float(Int(draw()%17)-8)*13 }
                let flags=(0..<count).map { _ -> UInt32 in step%13==0 ? 0x100:draw()%3==0 ? 0x100:0 }
                let state=ref_race_order(distances,flags,&order,Int32(count))
                try native.update(distances:distances,flags:flags)
                XCTAssertEqual(native.indices,order.map(Int.init))
                XCTAssertEqual(native.allFinished,state==4);cases += 1
            }
        }
        var order=try RaceOrder(carCount:3)
        try order.update(distances:[0,0,0],flags:[0,0,0]);XCTAssertEqual(order.indices,[0,1,2])
        XCTAssertThrowsError(try order.update(distances:[0,.nan,0],flags:[0,0,0]))
        XCTAssertEqual(order.indices,[0,1,2]);XCTAssertFalse(order.allFinished)
        print("RACE_SORT originalComparisons=\(cases) maxCars=16 tiesAndFinished=1")
    }
    func testCountdownPhysicsPauseCadenceAndRestart() throws {
        let simulation=try DrivingRuntimeTests().makeRuntime().simulation
        let configuration=try RaceSessionConfiguration(kind:.qualifying,laps:2)
        var runtime=try DrivingRuntime(simulation:simulation,configuration:configuration),direct=simulation
        let command=DriverCommand(throttle:0.5,gear:1),position=runtime.current.body.position
        for i in 0..<1500 {
            try direct.step(command:command,mode:i<999 ? .prestart:.running)
        }
        for _ in 0..<120 { try runtime.advance(elapsed:1/120,command:command) }
        XCTAssertEqual(runtime.phase,.prestart);XCTAssertEqual(runtime.current.body.position,position)
        let before=runtime.frame
        try runtime.advance(elapsed:100,command:command,paused:true)
        XCTAssertEqual(runtime.raceTime,before.raceTime);XCTAssertEqual(runtime.clock.tick,500)
        for _ in 0..<120 { try runtime.advance(elapsed:1/60,command:command) }
        XCTAssertEqual(runtime.phase,.running);XCTAssertEqual(runtime.clock.tick,1500)
        XCTAssertEqual(VehicleTelemetry.values(runtime.simulation.vehicle,track:simulation.road.geometry),VehicleTelemetry.values(direct.vehicle,track:simulation.road.geometry))
        runtime.endSession();let ended=try XCTUnwrap(runtime.result),tick=runtime.clock.tick
        XCTAssertEqual(ended.reason,.endedEarly);XCTAssertEqual(runtime.phase,.results)
        try runtime.advance(elapsed:100,command:command)
        XCTAssertEqual(runtime.clock.tick,tick);XCTAssertEqual(runtime.result,ended)
        let restarted=try DrivingRuntime(simulation:simulation,configuration:configuration)
        XCTAssertEqual(restarted.clock.tick,0);XCTAssertEqual(restarted.raceTime,-2)
        XCTAssertEqual(restarted.current.body.position,position);XCTAssertNil(restarted.result)
        XCTAssertEqual(restarted.simulation.random.state,simulation.random.state)
        XCTAssertThrowsError(try DrivingRuntime(simulation:simulation,configuration:RaceSessionConfiguration(kind:.race)))
        print("SESSION_LIFECYCLE physicsTicks=1500 pausedSeconds=100 countdownMotion=0 restartExact=1")
    }
    func testRetirementStopsBatchAndResultsRoundTrip() throws {
        var simulation=try DrivingRuntimeTests().makeRuntime().simulation
        try simulation.updateCarStatus(fuel:0)
        var runtime=try DrivingRuntime(simulation:simulation,configuration:RaceSessionConfiguration(laps:1,countdown:false))
        try runtime.advance(elapsed:0.1,command:.init(throttle:1,gear:1))
        let result=try XCTUnwrap(runtime.result)
        XCTAssertEqual(result.reason,.retired);XCTAssertEqual(runtime.clock.tick,1)
        XCTAssertEqual(result.laps.count,0);XCTAssertNil(result.bestLap)
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
        defer { try? FileManager.default.removeItem(at:url) }
        try result.save(to:url)
        XCTAssertEqual(try JSONDecoder().decode(DrivingSessionResult.self,from:Data(contentsOf:url)),result)
        let laps=try JSONDecoder().decode([CompletedLap].self,from:Data(#"[{"number":1,"time":42,"valid":true,"topSpeed":30,"minimumSpeed":0},{"number":2,"time":20,"valid":false,"topSpeed":40,"minimumSpeed":3},{"number":3,"time":37,"valid":true,"topSpeed":35,"minimumSpeed":2}]"#.utf8))
        let completed=DrivingSessionResult(configuration:try RaceSessionConfiguration(kind:.qualifying,laps:3),reason:.completed,elapsed:99,laps:laps,fuel:5,damage:12)
        XCTAssertEqual(completed.bestLap,37);XCTAssertEqual(completed.laps.count,3)
        try completed.save(to:url)
        XCTAssertEqual(try JSONDecoder().decode(DrivingSessionResult.self,from:Data(contentsOf:url)),completed)
        XCTAssertThrowsError(try RaceSessionConfiguration(laps:0))
        XCTAssertThrowsError(try RaceSessionConfiguration(laps:10001))
        XCTAssertThrowsError(try JSONDecoder().decode(RaceSessionConfiguration.self,from:Data(#"{"kind":0,"laps":0,"countdown":true}"#.utf8)))
    }
    func testLeaderFinishLappedCarAndCooldownCrossing() throws {
        let context=try RacePitTests.Context(count:3);defer { context.close() }
        let road=context.road,g=road.geometry
        let last=try XCTUnwrap(g.mainSegments.last { g.segments[$0].raceFlags & 1 != 0 })
        let start=try XCTUnwrap(g.mainSegments.first { g.segments[$0].raceFlags & 2 != 0 })
        let middle=try XCTUnwrap(g.mainSegments.first { g.segments[$0].raceFlags == 0 })
        let position=TrackLocalPosition(segment:last,toStart:0,toRight:5)
        var race=try RaceProgress(positions:[position,position,position],targetLaps:2),time:Double=0
        try context.world.initializeProgress(segments:[last,last,last],target:2)
        func step(_ segments:[Int]) throws {
            time += 10
            let samples=segments.enumerated().map { id,segment in
                RaceLapSample(position:.init(segment:segment,toStart:0,toRight:5),speed:30,width:1.9,flags:race.timing[id].flags)
            }
            let original=try context.world.manageProgress(samples:samples.map { s in
                let p=s.position
                return RefRaceProgressSample(position:.init(segment:Int32(p.segment),mode:Int32(p.mode.rawValue),toStart:p.toStart,toRight:p.toRight,toMiddle:p.toMiddle,toLeft:p.toLeft),
                    speed:s.speed,width:s.width,flags:s.flags,collision:s.collision)
            },time:time)
            try race.update(samples:samples,time:time,road:road)
            XCTAssertEqual(race.order.indices,original.order);XCTAssertEqual(race.ended,original.state==4)
            for id in 0..<3 {
                RaceLapTimingTests.check(race.timing[id],original.cars[id].timing)
                XCTAssertEqual(race.gaps[id].behindLeader,original.cars[id].behindLeader)
                XCTAssertEqual(race.gaps[id].behindPrevious,original.cars[id].behindPrevious)
                XCTAssertEqual(race.gaps[id].beforeNext,original.cars[id].beforeNext)
                XCTAssertEqual(race.gaps[id].lapsBehindLeader,Int(original.cars[id].lapsBehindLeader))
            }
        }
        try step([start,start,start]);try step([middle,middle,middle]);try step([last,middle,middle]);try step([start,middle,middle])
        XCTAssertEqual(race.laps[0].count,1);XCTAssertFalse(race.finishing)
        try step([middle,middle,middle]);try step([last,middle,middle]);try step([start,middle,middle])
        XCTAssertTrue(race.finishing);XCTAssertTrue(race.timing[0].finished);XCTAssertFalse(race.ended)
        try step([middle,last,middle]);try step([middle,start,middle])
        XCTAssertTrue(race.timing[1].finished);XCTAssertEqual(race.laps[1].count,1)
        XCTAssertEqual(race.gaps[1].lapsBehindLeader,1);XCTAssertFalse(race.ended)
        try step([last,middle,middle]);try step([start,middle,middle])
        XCTAssertTrue(race.ended);XCTAssertTrue(race.timing[2].finished)
        XCTAssertEqual(race.laps.map(\.count),[2,1,0])
        let snapshot=race.laps
        try step([middle,last,last]);XCTAssertEqual(race.laps,snapshot)
    }
}
