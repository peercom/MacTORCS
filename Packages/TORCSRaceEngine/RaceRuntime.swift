// SPDX-License-Identifier: GPL-2.0-only
// Stage order follows TORCS 1.3.9 raceengine.cpp ReOneStep and ReManage.
// Copyright (C) 2002-2017 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSConfiguration
import TORCSRobots
import TORCSSimulation
import TORCSTrack

/// Who supplies a car's commands. A native BT driver owns its own policy state;
/// the human car takes the command the caller sampled for this step.
public enum RaceDriverKind: Sendable,Equatable { case human,bt }

/// One car's entry: its merged parameters, who drives it and what the original
/// rules gate on. Fuel is merged from the driver's own strategy request.
public struct RaceEntry: Sendable {
    public var parameters: ParameterDocument
    public var kind: RaceDriverKind
    public var team: String
    public var skillLevel: Int
    public var setup: ParameterDocument?
    public var karma: Data?
    public init(parameters: ParameterDocument,kind: RaceDriverKind,team: String = "bt",skillLevel: Int = 3,
                setup: ParameterDocument? = nil,karma: Data? = nil) {
        self.parameters=parameters;self.kind=kind;self.team=team;self.skillLevel=skillLevel
        self.setup=setup;self.karma=karma
    }
}

public struct RaceCarResult: Sendable,Codable,Equatable {
    public let car,position,laps: Int
    public let totalTime,bestLap,behindLeader: Double
    public let lapsBehindLeader,penalties: Int
    public let penaltyTime: Float
    public let fuel: Float
    public let damage: Int32
    public let flags: UInt32
    public let finished,eliminated: Bool
    public let completedLaps: [CompletedLap]
}

public struct RaceResult: Sendable,Codable,Equatable {
    public let schema: Int
    public let configuration: RaceSessionConfiguration
    public let reason: SessionEndReason
    public let elapsed: Double
    /// Stable car indices in the final original race order, leader first.
    public let classification: [Int]
    public let cars: [RaceCarResult]
    public init(configuration: RaceSessionConfiguration,reason: SessionEndReason,elapsed: Double,
                classification: [Int],cars: [RaceCarResult]) {
        schema=1;self.configuration=configuration;self.reason=reason;self.elapsed=elapsed
        self.classification=classification;self.cars=cars
    }
    public func save(to url: URL) throws {
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(self).write(to:url,options:.atomic)
    }
}

/// One authoritative race: the original ReOneStep order over a native field.
///
/// Per step: the race clock, robot callbacks at the original 0.02 s interval for
/// every car that is still simulated, one physics update for the whole field,
/// per-car pit management, then ReManage's timing, gaps, complete rules and
/// ReSortCars. Own this on the simulation execution context; presentation reads
/// published values only.
public struct RaceRuntime: Sendable {
    public private(set) var simulation: MultiVehicleSimulation
    public private(set) var progress: RaceProgress
    public private(set) var pits: RacePitController
    public private(set) var rules: RaceRules
    public private(set) var clock: RaceStartClock
    public let configuration: RaceSessionConfiguration
    public let kinds: [RaceDriverKind]
    public let profiles: [RaceDriverProfile]
    public private(set) var drivers: [BTDriver?]
    public private(set) var commands: [DriverCommand]
    public private(set) var lastRobotTime: Double = -1
    public private(set) var lastRobotDelta: Double = 0
    public private(set) var driveCalls: [Int]
    public private(set) var pitCalls: [Int]
    /// The last pit request each driver published, for presentation.
    public private(set) var pitRequests: [Bool]
    public private(set) var lastDriveTick=0
    public private(set) var collisions: [PresentationCollisionHistory]
    public private(set) var result: RaceResult?
    public let maximumDamage: Int32
    public var raceTime: Double { clock.time }
    public var carCount: Int { simulation.cars.count }
    public var ended: Bool { progress.ended || result != nil }
    public var phase: DrivingSessionPhase { result != nil ? .results:clock.prestart ? .prestart:.running }
    /// Stable car indices in the current original race order, leader first.
    public var classification: [Int] { progress.order.indices }

