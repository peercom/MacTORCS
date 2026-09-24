// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSConfiguration
import TORCSSimulation
import TORCSTelemetry
import TORCSReferenceSupport

final class VehicleLifecycleTests: XCTestCase {
    func testFuelExhaustionAndTowingAgainstOriginalSimUpdate() throws { try run(reason:0) }
    func testMovingBrokenCarAgainstOriginalSimUpdate() throws { try run(reason:1) }
    func testMovingEliminatedCarAgainstOriginalSimUpdate() throws { try run(reason:2) }
    func testBrokenPitCarReleasesStallAgainstOriginalSimUpdate() throws { try run(reason:3) }
    func testSurvivingCarsCollideWhileMiddleCarIsTowed() throws { try run(reason:4) }
    func testPitCarRemainsInCollisionDispatchUntilRemoval() throws { try run(reason:5) }
    private func run(reason: Int) throws {
        let road=try ChassisTestContext.road()
        let content=try ReferenceContent(fixtures:XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)))
        let parameters=try ParameterDocument.parse(Data(contentsOf:content.category)).merging(ParameterDocument.parse(Data(contentsOf:content.car)))
        let count=reason==4 ? 3:2, removed=(reason==4 || reason==5) ? 1:0, spacing: Float=(reason==4 || reason==5) ? 5:30
        let original=try ReferenceWorld(track:content.track,car:content.car,category:content.category,cars:count,spacing:spacing)
        defer { original.close(); withExtendedLifetime(content) {} }
        var native=try MultiVehicleSimulation(definition:VehicleDynamicsDefinition(parameters:parameters),road:road,carCount:count,spacing:spacing)
        try native.settle(); try original.settle()
        var fields=0,ticks=0,coasting=0,pairs=0,outTicks=0,phases=Set<UInt32>()
        func compare() throws -> Bool {
            for car in 0..<count {
                let expectedTelemetry=try original.sample(car:car),actualTelemetry=VehicleTelemetry.values(native.cars[car],track:road.geometry)
                for (key,value) in expectedTelemetry {
                    let n=try XCTUnwrap(actualTelemetry[key])
                    if n != value { XCTFail("reason \(reason) tick \(ticks) car \(car) \(key): \(n) != \(value)"); return false }; fields += 1
                }
                let r=try original.lifecycle(car:car),s=native.lifecycle[car]
                let actual=LifecycleContext.values(s,blocked:native.cars[car].collision.blocked),expected=LifecycleContext.values(r)
                for i in actual.indices {
                    if !actual[i].isFinite || actual[i] != expected[i] { XCTFail("reason \(reason) tick \(ticks) car \(car) published field \(i): \(actual[i]) != \(expected[i])"); return false }; fields += 1
                }
            }
            return true
        }
        func advance(_ commands: [DriverCommand],maximumDamage: Int32=0) throws -> Bool {
            for (i,c) in commands.enumerated() { try original.command(.init(throttle:c.throttle,brake:c.brake,steering:c.steering,clutch:c.clutch,gear:Int32(c.gear)),car:i) }
            try original.step(); try native.step(commands:commands,maximumDamage:maximumDamage); ticks += 1
            return try compare()
        }
        guard try compare() else { return }
        if reason==1 || reason==2 {
            for _ in 0..<650 { guard try advance([.init(throttle:1,gear:1),.init(brake:1)]) else { return } }
            XCTAssertGreaterThan(abs(native.lifecycle[0].publicBody.velocity.x),1)
        }
        if reason==3 {
            try original.updateCarStatus(car:0,flags:1,pitOccupant:0,maximumDamage:100)
            try native.updateCarStatus(car:0,flags:1,pitOccupant:0)
            for _ in 0..<40 { guard try advance([.init(throttle:0.8,gear:1),.init(brake:1)],maximumDamage:100) else { return } }
            XCTAssertEqual(native.lifecycle[0].flags,1); XCTAssertTrue(native.lifecycle[0].collisionRegistered)
        }
        if reason==5 {
            try original.updateCarStatus(car:1,flags:1,pitOccupant:1)
            try native.updateCarStatus(car:1,flags:1,pitOccupant:1)
            for _ in 0..<2200 {
                guard try advance([.init(throttle:1,gear:1),.init(throttle:0.8,gear:1)]) else { return }
                if native.detectedPairs>0 { pairs += 1 }
            }
            XCTAssertGreaterThan(pairs,0); XCTAssertTrue(native.lifecycle[1].collisionRegistered)
        }
        let maximum: Int32=reason==5 ? 100000 : ((reason==1 || reason==3) ? 100:0)
        let fuel: Float?=(reason==0 || reason==4) ? 0:nil, damage: Int32?=maximum != 0 ? maximum+1:nil
        let flags: UInt32?=reason==2 ? 0x800:nil
        try original.updateCarStatus(car:removed,flags:flags,fuel:fuel,damage:damage,maximumDamage:maximum)
        try native.updateCarStatus(car:removed,flags:flags,fuel:fuel,damage:damage)
        for stageTick in 0..<60000 {
            var commands=Array(repeating:DriverCommand(brake:1),count:count)
            commands[removed] = .init(throttle:0.8,brake:0.2,steering:0.15,gear:1)
            if reason==4 { commands[0] = .init(throttle:stageTick<2500 ? 1:0,brake:stageTick<2500 ? 0:1,gear:1) }
            guard try advance(commands,maximumDamage:maximum) else { return }
            let s=native.lifecycle[removed]; phases.insert(s.flags & 0xFF)
            if s.flags & 0xFF == 0 { coasting += 1 }
            if native.detectedPairs>0 { pairs += 1 }
            if s.flags & 0x102 == 0x102 { outTicks += 1; if outTicks==32 { break } }
        }
        XCTAssertEqual(outTicks,32); XCTAssertTrue(phases.isSuperset(of:[4,8,16,2])); XCTAssertFalse(native.lifecycle[removed].collisionRegistered)
        if reason==1 || reason==2 { XCTAssertGreaterThan(coasting,0) }
        if reason==3 || reason==5 { XCTAssertEqual(native.lifecycle[removed].pitOccupant,-1); XCTAssertEqual(native.lifecycle[removed].flags & 1,0) }
        if reason==4 { XCTAssertGreaterThan(pairs,0) }
        var random=native.random
        for value in try original.randomTail() { XCTAssertEqual(random.next(),value) }
        print("VEHICLE_LIFECYCLE reason=\(reason) cars=\(count) ticks=\(ticks) coasting=\(coasting) contactTicks=\(pairs) fields=\(fields) maxAbsolute=0 randomDraws=\(native.random.draws) randomTail=32")
    }
}

