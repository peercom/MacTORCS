// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSConfiguration
import TORCSSimulation
import TORCSTelemetry
import TORCSReferenceSupport

final class PitServiceTests: XCTestCase {
    func testServiceAndPostPitDrivingAgainstOriginalSimUpdate() throws {
        var fields=0,ticks=0,services=0,heated=0,changedWear=0,setupMetrics=PitSetupMetrics(),powertrain=TransmissionMetrics()
        for layout in ["4WD","RWD","FWD"] {
            let content=try ReferenceContent(fixtures:XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)))
            // Authored layout variants in temporary staging; pinned files remain unchanged.
            for url in [content.car,content.category] {
                let xml=try String(contentsOf:url,encoding:.utf8).replacingOccurrences(of:"val=\"4WD\"",with:"val=\"\(layout)\"")
                try xml.write(to:url,atomically:true,encoding:.utf8)
            }
            let p=try ParameterDocument.parse(Data(contentsOf:content.category)).merging(ParameterDocument.parse(Data(contentsOf:content.car)))
            let world=try ReferenceWorld(track:content.track,car:content.car,category:content.category)
            defer { world.close(); withExtendedLifetime(content) {} }
            var native=try SingleVehicleSimulation(definition:VehicleDynamicsDefinition(parameters:p),road:ChassisTestContext.road())
            try native.settle(); try world.settle(); try world.setRuleFactors(tires:1)
            let base=native.vehicle.pitSetup
            func compare(_ tick: Int) throws -> Bool {
                let expected=try world.sample(),actual=VehicleTelemetry.values(native.vehicle,track:native.road.geometry)
                for (key,value) in expected {
                    if actual[key] != value { XCTFail("\(layout) tick \(tick) \(key): \(actual[key]!) != \(value)"); return false }; fields += 1
                }
                var a=LifecycleContext.values(native.lifecycle,blocked:native.vehicle.collision.blocked),b=LifecycleContext.values(try world.lifecycle())
                let s=native.lifecycle
                a += [Double(native.vehicle.definition.controls.steeringLock)]+native.vehicle.definition.transmission.gears.map { Double($0.ratio) }
                for i in 0..<4 { a += [Double(s.publishedTireGraining[i]),Double(s.publishedTirePressure[i]),Double(s.publishedTireTemperature[i]),Double(s.publishedTireWear[i])] }
                b += try world.servicePublication()
                for i in a.indices {
                    if !a[i].isFinite || a[i] != b[i] { XCTFail("\(layout) tick \(tick) lifecycle/publication \(i): \(a[i]) != \(b[i])"); return false }; fields += 1
                }
                return true
            }
            for tick in 0..<4500 {
                if [600,1800,3200].contains(tick) { try native.updateCarStatus(flags:1,pitOccupant:0); try world.updateCarStatus(car:0,flags:1,pitOccupant:0) }
                if [800,2000,3400].contains(tick) { try native.updateCarStatus(flags:0); try world.updateCarStatus(car:0,flags:0) }
                if [650,1850,3250].contains(tick) {
                    let v=tick/1000
                    var setup=PitSetupMetrics.modified(base,variant:v)
                    // Explicit, valid race setups, including differential bias clipping.
                    for i in 0..<3 {
                        setup[.differentialRatio,i] = .init(value:i==2 ? 4.2:1.15,minimum:0.8,maximum:5)
                        setup[.lockingTorque,i] = .init(value:2100,minimum:1000,maximum:4000)
                        setup[.brakingLockingTorque,i] = .init(value:800,minimum:400,maximum:2000)
                    }
                    var command=PitServiceCommand(setup:setup,fuel:tick==3250 ? 1000:17,repair:1200,changeAllTires:tick != 1850)
                    let oldWear=native.vehicle.runningGear.wheels.frontRight.thermal.wear
                    let response=try world.service(setup:PitSetupMetrics.reference(setup),fuel:command.fuel,repair:command.repair,changeAllTires:command.changeAllTires)
                    try native.service(&command); services += 1; setupMetrics.check(command.setup,response)
                    powertrain.setup(native.vehicle.definition.transmission,try world.transmissionSetup())
                    powertrain.state(native.vehicle.transmission,try world.transmissionState(),throttle:native.vehicle.driverCommand.throttle)
                    if command.changeAllTires { XCTAssertEqual(native.vehicle.runningGear.wheels.frontRight.thermal.wear,0); if oldWear>0 { changedWear += 1 } }
                    else { XCTAssertEqual(native.vehicle.runningGear.wheels.frontRight.thermal.wear,oldWear) }
                    guard try compare(tick) else { return }
                }
                let c=DriverCommand(throttle:tick%1200<800 ? 0.8:0,brake:tick%1200<800 ? 0:0.6,steering:tick>2400 ? 0.12:0,gear:tick%1500<1000 ? 1:2)
                try world.command(.init(throttle:c.throttle,brake:c.brake,steering:c.steering,gear:Int32(c.gear)))
                try world.step(); try native.step(command:c,tireFactor:1); ticks += 1
                guard try compare(tick) else { return }
                if native.vehicle.runningGear.wheels.frontRight.thermal.temperature>native.vehicle.runningGear.configuration.wheels[0].thermal.initialTemperature { heated += 1 }
            }
            var random=native.random
            for value in try world.randomTail() { XCTAssertEqual(random.next(),value) }
            world.close()
        }
        XCTAssertGreaterThan(heated,0); XCTAssertGreaterThan(changedWear,0); XCTAssertEqual(powertrain.values.worst,0)
        print("PIT_SERVICE scenarios=3 services=\(services) ticks=\(ticks) fields=\(fields) setupFields=\(setupMetrics.fields) transmissionFields=\(powertrain.values.fields) heated=\(heated) wornTireChanges=\(changedWear) randomTail=96 maxAbsolute=0")
    }
}
