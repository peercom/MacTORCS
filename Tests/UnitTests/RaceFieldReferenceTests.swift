// SPDX-License-Identifier: GPL-2.0-only
// The multi-car original BT race oracle: original starting grid, ReOneStep for a
// field, per-car callbacks, ReRaceRules penalties and ReSortCars classification.
// This pins the oracle itself. Native comparisons belong to later increments.
import XCTest
import TORCSReferenceSupport

final class RaceFieldReferenceTests:XCTestCase {
    private func fixtures() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil))
    }
    /// initStartingGrid's own arithmetic, recomputed independently here:
    /// startpos = length − (toStart + (i/rows)·columnDistance + (i%rows)·columnOffset)
    /// toRight  = a + b·((i%rows)+1)/(rows+1), with a/b selected by the pole side.
    private func expectedGrid(cars:Int,grid:ReferenceStartingGrid,width:Float,poleLeft:Bool)
        -> [(distanceFromEnd:Float,toRight:Float)] {
        let rows=max(1,grid.rows)
        let a:Float=poleLeft ? width:0, b:Float=poleLeft ? -width:width
        return (0..<cars).map { i in
            (grid.toStart+Float(i/rows)*grid.columnDistance+Float(i%rows)*grid.columnOffset,
             a+b*Float(i%rows+1)/Float(rows+1))
        }
    }
    func testOriginalStartingGridMatchesUpstreamArithmetic() throws {
        let fixtures=try fixtures()
        var report:[String]=[]
        // Aalborg's first turn is a right-hander, so the original default pole
        // side is right. Both explicit overrides are exercised as well.
        for (cars,grid,pole) in [(3,ReferenceStartingGrid.quickRace,nil as Bool?),
                                 (5,ReferenceStartingGrid.codeDefaults,nil),
                                 (4,ReferenceStartingGrid(rows:1,toStart:30,columnDistance:15,columnOffset:0),nil),
                                 (6,ReferenceStartingGrid(rows:3,toStart:20,columnDistance:18,columnOffset:6),false),
                                 (6,ReferenceStartingGrid(rows:3,toStart:20,columnDistance:18,columnOffset:6),true)] {
            var configuration=grid;configuration.poleLeft=pole
            let content=try ReferenceContent(fixtures:fixtures,bt:true,drivers:cars)
            let world=try ReferenceWorld(track:content.track,car:content.car,category:content.category,
                cars:cars,btDirectory:content.directory,laps:1,grid:configuration)
            defer { world.close() }
            let width=Float(world.trackWidth),length=Float(world.trackLength)
            let expected=expectedGrid(cars:cars,grid:configuration,width:width,poleLeft:pole ?? false)
            for car in 0..<cars {
                let slot=try world.gridSlot(car:car)
                XCTAssertEqual(slot.position.toRight,expected[car].toRight,accuracy:1e-4,"car \(car) lateral slot")
                XCTAssertEqual(slot.speed,configuration.initialSpeed,"car \(car) initial speed")
                // Distance along the track is recovered from the segment the
                // original walked back to, so this checks the walk as well.
                let segment=try world.trackGeometry().segments[Int(slot.position.segment)]
                let along=segment.distanceFromStart+(segment.curve == .straight ? slot.position.toStart
                    :slot.position.toStart*segment.radius)
                XCTAssertEqual(along,length-expected[car].distanceFromEnd,accuracy:2e-2,"car \(car) grid distance")
                XCTAssertEqual(slot.position.mode,0,"grid slots are main-track positions")
            }
            // Successive rows never share a slot, and the pole sits ahead.
            let distances=(0..<cars).map { expected[$0].distanceFromEnd }
            XCTAssertEqual(distances,distances.sorted(),"grid order must run back from the line")
            report.append("cars=\(cars) rows=\(configuration.rows) pole=\(pole.map { $0 ? "left":"right" } ?? "default")")
        }
        print("ORIGINAL_STARTING_GRID cases=\(report.count) \(report.joined(separator:" | "))")
    }
    func testOriginalFieldStepsEveryCarAndRepeatsExactly() throws {
        let fixtures=try fixtures()
        let cars=3,ticks=1500
        var captures:[[[String:Double]]]=[],finals:[[Double]]=[]
        for _ in 0..<2 {
            let content=try ReferenceContent(fixtures:fixtures,bt:true,drivers:cars)
            let world=try ReferenceWorld(track:content.track,car:content.car,category:content.category,
                cars:cars,btDirectory:content.directory,laps:1,grid: .quickRace)
            for car in 0..<cars {
                let initial=try world.robotStatus(car:car)
                XCTAssertEqual(initial.newTrackCalls,1,"car \(car) newTrack")
                XCTAssertEqual(initial.newRaceCalls,1,"car \(car) newRace")
                XCTAssertEqual(initial.driveCalls,0);XCTAssertEqual(initial.time,-2)
                XCTAssertEqual(Int(initial.position),car+1,"grid order sets the initial position")
            }
            var records:[[String:Double]]=[],calls=Array(repeating:UInt64(0),count:cars)
            for tick in 1...ticks {
                // ReOneStep holds RM_RACE_PRESTART (0x10) for the two-second
                // countdown, then resynchronizes to RM_RACE_RUNNING (0x1).
                let expected=tick<1000 ? 0x10:0x1
                XCTAssertEqual(try world.stepRace(),expected,"original race state at tick \(tick)")
                for car in 0..<cars {
                    let state=try world.robotStatus(car:car)
                    guard state.driveCalls>calls[car] else { continue }
                    XCTAssertEqual(state.driveCalls,calls[car]+1,"car \(car) callback count")
                    XCTAssertEqual(state.lastDriveTick,UInt64(tick),"car \(car) callback tick")
                    var input=try world.robotInput(car:car)
                    XCTAssertEqual(input.count,142)
                    input["car"]=Double(car)
                    input["raw.steering"]=Double(state.steering);input["raw.throttle"]=Double(state.throttle)
                    input["raw.brake"]=Double(state.brake);input["raw.gear"]=Double(state.gear)
                    records.append(input);calls[car]=state.driveCalls
                }
            }
            // Every car is driven by the original scheduler in the same block.
            XCTAssertEqual(Set(calls).count,1,"all cars receive the same callback count")
            // The original scheduler starts calling robots inside the countdown
            // once 0.02 s has elapsed since _reLastTime, so the count exceeds
            // the post-countdown driving time alone.
            XCTAssertGreaterThan(calls[0],90)
            var final:[Double]=[]
            for car in 0..<cars {
                let sample=try world.sample(car:car)
                for key in sample.keys.sorted() { final.append(sample[key]!) }
            }
            finals.append(final)
            captures.append(records)
            world.close()
        }
        XCTAssertEqual(captures[0],captures[1],"the field oracle must repeat exactly")
        XCTAssertEqual(finals[0],finals[1],"final field physics must repeat exactly")
        // Cars start from different grid slots, so their commands must differ.
        let perCar=Dictionary(grouping:captures[0]) { $0["car"] ?? -1 }
        XCTAssertEqual(perCar.count,cars)
        XCTAssertNotEqual(perCar[0]!.map { $0["position.y"] },perCar[1]!.map { $0["position.y"] },
            "grid slots must produce distinct trajectories")
        XCTAssertFalse(perCar[0]!.contains { $0["position.y"]==nil },"captured inputs must carry published positions")
        print("ORIGINAL_FIELD cars=\(cars) ticks=\(ticks) callbacksPerCar=\(captures[0].count/cars) repeated=2 exact=1")
    }
    func testOriginalRaceRulesProduceCornerCuttingPenalties() throws {
        let content=try ReferenceContent(fixtures:try fixtures(),bt:true,drivers:2)
        let world=try ReferenceWorld(track:content.track,car:content.car,category:content.category,
            cars:2,btDirectory:content.directory,laps:1,grid: .quickRace)
        defer { world.close() }
        // Rule 4 is the race-only corner-cutting time penalty. ReRaceRules gates
        // both the penalty list and the lap-time DNF rule on skill 3 and a robot.
        try world.configureRules(4,raceType: .race,skill:3,human:false)
        for car in 0..<2 {
            let state=try world.raceCarState(car:car)
            XCTAssertEqual(state.penaltyTime,0);XCTAssertEqual(state.penalties,0)
            XCTAssertEqual(state.ruleState,0);XCTAssertEqual(state.eliminated,0)
        }
        for _ in 1...1500 { XCTAssertGreaterThanOrEqual(try world.stepRace(),0) }
        // The original DNF rule eliminates a non-human car whose lap exceeds
        // 84.5 s + length/10; 1500 ticks is far below that, so nobody is out.
        for car in 0..<2 {
            let state=try world.raceCarState(car:car)
            XCTAssertEqual(state.eliminated,0,"car \(car) must not be eliminated this early")
            XCTAssertGreaterThanOrEqual(state.penaltyTime,0)
            XCTAssertEqual(state.firstPenalty,-1,"BT drivers take no pit-rule penalty on the opening lap")
        }
        XCTAssertEqual(try world.classification().sorted(),[0,1])
        print("ORIGINAL_RACE_RULES cars=2 rules=4 raceType=race skill=3 eliminated=0")
    }
    func testOriginalFieldClassificationFollowsReSortCars() throws {
        let content=try ReferenceContent(fixtures:try fixtures(),bt:true,drivers:3)
        let world=try ReferenceWorld(track:content.track,car:content.car,category:content.category,
            cars:3,btDirectory:content.directory,laps:1,grid: .quickRace)
        defer { world.close() }
        XCTAssertEqual(try world.classification(),[0,1,2],"the grid order is the initial classification")
        var distances:[[Double]]=[]
        for tick in 1...2500 {
            try world.stepRace()
            guard tick % 500 == 0 else { continue }
            let order=try world.classification()
            XCTAssertEqual(order.sorted(),[0,1,2],"classification is a permutation of stable car indices")
            var raced:[Double]=[]
            for car in order { raced.append(try world.robotStatus(car:car).distance) }
            // ReSortCars orders running cars by distance raced, leader first.
            XCTAssertEqual(raced,raced.sorted(by:>),"order must be non-increasing in distance raced")
            for slot in order.indices {
                XCTAssertEqual(Int(try world.raceCarState(car:order[slot]).position),slot+1,"published position matches the slot")
            }
            distances.append(raced)
        }
        print("ORIGINAL_FIELD_CLASSIFICATION cars=3 samples=\(distances.count) leaderDistance=\(distances.last![0])")
    }
}