enum LifecycleContext {
    static func dynamics(_ b: ChassisDynamics) -> [Double] {
        [b.position,b.orientation,b.velocity,b.angularVelocity,b.acceleration,b.angularAcceleration].flatMap { [Double($0.x),Double($0.y),Double($0.z)] }
    }
    static func values(_ s: VehicleRemovalState,blocked: Bool) -> [Double] {
        RemovalContext.scalars(RemovalContext.input(s,dt:0.002))+dynamics(s.publicWorld)+[Double(s.publicSpeed),Double(s.publishedFuel),Double(s.publishedDamage),blocked ? 1:0]
    }
    static func values(_ s: RefLifecycleOutput) -> [Double] {
        let b=s.publicWorld
        let world=[b.position,b.orientation,b.velocity,b.angularVelocity,b.acceleration,b.angularAcceleration].flatMap { [Double($0.x),Double($0.y),Double($0.z)] }
        return RemovalContext.scalars(s.removal)+world+[Double(s.publicSpeed),Double(s.publishedFuel),Double(s.publishedDamage),Double(s.blocked)]
    }
}

extension VehicleLifecycleTests {
    func testFreshInactiveStatesThenPrestartAgainstOriginal() throws {
        let road=try ChassisTestContext.road()
        let content=try ReferenceContent(fixtures:XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)))
        let p=try ParameterDocument.parse(Data(contentsOf:content.category)).merging(ParameterDocument.parse(Data(contentsOf:content.car)))
        let original=try ReferenceWorld(track:content.track,car:content.car,category:content.category,cars:2)
        defer { original.close(); withExtendedLifetime(content) {} }
        var native=try MultiVehicleSimulation(definition:VehicleDynamicsDefinition(parameters:p),road:road,carCount:2)
        try original.updateCarStatus(car:0,flags:1,pitOccupant:0); try native.updateCarStatus(car:0,flags:1,pitOccupant:0)
        try original.updateCarStatus(car:1,flags:2); try native.updateCarStatus(car:1,flags:2)
        var fields=0
        for tick in 0..<160 {
            if tick==40 { try original.updateCarStatus(car:0,flags:0); try native.updateCarStatus(car:0,flags:0) }
            if tick==80 { try original.updateCarStatus(car:0,fuel:0); try native.updateCarStatus(car:0,fuel:0) }
            for car in 0..<2 { try original.command(.init(throttle:0.5,brake:0.2,gear:1),car:car) }
            try original.step(raceState:16); try native.step(commands:Array(repeating:.init(throttle:0.5,brake:0.2,gear:1),count:2),mode:.prestart)
            for car in 0..<2 {
                let a=VehicleTelemetry.values(native.cars[car],track:road.geometry),b=try original.sample(car:car)
                for (key,value) in b { if a[key] != value { XCTFail("prestart tick \(tick) car \(car) \(key): \(a[key]!) != \(value)"); return }; fields += 1 }
                let actual=LifecycleContext.values(native.lifecycle[car],blocked:native.cars[car].collision.blocked),expected=LifecycleContext.values(try original.lifecycle(car:car))
                for i in actual.indices { if !actual[i].isFinite || actual[i] != expected[i] { XCTFail("prestart tick \(tick) car \(car) published \(i): \(actual[i]) != \(expected[i])"); return }; fields += 1 }
            }
        }
        XCTAssertEqual(native.lifecycle[1].flags,2); XCTAssertTrue(native.lifecycle[1].collisionRegistered)
        XCTAssertEqual(native.lifecycle[0].flags & 4,4); XCTAssertFalse(native.lifecycle[0].collisionRegistered)
        XCTAssertThrowsError(try native.updateCarStatus(car:0,flags:0))
        var random=native.random
        for value in try original.randomTail() { XCTAssertEqual(random.next(),value) }
        print("VEHICLE_LIFECYCLE_PRESTART ticks=160 fields=\(fields) maxAbsolute=0 randomDraws=\(native.random.draws) randomTail=32")
    }
}

