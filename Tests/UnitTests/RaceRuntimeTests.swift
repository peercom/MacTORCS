// SPDX-License-Identifier: GPL-2.0-only
// The authoritative native race runtime: ReOneStep order over a native field,
// with the original clock, robot scheduling, pit management, timing, complete
// rules and sorting. Trajectory parity with the original is not claimed here.
import XCTest
import TORCSConfiguration
import TORCSRaceEngine
import TORCSSimulation
import TORCSTrack
import TORCSReferenceSupport

final class RaceRuntimeTests:XCTestCase {
    private func parameters() throws -> ParameterDocument {
        let fixtures=try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil))
        return try ParameterDocument.parse(Data(contentsOf:fixtures.appendingPathComponent("Track-4WD-GrB.xml")))
            .merging(ParameterDocument.parse(Data(contentsOf:fixtures.appendingPathComponent("155-DTM.xml"))))
    }
    private func runtime(cars:Int,laps:Int,human:Int? = nil,kind:RaceSessionKind = .race) throws -> RaceRuntime {
        let p=try parameters()
        let entries=(0..<cars).map { index in
            RaceEntry(parameters:p,kind:index==human ? .human:.bt,team:"bt",skillLevel:3)
        }
        return try RaceRuntime(road:try ChassisTestContext.road(),entries:entries,grid:try .quickRace(),
            configuration:try RaceSessionConfiguration(kind:kind,laps:laps,countdown:true))
    }
    /// A short run is enough to cover the clock, scheduling, physics, pits,
    /// timing, rules and sorting together, and to compare two runs exactly.
    func testNativeRaceRepeatsExactly() throws {
        let ticks=3000
        var states:[[String]]=[]
        for _ in 0..<2 {
            var race=try runtime(cars:3,laps:2)
            for _ in 1...ticks { try race.step() }
            var lines:[String]=[]
            for car in 0..<race.carCount {
                let timing=race.progress.timing[car],rules=race.progress.carRules[car]
                let life=race.simulation.lifecycle[car]
                lines.append("""
                car\(car) drives=\(race.driveCalls[car]) pits=\(race.pitCalls[car]) laps=\(timing.laps) \
                distance=\(timing.distanceRaced) lapTime=\(timing.currentLapTime) valid=\(timing.commitBestLapTime) \
                flags=\(timing.flags) penalties=\(rules.penalties.count) penaltyTime=\(rules.penaltyTime) \
                state=\(rules.state.rawValue) fuel=\(race.simulation.cars[car].fuel) \
                damage=\(race.simulation.cars[car].damage) x=\(life.publicWorld.position.x) y=\(life.publicWorld.position.y)
                """)
            }
            lines.append("order=\(race.classification) time=\(race.raceTime) tick=\(race.simulation.tick)")
            states.append(lines)
        }
        XCTAssertEqual(states[0],states[1],"the native race must repeat exactly")
        print("NATIVE_RACE_REPEAT cars=3 ticks=\(ticks) exact=1")
    }
    /// The original schedules every robot on the same 0.02 s comparison, so the
    /// callback count over a tick range is a property of the clock, not the
    /// trajectory: it must equal the original harness's count for the same range.
    func testRobotSchedulingMatchesOriginalCadence() throws {
        let ticks=1500
        var race=try runtime(cars:3,laps:2)
        XCTAssertEqual(race.phase, .prestart)
        XCTAssertEqual(race.raceTime,-2)
        var prestartTicks=0
        for tick in 1...ticks {
            try race.step()
            if race.phase == .prestart { prestartTicks += 1 }
            XCTAssertEqual(race.phase,tick<1000 ? .prestart: .running,"phase at tick \(tick)")
        }
        // The G1 oracle records 98 callbacks per car over the same 1,500 ticks,
        // including the ones the original issues inside the countdown.
        XCTAssertEqual(Set(race.driveCalls).count,1,"every car is called in the same block")
        XCTAssertEqual(race.driveCalls[0],98,"original callback cadence over 1,500 ticks")
        XCTAssertEqual(prestartTicks,999,"the countdown holds for the original two seconds")
        print("NATIVE_RACE_SCHEDULE cars=3 ticks=\(ticks) callbacksPerCar=\(race.driveCalls[0]) prestartTicks=\(prestartTicks)")
    }
    func testNativeRaceCompletesAndClassifies() throws {
        var race=try runtime(cars:2,laps:1)
        var ticks=0
        while !race.ended,ticks<120_000 { try race.step();ticks += 1 }
        XCTAssertTrue(race.ended,"the race must finish within the tick budget")
        let result=try XCTUnwrap(race.result)
        XCTAssertEqual(result.reason, .completed)
        XCTAssertEqual(result.classification.sorted(),[0,1],"classification is a permutation of the field")
        XCTAssertEqual(result.cars.count,2)
        for car in result.cars {
            XCTAssertTrue(car.finished,"car \(car.car) must have finished")
            XCTAssertEqual(car.laps,1,"car \(car.car) completed lap count")
            XCTAssertGreaterThan(car.totalTime,0)
            XCTAssertGreaterThan(car.completedLaps.count,0)
        }
        // Positions follow the final order.
        for (slot,car) in result.classification.enumerated() {
            XCTAssertEqual(result.cars[car].position,slot+1,"published position for car \(car)")
        }
        XCTAssertEqual(result.cars[result.classification[0]].behindLeader,0,"the leader has no gap")
        let times=result.cars.map { String(format:"%.3f",$0.totalTime) }
        print("NATIVE_RACE_COMPLETE cars=2 laps=1 ticks=\(ticks) order=\(result.classification) times=\(times)")
    }
    /// The runtime passes no validity mask to lap timing, so the complete rules
    /// are the only path that can invalidate a lap. Observing an invalidation
    /// therefore proves the rules are wired into the runtime.
    ///
    /// Measured: this driver never cuts past the original 0.7-car-width threshold
    /// on Aalborg, so its race penalty time stays zero. Its laps are invalid for
    /// the other reason the original gives — striking the scenery — which is why
    /// the upstream reference lap is invalid too. The penalty arithmetic itself is
    /// compared against the original in RACE_RULES.md.
    func testCompleteRulesAreWiredIntoTheRuntime() throws {
        var race=try runtime(cars:1,laps:2,kind: .race)
        XCTAssertTrue(race.rules.enabled.contains(.cornerCuttingPenalty),"a race enables the original time penalty")
        XCTAssertEqual(race.rules.session, .race)
        var ticks=0,invalidated=false,collision:UInt32=0
        while ticks<60_000,!invalidated {
            try race.step();ticks += 1
            if !race.progress.timing[0].commitBestLapTime {
                invalidated=true;collision=race.simulation.lifecycle[0].publishedCollision
            }
        }
        XCTAssertTrue(invalidated,"the rules must invalidate this driver's lap within a lap")
        XCTAssertNotEqual(collision & 2,0,"the original wall-hit rule is what invalidated it")
        let penalty=race.progress.carRules[0].penaltyTime
        var practice=try runtime(cars:1,laps:2,kind: .practice)
        XCTAssertFalse(practice.rules.enabled.contains(.cornerCuttingPenalty),"practice never accumulates time")
        for _ in 1...ticks { try practice.step() }
        XCTAssertEqual(practice.progress.carRules[0].penaltyTime,0,"practice accumulates no penalty time")
        print("NATIVE_RACE_RULES_WIRED invalidatedAtTick=\(ticks) collision=\(collision) racePenaltySeconds=\(penalty)")
    }
    func testHumanEntryIsDrivenAtTheRobotCadence() throws {
        var race=try runtime(cars:3,laps:2,human:1)
        XCTAssertEqual(race.kinds,[.bt,.human,.bt])
        XCTAssertTrue(race.profiles[1].human,"the human entry is exempt from the lap-time rule")
        XCTAssertNil(race.drivers[1],"the human car has no robot policy")
        let start=race.progress.timing[1].distanceFromStart
        for _ in 1...2000 { try race.step(humanCommand:DriverCommand(throttle:1,gear:1)) }
        // Every car is scheduled together, human included.
        XCTAssertEqual(Set(race.driveCalls).count,1)
        XCTAssertGreaterThan(race.driveCalls[1],0)
        // The human car moved under the command the caller supplied. Distance
        // raced stays negative until the first crossing, as it does upstream,
        // so progress is measured along the track instead.
        let speed=race.simulation.lifecycle[1].publicSpeed
        XCTAssertGreaterThan(speed,1,"the human car accelerates on its own command")
        XCTAssertGreaterThan(race.progress.timing[1].distanceFromStart,start,"the human car advanced")
        print("NATIVE_RACE_HUMAN cars=3 humanCar=1 callbacks=\(race.driveCalls[1]) speed=\(speed)")
    }
    func testRuntimeRejectsInvalidFields() throws {
        let p=try parameters(),road=try ChassisTestContext.road()
        let configuration=try RaceSessionConfiguration(kind: .race,laps:1,countdown:true)
        // Two human cars, and an out-of-range skill level.
        XCTAssertThrowsError(try RaceRuntime(road:road,
            entries:[RaceEntry(parameters:p,kind: .human),RaceEntry(parameters:p,kind: .human)],
            grid:try .quickRace(),configuration:configuration))
        XCTAssertThrowsError(try RaceRuntime(road:road,
            entries:[RaceEntry(parameters:p,kind: .bt,skillLevel:9)],
            grid:try .quickRace(),configuration:configuration))
        XCTAssertThrowsError(try RaceRuntime(road:road,entries:[],grid:try .quickRace(),configuration:configuration))
        print("NATIVE_RACE_BOUNDARIES rejected=3")
    }
}
