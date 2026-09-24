// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import TORCSCore
import TORCSSimulation

/// An immutable boundary between a fixed-step driving session and presentation.
public struct DrivingFrame: Sendable {
    public let previous,current: VehicleVisualSnapshot
    public let interpolation: Float
    public let time: Double
    /// Original repeated-addition clock for presentation event timing.
    public let raceTime: Double
    public let presentationCar: RacePresentationCar
    public let speed,publicSpeed,rpm,fuel: Float
    public let gear,trackSegment: Int
    public let damage: Int32
    public let behind: Bool
    public let timing: RaceLapTiming
    public let completedLaps: [CompletedLap]
    public let configuration: RaceSessionConfiguration
    public let phase: DrivingSessionPhase
    public let result: DrivingSessionResult?
}

/// Own exclusively on the simulation execution context. Display callbacks only
/// read frames; pauses consume no simulation time and work caps retain backlog.
public struct DrivingRuntime: Sendable {
    public private(set) var simulation: SingleVehicleSimulation
    public private(set) var clock=FixedStepClock()
    public private(set) var previous,current: VehicleVisualSnapshot
    public private(set) var timing: RaceLapTiming
    public private(set) var completedLaps: [CompletedLap]=[]
    public var raceTime: Double { startClock.time }
    public let configuration: RaceSessionConfiguration
    public private(set) var startClock: RaceStartClock
    public private(set) var result: DrivingSessionResult?
    public var phase: DrivingSessionPhase { result != nil ? .results:startClock.prestart ? .prestart:.running }
    public private(set) var collisionHistory=PresentationCollisionHistory()
    public init(simulation: SingleVehicleSimulation,targetLaps: Int=5) throws {
        try self.init(simulation:simulation,configuration:RaceSessionConfiguration(laps:targetLaps,countdown:false))
    }
    public init(simulation: SingleVehicleSimulation,configuration: RaceSessionConfiguration) throws {
        guard configuration.kind != .race else { throw DrivingError.unsupportedSession }
        self.configuration=configuration;startClock=RaceStartClock(countdown:configuration.countdown)
        timing=RaceLapTiming(initialPosition:simulation.lifecycle.trackPosition,targetLaps:configuration.laps)
        self.simulation=simulation
        previous=simulation.visualSnapshot;current=simulation.visualSnapshot
        let life=simulation.lifecycle
        try collisionHistory.observe(tick:simulation.tick,flags:life.flags,accumulatedCollision:life.publishedCollision,stepCollision:life.publishedSimCollision)
    }
    public var frame: DrivingFrame {
        let vehicle=simulation.vehicle
        return DrivingFrame(previous:previous,current:current,interpolation:result != nil ? 1:Float(clock.interpolation),time:clock.time,raceTime:raceTime,presentationCar:RacePresentationCar(index:0,visual:current,trackPosition:simulation.lifecycle.trackPosition,remainingLaps:timing.remainingLaps,pitRequested:false,collisions:collisionHistory),
            speed:vehicle.chassis.body.velocity.x,publicSpeed:simulation.lifecycle.publicSpeed,rpm:vehicle.engine.speed*60/(2 * .pi),fuel:vehicle.fuel,
            gear:vehicle.transmission.gear,trackSegment:vehicle.chassis.trackPosition.segment,damage:vehicle.damage,behind:result == nil && clock.isBehind,timing:timing,completedLaps:completedLaps,configuration:configuration,phase:phase,result:result)
    }
    public mutating func endSession() { finish(.endedEarly) }
    private mutating func finish(_ reason: SessionEndReason) {
        guard result==nil else { return }
        result=DrivingSessionResult(configuration:configuration,reason:reason,elapsed:max(0,raceTime),laps:completedLaps,
            fuel:simulation.vehicle.fuel,damage:simulation.vehicle.damage)
    }
    public mutating func advance(elapsed: Double,command: DriverCommand,paused: Bool = false,maximumSteps: Int = 125,
        didStep: ((SingleVehicleSimulation,RaceLapTiming,Double)throws->Void)? = nil) throws {
        guard !paused,result==nil else { return }
        guard elapsed.isFinite,elapsed>=0,maximumSteps>0 else { throw DrivingError.invalidTime }
        var failure: Error?
        var endReason: SessionEndReason?
        clock.advanceContinuing(elapsed:elapsed,maximumSteps:maximumSteps) { _ in
            do {
                previous=current
                startClock.step()
                let tick=PerformanceSignposts.begin("Simulation tick")
                try simulation.step(command:command,mode:startClock.prestart ? .prestart:.running)
                PerformanceSignposts.end("Simulation tick",tick)
                let life=simulation.lifecycle
                // Capture publication before race-status changes can mask an active physics step.
                try collisionHistory.observe(tick:simulation.tick,flags:life.flags,accumulatedCollision:life.publishedCollision,stepCollision:life.publishedSimCollision)
                let sample=RaceLapSample(position:life.trackPosition,speed:life.publicBody.velocity.x,
                    width:simulation.vehicle.definition.chassis.runningGear.mass.dimensions.y,
                    flags:life.flags,collision:life.publishedSimCollision)
                let queries=PerformanceSignposts.begin("Track queries")
                let lap=try timing.update(sample,time:startClock.time,road:simulation.road)
                PerformanceSignposts.end("Track queries",queries)
                if let lap { completedLaps.append(lap) }
                if timing.flags != life.flags { try simulation.updateCarStatus(flags:timing.flags) }
                current=simulation.visualSnapshot
                try didStep?(simulation,timing,startClock.time)
                if life.flags & 0xE02 != 0 { endReason = .retired }
                else if timing.finished { endReason = .completed }
                return endReason==nil
            } catch { failure=error;return false }
        }
        // A failed runtime must be discarded. Never resume partially failed physics.
        if let failure { throw failure }
        if let endReason { finish(endReason) }
    }
}
public enum DrivingError: Error { case invalidTime,unsupportedSession }
