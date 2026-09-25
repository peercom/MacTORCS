// SPDX-License-Identifier: GPL-2.0-only
// The original session sequence: practice, then one qualifying session per
// driver, then a race whose grid reads the starting order.
// Copyright (C) 2002-2017 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSTrack

/// A weekend over one field: which session comes next, the qualifying ranking
/// built so far, and the grid order a race will start from.
///
/// The original qualifies **one driver at a time**, so a field of four means
/// four qualifying sessions. This value says which driver qualifies next and
/// takes each finished run, rather than inventing times for the cars that are
/// not driving.
public struct RaceWeekend: Sendable,Equatable {
    public let cars: Int
    public var startingOrder: StartingOrder
    /// The finished qualifying runs, already in the original's ranked order.
    public private(set) var ranking: [QualifyingRun]=[]
    /// The next driver to qualify, or nil once every driver has.
    public private(set) var qualifying: Int?
    public init(cars: Int,startingOrder: StartingOrder = .driversList) throws {
        guard (1...16).contains(cars) else { throw TrackError.invalid("A weekend holds 1…16 cars") }
        self.cars=cars;self.startingOrder=startingOrder
        qualifying=startingOrder == .driversList ? nil:0
    }
    public var qualifyingComplete: Bool { qualifying==nil }
    /// Record one driver's finished qualifying session and move to the next.
    public mutating func recordQualifying(car: Int,bestLapTime: Float,name: String? = nil) throws {
        guard let expected=qualifying else { throw TrackError.invalid("Qualifying is complete") }
        guard car==expected else { throw TrackError.invalid("Car \(expected) is the one qualifying") }
        guard bestLapTime>=0,bestLapTime.isFinite else { throw TrackError.invalid("Invalid qualifying lap time") }
        ranking=QualifyingRanking.insert(
            QualifyingRun(name:name ?? Self.defaultName(car),bestLapTime:bestLapTime,index:car),into:ranking)
        qualifying=car+1<cars ? car+1:nil
    }
    /// The entry order a race starts with: the car on each grid slot, from pole
    /// back. Qualifying must be complete unless the grid is the drivers list.
    public func grid() throws -> [Int] {
        if startingOrder != .driversList,!qualifyingComplete {
            throw TrackError.invalid("\(cars-(qualifying ?? cars)) of \(cars) drivers have qualified")
        }
        return try startingOrder.grid(entries:cars,previous:ranking)
    }
    public static func defaultName(_ car: Int) -> String { car==0 ? "You":"BT \(car+1)" }
}
