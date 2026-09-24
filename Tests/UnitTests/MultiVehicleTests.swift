// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import TORCSConfiguration
import TORCSSimulation
import TORCSTelemetry
import TORCSReferenceSupport

final class MultiVehicleTests: XCTestCase {
    func testNativeTwoCarCollisionAgainstOriginalSimUpdate() throws { try run(cars:2,spacing:10,ticks:3000) }
    func testNativeThreeCarPileupAgainstOriginalSimUpdate() throws { try run(cars:3,spacing:5,ticks:2000) }
    private func run(cars: Int,spacing: Float,ticks: Int) throws {
        let road = try ChassisTestContext.road()
        let content = try ReferenceContent(fixtures:XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)))
        let p = try ParameterDocument.parse(Data(contentsOf:content.category)).merging(ParameterDocument.parse(Data(contentsOf:content.car)))
        let original = try ReferenceWorld(track:content.track,car:content.car,category:content.category,cars:cars,spacing:spacing)
        defer { original.close(); withExtendedLifetime(content) {} }
        var native = try MultiVehicleSimulation(definition:VehicleDynamicsDefinition(parameters:p),road:road,carCount:cars,spacing:spacing)
        try native.settle(); try original.settle()
        var fields = 0, collisionTicks = 0, multiplePairs = 0, worst: Double = 0, maxDamage: Int32 = 0
        for tick in 1...ticks {
            var commands: [DriverCommand] = []
            for car in 0..<cars {
                let c = VehicleScenario.carCollision.command(tick:tick,car:car)
                try original.command(c,car:car)
                commands.append(.init(throttle:c.throttle,brake:c.brake,steering:c.steering,clutch:c.clutch,gear:Int(c.gear)))
            }
            try original.step(); try native.step(commands:commands)
            for car in 0..<cars {
                let expected = try original.sample(car:car), actual = VehicleTelemetry.values(native.cars[car],track:road.geometry)
                XCTAssertEqual(Set(actual.keys),Set(expected.keys))
                for (field,value) in expected {
                    let n = try XCTUnwrap(actual[field]); XCTAssertTrue(n.isFinite && value.isFinite)
                    XCTAssertEqual(n,value,accuracy:1e-5+1e-6*abs(value),"car \(car) tick \(tick) \(field)")
                    fields += 1; worst = max(worst,abs(n-value))
                }
            }
            if native.detectedPairs>0 { collisionTicks += 1 }
            if native.detectedPairs>1 { multiplePairs += 1 }
            maxDamage = max(maxDamage,native.cars.reduce(0) { $0+$1.damage })
            if worst != 0 { XCTFail("First multi-car divergence at tick \(tick)"); return }
        }
        if cars==3 { XCTAssertGreaterThan(multiplePairs,0) }
        XCTAssertGreaterThan(collisionTicks,0); XCTAssertGreaterThan(maxDamage,0); XCTAssertEqual(native.random.draws,UInt64((501+ticks)*cars))
        print("MULTI_VEHICLE cars=\(cars) ticks=\(ticks) multiplePairTicks=\(multiplePairs) fields=\(fields) maxAbsolute=\(worst) collisionTicks=\(collisionTicks) maximumDamage=\(maxDamage)")
    }
}