    public init(road: TrackRoad,entries: [RaceEntry],grid: StartingGridConfiguration,
                configuration: RaceSessionConfiguration,seed: UInt32 = 12345,maximumDamage: Int32 = 10000) throws {
        guard (1...16).contains(entries.count) else { throw TrackError.invalid("A race holds 1…16 entries") }
        guard entries.filter({ $0.kind == .human }).count<=1 else { throw TrackError.invalid("Only one human car is supported") }
        guard entries.allSatisfy({ (0..<5).contains($0.skillLevel) }) else { throw TrackError.invalid("Invalid entry skill level") }
        self.configuration=configuration;self.maximumDamage=maximumDamage
        kinds=entries.map(\.kind)
        profiles=entries.map { RaceDriverProfile(skillLevel:$0.skillLevel,human:$0.kind == .human) }
        let slots=try StartingGrid.slots(road:road,configuration:grid,cars:entries.count)
        // Each entry's registration needs its own dimensions before the driver's
        // fuel request is merged, which cannot change them.
        var registrations: [PitRegistration]=[]
        for entry in entries {
            let dimensions=try VehicleDynamicsDefinition(parameters:entry.parameters).chassis.runningGear.mass.dimensions
            registrations.append(PitRegistration(team:entry.team,length:dimensions.x,width:dimensions.y,skill:entry.skillLevel))
        }
        // Stall assignment is needed before a driver is built, and again from the
        // merged parameters once the fuel request is known.
        let stalls=try RacePitController(road:road,registrations:registrations,parameters:entries.map(\.parameters))
        // initTrack's GfParmSetNum then the category/car/setup merge: a BT driver
        // asks for its starting fuel before physics is configured.
        var configured: [ParameterDocument]=[],built: [BTDriver?]=[]
        for (index,entry) in entries.enumerated() {
            guard entry.kind == .bt else { configured.append(entry.parameters);built.append(nil);continue }
            let driver=try BTDriver(road:road,parameters:entry.parameters,setup:entry.setup,
                totalLaps:configuration.laps,driverIndex:index,pitStall:stalls.cars[index].stall,karma:entry.karma,
                fieldSize:entries.count)
            let fuel=try ParameterDocument.parse(Data("<params name=\"fuel\"><section name=\"Car\"><attnum name=\"initial fuel\" val=\"\(driver.initialFuel)\"/></section></params>".utf8))
            configured.append(try entry.parameters.merging(fuel));built.append(driver)
        }
        drivers=built
        pits=try RacePitController(road:road,registrations:registrations,parameters:configured)
        var simulation=try MultiVehicleSimulation(definitions:try configured.map { try VehicleDynamicsDefinition(parameters:$0) },
            road:road,grid:slots,seed:seed)
        for car in entries.indices where pits.cars[car].stall != nil {
            try simulation.updateCarStatus(car:car,pitOccupant:-1)
        }
        let settled=try simulation.settleForRace()
        self.simulation=simulation
        progress=try RaceProgress(positions:settled,targetLaps:configuration.laps)
        rules=RaceRules(road:road,enabled:configuration.kind == .race ? .race:.practice,session:configuration.kind)
        clock=RaceStartClock(countdown:configuration.countdown)
        commands=Array(repeating:DriverCommand(brake:1),count:entries.count)
        driveCalls=Array(repeating:0,count:entries.count)
        pitCalls=Array(repeating:0,count:entries.count)
        pitRequests=Array(repeating:false,count:entries.count)
        collisions=Array(repeating:PresentationCollisionHistory(),count:entries.count)
        for car in entries.indices {
            let life=self.simulation.lifecycle[car]
            try collisions[car].observe(tick:self.simulation.tick,flags:life.flags,
                accumulatedCollision:life.publishedCollision,stepCollision:life.publishedSimCollision)
        }
    }

    public func observation(car: Int) -> BTObservation {
        BTObservation(published:simulation.lifecycle[car],laps:progress.timing[car].laps,
            remainingLaps:progress.timing[car].remainingLaps,distanceFromStart:progress.timing[car].distanceFromStart)
    }
    /// One car's published state as the original opponent model reads it. Team
    /// membership is not configured: the original reads a team mate name from the
    /// driver setup, and these entries name none.
    public func carState(_ car: Int) -> BTCarState {
        let life=simulation.lifecycle[car]
        let dimensions=simulation.cars[car].definition.chassis.runningGear.mass.dimensions
        return BTCarState(position:life.trackPosition,
            worldPosition:SIMD2(life.publicWorld.position.x,life.publicWorld.position.y),
            worldVelocity:SIMD2(life.publicWorld.velocity.x,life.publicWorld.velocity.y),
            corners:(0..<4).map { SIMD2(life.publishedCorners[$0].x,life.publishedCorners[$0].y) },
            yaw:life.publicBody.orientation.z,length:dimensions.x,width:dimensions.y,
            distanceFromStart:progress.timing[car].distanceFromStart,laps:progress.timing[car].laps,
            damage:life.publishedDamage,flags:life.flags,teamMate:false)
    }
    public func presentationCar(_ car: Int) -> RacePresentationCar {
        RacePresentationCar(index:car,visual:simulation.visualSnapshot(car:car),
            trackPosition:simulation.lifecycle[car].trackPosition,remainingLaps:progress.timing[car].remainingLaps,
            pitRequested:pitRequests[car],collisions:collisions[car])
    }
    /// For deterministic authored diagnostics only. A race changes these through
    /// physics and pit service.
    public mutating func updateCarStatus(car: Int,fuel: Float? = nil,damage: Int32? = nil) throws {
        try simulation.updateCarStatus(car:car,fuel:fuel,damage:damage)
    }

