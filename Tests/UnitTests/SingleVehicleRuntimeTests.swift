// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSSimulation
import TORCSTelemetry
import TORCSReferenceSupport

final class SingleVehicleRuntimeTests: XCTestCase {
    func testOwnedPlatformRandomStreamMatchesOriginalScaling() {
        let seeds: [UInt32] = [0,1,2,12345,0x7ffffffe,0x7fffffff,0x80000000,0xfffffffe,0xffffffff]
        for seed in seeds {
            var original = [Float](repeating:0,count:10000)
            XCTAssertEqual(ref_random_sequence(seed,&original,10000),1)
            var stream = DarwinRandomStream(seed:seed)
            for value in original { XCTAssertEqual(stream.next(),value) }
            XCTAssertEqual(stream.draws,10000)
            var copy = stream
            for _ in 0..<100 { XCTAssertEqual(stream.next(),copy.next()) }
        }
        print("OWNED_RANDOM seeds=9 draws=90000 copiedDraws=900 maxAbsolute=0")
    }
    func testFreshPrestartAndUnsupportedLifecycle() throws {
        let road = try ChassisTestContext.road()
        var chassis = ChassisMetrics(), checked = DriverMetrics()
        try EngineTestContext.withWorld { p,_,world in
            var n = try SingleVehicleSimulation(definition:VehicleDynamicsDefinition(parameters:p),road:road)
            for tick in 0..<200 {
                let c = DriverCommand(throttle:0.8,brake:0.9,steering:tick<100 ? 1 : -1,clutch:0.7,gear:4)
                let seed = UInt32(12345+tick)
                let o = try world.stepSimulation(command:c.reference,raceState:16,randomSeed:seed)
                // Prestart mechanical state is independent of exhaust randomness;
                // the complete engine/random stream is covered in the other tests.
                try n.step(command:c,mode:.prestart)
                chassis.state(n.vehicle.chassis,o.vehicle.chassis); checked.command(n.vehicle.driverCommand,o.command)
                let actual = VehicleTelemetry.values(n.vehicle,track:road.geometry), expected = try world.sample()
                XCTAssertEqual(actual,expected)
                XCTAssertNil(n.vehicle.aerodynamics); XCTAssertEqual(n.vehicle.brakePressures,.zero)
            }
            var vehicle = n.vehicle
            for flags: UInt32 in [1,2,0x80,0x800] {
                XCTAssertThrowsError(try vehicle.stepActiveVehicle(command:.init(),track:road.geometry,carFlags:flags,random:{ XCTFail("Rejected state must not draw randomness"); return 0 }))
            }
            vehicle.damage = 2
            XCTAssertThrowsError(try vehicle.stepActiveVehicle(command:.init(),track:road.geometry,maximumDamage:1,random:{ XCTFail("Rejected state must not draw randomness"); return 0 }))
        }
        XCTAssertEqual(chassis.values.worst,0); XCTAssertEqual(checked.values.worst,0)
        print("FRESH_PRESTART ticks=200 chassisFields=\(chassis.values.fields) driverFields=\(checked.values.fields) telemetryFields=28400 maxAbsolute=0")
    }
    func testIndependentNativeRuntimeMatchesContinuousOriginalScenarios() throws {
        let road = try ChassisTestContext.road()
        var count = 0, fields = 0, worst: Double = 0
        for scenario in VehicleScenario.allCases where scenario != .carCollision {
            try EngineTestContext.withWorld { p,_,world in
                var native = try SingleVehicleSimulation(definition:VehicleDynamicsDefinition(parameters:p),road:road)
                try native.settle(); try world.settle()
                XCTAssertEqual(native.random.draws,501); XCTAssertEqual(native.tick,0)
                for tick in 1...3000 {
                    let c = scenario.command(tick:tick)
                    try world.command(c); try world.step()
                    try native.step(command:.init(throttle:c.throttle,brake:c.brake,steering:c.steering,clutch:c.clutch,gear:Int(c.gear)))
                    let a = VehicleTelemetry.record(native,scenario:scenario.identifier), b = try world.record(scenario:scenario.identifier)
                    XCTAssertEqual(a.tick,b.tick); XCTAssertEqual(a.time,b.time); XCTAssertEqual(a.scenario,b.scenario)
                    XCTAssertEqual(Set(a.values.keys),Set(b.values.keys)); XCTAssertEqual(a.values.count,142)
                    for (name,value) in b.values {
                        let actual = try XCTUnwrap(a.values[name]); XCTAssertTrue(actual.isFinite && value.isFinite)
                        XCTAssertEqual(actual,value,accuracy:1e-5+1e-6*abs(value),"\(scenario.rawValue) tick \(tick) \(name)")
                        worst = max(worst,abs(actual-value)); fields += 1
                    }
                    count += 1
                    if worst != 0 { XCTFail("First continuous stream divergence: \(scenario.rawValue) tick \(tick)"); return }
                }
                XCTAssertEqual(native.random.draws,3501)
                XCTAssertThrowsError(try native.settle())
            }
        }
        XCTAssertEqual(count,15000)
        print("NATIVE_RUNTIME scenarios=5 ticks=\(count) fields=\(fields) maxAbsolute=\(worst)")
    }
}
