// SPDX-License-Identifier: GPL-2.0-only
// The original qualifies one driver at a time. The player drives their own
// run; the opponents' runs are simulated here, headless and as fast as the
// machine allows, so the grid is set without the player watching each one.
import Foundation
import TORCSConfiguration
import TORCSTrack

public struct QualifyingSimulation: Sendable {
    public struct Outcome: Sendable,Equatable {
        /// The best lap the original's validity rule accepts, or 0 when none.
        public let bestValidLap: Float
        /// The fastest lap driven, valid or not. The BT policy rides the curbs
        /// on circuits such as Aalborg, which the corner-cut rule invalidates,
        /// so a grid built on valid laps alone would rank every opponent as
        /// having set no time. The game seeds the grid with this one.
        public let fastestLap: Float
        public let laps,ticks: Int
        public let completed: Bool
        /// The time the ranking takes: the fastest lap, or 0 for no lap at all.
        public var gridTime: Float { fastestLap }
    }
    /// One BT driver alone on the circuit over `laps` laps.
    ///
    /// `progress` receives the fraction of laps done as they complete;
    /// `cancelled` is polled so a player leaving the screen stops the work.
    public static func run(road: TrackRoad,parameters: ParameterDocument,laps: Int,skillLevel: Int = 3,
                           seed: UInt32 = 12345,maximumTicks: Int = 4_000_000,
                           progress: (@Sendable (Double)->Void)? = nil,
                           cancelled: (@Sendable ()->Bool)? = nil) throws -> Outcome {
        let configuration=try RaceSessionConfiguration(kind:.qualifying,laps:laps)
        let entry=RaceEntry(parameters:parameters,kind:.bt,team:"bt",skillLevel:skillLevel)
        var runtime=try RaceRuntime(road:road,entries:[entry],grid:try .quickRace(),configuration:configuration,seed:seed)
        var ticks=0,reportedLaps=0
        while ticks<maximumTicks,!runtime.ended {
            try runtime.step();ticks += 1
            if ticks % 2500==0 {
                if cancelled?() == true { runtime.endRace();break }
                let done=laps-runtime.presentationCar(0).remainingLaps
                if done != reportedLaps { reportedLaps=done;progress?(Double(min(done,laps))/Double(laps)) }
            }
        }
        if !runtime.ended { runtime.endRace() }
        let result=runtime.result?.cars.first
        func clean(_ value: Double?) -> Float { let f=Float(value ?? 0);return f.isFinite && f>0 ? f:0 }
        let fastest=result?.completedLaps.map(\.time).filter { $0>0 }.min()
        return Outcome(bestValidLap:clean(result?.bestLap),fastestLap:clean(fastest),laps:result?.laps ?? 0,ticks:ticks,
                       completed:runtime.result?.reason == .completed)
    }
}
