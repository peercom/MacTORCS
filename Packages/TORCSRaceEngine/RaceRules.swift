// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 raceengine.cpp ReRaceRules.
// Copyright (C) 2002-2017 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSTrack

/// The original penalties, in the original order of the per-car tail queue.
public struct RacePenalty: Sendable, Equatable {
    public enum Kind: Int32, Sendable, Equatable { case driveThrough = 1, stopAndGo = 2 }
    public let kind: Kind
    /// The original grants five laps: the penalty must be served by this lap.
    public let lapToClear: Int
    public init(kind: Kind,lapToClear: Int) { self.kind=kind;self.lapToClear=lapToClear }
}

/// Original RM_PNST_* pit-rule progress for one car.
public struct RacePitRuleState: OptionSet,Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue=rawValue }
    public static let driveThrough=Self(rawValue:0x1)
    public static let stopAndGo=Self(rawValue:0x2)
    public static let stopAndGoServed=Self(rawValue:0x4)
    public static let speeding=Self(rawValue:0x10000)
    public static let illegalPitUse=Self(rawValue:0x20000)
}

/// Per-car state the original rules own across ticks: the rule progress, the
/// penalty queue and accumulated penalty time.
public struct RaceCarRules: Sendable, Equatable {
    public internal(set) var state: RacePitRuleState=[]
    public internal(set) var penalties: [RacePenalty]=[]
    public internal(set) var penaltyTime: Float=0
    public var firstPenalty: RacePenalty? { penalties.first }
    public init() {}
}

/// Everything ReRaceRules reads from a car. `publicSpeed` is the original total
/// speed and `longitudinalSpeed` the original `_speed_x`; the corner-cut penalty
/// uses the former and the pit speed limit the latter.
public struct RaceRulesSample: Sendable {
    public var position,previousPosition: TrackLocalPosition
    public var width,publicSpeed,longitudinalSpeed: Float
    public var currentLapTime: Double
    public var laps: Int
    public var flags,collision: UInt32
    public var skillLevel: Int
    public var human: Bool
    /// Original `_pitStopType`: 0 repair, 1 stop and go.
    public var pitStopType: Int32
    public init(position: TrackLocalPosition,previousPosition: TrackLocalPosition,width: Float,publicSpeed: Float=0,
                longitudinalSpeed: Float=0,currentLapTime: Double=0,laps: Int=0,flags: UInt32=0,collision: UInt32=0,
                skillLevel: Int=0,human: Bool=true,pitStopType: Int32=0) {
        self.position=position;self.previousPosition=previousPosition;self.width=width;self.publicSpeed=publicSpeed
        self.longitudinalSpeed=longitudinalSpeed;self.currentLapTime=currentLapTime;self.laps=laps
        self.flags=flags;self.collision=collision;self.skillLevel=skillLevel;self.human=human
        self.pitStopType=pitStopType
    }
}

/// ReRaceRules. The original runs it from ReManage after the start-line crossing
/// and before publishing lap time, distance and the previous position.
public struct RaceRules: Sendable {
    public let road: TrackRoad
    public var enabled: LapValidityRules
    public var session: RaceSessionKind
    public init(road: TrackRoad,enabled: LapValidityRules = .practice,session: RaceSessionKind = .practice) {
        self.road=road;self.enabled=enabled;self.session=session
    }

    /// The lateral distance past the inside border of a turn, and the original
    /// minimum radius the corner-cut penalty divides by. Pit entry and exit count
    /// as track on the pit side, so running wide there is not cutting.
    public static func cornerCut(position: TrackLocalPosition,road: TrackRoad) -> (border: Float,minimumRadius: Float) {
        let segment=road.geometry.segments[position.segment]
        guard segment.curve != .straight else { return (0,1) }
        let pits=road.pits
        var inPit=false
        if pits.type == .trackSide,let entry=pits.entry,let exit=pits.exit {
            let start=road.geometry.segments[entry].upstreamID,end=road.geometry.segments[exit].upstreamID
            let id=segment.upstreamID
            inPit=start<end ? id>=start && id<=end:id>=start || id<=end
        }
        if segment.curve == .left,!(inPit && pits.side == .left) { return (position.toLeft,segment.leftRadius) }
        if segment.curve == .right,!(inPit && pits.side == .right) { return (position.toRight,segment.rightRadius) }
        return (0,1)
    }

