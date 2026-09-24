// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSConfiguration
import TORCSReferenceSupport
import TORCSRaceEngine
import TORCSSimulation
import TORCSTrack

final class RacePitTests: XCTestCase {
    struct Context {
        let content: ReferenceContent, world: ReferenceWorld, road: TrackRoad, parameters: ParameterDocument
        var native: RacePitController
        init(count: Int = 4,capacity: Int = 2,skill: Int = 3,xml: String? = nil,teams: [String]? = nil) throws {
            content=try ReferenceContent(fixtures:XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)))
            parameters=try ParameterDocument.parse(Data(contentsOf:content.category)).merging(ParameterDocument.parse(Data(contentsOf:content.car)))
            if let xml { try xml.write(to:content.track,atomically:true,encoding:.utf8); road=try TrackBuilder.buildRoad(parameters:ParameterDocument.parse(Data(xml.utf8))) }
            else { road=try ChassisTestContext.road() }
            world=try ReferenceWorld(track:content.track,car:content.car,category:content.category,cars:count)
            var registrations: [PitRegistration]=[]
            for i in 0..<count {
                let r=PitRegistration(team:teams?[i] ?? "Team \(i/3)",length:4.7+Float(i)*0.01,width:1.9,skill:skill)
                registrations.append(r); try world.raceRegistration(car:i,team:r.team,length:r.length,width:r.width,skill:r.skill)
            }
            try world.initializeRacePits(carsPerPit:capacity)
            native=try RacePitController(road:road,registrations:registrations,parameters:Array(repeating:parameters,count:count),carsPerPit:capacity)
        }
        func close() { world.close(); withExtendedLifetime(content) {} }
        func sample(car: Int = 0) -> PitAdmissionSample {
            let stall=native.stalls[native.cars[car].stall!]
            let distance=(stall.minimum+stall.maximum)/2
            let segment=road.geometry.segments.firstIndex { $0.role == .main && $0.distanceFromStart<=distance && $0.distanceFromStart+$0.length>distance }!
            let s=road.geometry.segments[segment]
            let start=s.curve == .straight ? distance-s.distanceFromStart:(distance-s.distanceFromStart)/s.radius
            var p=TrackLocalPosition(segment:segment,toStart:start,toRight:road.pits.positions[native.cars[car].stall!].toRight)
            p.toLeft=s.width-p.toRight
            return .init(flags:0,damage:0,speed:.zero,position:p)
        }
    }
    static func reference(_ r: RacePitRules) -> RefRacePitRules { .init(baseTime:r.baseTime,fuelFlow:r.fuelFlow,repairFactor:r.repairFactor,tireFactor:r.tireFactor,tireChangeTime:r.tireChangeTime) }
    static func check(_ n: RacePitController,_ world: ReferenceWorld,car: Int,flags: UInt32,services: Int,menus: Int = 0) throws {
        let a=n.cars[car],b=try world.racePitState(car:car)
        XCTAssertEqual(flags,b.flags); XCTAssertEqual(a.raceCommand,b.raceCommand); XCTAssertEqual(a.stops,Int(b.stops))
        XCTAssertEqual(a.stall.map(Int32.init) ?? -1,b.stall); XCTAssertEqual(a.stall.map { n.stalls[$0].occupant } ?? -1,b.occupant)
        XCTAssertEqual(a.stopType,b.stopType); XCTAssertEqual(a.startTime,b.startTime); XCTAssertEqual(a.totalTime,b.totalTime)
        XCTAssertEqual(a.scheduledTime,b.scheduledTime); XCTAssertEqual(a.penaltyTime,b.penaltyTime)
        XCTAssertEqual(services,Int(b.services)); XCTAssertEqual(menus,Int(b.menuRequests))
        let msg=withUnsafeBytes(of:b.message) { String(cString:$0.baseAddress!.assumingMemoryBound(to:CChar.self)) }
        XCTAssertEqual(a.message,msg)
        var metrics=PitSetupMetrics(); metrics.check(a.command.setup,try world.pitSetup(car:car))
    }
    func testOriginalTeamAssignmentAndCapacity() throws {
        var cases=0
        for capacity in [-1,1,2,3,4,10] {
            let c=try Context(count:16,capacity:capacity); defer { c.close() }
            for (i,n) in c.native.stalls.enumerated() {
                let o=try c.world.raceStall(i)
                XCTAssertEqual(n.cars.count,Int(o.count)); XCTAssertEqual(n.occupant,o.occupant)
                XCTAssertEqual(n.minimum,o.minimum); XCTAssertEqual(n.maximum,o.maximum)
                let cars=withUnsafeBytes(of:o.cars) { Array($0.bindMemory(to:Int32.self)) }
                XCTAssertEqual(n.cars.map(Int32.init),Array(cars.prefix(Int(o.count)))); cases += 1
            }
            c.close()
        }
        print("RACE_PIT_ASSIGN stalls=\(cases) maxAbsolute=0")
    }
    func testAdmissionSharedStallAndStrictRelease() throws {
        var c=try Context(); defer { c.close() }
        let rules=RacePitRules(),r=Self.reference(rules)
        for car in 0..<2 {
            let command=PitServiceCommand(setup:c.native.cars[car].command.setup,fuel:4,repair:25)
            try c.native.setCommand(car:car,raceCommand:1,service:command)
            try c.world.racePitCommand(car:car,command:1,setup:PitSetupMetrics.reference(command.setup),fuel:4,repair:25,tires:false,stop:0,penalty:0)
        }
        var flags: [UInt32]=[0,0],services=[0,0],cases=0
        let deadline=10+Double(rules.baseTime)+4/Double(rules.fuelFlow)+Double(Float(25)*rules.repairFactor)+Double(rules.tireChangeTime)
        for (car,time) in [(0,10.0),(1,10.0),(0,deadline),(1,deadline),(0,deadline.nextUp),(1,deadline.nextUp),(1,deadline+100)] {
            var sample=c.sample(car:car); sample.flags=flags[car]
            let result=try c.native.manage(car:car,sample:sample,time:time,session:.practice,rules:rules)
            try c.world.manageRacePit(car:car,position:sample.position,flags:sample.flags,damage:sample.damage,speed:sample.speed,time:time,session:0,rules:r)
            if var command=result.service {
                // Apply native physics adjustment to the command in its own state.
                var vehicle=try SingleVehicleSimulation(definition:VehicleDynamicsDefinition(parameters:c.parameters),road:c.road)
                try vehicle.service(&command); try c.native.recordService(car:car,command:command); services[car] += 1
            }
            flags[car]=result.flags
            try Self.check(c.native,c.world,car:car,flags:flags[car],services:services[car]); cases += 1
        }
        XCTAssertEqual(services,[1,1]); XCTAssertEqual(c.native.stalls[0].occupant,-1)
        print("RACE_PIT_SEQUENCE transitions=\(cases) maxAbsolute=0")
    }
}

