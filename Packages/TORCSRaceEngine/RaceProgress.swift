// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 ReManage and ReSortCars session progression.
// Copyright (C) 2002-2017 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import TORCSTrack

public struct RaceGap: Sendable,Equatable {
    public internal(set) var behindLeader: Double=0,behindPrevious: Double=0,beforeNext: Double=0
    public internal(set) var lapsBehindLeader=0
}

/// What ReRaceRules gates its professional rules and lap-time elimination on.
public struct RaceDriverProfile: Sendable,Equatable {
    public var skillLevel: Int
    public var human: Bool
    /// Original `_pitStopType`: 0 repair, 1 stop and go.
    public var pitStopType: Int32
    public init(skillLevel: Int = 3,human: Bool = false,pitStopType: Int32 = 0) {
        self.skillLevel=skillLevel;self.human=human;self.pitStopType=pitStopType
    }
}

/// Timing consumes published physics in the preceding tick's race order. Car
/// identity stays stable across sorting; physics and drivers own no standings.
/// Pit admission and service must be applied by the enclosing engine; penalties
/// are applied here when a runtime supplies the complete rules.
public struct RaceProgress: Sendable {
    public private(set) var timing: [RaceLapTiming]
    public private(set) var laps: [[CompletedLap]]
    public private(set) var gaps: [RaceGap]
    public private(set) var order: RaceOrder
    public private(set) var finishing=false
    /// Per-car ReRaceRules state, populated only when a runtime supplies the
    /// complete rules. Mirrors the original per-car tRmCarRules and penalty list.
    public private(set) var carRules: [RaceCarRules]
    /// The original tReCarInfo.prevTrkPos: ReRaceRules reads the whole previous
    /// position, while lap timing needs only its segment.
    public private(set) var previousPositions: [TrackLocalPosition]
    public var ended: Bool { order.allFinished }
    public init(positions: [TrackLocalPosition],targetLaps: Int) throws {
        guard (1...10000).contains(targetLaps) else { throw TrackError.invalid("Invalid race lap count") }
        order=try RaceOrder(carCount:positions.count)
        timing=positions.map { RaceLapTiming(initialPosition:$0,targetLaps:targetLaps) }
        laps=Array(repeating:[],count:positions.count);gaps=Array(repeating:RaceGap(),count:positions.count)
        carRules=Array(repeating:RaceCarRules(),count:positions.count)
        previousPositions=positions
    }
    /// `raceRules` applies the complete original routine, including penalties. It
    /// runs where ReManage runs it: after the crossing, which may have reset the
    /// lap-validity flag and raised the lap count, and before the previous
    /// position and lap time are published, which it reads from the last tick.
    /// Supplying it makes `rules` redundant, so pass no validity rules then.
    public mutating func update(samples: [RaceLapSample],time: Double,road: TrackRoad,rules: LapValidityRules = .practice,
                                raceRules: RaceRules? = nil,profiles: [RaceDriverProfile]? = nil) throws {
        guard profiles.map({ $0.count==timing.count }) ?? true else {
            throw TrackError.invalid("One driver profile is required per car")
        }
        guard samples.count==timing.count,time.isFinite,
            samples.allSatisfy({ road.geometry.segments.indices.contains($0.position.segment) &&
                [$0.position.toStart,$0.position.toRight,$0.position.toLeft,$0.speed,$0.width].allSatisfy(\.isFinite) && $0.width>0 }),
            timing.allSatisfy({road.geometry.segments.indices.contains($0.previousSegment)}) else {
            throw TrackError.invalid("Invalid race progress samples")
        }
        guard !ended else { return }
        var finishField=false
        let previousOrder=order.indices,leader=previousOrder[0]
        for (slot,id) in previousOrder.enumerated() {
            let input=samples[id],old=timing[id],segments=road.geometry.segments
            let publishedFlags=input.flags | (finishField ? 0x100:0)
            let recross=publishedFlags & 0x100 != 0 && old.backwardCrossings==0 && old.previousSegment != input.position.segment &&
                segments[old.previousSegment].raceFlags & 1 != 0 && segments[input.position.segment].raceFlags & 2 != 0
            let sample=RaceLapSample(position:input.position,speed:input.speed,width:input.width,
                flags:publishedFlags,collision:input.collision,publicSpeed:input.publicSpeed)
            // Captured before the crossing publishes them: the rules read the
            // previous tick's lap time and previous position.
            let previousLapTime=old.currentLapTime,previousPosition=previousPositions[id]
            if let lap=try timing[id].update(sample,time:time,road:road,rules:rules,raceFinishing:finishing) {
                laps[id].append(lap)
                if slot==0 { gaps[id].behindLeader=0;gaps[id].behindPrevious=0;gaps[id].lapsBehindLeader=0 }
                else {
                    let previous=previousOrder[slot-1]
                    gaps[id].behindLeader=timing[id].totalTime-timing[leader].totalTime
                    gaps[id].lapsBehindLeader=timing[leader].laps-timing[id].laps
                    gaps[id].behindPrevious=timing[id].totalTime-timing[previous].totalTime
                    gaps[previous].beforeNext=gaps[id].behindPrevious
                }
            }
            if timing[id].finished,publishedFlags & 0x100 == 0 { finishing=true }
            // The original returns from ReManage before the rules and before
            // publishing the previous position when a finished car crosses again.
            if !recross {
                if let raceRules {
                    let profile=profiles?[id] ?? RaceDriverProfile()
                    var commit=timing[id].commitBestLapTime
                    let ruleSample=RaceRulesSample(position:input.position,previousPosition:previousPosition,
                        width:input.width,publicSpeed:input.publicSpeed,longitudinalSpeed:input.speed,
                        currentLapTime:previousLapTime,laps:timing[id].laps,flags:timing[id].flags,
                        collision:input.collision,skillLevel:profile.skillLevel,human:profile.human,
                        pitStopType:profile.pitStopType)
                    let flags=try raceRules.apply(ruleSample,state:&carRules[id],commitBestLapTime:&commit)
                    if !commit,timing[id].commitBestLapTime { timing[id].invalidateLap() }
                    if flags != timing[id].flags { timing[id].applyRuleFlags(flags) }
                }
                previousPositions[id]=input.position
            }
            if recross { finishField=true;for car in timing.indices { timing[car].finishWithField() } }
        }
        try order.update(distances:timing.map(\.distanceRaced),flags:timing.map(\.flags))
    }
}