    /// The section the original applies to every car, before its skill gate: the
    /// lap-time elimination, wall-hit and corner-cut invalidation, and the
    /// race-only corner-cut time penalty. Returns the original car state.
    @discardableResult
    public func applyCommon(_ sample: RaceRulesSample,state: inout RaceCarRules,
                            commitBestLapTime: inout Bool) -> UInt32 {
        var flags=sample.flags
        // The original compares its float lap time against a double threshold and
        // exempts human drivers so an explorer can stop and look around.
        if Double(Float(sample.currentLapTime))>84.5+Double(road.length)/10,!sample.human {
            return flags | 0x800
        }
        guard flags & 0x100 == 0 else { return flags }
        if enabled.contains(.wallHit),commitBestLapTime,sample.collision & 2 != 0 { commitBestLapTime=false }
        let cut=Self.cornerCut(position:sample.position,road:road)
        let limit=sample.width*0.7
        if cut.border < -limit {
            if enabled.contains(.cornerCutting) { commitBestLapTime=false }
            if session == .race,enabled.contains(.cornerCuttingPenalty) {
                let radius=cut.minimumRadius-limit
                if radius>1 {
                    // The original accumulates in double and stores into a float.
                    let added=Double(sample.publicSpeed)*0.002*Double(-cut.border-limit)/Double(radius)
                    state.penaltyTime=Float(Double(state.penaltyTime)+added)
                }
            }
        }
        return flags
    }

    /// Complete ReRaceRules, including the rules the original applies only to
    /// skill level 3 and above: the penalty queue, the pit-lane rule progress and
    /// the pit speed limit.
    public func apply(_ sample: RaceRulesSample,state: inout RaceCarRules,
                      commitBestLapTime: inout Bool) throws -> UInt32 {
        let g=road.geometry
        guard g.segments.indices.contains(sample.position.segment),
              g.segments.indices.contains(sample.previousPosition.segment),
              [sample.width,sample.publicSpeed,sample.longitudinalSpeed].allSatisfy(\.isFinite),
              sample.width>0,sample.currentLapTime.isFinite,(0..<5).contains(sample.skillLevel) else {
            throw TrackError.invalid("Invalid race rules sample")
        }
        var flags=applyCommon(sample,state:&state,commitBestLapTime:&commitBestLapTime)
        if flags & 0x800 != 0 { return flags }
        // "Only for the pros": everything below is skipped for lower skill.
        guard sample.skillLevel>=3 else { return flags }
        if let penalty=state.penalties.first {
            // Too late to serve it: out of the race.
            if sample.laps>penalty.lapToClear { return flags | 0x800 }
        }
        let current=g.segments[g.effectiveSegment(sample.position)].raceFlags
        let previous=g.segments[g.effectiveSegment(sample.previousPosition)].raceFlags
        let inPits=flags & 0x1 != 0
        if previous & 0x80 != 0 {
            // Just entered the pit lane: a penalty may start being served.
            if current & 0x40 != 0,let penalty=state.penalties.first {
                switch penalty.kind {
                case .driveThrough:state.state.insert(.driveThrough)
                case .stopAndGo:state.state.insert(.stopAndGo)
                }
            }
        } else if previous & 0x40 != 0 {
            if current & 0x40 != 0 {
                if inPits {
                    if state.state.contains(.driveThrough) { state.state.remove(.driveThrough) }
                    else if state.state.contains(.stopAndGo) { state.state.insert(.stopAndGoServed) }
                } else if state.state.contains(.stopAndGoServed),sample.pitStopType != 1 {
                    // Served, but the stop was not a stop and go, so it does not
                    // count: the original clears both stop-and-go flags.
                    state.state.subtract([.stopAndGo,.stopAndGoServed])
                }
            } else if current & 0x100 != 0 {
                // Left the pit lane properly: clear a served penalty.
                // The original dereferences the queue head here; the rule flags
                // can only be set while a penalty exists, so an empty queue is
                // reported as no penalty to clear rather than read.
                if !state.state.isDisjoint(with:[.driveThrough,.stopAndGoServed]),!state.penalties.isEmpty {
                    state.penalties.removeFirst()
                }
                state.state=[]
            } else if !state.state.contains(.illegalPitUse) {
                // Left the pit lane anywhere else: a new stop and go.
                state.penalties.append(RacePenalty(kind:.stopAndGo,lapToClear:sample.laps+5))
                state.state=[.illegalPitUse]
            }
        } else if current & 0x100 != 0 {
            state.state=[]
        } else if current & 0x40 != 0,!state.state.contains(.illegalPitUse) {
            // Entered the pits other than through the pit entry.
            state.penalties.append(RacePenalty(kind:.stopAndGo,lapToClear:sample.laps+5))
            state.state=[.illegalPitUse]
        }
        if current & 0x8 != 0 {
            if state.state.isDisjoint(with:[.speeding,.illegalPitUse]),sample.longitudinalSpeed>road.pits.speedLimit {
                state.state.insert(.speeding)
                state.penalties.append(RacePenalty(kind:.driveThrough,lapToClear:sample.laps+5))
            }
        }
        return flags
    }
}
