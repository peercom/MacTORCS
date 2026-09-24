// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSConfiguration
import TORCSTrack
import TORCSSimulation
import TORCSReferenceSupport

final class WheelRideTests: XCTestCase {
    func withRoad(_ body: (TrackRoad, ReferenceWorld) throws -> Void) throws {
        let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let data = try Data(contentsOf: fixtures.appendingPathComponent("aalborg.xml"))
        let parameters = try ParameterDocument.parse(data, entities: [
            "default-surfaces": Data(contentsOf: fixtures.appendingPathComponent("surfaces.xml")),
            "default-objects": Data(contentsOf: fixtures.appendingPathComponent("objects.xml"))], allowLegacyLatin1: true)
        let native = try TrackBuilder.buildRoad(parameters: parameters)
        let content = try ReferenceContent(fixtures: fixtures)
        let world = try ReferenceWorld(track: content.track, car: content.car, category: content.category)
        defer { world.close(); withExtendedLifetime(content) {} }
        try body(native, world)
    }
    func compare(state: inout WheelRideState, at point: SIMD3<Float>, main: Int, suspension: SuspensionDefinition,
                 pressure: Float, speed: Float, spin: Float, road: TrackRoad, world: ReferenceWorld) throws -> Float {
        let input = RefWheelRideInput(position: RefTrackVector(x: point.x, y: point.y, z: point.z), mainSegment: Int32(main), flags: state.flags,
            displacement: state.displacement, relativeVelocity: state.relativeVelocity, bellcrank: suspension.bellcrank,
            packers: suspension.packers, maximumTravel: suspension.travel, brakeCoefficient: 0.00006, brakeRadius: 0.1,
            brakePressure: pressure, brakeTemperature: state.brake.temperature, longitudinalSpeed: speed, wheelSpin: spin, dt: 0.002)
        let original = try world.wheelRide(input)
        let contact = try state.update(position: point, carSegment: main, track: road.geometry, suspension: suspension,
            brakeCoefficient: 0.00006, brakeRadius: 0.1, brakePressure: pressure, longitudinalSpeed: speed, wheelSpin: spin)
        XCTAssertEqual(contact.position.segment, Int(original.position.segment))
        XCTAssertEqual(contact.position.mode.rawValue, Int(original.position.mode))
        XCTAssertEqual(state.flags, original.flags); XCTAssertEqual(state.suspensionFlags, original.suspensionFlags)
        var worst: Float = 0
        for (a,b) in [(contact.position.toStart, original.position.toStart), (contact.position.toRight, original.position.toRight),
                      (contact.position.toMiddle, original.position.toMiddle), (contact.position.toLeft, original.position.toLeft),
                      (contact.normal.x, original.normal.x), (contact.normal.y, original.normal.y), (contact.normal.z, original.normal.z),
                      (contact.roadHeight, original.roadHeight), (contact.rideHeight, original.rideHeight),
                      (state.displacement, original.displacement), (state.suspensionVelocity, original.suspensionVelocity),
                      (state.relativeVelocity, original.relativeVelocity), (state.brake.torque, original.brakeTorque),
                      (state.brake.temperature, original.brakeTemperature)] {
            XCTAssertTrue(a.isFinite && b.isFinite)
            worst = max(worst, abs(a-b))
            XCTAssertEqual(a, b, accuracy: 1e-5 + 1e-6 * abs(b))
        }
        return worst
    }
    func testContactAcrossRoadEdgesAndSuspensionLimitsAgainstOriginal() throws {
        try withRoad { road, world in
            var count = 0, compressed = 0, extended = 0, airborne = 0, grounded = 0
            var worst: Float = 0
            for offset in stride(from: 0, to: road.geometry.mainSegments.count, by: 17) {
                let main = road.geometry.mainSegments[offset], segment = road.geometry.segments[main]
                for fraction: Float in [0.2, 0.93, 1.02] {
                    for lateral: Float in [-5, -0.01, 3, 11, 25] {
                        let p = TrackLocalPosition(segment: main, toStart: segment.extent * fraction, toRight: lateral)
                        let xy = road.geometry.localToGlobal(p), height = try road.geometry.height(at: xy, startingAt: main)
                        for (i, clearance) in [Float(-0.02), 0.02, 0.2, 0.8].enumerated() {
                            for bellcrank: Float in [0.5, 1, 1.7] {
                                let definition = SuspensionDefinition(travel: 0.5, bellcrank: bellcrank, packers: 0.015)
                                var state = WheelRideState(displacement: (i == 3 ? 0.8 : 0.2) * bellcrank,
                                    relativeVelocity: i == 0 ? -2 : (i == 1 ? 120 : 3), flags: Int32(i % 3 + 8), brakeTemperature: 0.4)
                                worst = max(worst, try compare(state: &state, at: SIMD3(xy.x, xy.y, height + clearance),
                                    main: main, suspension: definition, pressure: Float(i) * 250000, speed: -23, spin: 130, road: road, world: world))
                                if state.suspensionFlags == 1 { compressed += 1 }
                                if state.suspensionFlags == 2 { extended += 1 }
                                if state.flags & 4 != 0 { airborne += 1 } else { grounded += 1 }
                                XCTAssertEqual(state.flags & 8, 8, "Ride stage preserves unrelated flags")
                                count += 1
                            }
                        }
                    }
                }
            }
            XCTAssertGreaterThan(compressed, 0); XCTAssertGreaterThan(extended, 0)
            XCTAssertGreaterThan(airborne, 0); XCTAssertGreaterThan(grounded, 0)
            print("WHEEL_RIDE samples=\(count) maxAbsolute=\(worst) compressed=\(compressed) extended=\(extended) airborne=\(airborne) grounded=\(grounded)")
        }
    }
    func testSequentialRideAndBrakeStateAgainstOriginal() throws {
        try withRoad { road, world in
            var native = WheelRideState(displacement: 0.25, relativeVelocity: -1)
            var original = RefWheelRideResult()
            original.displacement = 0.25; original.relativeVelocity = -1
            let suspension = SuspensionDefinition(bellcrank: 1.3, packers: 0.02)
            var worst: Float = 0
            for tick in 0..<5000 {
                let main = road.geometry.mainSegments[(tick / 40) % road.geometry.mainSegments.count]
                let p = TrackLocalPosition(segment: main, toStart: road.geometry.segments[main].extent * Float(tick % 40) / 40,
                                          toRight: 6 + 9 * sin(Float(tick) * 0.007))
                let xy = road.geometry.localToGlobal(p), height = try road.geometry.height(at: xy, startingAt: main)
                let position = SIMD3(xy.x, xy.y, height + 0.23 + 0.3 * sin(Float(tick) * 0.031))
                let pressure: Float = tick % 1000 < 400 ? 750000 : 0
                let input = RefWheelRideInput(position: RefTrackVector(x: position.x, y: position.y, z: position.z),
                    mainSegment: Int32(main), flags: original.flags, displacement: original.displacement, relativeVelocity: original.relativeVelocity,
                    bellcrank: 1.3, packers: 0.02, maximumTravel: 0.5, brakeCoefficient: 0.00006, brakeRadius: 0.1,
                    brakePressure: pressure, brakeTemperature: original.brakeTemperature, longitudinalSpeed: 25, wheelSpin: 120, dt: 0.002)
                original = try world.wheelRide(input)
                _ = try native.update(position: position, carSegment: main, track: road.geometry, suspension: suspension,
                    brakeCoefficient: 0.00006, brakeRadius: 0.1, brakePressure: pressure, longitudinalSpeed: 25, wheelSpin: 120)
                XCTAssertEqual(native.flags, original.flags); XCTAssertEqual(native.suspensionFlags, original.suspensionFlags)
                for (a,b) in [(native.displacement, original.displacement), (native.suspensionVelocity, original.suspensionVelocity),
                              (native.relativeVelocity, original.relativeVelocity), (native.brake.torque, original.brakeTorque),
                              (native.brake.temperature, original.brakeTemperature)] {
                    worst = max(worst, abs(a-b)); XCTAssertEqual(a,b, accuracy: 1e-5 + 1e-6 * abs(b))
                }
            }
            print("WHEEL_RIDE_SEQUENTIAL ticks=5000 maxAbsolute=\(worst)")
        }
    }
}
