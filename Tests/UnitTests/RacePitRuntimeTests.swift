// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSConfiguration
import TORCSReferenceSupport
import TORCSRaceEngine
import TORCSSimulation
import TORCSTrack
import TORCSTelemetry

final class RacePitRuntimeTests: XCTestCase {
    func testAutomaticPitServiceHoldAndDepartureAgainstOriginal() throws {
        var fields=0,entries=0,releases=0,held=0
        for session in [RaceSessionKind.practice,.race] {
            let content=try ReferenceContent(fixtures:XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)))
            let parameters=try ParameterDocument.parse(Data(contentsOf:content.category)).merging(ParameterDocument.parse(Data(contentsOf:content.car)))
            let road=try ChassisTestContext.road(),definition=try VehicleDynamicsDefinition(parameters:parameters)
            let pit=road.pits.positions[0],distance=road.geometry.segments[pit.segment].distanceFromStart+pit.toStart
            let world=try ReferenceWorld(track:content.track,car:content.car,category:content.category,startDistance:distance,lateralPosition:pit.toRight)
            defer { world.close(); withExtendedLifetime(content) {} }
            var physics=try MultiVehicleSimulation(definition:definition,road:road,carCount:1,startDistance:distance,lateralPosition:pit.toRight)
            for (stage,settle) in [("initial",false),("settled",true)] {
                if settle { try physics.settle(); try world.settle() }
                let native=VehicleTelemetry.values(physics.cars[0],track:road.geometry),original=try world.sample()
                for key in original.keys.sorted() { XCTAssertEqual(native[key],original[key],"\(stage) \(key)") }
            }
            try world.setRuleFactors(tires:1)
            let dimensions=definition.chassis.runningGear.mass.dimensions
            let registration=PitRegistration(team:"Native",length:dimensions.x,width:dimensions.y,skill:3)
            try world.raceRegistration(car:0,team:registration.team,length:registration.length,width:registration.width,skill:3)
            try world.initializeRacePits(carsPerPit:1)
            let rules=RacePitRules(baseTime:0.2,fuelFlow:8,repairFactor:0.007,tireFactor:1,tireChangeTime:0.4)
            var race=try RacePitSimulation(simulation:physics,registrations:[registration],parameters:[parameters],session:session,rules:rules)
            var services=0,previousFlags: UInt32=0
            var referenceTime=0.0
            for tick in 0..<6000 {
                if tick==0 || tick==1800 {
                    var setup=PitSetupMetrics.modified(definition.initialPitSetup,variant:tick==0 ? 1:2)
                    // Preserve gear availability while exercising session setup policy.
                    for i in 0..<8 { setup[.gearRatio,i]=definition.initialPitSetup[.gearRatio,i] }
                    let command=PitServiceCommand(setup:setup,fuel:8,repair:10)
                    try race.setCommand(car:0,raceCommand:1,service:command,penaltyTime:0.03)
                    try world.racePitCommand(car:0,command:1,setup:PitSetupMetrics.reference(setup),fuel:8,repair:10,tires:false,stop:0,penalty:0.03)
                }
                let drive=DriverCommand(throttle:tick<4000 ? 0:0.4,brake:tick<4000 ? 1:0,gear:tick<4000 ? 0:1)
                try world.command(.init(throttle:drive.throttle,brake:drive.brake,gear:Int32(drive.gear)))
                try world.step(); referenceTime += 0.002
                try world.manageRacePit(car:0,position:pit,flags:0,damage:0,speed:.zero,time:referenceTime,session:session.rawValue,rules:RacePitTests.reference(rules),usePublished:true)
                try race.step(commands:[drive])
                XCTAssertEqual(race.time,referenceTime)
                let flags=race.simulation.lifecycle[0].flags
                if previousFlags & 1==0 && flags & 1 != 0 { entries += 1; services += 1 }
                if previousFlags & 1 != 0 && flags & 1==0 { releases += 1 }
                if flags & 1 != 0 { held += 1 }
                previousFlags=flags
                let a=VehicleTelemetry.values(race.simulation.cars[0],track:road.geometry),b=try world.sample()
                for (key,value) in b {
                    guard a[key]==value else { return XCTFail("\(session) tick \(tick) \(key): \(a[key]!) != \(value)") }; fields += 1
                }
                let x=LifecycleContext.values(race.simulation.lifecycle[0],blocked:race.simulation.cars[0].collision.blocked),y=LifecycleContext.values(try world.lifecycle())
                for i in x.indices { guard x[i]==y[i] else { return XCTFail("\(session) tick \(tick) lifecycle \(i): \(x[i]) != \(y[i])") }; fields += 1 }
                try RacePitTests.check(race.pits,world,car:0,flags:flags,services:services)
            }
            XCTAssertEqual(services,2)
            var random=race.simulation.random
            for value in try world.randomTail() { XCTAssertEqual(random.next(),value) }
            world.close()
        }
        XCTAssertEqual(entries,4); XCTAssertEqual(releases,4); XCTAssertGreaterThan(held,0)
        print("RACE_PIT_RUNTIME scenarios=2 ticks=12000 fields=\(fields) entries=\(entries) releases=\(releases) held=\(held) randomTail=64 maxAbsolute=0")
    }
}

