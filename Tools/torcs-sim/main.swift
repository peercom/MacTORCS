// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import TORCSSimulation
import TORCSTelemetry

do {
    if CommandLine.arguments.contains("--race") {
        try runNativeRace(Array(CommandLine.arguments.dropFirst()))
        exit(0)
    }
    if CommandLine.arguments.contains("--robot") {
        try runNativeBTRace(Array(CommandLine.arguments.dropFirst()))
        exit(0)
    }
    if CommandLine.arguments.contains("--scenario") {
        try runNativeVehicleScenario(Array(CommandLine.arguments.dropFirst()))
        exit(0)
    }
    let options = try ComponentCLI.options(Array(CommandLine.arguments.dropFirst()))
    let suspension = SuspensionDefinition(), brakes = BrakeSystem()
    var steering = SteeringState(), brake = BrakeState(), records: [TelemetryRecord] = []
    for tick in 1...options.ticks {
        let input = ComponentInput(tick: tick)
        let s = suspension.evaluate(displacement: input.displacement, velocity: input.velocity)
        steering.update(command: input.steering)
        let pressure = brakes.pressures(command: input.brake, clicks: input.clicks)
        brake.update(coefficient: 0.00006, radius: 0.1, pressure: pressure.front, longitudinalSpeed: input.speed, wheelSpin: input.spin)
        records.append(TelemetryRecord(scenario: ComponentInput.scenario, tick: tick, time: Double(tick) * 0.002,
            values: ["suspension.displacement": Double(s.displacement), "suspension.force": Double(s.force), "suspension.state": Double(s.state),
                     "steering.angle": Double(steering.angle), "steering.right": Double(steering.right), "steering.left": Double(steering.left),
                     "brake.frontPressure": Double(pressure.front), "brake.rearPressure": Double(pressure.rear),
                     "brake.torque": Double(brake.torque), "brake.temperature": Double(brake.temperature)]))
    }
    try TelemetryIO.write(records, to: options.output)
    print("Wrote \(records.count) Swift component samples to \(options.output.path)")
} catch {
    FileHandle.standardError.write(Data("torcs-sim: \(error)\n".utf8)); exit(2)
}
