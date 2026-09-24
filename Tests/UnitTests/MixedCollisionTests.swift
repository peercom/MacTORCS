// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import TORCSTrack
import TORCSConfiguration
import TORCSSimulation
import TORCSReferenceSupport
import TORCSTelemetry

final class MixedCollisionTests: XCTestCase {
    func testThreeCarsAndWallAgainstOriginalSimUpdate() throws {
        let content = try ReferenceContent(fixtures:XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)))
        defer { withExtendedLifetime(content) {} }
        let definition = try VehicleDynamicsDefinition(parameters:ParameterDocument.parse(Data(contentsOf:content.category)).merging(ParameterDocument.parse(Data(contentsOf:content.car))))
        var fields = 0, wallTicks = 0, carTicks = 0, mixedTicks = 0
        for side in ["Left","Right"] {
            // A narrow road brings the wall into the same pileup; on the wide
            // fixture the cars stopped one another before reaching a wall.
            let xml = TrackWallCollisionTests.fixture(side:side,both:false,wrap:false,change:0)
                .replacingOccurrences(of:"name=\"width\" val=\"11\"",with:"name=\"width\" val=\"3\"")
            let data = Data(xml.utf8)
            let road = try TrackBuilder.buildRoad(parameters:ParameterDocument.parse(data))
            let url = content.track.deletingLastPathComponent().appendingPathComponent("mixed-strike.xml")
            try data.write(to:url)
            let world = try ReferenceWorld(track:url,car:content.car,category:content.category,cars:3,startDistance:45,spacing:5)
            defer { world.close() }
            var native = try MultiVehicleSimulation(definition:definition,road:road,carCount:3,startDistance:45,spacing:5)
            try world.settle(); try native.settle()
            for tick in 1...3500 {
                let steering: Float = side=="Left" ? 0.35 : -0.35
                let commands: [DriverCommand] = [.init(throttle:1,steering:steering,gear:1),.init(throttle:0.25,steering:steering,gear:1),.init(brake:1)]
                for i in 0..<3 { let c = commands[i]; try world.command(.init(throttle:c.throttle,brake:c.brake,steering:c.steering,gear:Int32(c.gear)),car:i) }
                try world.step(); try native.step(commands:commands)
                for i in 0..<3 {
                    let expected = try world.sample(car:i), actual = VehicleTelemetry.values(native.cars[i],track:road.geometry)
                    for (key,value) in expected {
                        let n = try XCTUnwrap(actual[key]); XCTAssertEqual(n,value,"\(side) tick \(tick) car \(i) \(key)")
                        if n != value { return }; fields += 1
                    }
                }
                if native.detectedWallPairs>0 { wallTicks += 1 }
                if native.detectedPairs>0 { carTicks += 1 }
                if native.detectedWallPairs>0 && native.detectedPairs>0 { mixedTicks += 1 }
            }
            world.close()
        }
        print("MIXED_COLLISION scenarios=2 cars=3 ticks=7000 fields=\(fields) wallTicks=\(wallTicks) carTicks=\(carTicks) mixedTicks=\(mixedTicks) maxAbsolute=0")
        XCTAssertGreaterThan(wallTicks,0); XCTAssertGreaterThan(carTicks,0); XCTAssertGreaterThan(mixedTicks,0)
    }
}