extension RacePitTests {
    func testServiceTimingSetupPolicyAndMenuAgainstOriginal() throws {
        var cases=0,services=0,setupFields=0
        for session in [RaceSessionKind.practice,.qualifying,.race] {
            for variant in 0..<12 {
                var c=try Context(count:1,skill:[0,2,3,4][variant%4]); defer { c.close() }
                let rules=RacePitRules(baseTime:1.3,fuelFlow:7.1,repairFactor:0.0063,tireFactor:variant%3==0 ? 0:1,tireChangeTime:13.7)
                var command=PitServiceCommand(setup:PitSetupMetrics.modified(c.native.cars[0].command.setup,variant:variant),fuel:Float(variant-6)*1.3,repair:Int32(variant-6)*31,changeAllTires:false)
                let stop: Int32=variant%3==0 ? 1:0,penalty=Float(variant)*0.37
                let menu=variant%2==0,tires=variant%3 != 1
                try c.native.setCommand(car:0,raceCommand:5,service:command,stopType:stop,penaltyTime:penalty)
                try c.world.racePitCommand(car:0,command:5,setup:PitSetupMetrics.reference(command.setup),fuel:command.fuel,repair:command.repair,tires:false,stop:stop,penalty:penalty,menu:menu,tireOverride:tires ? 1:0)
                let sample=c.sample(),time=123.456
                let result=try c.native.manage(car:0,sample:sample,time:time,session:session,rules:rules,decide:{ $0.changeAllTires=tires; return menu })
                try c.world.manageRacePit(car:0,position:sample.position,flags:0,damage:0,speed:.zero,time:time,session:session.rawValue,rules:Self.reference(rules))
                XCTAssertTrue(result.entered)
                var service=result.service
                if menu {
                    XCTAssertTrue(result.menuRequested); XCTAssertTrue(c.native.cars[0].awaitingMenu)
                    service=try c.native.completeMenu(car:0,command:c.native.cars[0].command,stopType:stop,time:time,session:session,rules:rules)
                    try c.world.completeRacePitMenu(car:0)
                }
                if let requested=service {
                    command=requested
                    var vehicle=try SingleVehicleSimulation(definition:VehicleDynamicsDefinition(parameters:c.parameters),road:c.road)
                    try vehicle.service(&command); try c.native.recordService(car:0,command:command); services += 1
                }
                try Self.check(c.native,c.world,car:0,flags:result.flags,services:stop==0 ? 1:0,menus:menu ? 1:0)
                setupFields += 270; cases += 1; c.close()
            }
        }
        print("RACE_PIT_TIMING cases=\(cases) services=\(services) setupFields=\(setupFields) maxAbsolute=0")
    }
    func testAdmissionBoundaryGatesAgainstOriginal() throws {
        var cases=0,admitted=0
        for variant in 0..<22 {
            var c=try Context(count:1); defer { c.close() }
            let command=c.native.cars[0].command,rules=RacePitRules()
            var sample=c.sample(),maximum: Int32=1000,request: UInt32=1
            let stall=c.native.stalls[0],s=c.road.geometry.segments[sample.position.segment]
            switch variant {
            case 0: sample.position.toStart=stall.minimum-s.distanceFromStart
            case 1: sample.position.toStart=stall.maximum-s.distanceFromStart
            case 2: sample.position.toStart=(stall.minimum-s.distanceFromStart).nextDown
            case 3: sample.position.toStart=(stall.maximum-s.distanceFromStart).nextUp
            case 4: sample.speed.x=1
            case 5: sample.speed.x = -1
            case 6: sample.speed.y=1
            case 7: sample.speed.y = -1
            case 8: sample.speed.x=Float(1).nextDown
            case 9: sample.speed.y = -Float(1).nextDown
            case 10: sample.damage=1001
            case 11: sample.damage=1000
            case 12: maximum=0; sample.damage=Int32.max
            case 13: request=0
            case 14: request=2
            case 15: request=5
            case 16: sample.flags=0x100
            case 17: sample.flags=2 // Original admission has no DNF gate.
            case 18,19,20,21:
                let strip=s.right!,outer=c.road.geometry.segments[strip].right
                var width=c.road.geometry.width(segment:strip,toStart:sample.position.toStart)
                if let outer { width += c.road.geometry.width(segment:outer,toStart:sample.position.toStart) }
                let edge=Float(Double(c.road.pits.laneWidth)-Double(c.native.registrations[0].width)/2)-width
                sample.position.toRight=variant==18 ? edge:variant==19 ? edge.nextUp:variant==20 ? edge.nextDown:edge-0.01
            default: break
            }
            sample.position.toLeft=s.width-sample.position.toRight
            try c.native.setCommand(car:0,raceCommand:request,service:command)
            try c.world.racePitCommand(car:0,command:request,setup:PitSetupMetrics.reference(command.setup),fuel:0,repair:0,tires:false,stop:0,penalty:0)
            let result=try c.native.manage(car:0,sample:sample,time:10,maximumDamage:maximum,session:.race,rules:rules)
            try c.world.manageRacePit(car:0,position:sample.position,flags:sample.flags,damage:sample.damage,speed:sample.speed,time:10,maximumDamage:maximum,session:2,rules:Self.reference(rules))
            if var command=result.service {
                var vehicle=try SingleVehicleSimulation(definition:VehicleDynamicsDefinition(parameters:c.parameters),road:c.road)
                try vehicle.service(&command); try c.native.recordService(car:0,command:command); admitted += 1
            }
            try Self.check(c.native,c.world,car:0,flags:result.flags,services:result.entered ? 1:0); cases += 1; c.close()
        }
        XCTAssertGreaterThan(admitted,0); XCTAssertLessThan(admitted,cases)
        print("RACE_PIT_GATES cases=\(cases) admitted=\(admitted) maxAbsolute=0")
    }
}

