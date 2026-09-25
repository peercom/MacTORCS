// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 raceengine.cpp ReManage lap timing and human
// lap-validity rules. Copyright (C) 2002-2017 Eric Espie, Bernhard Wymann;
// original GPL-2.0-or-later attribution retained.
import Foundation
import TORCSTrack

public struct LapValidityRules: OptionSet,Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue=rawValue }
    public static let cornerCutting=Self(rawValue:1)
    public static let wallHit=Self(rawValue:2)
    /// Race-only: the original adds time instead of invalidating the lap.
    public static let cornerCuttingPenalty=Self(rawValue:4)
    public static let practice: Self=[.cornerCutting,.wallHit]
    public static let race: Self=[.cornerCutting,.wallHit,.cornerCuttingPenalty]
}
public struct CompletedLap: Sendable,Codable,Equatable {
    public let number: Int
    public let time: Double
    public let valid: Bool
    public let topSpeed,minimumSpeed: Float
}
public struct RaceLapSample: Sendable {
    public let position: TrackLocalPosition
    public let speed,width: Float
    public let flags,collision: UInt32
    /// Original total speed. Only the corner-cutting time penalty reads it.
    public let publicSpeed: Float
    public init(position: TrackLocalPosition,speed: Float,width: Float,flags: UInt32=0,collision: UInt32=0,
                publicSpeed: Float=0) {
        self.position=position;self.speed=speed;self.width=width;self.flags=flags;self.collision=collision
        self.publicSpeed=publicSpeed
    }
}
/// Single human car timing. Multi-car ordering/gaps, robot timeout and pit
/// penalties belong to the complete race controller, not this timing boundary.
public struct RaceLapTiming: Sendable {
    public private(set) var laps=0,remainingLaps: Int,backwardCrossings=0,previousSegment: Int
    public private(set) var startTime: Double=0,currentLapTime: Double=0,lastLapTime: Double=0,bestLapTime: Double=0,deltaBestLapTime: Double=0,totalTime: Double=0
    public private(set) var topSpeed: Float=0,lapTopSpeed: Float=0,lapMinimumSpeed: Float=0,currentMinimumSpeed: Float=0,distanceFromStart: Float=0,distanceRaced: Float=0
    public private(set) var commitBestLapTime=true
    public private(set) var flags: UInt32=0
    public var finished: Bool { flags & 0x100 != 0 }
    public var completedLaps: Int { max(0,laps-1) }
    // ReManage's post-finish crossing forces the remaining field to finish.
    mutating func finishWithField() { flags |= 0x100 }
    /// For a runtime that applies the complete ReRaceRules itself: the original
    /// clears the same flag from inside the rules, after the crossing reset.
    public mutating func invalidateLap() { commitBestLapTime=false }
    /// The complete rules can eliminate a car. The original writes the state onto
    /// the car, so the same tick's sorting and the enclosing runtime both see it.
    public mutating func applyRuleFlags(_ value: UInt32) { flags=value }
    public let targetLaps: Int
    public init(initialPosition: TrackLocalPosition,targetLaps: Int=5) {
        precondition((1...10000).contains(targetLaps))
        remainingLaps=targetLaps;self.targetLaps=targetLaps;previousSegment=initialPosition.segment
    }
    @discardableResult public mutating func update(_ sample: RaceLapSample,time: Double,road: TrackRoad,rules: LapValidityRules = .practice,raceFinishing: Bool=false) throws -> CompletedLap? {
        let p=sample.position,g=road.geometry
        guard g.segments.indices.contains(previousSegment),g.segments.indices.contains(p.segment),time.isFinite,
              [p.toStart,p.toRight,p.toLeft,sample.speed,sample.width].allSatisfy(\.isFinite),sample.width>0 else { throw TrackError.invalid("Invalid lap timing sample") }
        let old=g.segments[previousSegment],segment=g.segments[p.segment]
        flags=sample.flags
        topSpeed=max(topSpeed,sample.speed);lapTopSpeed=max(lapTopSpeed,sample.speed)
        if sample.speed<lapMinimumSpeed { lapMinimumSpeed=sample.speed;currentMinimumSpeed=sample.speed }
        var completed: CompletedLap?
        if previousSegment != p.segment {
            if old.raceFlags & 1 != 0,segment.raceFlags & 2 != 0 {
                if backwardCrossings==0 {
                    if !finished {
                        laps += 1;remainingLaps -= 1
                        if laps>1 {
                            lastLapTime=time-startTime;totalTime += lastLapTime
                            if bestLapTime != 0 { deltaBestLapTime=lastLapTime-bestLapTime }
                            if lastLapTime<bestLapTime || bestLapTime==0,commitBestLapTime { bestLapTime=lastLapTime }
                            completed=CompletedLap(number:laps-1,time:lastLapTime,valid:commitBestLapTime,topSpeed:lapTopSpeed,minimumSpeed:lapMinimumSpeed)
                            commitBestLapTime=true;startTime=Double(Float(time)) // Original tReCarInfo.sTime is tdble (Float).
                        }
                        lapTopSpeed=sample.speed;lapMinimumSpeed=sample.speed;currentMinimumSpeed=sample.speed
                        if remainingLaps<0 || raceFinishing { flags |= 0x100 }
                    } else { return nil } // Original early return leaves previous position/time untouched.
                } else { backwardCrossings -= 1 }
            }
            if old.raceFlags & 2 != 0,segment.raceFlags & 1 != 0 { backwardCrossings += 1 }
        }
        // ReRaceRules runs after crossing/reset and before publication of time.
        // Only its lap-validity half applies here; the corner-cut geometry is
        // shared with RaceRules, which owns the complete routine. A race runtime
        // that calls RaceRules.apply should pass no validity rules here so the
        // shared section is not applied twice.
        if !finished {
            if rules.contains(.wallHit),commitBestLapTime,sample.collision & 2 != 0 { commitBestLapTime=false }
            let border=RaceRules.cornerCut(position:p,road:road).border
            if border < -(sample.width*0.7),rules.contains(.cornerCutting) { commitBestLapTime=false }
        }
        previousSegment=p.segment;currentLapTime=time-startTime
        distanceFromStart=segment.distanceFromStart+(segment.curve == .straight ? p.toStart:p.toStart*segment.radius)
        distanceRaced=Float(laps-(backwardCrossings+1))*road.length+distanceFromStart
        return completed
    }
}
