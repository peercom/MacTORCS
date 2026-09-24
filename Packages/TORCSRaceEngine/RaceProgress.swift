// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 ReManage and ReSortCars session progression.
// Copyright (C) 2002-2017 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import TORCSTrack

public struct RaceGap: Sendable,Equatable {
    public internal(set) var behindLeader: Double=0,behindPrevious: Double=0,beforeNext: Double=0
    public internal(set) var lapsBehindLeader=0
}

/// Timing consumes published physics in the preceding tick's race order. Car
/// identity stays stable across sorting; physics and drivers own no standings.
/// Pit admission/service and penalties must be applied by the enclosing engine.
public struct RaceProgress: Sendable {
    public private(set) var timing: [RaceLapTiming]
    public private(set) var laps: [[CompletedLap]]
    public private(set) var gaps: [RaceGap]
    public private(set) var order: RaceOrder
    public private(set) var finishing=false
    public var ended: Bool { order.allFinished }
    public init(positions: [TrackLocalPosition],targetLaps: Int) throws {
        guard (1...10000).contains(targetLaps) else { throw TrackError.invalid("Invalid race lap count") }
        order=try RaceOrder(carCount:positions.count)
        timing=positions.map { RaceLapTiming(initialPosition:$0,targetLaps:targetLaps) }
        laps=Array(repeating:[],count:positions.count);gaps=Array(repeating:RaceGap(),count:positions.count)
    }
    public mutating func update(samples: [RaceLapSample],time: Double,road: TrackRoad,rules: LapValidityRules = .practice) throws {
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
                flags:publishedFlags,collision:input.collision)
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
            if recross { finishField=true;for car in timing.indices { timing[car].finishWithField() } }
        }
        try order.update(distances:timing.map(\.distanceRaced),flags:timing.map(\.flags))
    }
}
