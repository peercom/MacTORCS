// SPDX-License-Identifier: GPL-2.0-only
// Pit integration order follows original ReOneStep: simulation, then per-car
// ReManage/service. Copyright (C) Eric Espie, Bernhard Wymann, GPL-2.0-or-later.
import TORCSConfiguration
import TORCSSimulation
import TORCSTrack

/// An integration boundary for race pit policy, not a complete race engine.
/// Car order is caller-supplied stable index order until race sorting is ported.
public struct RacePitSimulation: Sendable {
    public private(set) var simulation: MultiVehicleSimulation
    public private(set) var pits: RacePitController
    public private(set) var time: Double = 0
    public private(set) var pendingMenu: Int?
    public var session: RaceSessionKind
    public var rules: RacePitRules
    public var maximumDamage: Int32 = 0
    public init(simulation: MultiVehicleSimulation,registrations: [PitRegistration],parameters: [ParameterDocument],
        carsPerPit: Int = 1,session: RaceSessionKind,rules: RacePitRules = .init()) throws {
        guard registrations.count==simulation.cars.count else { throw TrackError.invalid("Pit registrations do not match simulation cars") }
        self.simulation=simulation; self.session=session; self.rules=rules
        pits=try RacePitController(road:simulation.road,registrations:registrations,parameters:parameters,carsPerPit:carsPerPit)
        try synchronizeOccupancy()
    }
    public mutating func setCommand(car: Int,raceCommand: UInt32,service: PitServiceCommand,stopType: Int32 = 0,penaltyTime: Float? = nil) throws {
        try pits.setCommand(car:car,raceCommand:raceCommand,service:service,stopType:stopType,penaltyTime:penaltyTime)
    }
    public mutating func updateCarStatus(car: Int,flags: UInt32? = nil,fuel: Float? = nil,damage: Int32? = nil) throws {
        try simulation.updateCarStatus(car:car,flags:flags,fuel:fuel,damage:damage)
    }
    private mutating func synchronizeOccupancy() throws {
        for car in pits.cars.indices {
            if let stall=pits.cars[car].stall { try simulation.updateCarStatus(car:car,pitOccupant:pits.stalls[stall].occupant) }
        }
    }
    public mutating func step(commands: [DriverCommand],damageFactor: Float = 1,
        decide: (Int,inout PitServiceCommand) -> Bool = { _,_ in false }) throws {
        guard pendingMenu==nil else { throw TrackError.invalid("Complete the pit menu before advancing simulation") }
        let previous=simulation.lifecycle.map(\.pitOccupant)
        time += 0.002
        try simulation.step(commands:commands,damageFactor:damageFactor,tireFactor:rules.tireFactor,maximumDamage:maximumDamage,skillLevels:pits.registrations.map(\.skill))
        for car in pits.cars.indices {
            if previous[car] != nil && previous[car] != -1 && simulation.lifecycle[car].pitOccupant == -1 { try pits.releaseRemovedCar(car) }
        }
        for car in pits.cars.indices {
            let state=simulation.lifecycle[car]
            let sample=PitAdmissionSample(flags:state.flags,damage:state.publishedDamage,speed:SIMD2(state.publicBody.velocity.x,state.publicBody.velocity.y),position:state.trackPosition)
            let result=try pits.manage(car:car,sample:sample,time:time,maximumDamage:maximumDamage,session:session,rules:rules,decide:{ decide(car,&$0) })
            try simulation.updateCarStatus(car:car,flags:result.flags)
            if var command=result.service { try simulation.service(car:car,command:&command); try pits.recordService(car:car,command:command) }
            // ReStop prevents the next physics step; the current ReManage loop
            // continues through all cars in the original. One UI owns the menu.
            if result.menuRequested { pendingMenu=car }
        }
        try synchronizeOccupancy()
    }
    public mutating func completeMenu(command: PitServiceCommand,stopType: Int32 = 0) throws {
        guard let car=pendingMenu else { throw TrackError.invalid("No pending pit menu") }
        if var command=try pits.completeMenu(car:car,command:command,stopType:stopType,time:time,session:session,rules:rules) {
            try simulation.service(car:car,command:&command); try pits.recordService(car:car,command:command)
        }
        pendingMenu=nil
    }
}