    /// One original ReOneStep. `humanCommand` is sampled at the original robot
    /// interval, as the original human driver module is.
    public mutating func step(humanCommand: DriverCommand = DriverCommand()) throws {
        guard result==nil else { throw TrackError.invalid("The race has ended") }
        let wasPrestart=clock.prestart
        clock.step()
        if wasPrestart && !clock.prestart { lastRobotTime=0 }
        if clock.time-lastRobotTime>=0.02 {
            lastRobotDelta=clock.time-lastRobotTime
            for car in simulation.cars.indices where simulation.lifecycle[car].flags & 0xFF == 0 {
                switch kinds[car] {
                case .human:commands[car]=humanCommand
                case .bt:
                    guard drivers[car] != nil else { continue }
                    // The original keeps one Opponent per other car, in the order
                    // the field had when the race started.
                    let field=simulation.cars.indices.filter { $0 != car }.map { carState($0) }
                    let decision=try drivers[car]!.drive(observation(car:car),field:field,deltaTime:lastRobotDelta)
                    commands[car]=decision.command;pitRequests[car]=decision.pitRequested
                    try pits.setCommand(car:car,raceCommand:decision.pitRequested ? 1:0,service:pits.cars[car].command)
                }
                driveCalls[car] += 1
            }
            lastDriveTick=simulation.tick+1
            lastRobotTime=clock.time
        }
        let previousOccupants=simulation.lifecycle.map(\.pitOccupant)
        try simulation.step(commands:commands,mode:clock.prestart ? .prestart:.running,tireFactor:1,
            maximumDamage:maximumDamage,skillLevels:profiles.map(\.skillLevel))
        // SimUpdate mutates the controls it was given, notably the prestart gear
        // and throttle. Keep that publication until the next robot callback.
        for car in simulation.cars.indices { commands[car]=simulation.cars[car].driverCommand }
        for car in simulation.cars.indices {
            let life=simulation.lifecycle[car]
            try collisions[car].observe(tick:simulation.tick,flags:life.flags,
                accumulatedCollision:life.publishedCollision,stepCollision:life.publishedSimCollision)
        }
        // ReManage's pit block, per car, before its timing and rules.
        for car in simulation.cars.indices {
            let previous=previousOccupants[car]
            if previous != nil,previous != -1,simulation.lifecycle[car].pitOccupant == -1 { try pits.releaseRemovedCar(car) }
            let life=simulation.lifecycle[car]
            let sample=PitAdmissionSample(flags:life.flags,damage:life.publishedDamage,
                speed:SIMD2(life.publicBody.velocity.x,life.publicBody.velocity.y),position:life.trackPosition)
            let observed=observation(car:car)
            var calls=0
            let management=try pits.manage(car:car,sample:sample,time:clock.time,maximumDamage:maximumDamage,
                session:configuration.kind,rules:.init()) { service in
                guard self.drivers[car] != nil else { return false }
                let decision=self.drivers[car]!.pitCommand(observed)
                service.fuel=decision.fuel;service.repair=decision.repair;calls += 1
                return false
            }
            pitCalls[car] += calls
            try simulation.updateCarStatus(car:car,flags:management.flags)
            if var service=management.service {
                try simulation.service(car:car,command:&service)
                try pits.recordService(car:car,command:service)
            }
            if let stall=pits.cars[car].stall {
                try simulation.updateCarStatus(car:car,pitOccupant:pits.stalls[stall].occupant)
            }
        }
        // ReManage's timing, gaps and complete rules, then ReSortCars. The rules
        // own lap validity here, so no separate validity mask is passed.
        let samples=simulation.cars.indices.map { car -> RaceLapSample in
            let life=simulation.lifecycle[car]
            return RaceLapSample(position:life.trackPosition,speed:life.publicBody.velocity.x,
                width:simulation.cars[car].definition.chassis.runningGear.mass.dimensions.y,
                flags:life.flags,collision:life.publishedSimCollision,publicSpeed:life.publicSpeed)
        }
        try progress.update(samples:samples,time:clock.time,road:simulation.road,rules:[],
            raceRules:rules,profiles:profiles)
        for car in simulation.cars.indices where progress.timing[car].flags != simulation.lifecycle[car].flags {
            try simulation.updateCarStatus(car:car,flags:progress.timing[car].flags)
        }
        if progress.ended { finish(.completed) }
    }

    public mutating func endRace() { finish(.endedEarly) }
    private mutating func finish(_ reason: SessionEndReason) {
        guard result==nil else { return }
        let order=progress.order.indices
        let cars=simulation.cars.indices.map { car -> RaceCarResult in
            let timing=progress.timing[car],rule=progress.carRules[car]
            return RaceCarResult(car:car,position:(order.firstIndex(of:car) ?? car)+1,laps:timing.completedLaps,
                totalTime:timing.totalTime,bestLap:timing.bestLapTime,behindLeader:progress.gaps[car].behindLeader,
                lapsBehindLeader:progress.gaps[car].lapsBehindLeader,penalties:rule.penalties.count,
                penaltyTime:rule.penaltyTime,fuel:simulation.cars[car].fuel,damage:simulation.cars[car].damage,
                flags:timing.flags,finished:timing.finished,eliminated:timing.flags & 0x800 != 0,
                completedLaps:progress.laps[car])
        }
        result=RaceResult(configuration:configuration,reason:reason,elapsed:max(0,clock.time),
            classification:order,cars:cars)
    }
}
