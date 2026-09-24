// SPDX-License-Identifier: GPL-2.0-only
// A native field placed by the original starting grid, stepped against the same
// field in original simuv2, plus a heterogeneous native field the reference
// harness cannot express (it loads one car model per world).
import XCTest
import TORCSConfiguration
import TORCSSimulation
import TORCSTelemetry
import TORCSTrack
import TORCSReferenceSupport

final class StartingGridFieldTests:XCTestCase {
    private func command(tick:Int,car:Int) -> ReferenceCommand {
        // Divergent but bounded: every car accelerates with its own small steering
        // bias, so grid slots, traffic and contacts all differ between cars.
        .init(throttle:0.35+Float(car)*0.08,brake:0,steering:0.01*Float(car)-0.01,clutch:0,gear:1)
    }
    /// The grid puts cars side by side in rows, a different contact geometry from
    /// the single-file centreline cases MultiVehicleTests already covers, so the
    /// front row is held while the row behind accelerates into it.
    private func contactCommand(car:Int,rows:Int) -> ReferenceCommand {
        car<rows ? .init(throttle:0,brake:1,steering:0,clutch:0,gear:0)
                 : .init(throttle:1,brake:0,steering:0,clutch:0,gear:1)
    }
    func testNativeGridFieldMatchesOriginalFieldStepForStep() throws {
        try compareGridField(cars:4,grid: .quickRace,ticks:1200,contact:false)
    }
    func testNativeGridFieldContactsMatchOriginalField() throws {
        // A tight grid: 8 m between columns, so the rear row reaches the held
        // front row while both are still on the starting straight.
        try compareGridField(cars:4,grid:ReferenceStartingGrid(rows:2,toStart:12,columnDistance:8,columnOffset:4),
            ticks:1500,contact:true)
    }
    private func compareGridField(cars:Int,grid:ReferenceStartingGrid,ticks:Int,contact:Bool) throws {
        let road=try ChassisTestContext.road()
        let content=try ReferenceContent(fixtures:try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)))
        let parameters=try ParameterDocument.parse(Data(contentsOf:content.category))
            .merging(ParameterDocument.parse(Data(contentsOf:content.car)))
        let definition=try VehicleDynamicsDefinition(parameters:parameters)
        let original=try ReferenceWorld(track:content.track,car:content.car,category:content.category,
            cars:cars,grid:grid)
        defer { original.close();withExtendedLifetime(content) {} }
        let slots=try StartingGrid.slots(road:road,
            configuration:StartingGridConfiguration(rows:grid.rows,toStart:grid.toStart,columnDistance:grid.columnDistance,
                columnOffset:grid.columnOffset,initialSpeed:grid.initialSpeed,initialHeight:grid.initialHeight),cars:cars)
        var native=try MultiVehicleSimulation(definitions:Array(repeating:definition,count:cars),road:road,grid:slots)
        // Placement must already agree before either side settles.
        for car in 0..<cars {
            XCTAssertEqual(native.cars[car].chassis.trackPosition.segment,slots[car].position.segment)
            XCTAssertEqual(native.cars[car].chassis.world.position,slots[car].world,"car \(car) grid position")
            XCTAssertEqual(native.cars[car].chassis.world.orientation.z,slots[car].yaw,"car \(car) grid yaw")
        }
        try native.settle();try original.settle()
        var fields=0,worst:Double=0,collisionTicks=0
        for tick in 1...ticks {
            var commands:[DriverCommand]=[]
            for car in 0..<cars {
                let c=contact ? contactCommand(car:car,rows:grid.rows):command(tick:tick,car:car)
                try original.command(c,car:car)
                commands.append(.init(throttle:c.throttle,brake:c.brake,steering:c.steering,clutch:c.clutch,gear:Int(c.gear)))
            }
            try original.step();try native.step(commands:commands)
            for car in 0..<cars {
                let expected=try original.sample(car:car),actual=VehicleTelemetry.values(native.cars[car],track:road.geometry)
                XCTAssertEqual(Set(actual.keys),Set(expected.keys))
                for (field,value) in expected {
                    let n=try XCTUnwrap(actual[field])
                    XCTAssertTrue(n.isFinite && value.isFinite,"car \(car) tick \(tick) \(field) is not finite")
                    XCTAssertEqual(n,value,accuracy:1e-5+1e-6*abs(value),"car \(car) tick \(tick) \(field)")
                    fields += 1;worst=max(worst,abs(n-value))
                }
            }
            if native.detectedPairs>0 { collisionTicks += 1 }
            if worst>1e-5 { XCTFail("First grid-field divergence at tick \(tick)");return }
        }
        if contact { XCTAssertGreaterThan(collisionTicks,0,"the tight grid must produce contacts") }
        print("NATIVE_GRID_FIELD cars=\(cars) rows=\(grid.rows) ticks=\(ticks) fields=\(fields) maxAbsolute=\(worst) collisionTicks=\(collisionTicks)")
    }
    func testNativeHeterogeneousFieldPlacesAndStepsEachCar() throws {
        let road=try ChassisTestContext.road()
        let content=try ReferenceContent(fixtures:try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)))
        let base=try ParameterDocument.parse(Data(contentsOf:content.category))
            .merging(ParameterDocument.parse(Data(contentsOf:content.car)))
        defer { withExtendedLifetime(content) {} }
        // The reference harness reads one car XML per world, so a mixed field has
        // no original counterpart; this checks the native field itself.
        func variant(mass:Float,length:Float,width:Float) throws -> VehicleDynamicsDefinition {
            let override=try ParameterDocument.parse(Data("""
            <params name="variant"><section name="Car">\
            <attnum name="mass" val="\(mass)"/><attnum name="body length" val="\(length)"/>\
            <attnum name="body width" val="\(width)"/></section></params>
            """.utf8))
            return try VehicleDynamicsDefinition(parameters:base.merging(override))
        }
        let definitions=[try variant(mass:1000,length:4.7,width:1.9),
                         try variant(mass:1250,length:5.1,width:2.05),
                         try variant(mass:900,length:4.2,width:1.75)]
        let dimensions=definitions.map(\.chassis.runningGear.mass.dimensions)
        XCTAssertEqual(Set(dimensions.map(\.x)).count,3,"each variant must have its own length")
        let slots=try StartingGrid.slots(road:road,configuration:StartingGridConfiguration(),cars:definitions.count)
        var first=try MultiVehicleSimulation(definitions:definitions,road:road,grid:slots)
        for car in definitions.indices {
            XCTAssertEqual(first.cars[car].chassis.world.position,slots[car].world,"car \(car) placement")
            XCTAssertEqual(first.cars[car].definition.chassis.runningGear.mass.dimensions,dimensions[car],
                "each car keeps its own definition")
        }
        try first.settle()
        var second=try MultiVehicleSimulation(definitions:definitions,road:road,grid:slots)
        try second.settle()
        var samples=0
        for tick in 1...600 {
            let commands=definitions.indices.map { car in
                let c=command(tick:tick,car:car)
                return DriverCommand(throttle:c.throttle,brake:c.brake,steering:c.steering,clutch:c.clutch,gear:Int(c.gear))
            }
            try first.step(commands:commands);try second.step(commands:commands)
            for car in definitions.indices {
                let a=VehicleTelemetry.values(first.cars[car],track:road.geometry)
                let b=VehicleTelemetry.values(second.cars[car],track:road.geometry)
                XCTAssertEqual(a,b,"car \(car) tick \(tick) must repeat exactly")
                samples += a.count
            }
        }
        // Different cars from different slots must not end up in the same state.
        let poses=definitions.indices.map { first.cars[$0].chassis.world.position }
        XCTAssertEqual(Set(poses.map(\.x)).count,definitions.count,"a mixed field must not collapse to one trajectory")
        XCTAssertThrowsError(try MultiVehicleSimulation(definitions:definitions,road:road,grid:Array(slots.dropLast())),
            "one grid slot per car is required")
        print("NATIVE_MIXED_FIELD cars=\(definitions.count) ticks=600 comparedValues=\(samples) repeated=exact")
    }
}