extension RacePitTests {
    func testAuthoredPitSidesCurvesWrapAndExhaustionAgainstOriginal() throws {
        var stalls=0,entries=0,unassigned=0
        for side in ["left","right"] { for wrap in [false,true] { for markers in [false,true] {
            let xml=TrackGeometryTests.infrastructureFixture(side:side,wrap:wrap,validMarkers:markers)
            var c=try Context(count:16,capacity:1,xml:xml); defer { c.close() }
            for (i,n) in c.native.stalls.enumerated() {
                let o=try c.world.raceStall(i)
                XCTAssertEqual(n.minimum,o.minimum); XCTAssertEqual(n.maximum,o.maximum); XCTAssertEqual(n.cars.count,Int(o.count)); stalls += 1
            }
            for car in 0..<16 {
                guard c.native.cars[car].stall != nil else {
                    XCTAssertEqual(try c.world.racePitState(car:car).stall,-1); unassigned += 1; continue
                }
                let command=c.native.cars[car].command,rules=RacePitRules()
                try c.native.setCommand(car:car,raceCommand:1,service:command,stopType:1)
                try c.world.racePitCommand(car:car,command:1,setup:PitSetupMetrics.reference(command.setup),fuel:0,repair:0,tires:false,stop:1,penalty:0)
                let sample=c.sample(car:car)
                let result=try c.native.manage(car:car,sample:sample,time:10,session:.race,rules:rules)
                try c.world.manageRacePit(car:car,position:sample.position,flags:0,damage:0,speed:.zero,time:10,session:2,rules:Self.reference(rules))
                try Self.check(c.native,c.world,car:car,flags:result.flags,services:0)
                if result.entered { entries += 1 }
            }
            c.close()
        } } }
        XCTAssertGreaterThan(entries,0); XCTAssertGreaterThan(unassigned,0)
        print("RACE_PIT_TRACKS scenarios=8 stalls=\(stalls) entries=\(entries) unassigned=\(unassigned) maxAbsolute=0")
    }
    func testTeamNamesUseOriginalByteEquality() throws {
        let c=try Context(count:4,capacity:4,teams:["Café","Cafe\u{301}","Café","Cafe\u{301}"])
        defer { c.close() }
        XCTAssertEqual(c.native.stalls[0].cars,[0,2]); XCTAssertEqual(c.native.stalls[1].cars,[1,3])
        for car in 0..<4 { XCTAssertEqual(c.native.cars[car].stall.map(Int32.init),try c.world.racePitState(car:car).stall) }
    }
}
