// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of the qualifying ranking in TORCS 1.3.9 raceresults.cpp, and of
// the starting order racemain.cpp selects for a race.
// Copyright (C) 2002-2017 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSTrack

/// One finished qualifying run. The original qualifies one driver at a time and
/// inserts each finished run into a ranked list.
public struct QualifyingRun: Sendable,Equatable {
    public let name: String
    /// Seconds. Zero means the driver set no time, which the original treats as
    /// worse than any time rather than as a fast lap.
    public let bestLapTime: Float
    public let index: Int
    public init(name: String,bestLapTime: Float,index: Int) {
        self.name=name;self.bestLapTime=bestLapTime;self.index=index
    }
}

public enum QualifyingRanking {
    /// The original compares and stores at millisecond resolution.
    static func milliseconds(_ time: Float) -> Double { Double(time*1000).rounded() }
    static func stored(_ time: Float) -> Float { Float(Double(time*1000).rounded()/1000) }

    /// The original insertion: walk the ranks from last to first, shifting each
    /// down while the new run beats it at millisecond resolution or that entry
    /// has no time at all, then insert after the first entry it does not beat.
    /// A run without a time never displaces anyone, so it lands at the end, and
    /// an equal time keeps the earlier qualifier ahead.
    public static func insert(_ run: QualifyingRun,into ranks: [QualifyingRun]) -> [QualifyingRun] {
        var result=ranks
        var position=ranks.count
        while position>0 {
            let opponent=result[position-1].bestLapTime
            guard run.bestLapTime != 0,
                  milliseconds(run.bestLapTime)<milliseconds(opponent) || opponent==0 else { break }
            position -= 1
        }
        result.insert(QualifyingRun(name:run.name,bestLapTime:stored(run.bestLapTime),index:run.index),at:position)
        return result
    }
    /// Every run inserted in the order the sessions happened.
    public static func rank(_ runs: [QualifyingRun]) -> [QualifyingRun] {
        runs.reduce(into:[QualifyingRun]()) { $0=insert($1,into:$0) }
    }
}

/// How the original orders a starting grid, from the race manager's
/// `starting order` attribute.
public enum StartingOrder: String,Sendable,CaseIterable {
    case driversList="drivers list"
    case lastRace="last race"
    case lastRaceReversed="last race reversed"
    /// Anything the original does not recognize falls back to the drivers list,
    /// because its final branch is an else.
    public init(attribute: String) { self=StartingOrder(rawValue:attribute) ?? .driversList }

    /// The grid order as car indices, given the entry list order and the ranked
    /// result of the previous session. The original caps the field at the race's
    /// maximum driver count.
    public func grid(entries: Int,previous: [QualifyingRun],maximumCars: Int = 100) throws -> [Int] {
        guard entries>0,maximumCars>0 else { throw TrackError.invalid("A grid needs at least one entry") }
        let count=min(entries,maximumCars)
        switch self {
        case .driversList:return Array(0..<count)
        case .lastRace,.lastRaceReversed:
            guard previous.count>=count else {
                throw TrackError.invalid("The previous session ranked \(previous.count) of \(count) cars")
            }
            let ranked=previous.prefix(count).map(\.index)
            guard Set(ranked)==Set(0..<count) else {
                throw TrackError.invalid("The previous session's ranking does not cover the field")
            }
            return self == .lastRace ? Array(ranked):Array(ranked.reversed())
        }
    }
}
