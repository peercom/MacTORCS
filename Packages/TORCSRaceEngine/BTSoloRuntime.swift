// SPDX-License-Identifier: GPL-2.0-only
// Stage ordering follows TORCS 1.3.9 racemain.cpp and raceengine.cpp.
// Copyright (C) Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSCore
import TORCSConfiguration
import TORCSSimulation
import TORCSTrack
import TORCSRobots

/// A bounded native BT single-car race integration. Diagnostic centerline start
/// matches the reference harness; original grids, penalties and opponents remain
/// separate work. All commands, physics, timing and pit service execute in Swift.
public struct BTSoloRuntime: Sendable {
    public private(set) var simulation: MultiVehicleSimulation
    public private(set) var driver: BTSoloDriver
    public private(set) var timing: RaceLapTiming
    public private(set) var pits: RacePitController
    public private(set) var clock=RaceStartClock(countdown:true)
    public private(set) var completedLaps: [CompletedLap]=[]
    public private(set) var lastRobotTime: Double = -1
    public private(set) var lastRobotDelta: Double = 0
    public private(set) var lastDriveTick=0,pitCalls=0
    public private(set) var lastDecision: BTDecision?
    public private(set) var command=DriverCommand(brake:1)
    public var finished: Bool { timing.finished }
    public var retired: Bool { simulation.lifecycle[0].flags & 0xE02 != 0 }
    public init(road: TrackRoad,parameters: ParameterDocument,laps: Int,seed: UInt32=12345,karma: Data?=nil) throws {
        let dimensions=try VehicleDynamicsDefinition(parameters:parameters).chassis.runningGear.mass.dimensions
        let registration=PitRegistration(team:"bt",length:dimensions.x,width:dimensions.y,skill:3)
        var pits=try RacePitController(road:road,registrations:[registration],parameters:[parameters])
        let driver=try BTSoloDriver(road:road,parameters:parameters,totalLaps:laps,pitStall:pits.cars[0].stall,karma:karma)
        // Mirrors initTrack's GfParmSetNum then category/car/setup merge.
        let fuel=try ParameterDocument.parse(Data("<params name=\"BT fuel\"><section name=\"Car\"><attnum name=\"initial fuel\" val=\"\(driver.initialFuel)\"/></section></params>".utf8))
        let configured=try parameters.merging(fuel)
        let definition=try VehicleDynamicsDefinition(parameters:configured)
        pits=try RacePitController(road:road,registrations:[registration],parameters:[configured])
        var simulation=try MultiVehicleSimulation(definition:definition,road:road,carCount:1,seed:seed,startDistance:road.length-10)
        if pits.cars[0].stall != nil { try simulation.updateCarStatus(car:0,pitOccupant:-1) }
        let previous=try simulation.settleForRace()
        self.simulation=simulation;self.driver=driver;self.pits=pits
        timing=RaceLapTiming(initialPosition:previous[0],targetLaps:laps)
    }
    public var observation: BTObservation {
        BTObservation(published:simulation.lifecycle[0],laps:timing.laps,remainingLaps:timing.remainingLaps,distanceFromStart:timing.distanceFromStart)
    }
    /// For deterministic authored diagnostics (fuel depletion/damage). Normal
    /// race progression changes these through physics and pit service.
    public mutating func updateCarStatus(fuel: Float?=nil,damage: Int32?=nil) throws {
        try simulation.updateCarStatus(car:0,fuel:fuel,damage:damage)
    }
    public mutating func step() throws {
        guard !finished,!retired else { throw BTError.invalid("BT session has ended") }
        let wasPrestart=clock.prestart;clock.step()
        if wasPrestart && !clock.prestart { lastRobotTime=0 }
        if clock.time-lastRobotTime>=0.02 {
            lastRobotDelta=clock.time-lastRobotTime
            if simulation.lifecycle[0].flags & 0xFF == 0 {
                let thinking=PerformanceSignposts.begin("AI update")
                let decision=try driver.drive(observation)
                PerformanceSignposts.end("AI update",thinking)
                lastDecision=decision;command=decision.command;lastDriveTick=simulation.tick+1
                try pits.setCommand(car:0,raceCommand:decision.pitRequested ? 1:0,service:pits.cars[0].command)
            }
            lastRobotTime=clock.time
        }
        let previousOccupant=simulation.lifecycle[0].pitOccupant
        try simulation.step(commands:[command],mode:clock.prestart ? .prestart:.running,tireFactor:1,maximumDamage:10000)
        // SimUpdate mutates controls (notably prestart gear and throttle). Keep
        // that publication until the next actual robot callback.
        command=simulation.cars[0].driverCommand
        let life=simulation.lifecycle[0]
        if previousOccupant != nil && previousOccupant != -1 && life.pitOccupant == -1 { try pits.releaseRemovedCar(0) }
        let sample=PitAdmissionSample(flags:life.flags,damage:life.publishedDamage,speed:SIMD2(life.publicBody.velocity.x,life.publicBody.velocity.y),position:life.trackPosition)
        let car=observation
        var calls=0
        let management=try pits.manage(car:0,sample:sample,time:clock.time,maximumDamage:10000,session:.race,rules:.init()) { service in
            let result=driver.pitCommand(car);service.fuel=result.fuel;service.repair=result.repair;calls += 1;return false
        }
        pitCalls += calls
        try simulation.updateCarStatus(car:0,flags:management.flags)
        if var service=management.service { try simulation.service(car:0,command:&service);try pits.recordService(car:0,command:service) }
        if let stall=pits.cars[0].stall { try simulation.updateCarStatus(car:0,pitOccupant:pits.stalls[stall].occupant) }
        let lapSample=RaceLapSample(position:life.trackPosition,speed:life.publicBody.velocity.x,
            width:simulation.cars[0].definition.chassis.runningGear.mass.dimensions.y,flags:management.flags,collision:life.publishedSimCollision)
        if let lap=try timing.update(lapSample,time:clock.time,road:simulation.road) { completedLaps.append(lap) }
        if timing.flags != management.flags { try simulation.updateCarStatus(car:0,flags:timing.flags) }
    }
}
