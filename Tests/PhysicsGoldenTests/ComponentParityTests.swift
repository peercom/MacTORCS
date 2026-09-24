// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSSimulation
import TORCSTelemetry

// The upstream oracle uses mutable globals and is intentionally called serially.
final class ComponentParityTests: XCTestCase {
    func testSuspensionBoundariesAndBellcranksAgainstOriginal() {
        for ratio: Float in [0.5, 1, 1.7] {
            let definition = SuspensionDefinition(bellcrank: ratio, packers: 0.01)
            let config = RefSuspensionConfig(springRate: 175000, preload: 3000, rest: 0.2, travel: 0.5, bellcrank: ratio, packers: 0.01, slowBump: 3000, fastBump: 1000, bumpThreshold: 0.5, slowRebound: 5000, fastRebound: 2000, reboundThreshold: 0.5)
            for x: Float in [-1, 0, 0.01, 0.199, 0.2, 0.3, 0.5, 2] {
                for v: Float in [-20, -10, -0.501, -0.5, -0.499, 0, 0.499, 0.5, 0.501, 10, 20] {
                    let native = definition.evaluate(displacement: x, velocity: v), original = ref_suspension(config, x, v)
                    XCTAssertEqual(native.displacement, original.displacement)
                    XCTAssertEqual(native.force, original.force, accuracy: 0.02)
                    XCTAssertEqual(native.state, original.state)
                }
            }
        }
    }
    func testSequentialSteeringAndBrakesAgainstOriginal() {
        var steering = SteeringState(), brake = BrakeState()
        var originalAngle: Float = 0, originalTemperature: Float = 0
        let system = BrakeSystem()
        for tick in 1...10000 {
            let i = ComponentInput(tick: tick)
            steering.update(command: i.steering)
            let original = ref_steering(originalAngle, i.steering, 0.43, 1, 2.5, 1.5, 0.002)
            originalAngle = original.angle
            XCTAssertEqual(steering.angle, original.angle, accuracy: 1e-6)
            XCTAssertEqual(steering.right, original.right, accuracy: 1e-6)
            XCTAssertEqual(steering.left, original.left, accuracy: 1e-6)
            let p = system.pressures(command: i.brake, clicks: i.clicks)
            let op = ref_brake_pressures(i.brake, 1_000_000, 0.5, 0.0025, 20, i.clicks)
            XCTAssertEqual(p.front, op.front); XCTAssertEqual(p.rear, op.rear)
            brake.update(coefficient: 0.00006, radius: 0.1, pressure: p.front, longitudinalSpeed: i.speed, wheelSpin: i.spin)
            let ob = ref_brake(0.00006, 0.1, op.front, i.speed, i.spin, originalTemperature, 0.002)
            originalTemperature = ob.temperature
            XCTAssertEqual(brake.torque, ob.torque); XCTAssertEqual(brake.temperature, ob.temperature, accuracy: 1e-6)
        }
    }
    func testBrakeRepartitionSaturatesAndTemperatureClamps() {
        var system = BrakeSystem(); system.repartition = 0.99; system.clickValue = 0.5
        let p = system.pressures(command: 1, clicks: 100)
        XCTAssertEqual(p.front, 1_000_000); XCTAssertEqual(p.rear, 0)
        var brake = BrakeState(temperature: 0.99)
        brake.update(coefficient: 0.1, radius: 1, pressure: 1e10, longitudinalSpeed: 0, wheelSpin: 1000)
        XCTAssertEqual(brake.temperature, 1)
        brake.update(coefficient: 0.1, radius: 1, pressure: 0, longitudinalSpeed: 1e10, wheelSpin: 0)
        XCTAssertEqual(brake.temperature, 0)
    }
    func testCommittedGoldenSamples() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "components", withExtension: "jsonl", subdirectory: "Fixtures"))
        let reference = try TelemetryIO.read(url)
        var steering = SteeringState(), brake = BrakeState(), candidate: [TelemetryRecord] = []
        let definition = SuspensionDefinition(), system = BrakeSystem()
        for r in reference {
            let i = ComponentInput(tick: r.tick), s = definition.evaluate(displacement: i.displacement, velocity: i.velocity)
            steering.update(command: i.steering)
            let p = system.pressures(command: i.brake, clicks: i.clicks)
            brake.update(coefficient: 0.00006, radius: 0.1, pressure: p.front, longitudinalSpeed: i.speed, wheelSpin: i.spin)
            candidate.append(.init(scenario: r.scenario, tick: r.tick, time: r.time, values: [
                "suspension.displacement": Double(s.displacement), "suspension.force": Double(s.force), "suspension.state": Double(s.state),
                "steering.angle": Double(steering.angle), "steering.right": Double(steering.right), "steering.left": Double(steering.left),
                "brake.frontPressure": Double(p.front), "brake.rearPressure": Double(p.rear), "brake.torque": Double(brake.torque), "brake.temperature": Double(brake.temperature)]))
        }
        let report = try TelemetryDiff.compare(reference: reference, candidate: candidate)
        XCTAssertTrue(report.passed, report.text)
    }
}
