// SPDX-License-Identifier: GPL-2.0-only
// Clock and ordering semantically ported from TORCS 1.3.9 raceengine.cpp.
// Copyright (C) 2002-2017 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSCore
import TORCSTrack

public struct RaceSessionConfiguration: Sendable, Equatable, Codable {
    public let kind: RaceSessionKind
    public let laps: Int
    public let countdown: Bool
    public init(kind: RaceSessionKind = .practice,laps: Int = 5,countdown: Bool = true) throws {
        guard (1...10000).contains(laps) else { throw TrackError.invalid("Session laps must be 1…10000") }
        self.kind=kind;self.laps=laps;self.countdown=countdown
    }
    private enum CodingKeys: String,CodingKey { case kind,laps,countdown }
    public init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        try self.init(kind:c.decode(RaceSessionKind.self,forKey:.kind),laps:c.decode(Int.self,forKey:.laps),countdown:c.decode(Bool.self,forKey:.countdown))
    }
}

/// ReRaceStart begins at -2; ReOneStep adds the fixed step then resets to zero
/// on the first nonnegative tick. Presentation/pause clocks never alter this.
public struct RaceStartClock: Sendable {
    public private(set) var time: Double
    public private(set) var prestart: Bool
    public init(countdown: Bool) { time=countdown ? -2:0;prestart=countdown }
    public mutating func step() {
        time += FixedStepClock.step
        if prestart,time>=0 { prestart=false;time=0 }
    }
}

/// Stable car identities are distinct from current race positions. This retains
/// ReSortCars' strict comparison, ties, and asymmetric finished-car handling.
public struct RaceOrder: Sendable {
    public private(set) var indices: [Int]
    public private(set) var allFinished=false
    public init(carCount: Int) throws {
        guard (1...16).contains(carCount) else { throw TrackError.invalid("Race requires 1…16 cars") }
        indices=Array(0..<carCount)
    }
    public mutating func update(distances: [Float],flags: [UInt32]) throws {
        guard distances.count==indices.count,flags.count==indices.count,distances.allSatisfy(\.isFinite) else {
            throw TrackError.invalid("Invalid race classification samples")
        }
        allFinished=flags[indices[0]] & 0x100 != 0
        for i in 1..<indices.count {
            var j=i
            while j>0 {
                if flags[indices[j]] & 0x100 == 0 {
                    allFinished=false
                    if distances[indices[j]]>distances[indices[j-1]] {
                        indices.swapAt(j,j-1);j -= 1;continue
                    }
                }
                break
            }
        }
    }
}

public enum DrivingSessionPhase: String,Sendable,Codable { case prestart,running,results }
public enum SessionEndReason: String,Sendable,Codable { case completed,retired,endedEarly }

/// Immutable results remain available after restart, and can be exported without
/// reading or mutating a live simulation. Invalid laps never supply a best time.
public struct DrivingSessionResult: Sendable,Codable,Equatable {
    public let schema: Int
    public let configuration: RaceSessionConfiguration
    public let reason: SessionEndReason
    public let elapsed: Double
    public let laps: [CompletedLap]
    public let bestLap: Double?
    public let fuel: Float
    public let damage: Int32
    public init(configuration: RaceSessionConfiguration,reason: SessionEndReason,elapsed: Double,laps: [CompletedLap],fuel: Float,damage: Int32) {
        schema=1;self.configuration=configuration;self.reason=reason;self.elapsed=elapsed
        self.laps=laps;self.fuel=fuel;self.damage=damage
        bestLap=laps.filter(\.valid).map(\.time).min()
    }
    public func save(to url: URL) throws {
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(self).write(to:url,options:.atomic)
    }
}