extension RacePitRuntimeTests {
    func testBrokenPitCarReleasesSharedStallThroughPhysics() throws {
        let content=try ReferenceContent(fixtures:XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)))
        let p=try ParameterDocument.parse(Data(contentsOf:content.category)).merging(ParameterDocument.parse(Data(contentsOf:content.car)))
        let road=try ChassisTestContext.road(),d=try VehicleDynamicsDefinition(parameters:p)
        let pit=road.pits.positions[0],distance=road.geometry.segments[pit.segment].distanceFromStart+pit.toStart
        let world=try ReferenceWorld(track:content.track,car:content.car,category:content.category,cars:2,startDistance:distance,lateralPosition:pit.toRight)
        defer { world.close(); withExtendedLifetime(content) {} }
        var physics=try MultiVehicleSimulation(definition:d,road:road,carCount:2,startDistance:distance,lateralPosition:pit.toRight)
        try physics.settle(); try world.settle(); try world.setRuleFactors(tires:1)
        let size=d.chassis.runningGear.mass.dimensions,rules=RacePitRules()
        let registration=PitRegistration(team:"Shared",length:size.x,width:size.y,skill:3)
        for car in 0..<2 { try world.raceRegistration(car:car,team:registration.team,length:size.x,width:size.y,skill:3) }
        try world.initializeRacePits(carsPerPit:2)
        var race=try RacePitSimulation(simulation:physics,registrations:[registration,registration],parameters:[p,p],carsPerPit:2,session:.race,rules:rules)
        race.maximumDamage=1000
        let service=PitServiceCommand(setup:d.initialPitSetup,fuel:8)
        try race.setCommand(car:0,raceCommand:1,service:service)
        try world.racePitCommand(car:0,command:1,setup:PitSetupMetrics.reference(service.setup),fuel:8,repair:0,tires:false,stop:0,penalty:0)
        var fields=0,time=0.0
        for tick in 0..<4000 {
            if tick==250 {
                try race.updateCarStatus(car:0,damage:2000)
                try world.updateCarStatus(car:0,damage:2000,maximumDamage:1000)
            }
            for car in 0..<2 { try world.command(.init(brake:1),car:car) }
            try world.step(); time += 0.002
            for car in 0..<2 { try world.manageRacePit(car:car,position:pit,flags:0,damage:0,speed:.zero,time:time,maximumDamage:1000,session:2,rules:RacePitTests.reference(rules),usePublished:true) }
            try race.step(commands:[.init(brake:1),.init(brake:1)])
            for car in 0..<2 {
                let a=VehicleTelemetry.values(race.simulation.cars[car],track:road.geometry),b=try world.sample(car:car)
                for (key,value) in b { guard a[key]==value else { return XCTFail("tick \(tick) car \(car) \(key): \(a[key]!) != \(value)") }; fields += 1 }
                let x=LifecycleContext.values(race.simulation.lifecycle[car],blocked:race.simulation.cars[car].collision.blocked),y=LifecycleContext.values(try world.lifecycle(car:car))
                for i in x.indices { guard x[i]==y[i] else { return XCTFail("tick \(tick) car \(car) lifecycle \(i): \(x[i]) != \(y[i])") }; fields += 1 }
                try RacePitTests.check(race.pits,world,car:car,flags:race.simulation.lifecycle[car].flags,services:car==0 ? 1:0)
            }
            if tick==249 { XCTAssertEqual(race.pits.stalls[0].occupant,0) }
            if tick>=250 { XCTAssertEqual(race.pits.stalls[0].occupant,-1); XCTAssertEqual(race.simulation.lifecycle[1].pitOccupant,-1) }
        }
        XCTAssertFalse(race.simulation.lifecycle[0].collisionRegistered)
        var random=race.simulation.random
        for value in try world.randomTail() { XCTAssertEqual(random.next(),value) }
        print("RACE_PIT_REMOVAL cars=2 ticks=4000 fields=\(fields) randomTail=32 maxAbsolute=0")
    }
    func testInteractivePitCommandPausesClockUntilCompletion() throws {
        let content=try ReferenceContent(fixtures:XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)))
        let p=try ParameterDocument.parse(Data(contentsOf:content.category)).merging(ParameterDocument.parse(Data(contentsOf:content.car)))
        let road=try ChassisTestContext.road(),d=try VehicleDynamicsDefinition(parameters:p)
        let pit=road.pits.positions[0],distance=road.geometry.segments[pit.segment].distanceFromStart+pit.toStart
        let world=try ReferenceWorld(track:content.track,car:content.car,category:content.category,startDistance:distance,lateralPosition:pit.toRight)
        defer { world.close(); withExtendedLifetime(content) {} }
        var physics=try MultiVehicleSimulation(definition:d,road:road,carCount:1,startDistance:distance,lateralPosition:pit.toRight)
        try physics.settle(); try world.settle()
        let size=d.chassis.runningGear.mass.dimensions,rules=RacePitRules(tireFactor:0)
        let registration=PitRegistration(team:"Menu",length:size.x,width:size.y,skill:3)
        try world.raceRegistration(car:0,team:registration.team,length:size.x,width:size.y,skill:3); try world.initializeRacePits(carsPerPit:1)
        var race=try RacePitSimulation(simulation:physics,registrations:[registration],parameters:[p],session:.practice,rules:rules)
        let command=PitServiceCommand(setup:d.initialPitSetup,fuel:3)
        try race.setCommand(car:0,raceCommand:1,service:command)
        try world.racePitCommand(car:0,command:1,setup:PitSetupMetrics.reference(command.setup),fuel:3,repair:0,tires:false,stop:0,penalty:0,menu:true)
        try world.command(.init(brake:1)); try world.step()
        try world.manageRacePit(car:0,position:pit,flags:0,damage:0,speed:.zero,time:0.002,session:0,rules:RacePitTests.reference(rules),usePublished:true)
        try race.step(commands:[.init(brake:1)],decide:{ _,_ in true })
        XCTAssertEqual(race.pendingMenu,0); XCTAssertEqual(race.time,0.002)
        try RacePitTests.check(race.pits,world,car:0,flags:race.simulation.lifecycle[0].flags,services:0,menus:1)
        XCTAssertThrowsError(try race.step(commands:[.init(brake:1)]))
        XCTAssertEqual(race.time,0.002); XCTAssertEqual(race.simulation.tick,1)
        try race.completeMenu(command:race.pits.cars[0].command); try world.completeRacePitMenu(car:0)
        XCTAssertNil(race.pendingMenu)
        try RacePitTests.check(race.pits,world,car:0,flags:race.simulation.lifecycle[0].flags,services:1,menus:1)
        XCTAssertThrowsError(try race.completeMenu(command:command))
    }
}
