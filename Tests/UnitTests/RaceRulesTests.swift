// SPDX-License-Identifier: GPL-2.0-only
// Native ReRaceRules port driven against the original routine with authored
// positions, so every rule branch is triggered deterministically.
import XCTest
import TORCSConfiguration
import TORCSRaceEngine
import TORCSTrack
import CReference
import TORCSReferenceSupport

final class RaceRulesTests:XCTestCase {
    private func road() throws -> TrackRoad { try ChassisTestContext.road() }
    private func world(cars:Int=1) throws -> (ReferenceContent,ReferenceWorld) {
        let content=try ReferenceContent(fixtures:try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)))
        let world=try ReferenceWorld(track:content.track,car:content.car,category:content.category,cars:cars)
        return (content,world)
    }
    private func sample(_ p:TrackLocalPosition,speed:Float,width:Float) -> RefRaceProgressSample {
        RefRaceProgressSample(position:RefTrackPosition(segment:Int32(p.segment),mode:Int32(p.mode.rawValue),
            toStart:p.toStart,toRight:p.toRight,toMiddle:p.toMiddle,toLeft:p.toLeft),speed:speed,width:width,flags:0,collision:0)
    }
    /// A turn outside the pit entry/exit range, where cutting is a real cut.
    private func turn(_ road:TrackRoad) throws -> Int {
        let g=road.geometry
        for index in g.mainSegments where g.segments[index].curve != .straight {
            if RaceRules.cornerCut(position:TrackLocalPosition(segment:index,toStart:0,toRight:0,toMiddle:0,toLeft:-10),
                                   road:road).minimumRadius>1 { return index }
        }
        throw TrackError.invalid("No usable turn")
    }
    private func firstSegment(_ road:TrackRoad,raceFlag:UInt32) throws -> Int {
        guard let index=road.geometry.segments.indices.first(where:{ road.geometry.segments[$0].raceFlags & raceFlag == raceFlag })
        else { throw TrackError.invalid("No segment carries flag \(raceFlag)") }
        return index
    }
    func testCornerCuttingTimePenaltyMatchesOriginal() throws {
        let road=try road(),(content,original)=try world()
        defer { original.close();withExtendedLifetime(content) {} }
        let index=try turn(road),segment=road.geometry.segments[index],width:Float=1.9
        // Well past the inside border, so the original accumulates penalty time.
        let inside=segment.curve == .left
        let over = -(width*0.7)-2.5
        let position=TrackLocalPosition(segment:index,toStart:0.5,
            toRight:inside ? segment.width-over:over,toMiddle:0,toLeft:inside ? over:segment.width-over,mode:.main)
        try original.initializeProgress(segments:[index],target:5)
        // Rule 4 is the race-only corner-cutting time penalty.
        try original.configureRules(4,raceType: .race,skill:3,human:false)
        var rules=RaceRules(road:road,enabled:[.cornerCuttingPenalty],session: .race)
        var state=RaceCarRules(),commit=true,time:Double=0
        let speeds:[Float]=[10,25,40,55,70]
        for step in 1...200 {
            let speed=speeds[step % speeds.count]
            time += 0.002
            try original.setPublicSpeed(speed,car:0)
            _=try original.manageProgress(samples:[sample(position,speed:speed,width:width)],time:time,rules:4)
            let native=RaceRulesSample(position:position,previousPosition:position,width:width,publicSpeed:speed,
                longitudinalSpeed:speed,currentLapTime:time,laps:1,flags:0,skillLevel:3,human:false)
            _=try rules.apply(native,state:&state,commitBestLapTime:&commit)
            let reference=try original.raceCarState(car:0)
            XCTAssertEqual(state.penaltyTime,reference.penaltyTime,"penalty time at step \(step)")
        }
        XCTAssertGreaterThan(state.penaltyTime,0,"the authored cut must accumulate penalty time")
        print("NATIVE_CORNER_CUT_PENALTY steps=200 penaltyTime=\(state.penaltyTime) matched=1")
    }
    func testCornerCuttingInvalidationInsteadOfPenaltyOutsideRace() throws {
        let road=try road(),index=try turn(road),segment=road.geometry.segments[index]
        let width:Float=1.9,inside=segment.curve == .left
        let over = -(width*0.7)-2.5
        let position=TrackLocalPosition(segment:index,toStart:0.5,
            toRight:inside ? segment.width-over:over,toMiddle:0,toLeft:inside ? over:segment.width-over,mode:.main)
        // Practice invalidates the lap and never accumulates time.
        var practice=RaceRules(road:road,enabled: .practice,session: .practice)
        var state=RaceCarRules(),commit=true
        let s=RaceRulesSample(position:position,previousPosition:position,width:width,publicSpeed:50,
            longitudinalSpeed:50,currentLapTime:1,laps:1,skillLevel:3,human:false)
        _=try practice.apply(s,state:&state,commitBestLapTime:&commit)
        XCTAssertFalse(commit,"practice invalidates a cut lap")
        XCTAssertEqual(state.penaltyTime,0,"practice never accumulates penalty time")
        // The race penalty bit alone does not invalidate the lap.
        var race=RaceRules(road:road,enabled:[.cornerCuttingPenalty],session: .race)
        var raceState=RaceCarRules(),raceCommit=true
        _=try race.apply(s,state:&raceState,commitBestLapTime:&raceCommit)
        XCTAssertTrue(raceCommit,"the penalty rule alone keeps the lap valid")
        XCTAssertGreaterThan(raceState.penaltyTime,0)
        print("NATIVE_CUT_MODES practiceInvalidated=1 racePenalty=\(raceState.penaltyTime)")
    }
    func testLapTimeEliminationMatchesOriginal() throws {
        let road=try road(),(content,original)=try world()
        defer { original.close();withExtendedLifetime(content) {} }
        let index=road.geometry.mainSegments[0]
        let position=TrackLocalPosition(segment:index,toStart:1,toRight:5,toMiddle:0,toLeft:5,mode:.main)
        try original.initializeProgress(segments:[index],target:5)
        try original.configureRules(3,raceType: .race,skill:3,human:false)
        // The original threshold is 84.5 s plus a tenth of the track length.
        let threshold=84.5+Double(road.length)/10
        var rules=RaceRules(road:road,enabled: .practice,session: .race)
        var state=RaceCarRules(),commit=true
        func native(_ time:Double,human:Bool) -> UInt32 {
            var local=state,localCommit=commit
            return rules.applyCommon(RaceRulesSample(position:position,previousPosition:position,width:1.9,
                publicSpeed:5,longitudinalSpeed:5,currentLapTime:time,laps:1,flags:0,skillLevel:3,human:human),
                state:&local,commitBestLapTime:&localCommit)
        }
        XCTAssertEqual(native(threshold-1,human:false) & 0x800,0,"below the threshold the car stays in")
        XCTAssertEqual(native(threshold+1,human:false) & 0x800,0x800,"above it a robot is eliminated")
        XCTAssertEqual(native(threshold+1,human:true) & 0x800,0,"a human driver is exempt")
        // ReManage publishes _curLapTime after calling ReRaceRules, so the rule
        // sees the previous tick's value: the first step only publishes it.
        _=try original.manageProgress(samples:[sample(position,speed:5,width:1.9)],time:threshold+1,rules:3)
        XCTAssertEqual(try original.raceCarState(car:0).eliminated,0,"the first step only publishes the lap time")
        _=try original.manageProgress(samples:[sample(position,speed:5,width:1.9)],time:threshold+1.002,rules:3)
        let reference=try original.raceCarState(car:0)
        XCTAssertEqual(reference.eliminated,1,"the original eliminates the slow robot on the next step")
        print("NATIVE_LAP_TIME_DNF threshold=\(threshold) robotEliminated=1 humanExempt=1")
    }
    func testPitLaneRuleStateAndSpeedLimitMatchOriginal() throws {
        let road=try road(),(content,original)=try world()
        defer { original.close();withExtendedLifetime(content) {} }
        let pitStart=try firstSegment(road,raceFlag:0x80)
        let pitLane=try firstSegment(road,raceFlag:0x40)
        let pitEnd=try firstSegment(road,raceFlag:0x100)
        XCTAssertNotEqual(road.pits.speedLimit,0,"the fixture must define a pit speed limit")
        func local(_ index:Int) -> TrackLocalPosition {
            let s=road.geometry.segments[index]
            return TrackLocalPosition(segment:index,toStart:0.5,toRight:s.width/2,toMiddle:0,toLeft:s.width/2,mode:.main)
        }
        try original.initializeProgress(segments:[pitStart],target:5)
        try original.configureRules(3,raceType: .race,skill:3,human:false)
        var rules=RaceRules(road:road,enabled: .practice,session: .race)
        var state=RaceCarRules(),commit=true
        let overLimit=road.pits.speedLimit+10
        let track=road.geometry.mainSegments[0]
        // ReManage carries the previous position forward itself, so the native
        // side must be given the same chain: each step's position becomes the
        // next step's previous position on both sides.
        var step=0,previous=pitStart
        func advance(to current:Int,speed:Float,flags:UInt32 = 0) throws {
            step += 1
            let time=Double(step)*0.002
            try original.setPublicSpeed(speed,car:0)
            var authored=sample(local(current),speed:speed,width:1.9)
            authored.flags=flags
            _=try original.manageProgress(samples:[authored],time:time,rules:3)
            let native=RaceRulesSample(position:local(current),previousPosition:local(previous),width:1.9,
                publicSpeed:speed,longitudinalSpeed:speed,currentLapTime:time,laps:0,flags:flags,skillLevel:3,human:false)
            _=try rules.apply(native,state:&state,commitBestLapTime:&commit)
            previous=current
            let reference=try original.raceCarState(car:0)
            XCTAssertEqual(state.state.rawValue,UInt32(bitPattern:Int32(reference.ruleState)),"rule state after step \(step)")
            XCTAssertEqual(state.penalties.count,Int(reference.penalties),"penalty count after step \(step)")
            XCTAssertEqual(state.penalties.first.map { Int($0.kind.rawValue) } ?? -1,Int(reference.firstPenalty),
                "first penalty after step \(step)")
            XCTAssertEqual(state.penalties.first.map(\.lapToClear) ?? -1,Int(reference.firstPenaltyLapToClear),
                "lap to clear after step \(step)")
        }
        // Entering the lane over the pit speed limit earns a drive-through.
        try advance(to:pitLane,speed:overLimit)
        XCTAssertTrue(state.state.contains(.speeding),"speeding must be recorded")
        XCTAssertEqual(state.penalties.first?.kind,.driveThrough)
        XCTAssertEqual(state.penalties.first?.lapToClear,5,"the original grants five laps from lap zero")
        // Leaving resets the progress but does not serve a penalty that did not
        // exist when the car entered the lane.
        try advance(to:pitEnd,speed:5)
        XCTAssertEqual(state.penalties.count,1,"a penalty issued on entry is not served on that pass")
        XCTAssertEqual(state.state,[],"the rule state resets at the exit")
        try advance(to:track,speed:40)
        // Coming back through the entry, now carrying the penalty, serves it.
        try advance(to:pitStart,speed:20)
        try advance(to:pitLane,speed:5)
        XCTAssertTrue(state.state.contains(.driveThrough),"the queued drive-through starts being served")
        try advance(to:pitEnd,speed:5)
        XCTAssertEqual(state.penalties.count,0,"a served drive-through is cleared at the exit")
        XCTAssertEqual(state.state,[],"the rule state resets at the exit")
        // Entering the lane other than through the entry is a new stop and go.
        try advance(to:track,speed:40)
        try advance(to:pitLane,speed:5)
        XCTAssertEqual(state.penalties.first?.kind,.stopAndGo)
        XCTAssertEqual(state.penalties.first?.lapToClear,5,"the original grants five laps")
        print("NATIVE_PIT_RULES steps=\(step) speedLimit=\(road.pits.speedLimit) matched=1")
    }
    /// The stop-and-go cycle and the original's refusal to count a stop that was
    /// not a stop and go. Each phase uses its own world: only one may be active.
    private func stopAndGoWalk(pitStopType:Int32) throws -> (RaceCarRules,Int) {
        let road=try road(),(content,original)=try world()
        defer { original.close();withExtendedLifetime(content) {} }
        let pitStart=try firstSegment(road,raceFlag:0x80)
        let pitLane=try firstSegment(road,raceFlag:0x40)
        let pitEnd=try firstSegment(road,raceFlag:0x100)
        let track=road.geometry.mainSegments[0]
        func local(_ index:Int) -> TrackLocalPosition {
            let s=road.geometry.segments[index]
            return TrackLocalPosition(segment:index,toStart:0.5,toRight:s.width/2,toMiddle:0,toLeft:s.width/2,mode:.main)
        }
        try original.initializeProgress(segments:[track],target:5)
        try original.configureRules(3,raceType: .race,skill:3,human:false)
        // The original reads _pitStopType when deciding whether a stop counted.
        try original.racePitCommand(car:0,command:0,setup:RefPitSetup(),fuel:0,repair:0,tires:false,
            stop:pitStopType,penalty:0)
        var rules=RaceRules(road:road,enabled: .practice,session: .race)
        var state=RaceCarRules(),commit=true,step=0,previous=track
        func advance(to current:Int,flags:UInt32 = 0) throws {
            step += 1
            let time=Double(step)*0.002
            try original.setPublicSpeed(5,car:0)
            var authored=sample(local(current),speed:5,width:1.9)
            authored.flags=flags
            _=try original.manageProgress(samples:[authored],time:time,rules:3)
            let native=RaceRulesSample(position:local(current),previousPosition:local(previous),width:1.9,
                publicSpeed:5,longitudinalSpeed:5,currentLapTime:time,laps:0,flags:flags,skillLevel:3,human:false,
                pitStopType:pitStopType)
            _=try rules.apply(native,state:&state,commitBestLapTime:&commit)
            previous=current
            let reference=try original.raceCarState(car:0)
            XCTAssertEqual(state.state.rawValue,UInt32(bitPattern:Int32(reference.ruleState)),
                "stop type \(pitStopType) rule state after step \(step)")
            XCTAssertEqual(state.penalties.count,Int(reference.penalties),
                "stop type \(pitStopType) penalty count after step \(step)")
            XCTAssertEqual(state.penalties.first.map { Int($0.kind.rawValue) } ?? -1,Int(reference.firstPenalty),
                "stop type \(pitStopType) first penalty after step \(step)")
        }
        // Enter the lane without using the entry: a stop and go.
        try advance(to:pitLane)
        XCTAssertEqual(state.penalties.first?.kind,.stopAndGo)
        try advance(to:pitEnd)
        XCTAssertEqual(state.penalties.count,1,"leaving does not serve a penalty issued on the way in")
        try advance(to:track)
        // Come back properly, carrying the stop and go.
        try advance(to:pitStart)
        try advance(to:pitLane)
        XCTAssertTrue(state.state.contains(.stopAndGo),"the queued stop and go starts being served")
        // Stop in the box.
        try advance(to:pitLane,flags:0x1)
        XCTAssertTrue(state.state.contains(.stopAndGoServed),"stopping in the box serves it")
        // Roll again without being in the pits: the original only keeps the
        // service if the stop really was a stop and go.
        try advance(to:pitLane)
        try advance(to:pitEnd)
        return (state,step)
    }
    func testStopAndGoServiceMatchesOriginal() throws {
        let (served,steps)=try stopAndGoWalk(pitStopType:1)
        XCTAssertEqual(served.penalties.count,0,"a stop-and-go stop clears the penalty at the exit")
        XCTAssertEqual(served.state,[],"the rule state resets at the exit")
        let (kept,_)=try stopAndGoWalk(pitStopType:0)
        XCTAssertEqual(kept.penalties.count,1,"a repair stop does not serve a stop and go")
        print("NATIVE_STOP_AND_GO steps=\(steps) servedCleared=1 repairStopKept=1 matched=1")
    }
    func testRulesRejectInvalidSamples() throws {
        let road=try road()
        var rules=RaceRules(road:road,session: .race)
        var state=RaceCarRules(),commit=true
        let valid=TrackLocalPosition(segment:road.geometry.mainSegments[0],toStart:0,toRight:5,mode:.main)
        for bad in [RaceRulesSample(position:valid,previousPosition:valid,width:0),
                    RaceRulesSample(position:valid,previousPosition:valid,width:1.9,publicSpeed: .nan),
                    RaceRulesSample(position:valid,previousPosition:valid,width:1.9,skillLevel:9)] {
            XCTAssertThrowsError(try rules.apply(bad,state:&state,commitBestLapTime:&commit))
        }
        print("NATIVE_RULES_BOUNDARIES rejected=3")
    }
}
