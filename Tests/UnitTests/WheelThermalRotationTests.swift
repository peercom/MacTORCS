// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSSimulation

final class WheelThermalRotationTests: XCTestCase {
    let config = RefTireThermalConfig(pressure: 275600, initialTemperature: 293.15, idealTemperature: 368.15,
        treadMass: 2.14, baseMass: 4.87, gasMass: 0.119, convectionSurface: 0.61, hysteresisFactor: 1.12, wearFactor: 1.3)
    var definition: TireThermalDefinition {
        TireThermalDefinition(pressure: config.pressure, initialTemperature: config.initialTemperature,
            idealTemperature: config.idealTemperature, treadMass: config.treadMass, baseMass: config.baseMass,
            gasMass: config.gasMass, convectionSurface: config.convectionSurface, hysteresisFactor: config.hysteresisFactor, wearFactor: config.wearFactor)
    }
    func compare(_ n: TireThermalState, _ o: RefTireThermalState, file: StaticString = #filePath, line: UInt = #line) -> Double {
        let values = [(Double(n.pressure), Double(o.pressure)), (Double(n.temperature), Double(o.temperature)),
                      (Double(n.graining), Double(o.graining)), (Double(n.grip), Double(o.grip)), (n.wear, o.wear)]
        var worst = 0.0
        for (a,b) in values {
            XCTAssertTrue(a.isFinite && b.isFinite, file: file, line: line)
            XCTAssertEqual(a,b,accuracy: 1e-5 + 1e-6 * abs(b), file: file, line: line)
            worst = max(worst, abs(a-b))
        }
        // Do not accidentally accept Float precision for the original double wear accumulator.
        XCTAssertEqual(n.wear, o.wear, accuracy: 1e-12 + 1e-10 * abs(o.wear), file: file, line: line)
        return worst
    }
    func testThermalWearGrainingAndSkillGatesAgainstOriginal() {
        var count = 0, worst = 0.0, worn = 0, cold = 0, hot = 0
        for temperature: Float in [270, 293.15, 340, 368.15, 450] {
            for wear in [0.0, 0.4, 0.999999, 1] {
                for graining: Float in [0, 0.9, 1] {
                    for skill in 0..<5 {
                        for factor: Float in [-1, 0, 1, 100] {
                            for spin: Float in [-200, 0, 310] {
                                let pressure: Float = temperature / config.initialTemperature * config.pressure
                                var n = TireThermalState(pressure: pressure, temperature: temperature, wear: wear, graining: graining, grip: 0.85)
                                let initial = RefTireThermalState(pressure: pressure, temperature: temperature, graining: graining, grip: 0.85, wear: wear)
                                let o = ref_tire_thermal(config, initial, 6000, 1.5, spin, 0.32, 293.15, 101325, Int32(skill), factor, 0.002, 0)
                                n.update(definition: definition, tireLoad: 6000, slip: 1.5, spin: spin, radius: 0.32,
                                         localTemperature: 293.15, localPressure: 101325, skillLevel: skill, tireFactor: factor)
                                worst = max(worst, compare(n,o)); count += 1
                                if skill == 3 && factor > 0 {
                                    if n.wear == 1 { worn += 1 }
                                    if n.graining > graining { cold += 1 }
                                    if n.graining < graining { hot += 1 }
                                } else {
                                    XCTAssertEqual(n.temperature, temperature); XCTAssertEqual(n.wear, wear); XCTAssertEqual(n.grip, 0.85)
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(worn, 0); XCTAssertGreaterThan(cold, 0); XCTAssertGreaterThan(hot, 0)
        print("TIRE_THERMAL samples=\(count) maxAbsolute=\(worst) worn=\(worn) grainingIncreased=\(cold) grainingDecreased=\(hot)")
    }
    func testIndependentThermalSequenceAndResetAgainstOriginal() {
        var native = TireThermalState(pressure: config.pressure, temperature: config.initialTemperature)
        var original = RefTireThermalState(pressure: config.pressure, temperature: config.initialTemperature, graining: 0, grip: 1, wear: 0)
        var worst = 0.0, resets = 0
        for tick in 0..<20000 {
            let load: Float = 4500 + 4000 * sin(Float(tick) * 0.002)
            let slip: Float = 0.75 + 0.7 * sin(Float(tick) * 0.0009)
            let spin: Float = 210 * sin(Float(tick) * 0.0011)
            let reset = tick == 9999
            original = ref_tire_thermal(config, original, load, slip, spin, 0.32, 288.15, 96000, 3, 2, 0.002, reset ? 1 : 0)
            if reset { native.reset(definition: definition, localTemperature: 288.15); resets += 1 }
            else { native.update(definition: definition, tireLoad: load, slip: slip, spin: spin, radius: 0.32,
                                 localTemperature: 288.15, localPressure: 96000, skillLevel: 3, tireFactor: 2) }
            worst = max(worst, compare(native, original))
        }
        XCTAssertGreaterThan(native.wear, 0); XCTAssertNotEqual(native.temperature, config.initialTemperature)
        print("TIRE_THERMAL_SEQUENTIAL ticks=20000 maxAbsolute=\(worst) resets=\(resets)")
    }
    func testFreeWheelBrakingStopsWithoutReversing() {
        for spin: Float in [-200, -0.001, 0, 0.001, 200] {
            for torque: Float in [-2000, 0, 2000] {
                for axle in 0..<2 {
                    var n = WheelRotationState(spin: spin, previousSpin: 17, angle: 3.14)
                    let o = ref_wheel_rotation(spin, 17, 3.14, 0, torque, 1000000, 1.7, 0.6, 0.002, Int32(axle), 1)
                    let input = n.updateFree(tireTorque: torque, brakeTorque: 1000000, wheelInertia: 1.7, axleInertia: 0.6)
                    XCTAssertEqual(input, 0); XCTAssertEqual(input, o.inputSpin)
                    n.update(drivetrainSpin: input)
                    XCTAssertEqual(n.spin,o.spin); XCTAssertEqual(n.previousSpin,o.previousSpin); XCTAssertEqual(n.angle,o.angle)
                    XCTAssertEqual(n.spin,o.publishedSpin)
                }
            }
        }
        print("WHEEL_ROTATION_LOCK samples=30 maxAbsolute=0")
    }
    func testIndependentFreeAndDrivenRotationSequenceAgainstOriginal() {
        var worst: Float = 0, wraps = 0
        for axle in 0..<2 {
            var native = WheelRotationState(spin: -100, previousSpin: -90, angle: -3.12)
            var original = RefWheelRotation(spin: -100, previousSpin: -90, angle: -3.12, inputSpin: 0, publishedSpin: 0)
            for tick in 0..<10000 {
                let free = tick % 200 < 100
                let torque: Float = 1400 * sin(Float(tick) * 0.004), brake: Float = tick % 300 < 80 ? 1100 : 0
                let driven: Float = 330 * sin(Float(tick) * 0.0011)
                original = ref_wheel_rotation(original.spin, original.previousSpin, original.angle, driven, torque, brake, 1.7, 0.6,
                                               0.002, Int32(axle), free ? 1 : 0)
                let input = free ? native.updateFree(tireTorque: torque, brakeTorque: brake, wheelInertia: 1.7, axleInertia: 0.6) : driven
                XCTAssertEqual(input, original.inputSpin)
                let previousAngle = native.angle
                native.update(drivetrainSpin: input)
                for (a,b) in [(native.spin, original.spin), (native.previousSpin, original.previousSpin), (native.angle, original.angle),
                              (native.spin, original.publishedSpin)] {
                    worst = max(worst, abs(a-b)); XCTAssertEqual(a,b,accuracy: 1e-5 + 1e-6 * abs(b))
                }
                if abs(previousAngle - native.angle) > 3 { wraps += 1 }
            }
        }
        XCTAssertGreaterThan(wraps, 0)
        print("WHEEL_ROTATION_SEQUENTIAL ticks=20000 maxAbsolute=\(worst) wraps=\(wraps)")
    }
}
