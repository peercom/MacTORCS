// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSConfiguration
import TORCSReferenceSupport
import TORCSRaceEngine
import TORCSSimulation
import TORCSTelemetry
import TORCSTrack

final class RaceLapTimingTests: XCTestCase {
    static func check(_ n: RaceLapTiming,_ r: RefLapTiming,file: StaticString=#filePath,line: UInt=#line) {
        let a=[n.startTime,n.currentLapTime,n.lastLapTime,n.bestLapTime,n.deltaBestLapTime,n.totalTime,
               Double(n.topSpeed),Double(n.lapTopSpeed),Double(n.lapMinimumSpeed),Double(n.currentMinimumSpeed),Double(n.distanceFromStart),Double(n.distanceRaced),
               Double(n.laps),Double(n.remainingLaps),Double(n.backwardCrossings),Double(n.previousSegment),n.commitBestLapTime ? 1:0,Double(n.flags)]
        let b=[r.startTime,r.currentLapTime,r.lastLapTime,r.bestLapTime,r.deltaBestLapTime,r.totalTime,
               Double(r.topSpeed),Double(r.lapTopSpeed),Double(r.lapMinimumSpeed),Double(r.currentMinimumSpeed),Double(r.distanceFromStart),Double(r.distanceRaced),
               Double(r.laps),Double(r.remainingLaps),Double(r.backwardCrossings),Double(r.previousSegment),Double(r.commitBestLapTime),Double(r.flags)]
        for i in a.indices { XCTAssertEqual(a[i],b[i],"field \(i)",file:file,line:line) }
    }
    func testCrossingsReversalsInvalidationAndFinishAgainstOriginal() throws {
        let c=try RacePitTests.Context(count:1);defer { c.close() }
        let g=c.road.geometry,last=try XCTUnwrap(g.mainSegments.last { g.segments[$0].raceFlags & 1 != 0 }),start=try XCTUnwrap(g.mainSegments.first { g.segments[$0].raceFlags & 2 != 0 })
        let middle=try XCTUnwrap(g.mainSegments.first { g.segments[$0].raceFlags == 0 })
        var n=RaceLapTiming(initialPosition:.init(segment:last,toStart:0,toRight:5)),time:Double=0,records:[CompletedLap]=[],cases=0
        try c.world.initializeLaps(segment:last)
        func sample(_ segment:Int,collision:UInt32=0,finishing:Bool=false) throws {
            time += 13.173
            var p=TrackLocalPosition(segment:segment,toStart:0.25,toRight:5);p.toLeft=g.segments[segment].width-5
            let s=RaceLapSample(position:p,speed:Float(cases%7)-2,width:1.9,flags:n.flags,collision:collision)
            let r=try c.world.manageLaps(position:p,speed:s.speed,width:s.width,flags:s.flags,collision:collision,time:time,finishing:finishing)
            if let lap=try n.update(s,time:time,road:c.road,raceFinishing:finishing) { records.append(lap) }
            Self.check(n,r);cases += 1
        }
        try sample(start);XCTAssertEqual(n.laps,1);XCTAssertEqual(n.startTime,0)
        try sample(start);try sample(last);XCTAssertEqual(n.backwardCrossings,1)
        try sample(start);XCTAssertEqual(n.laps,1);XCTAssertEqual(n.backwardCrossings,0)
        try sample(middle,collision:2);try sample(last);try sample(start)
        XCTAssertEqual(records.count,1);XCTAssertFalse(records[0].valid);XCTAssertEqual(n.bestLapTime,0);XCTAssertEqual(records[0].time,time)
        for _ in 0..<4 { try sample(middle);try sample(last);try sample(start,collision:2) }
        XCTAssertEqual(records.count,5);XCTAssertTrue(records[1].valid);XCTAssertTrue(n.finished)
        XCTAssertTrue(n.commitBestLapTime) // Finish suppresses crossing-tick invalidation.
        try sample(middle);try sample(last);let previousTime=n.currentLapTime
        try sample(start);XCTAssertEqual(n.currentLapTime,previousTime);XCTAssertEqual(n.previousSegment,last)
        // Existing race-finishing state ends a car at its next forward crossing.
        try c.world.initializeLaps(segment:last,target:10)
        n=RaceLapTiming(initialPosition:.init(segment:last,toStart:0,toRight:5),targetLaps:10)
        try sample(start,finishing:true);XCTAssertTrue(n.finished);XCTAssertEqual(n.completedLaps,0)
        print("LAP_CROSSINGS samples=\(cases) fieldsEach=18 exact=1 authoredCompletedLaps=5")
    }
    func testCuttingThresholdsPitExemptionsAndRuleMasksAgainstOriginal() throws {
        var cases=0,invalid=0
        for side in ["left","right"] { for wrap in [false,true] {
            let c=try RacePitTests.Context(count:1,xml:TrackGeometryTests.infrastructureFixture(side:side,wrap:wrap,validMarkers:true));defer { c.close() }
            for segment in c.road.geometry.mainSegments {
                for rules:UInt32 in [0,1,2,3] { for edge in [-Float(1.9)*0.7,(-Float(1.9)*0.7).nextDown,(-Float(1.9)*0.7).nextUp,Float(-10)] {
                    for collision:UInt32 in [0,2] {
                        var p=TrackLocalPosition(segment:segment,toStart:0.125,toRight:edge);p.toLeft=edge
                        var n=RaceLapTiming(initialPosition:p)
                        try c.world.initializeLaps(segment:segment)
                        let r=try c.world.manageLaps(position:p,speed:27,width:1.9,collision:collision,time:9.273,rules:rules)
                        try n.update(.init(position:p,speed:27,width:1.9,collision:collision),time:9.273,road:c.road,rules:.init(rawValue:rules))
                        Self.check(n,r);cases += 1;if !n.commitBestLapTime { invalid += 1 }
                    }
                } }
            }
            c.close()
        } }
        XCTAssertGreaterThan(invalid,0);XCTAssertLessThan(invalid,cases)
        print("LAP_VALIDITY samples=\(cases) invalid=\(invalid) fieldsEach=18 exact=1")
    }
    func testActualPhysicsCrossingAgainstOriginal() throws {
        let content=try ReferenceContent(fixtures:XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)))
        let road=try ChassisTestContext.road()
        let params=try ParameterDocument.parse(Data(contentsOf:content.category)).merging(ParameterDocument.parse(Data(contentsOf:content.car)))
        var sim=try SingleVehicleSimulation(definition:VehicleDynamicsDefinition(parameters:params),road:road,startDistance:road.length-10)
        let world=try ReferenceWorld(track:content.track,car:content.car,category:content.category,startDistance:road.length-10)
        defer { world.close();withExtendedLifetime(content) {} }
        try sim.settle();try world.settle()
        var n=RaceLapTiming(initialPosition:sim.lifecycle.trackPosition),time:Double=0
        try world.initializeLaps(segment:sim.lifecycle.trackPosition.segment)
        for tick in 0..<5000 {
            let command=DriverCommand(throttle:tick<3000 ? 0.7:0,brake:tick<3000 ? 0:0.5,gear:1)
            try sim.step(command:command);try world.command(.init(throttle:command.throttle,brake:command.brake,steering:0,clutch:0,gear:1));try world.step()
            time += 0.002
            let life=sim.lifecycle
            let s=RaceLapSample(position:life.trackPosition,speed:life.publicBody.velocity.x,width:sim.vehicle.definition.chassis.runningGear.mass.dimensions.y,flags:life.flags,collision:life.publishedSimCollision)
            try n.update(s,time:time,road:road)
            let r=try world.manageLaps(position:s.position,speed:s.speed,width:s.width,time:time,usePublished:true)
            Self.check(n,r)
            let actual=VehicleTelemetry.values(sim.vehicle,track:road.geometry),expected=try world.sample()
            guard actual==expected else { XCTFail("Physics telemetry diverged at tick \(tick+1)");return }
        }
        XCTAssertEqual(n.laps,1);XCTAssertEqual(n.completedLaps,0)
        print("LAP_PHYSICS ticks=5000 timingScalars=90000 physicsScalars=710000 exact=1 forwardCrossings=1 completedLaps=0")
    }
}