extension VehicleLifecycleTests {
    func testSingleFacadeRetainsRemovalStateAcrossDefaultSteps() throws {
        let road=try ChassisTestContext.road()
        let content=try ReferenceContent(fixtures:XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)))
        let p=try ParameterDocument.parse(Data(contentsOf:content.category)).merging(ParameterDocument.parse(Data(contentsOf:content.car)))
        let original=try ReferenceWorld(track:content.track,car:content.car,category:content.category)
        defer { original.close(); withExtendedLifetime(content) {} }
        var native=try SingleVehicleSimulation(definition:VehicleDynamicsDefinition(parameters:p),road:road)
        try native.settle(); try original.settle()
        try native.updateCarStatus(fuel:0); try original.updateCarStatus(car:0,fuel:0)
        let draws=native.random.draws
        var fields=0
        for tick in 0..<120 {
            try original.command(.init(throttle:0.7,brake:0.2,gear:1)); try original.step()
            try native.step(command:.init(throttle:0.7,brake:0.2,gear:1))
            let a=VehicleTelemetry.values(native.vehicle,track:road.geometry),b=try original.sample()
            for (key,value) in b { if a[key] != value { XCTFail("single tick \(tick) \(key)"); return }; fields += 1 }
            let actual=LifecycleContext.values(native.lifecycle,blocked:native.vehicle.collision.blocked),expected=LifecycleContext.values(try original.lifecycle())
            for i in actual.indices { if !actual[i].isFinite || actual[i] != expected[i] { XCTFail("single tick \(tick) published field \(i)"); return }; fields += 1 }
        }
        XCTAssertEqual(native.lifecycle.flags & 4,4); XCTAssertFalse(native.lifecycle.collisionRegistered)
        XCTAssertEqual(native.random.draws,draws)
        var random=native.random
        for value in try original.randomTail() { XCTAssertEqual(random.next(),value) }
        print("VEHICLE_LIFECYCLE_SINGLE ticks=120 fields=\(fields) maxAbsolute=0 randomDraws=\(native.random.draws) randomTail=32")
    }
}
