// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 raceengineclient initPits, ReManage pit branch
// and ReUpdtPitTime. Copyright (C) 2002-2017 Eric Espie, Bernhard Wymann;
// upstream GPL-2.0-or-later.
import Foundation
import TORCSConfiguration
import TORCSSimulation
import TORCSTrack

public enum RaceSessionKind: Int32, Sendable, Codable, CaseIterable { case practice = 0, qualifying = 1, race = 2 }
public struct RacePitRules: Sendable {
    public var baseTime: Float, fuelFlow: Float, repairFactor: Float, tireFactor: Float, tireChangeTime: Float
    public init(baseTime: Float = 2,fuelFlow: Float = 8,repairFactor: Float = 0.007,tireFactor: Float = 1,tireChangeTime: Float = 16) {
        self.baseTime=max(0,baseTime); self.fuelFlow=max(1,fuelFlow); self.repairFactor=max(0,repairFactor)
        self.tireFactor=max(0,tireFactor); self.tireChangeTime=max(0,tireChangeTime)
    }
}
public struct PitRegistration: Sendable {
    public var team: String, length: Float, width: Float, skill: Int
    public init(team: String,length: Float,width: Float,skill: Int) { self.team=team; self.length=length; self.width=width; self.skill=skill }
}
public struct RacePitStall: Sendable {
    public internal(set) var cars: [Int] = []
    public internal(set) var occupant: Int32 = -1
    public internal(set) var minimum: Float = 0, maximum: Float = 0
}
public struct RacePitCar: Sendable {
    public internal(set) var stall: Int?
    public internal(set) var raceCommand: UInt32 = 0, stops = 0
    public internal(set) var startTime: Double = 0, totalTime: Double = 0, scheduledTime: Double = 0
    public internal(set) var penaltyTime: Float = 0
    public internal(set) var stopType: Int32 = 0
    public internal(set) var command: PitServiceCommand
    public internal(set) var awaitingMenu = false
    public internal(set) var message = ""
}
public struct PitAdmissionSample: Sendable {
    public var flags: UInt32, damage: Int32, speed: SIMD2<Float>, position: TrackLocalPosition
    public init(flags: UInt32,damage: Int32,speed: SIMD2<Float>,position: TrackLocalPosition) {
        self.flags=flags; self.damage=damage; self.speed=speed; self.position=position
    }
}
public struct PitManagementResult: Sendable {
    public var flags: UInt32
    public var service: PitServiceCommand?
    public var entered = false, released = false, menuRequested = false
}
/// Pit policy only. The enclosing race loop must call this after physics in car
/// order, apply returned service immediately, and stop stepping for a pit menu.
public struct RacePitController: Sendable {
    public let road: TrackRoad
    public let registrations: [PitRegistration]
    public private(set) var stalls: [RacePitStall]
    public private(set) var cars: [RacePitCar]
    private let parameters: [ParameterDocument]
    public init(road: TrackRoad,registrations: [PitRegistration],parameters: [ParameterDocument],carsPerPit: Int = 1) throws {
        guard registrations.count==parameters.count else { throw TrackError.invalid("One parameter document is required per pit registration") }
        self.road=road; self.registrations=registrations; self.parameters=parameters
        stalls=Array(repeating:RacePitStall(),count:road.pits.positions.count)
        cars=parameters.map { RacePitCar(command:PitServiceCommand(setup:PitSetup(parameters:$0))) }
        guard road.pits.type == .trackSide else { return }
        let capacity=min(4,max(1,carsPerPit))
        for i in cars.indices {
            for j in stalls.indices {
                if stalls[j].cars.isEmpty || (registrations[stalls[j].cars[0]].team.utf8.elementsEqual(registrations[i].team.utf8) && stalls[j].cars.count<capacity) {
                    if stalls[j].cars.isEmpty {
                        let position=road.pits.positions[j]
                        let start=road.geometry.segments[position.segment].distanceFromStart+position.toStart
                        // Original stores pit toStart without curved-segment conversion.
                        stalls[j].minimum=Float(Double(start)-Double(road.pits.stallLength)/2+Double(registrations[i].length)/2)
                        stalls[j].maximum=Float(Double(start)+Double(road.pits.stallLength)/2-Double(registrations[i].length)/2)
                        if stalls[j].minimum>road.length { stalls[j].minimum -= road.length }
                        if stalls[j].maximum>road.length { stalls[j].maximum -= road.length }
                    }
                    stalls[j].cars.append(i); cars[i].stall=j; break
                }
            }
        }
    }
    public mutating func setCommand(car: Int,raceCommand: UInt32,service: PitServiceCommand,stopType: Int32 = 0,penaltyTime: Float? = nil) throws {
        guard cars.indices.contains(car) else { throw TrackError.invalid("Invalid pit car") }
        cars[car].raceCommand=raceCommand; cars[car].command=service; cars[car].stopType=stopType
        if let penaltyTime { cars[car].penaltyTime=penaltyTime }
    }
    /// Called when physics removes a broken car from an occupied stall.
    public mutating func releaseRemovedCar(_ car: Int) throws {
        guard cars.indices.contains(car) else { throw TrackError.invalid("Invalid pit car") }
        if let stall=cars[car].stall { stalls[stall].occupant = -1 }
    }
    private mutating func schedule(_ car: Int,time: Double,session: RaceSessionKind,rules: RacePitRules) -> PitServiceCommand? {
        switch cars[car].stopType {
        case 0:
            let command=cars[car].command
            var duration=Double(rules.baseTime)+abs(Double(command.fuel))/Double(rules.fuelFlow)
            duration += Double(Float(abs(Double(command.repair)))*rules.repairFactor)
            duration += Double(cars[car].penaltyTime)
            if command.changeAllTires && registrations[car].skill==3 && rules.tireFactor>0 { duration += Double(rules.tireChangeTime) }
            cars[car].totalTime=duration
            cars[car].command.setup.load(parameters:parameters[car],boundsOnly:session != .race)
            cars[car].scheduledTime=time+duration; cars[car].penaltyTime=0
            return cars[car].command
        case 1:
            cars[car].totalTime=Double(cars[car].penaltyTime)
            cars[car].scheduledTime=time+cars[car].totalTime; cars[car].penaltyTime=0
            return nil
        default: return nil
        }
    }
    /// The callback models rbPitCmd: tires default to ALL before it runs; return
    /// true to defer scheduling until completeMenu. It can edit the service command.
    public mutating func manage(car: Int,sample: PitAdmissionSample,time: Double,maximumDamage: Int32 = 0,
        session: RaceSessionKind,rules: RacePitRules,
        decide: (inout PitServiceCommand) -> Bool = { _ in false }) throws -> PitManagementResult {
        guard cars.indices.contains(car),time.isFinite,road.geometry.segments.indices.contains(sample.position.segment) else { throw TrackError.invalid("Invalid pit management input") }
        var result=PitManagementResult(flags:sample.flags)
        guard let stall=cars[car].stall else { return result }
        if cars[car].raceCommand & 1 != 0 { cars[car].message=stalls[stall].occupant == -1 ? "Can Pit":"Pit Occupied" }
        if sample.flags & 1 != 0 {
            cars[car].raceCommand &= ~1
            if cars[car].scheduledTime<time {
                result.flags &= ~1; stalls[stall].occupant = -1; result.released=true
            } else { cars[car].message=String(String(format:"in pits %.1fs",time-cars[car].startTime).prefix(31)) }
            return result
        }
        guard cars[car].raceCommand & 1 != 0,stalls[stall].occupant == -1,
              maximumDamage==0 || sample.damage<=maximumDamage else { return result }
        let p=sample.position, segment=road.geometry.segments[p.segment]
        let distance=segment.distanceFromStart+(segment.curve == .straight ? p.toStart:p.toStart*segment.radius)
        guard distance>stalls[stall].minimum,distance<stalls[stall].maximum,let side=road.pits.side else { return result }
        guard let strip=(side == .right ? segment.right:segment.left) else { throw TrackError.invalid("Original pit admission would dereference a missing side strip") }
        var width=road.geometry.width(segment:strip,toStart:p.toStart)
        if let outer=(side == .right ? road.geometry.segments[strip].right:road.geometry.segments[strip].left) { width += road.geometry.width(segment:outer,toStart:p.toStart) }
        let border=side == .right ? p.toRight:p.toLeft
        guard Double(border+width)<Double(road.pits.laneWidth)-Double(registrations[car].width)/2,
              abs(sample.speed.x)<1,abs(sample.speed.y)<1 else { return result }
        result.flags |= 1; result.entered=true; cars[car].stops += 1
        if let index=stalls[stall].cars.firstIndex(of:car) { stalls[stall].occupant=Int32(index) }
        cars[car].startTime=time; cars[car].command.changeAllTires=true
        if decide(&cars[car].command) { cars[car].awaitingMenu=true; result.menuRequested=true }
        else { result.service=schedule(car,time:time,session:session,rules:rules) }
        return result
    }
    public mutating func completeMenu(car: Int,command: PitServiceCommand,stopType: Int32 = 0,time: Double,
        session: RaceSessionKind,rules: RacePitRules) throws -> PitServiceCommand? {
        guard cars.indices.contains(car),cars[car].awaitingMenu,time.isFinite else { throw TrackError.invalid("No pending pit menu") }
        cars[car].command=command; cars[car].stopType=stopType; cars[car].awaitingMenu=false
        return schedule(car,time:time,session:session,rules:rules)
    }
    /// Physics clamps setup requests in place. Preserve the resulting car pitcmd.
    public mutating func recordService(car: Int,command: PitServiceCommand) throws {
        guard cars.indices.contains(car) else { throw TrackError.invalid("Invalid pit car") }
        cars[car].command=command
    }
}
