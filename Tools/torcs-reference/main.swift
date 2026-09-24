// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import CReference
import TORCSTelemetry
import TORCSReferenceSupport
import CryptoKit

do {
    if CommandLine.arguments.contains("--robot") {
        try runRobotRace(Array(CommandLine.arguments.dropFirst()));exit(0)
    }
    if CommandLine.arguments.contains("--scenario") {
        try runVehicleScenario(Array(CommandLine.arguments.dropFirst()))
        exit(0)
    }
    let options = try ComponentCLI.options(Array(CommandLine.arguments.dropFirst()))
    let config = RefSuspensionConfig(springRate: 175000, preload: 3000, rest: 0.2, travel: 0.5, bellcrank: 1,
                                    packers: 0, slowBump: 3000, fastBump: 1000, bumpThreshold: 0.5,
                                    slowRebound: 5000, fastRebound: 2000, reboundThreshold: 0.5)
    var records: [TelemetryRecord] = [], angle: Float = 0, temperature: Float = 0
    for tick in 1...options.ticks {
        let input = ComponentInput(tick: tick)
        let s = ref_suspension(config, input.displacement, input.velocity)
        let steering = ref_steering(angle, input.steering, 0.43, 1, 2.5, 1.5, 0.002)
        let pressure = ref_brake_pressures(input.brake, 1_000_000, 0.5, 0.0025, 20, input.clicks)
        let b = ref_brake(0.00006, 0.1, pressure.front, input.speed, input.spin, temperature, 0.002)
        angle = steering.angle; temperature = b.temperature
        records.append(TelemetryRecord(scenario: ComponentInput.scenario, tick: tick, time: Double(tick) * 0.002,
            values: ["suspension.displacement": Double(s.displacement), "suspension.force": Double(s.force), "suspension.state": Double(s.state),
                     "steering.angle": Double(angle), "steering.right": Double(steering.right), "steering.left": Double(steering.left),
                     "brake.frontPressure": Double(pressure.front), "brake.rearPressure": Double(pressure.rear),
                     "brake.torque": Double(b.torque), "brake.temperature": Double(temperature)]))
    }
    try TelemetryIO.write(records, to: options.output)
    print("Wrote \(records.count) upstream component samples to \(options.output.path)")
} catch {
    FileHandle.standardError.write(Data("torcs-reference: \(error)\n".utf8)); exit(2)
}

func runVehicleScenario(_ args: [String]) throws {
    var scenario: VehicleScenario?, fixtureURL: URL?, output: URL?, ticks = 3000, seed: UInt32 = 12345, cars = 1
    var i = 0
    while i < args.count {
        guard i + 1 < args.count else { throw TelemetryError.invalid("Missing option value") }
        switch args[i] {
        case "--scenario": scenario = VehicleScenario(rawValue: args[i+1])
        case "--fixtures": fixtureURL = URL(fileURLWithPath: args[i+1], isDirectory: true)
        case "--telemetry": output = URL(fileURLWithPath: args[i+1])
        case "--ticks": guard let v = Int(args[i+1]), (1...20000).contains(v) else { throw TelemetryError.invalid("Vehicle ticks must be 1…20000") }; ticks = v
        case "--seed": guard let v = UInt32(args[i+1]) else { throw TelemetryError.invalid("Invalid seed") }; seed = v
        case "--cars": guard let v = Int(args[i+1]), (1...16).contains(v) else { throw TelemetryError.invalid("Cars must be 1…16") }; cars = v
        default: throw TelemetryError.invalid("Unknown vehicle option: \(args[i])")
        }
        i += 2
    }
    guard let scenario, let fixtureURL, let output else {
        throw TelemetryError.invalid("Usage: --scenario stationary|acceleration|braking|cornering|combined|car-collision --fixtures Tests/UnitTests/Fixtures --telemetry output.jsonl [--ticks 3000] [--seed 12345] [--cars 1]")
    }
    if scenario == .carCollision {
        if !args.contains("--cars") { cars = 2 }
        guard cars == 2 else { throw TelemetryError.invalid("car-collision requires exactly two cars") }
    }
    let content = try ReferenceContent(fixtures: fixtureURL)
    let world = try ReferenceWorld(track: content.track, car: content.car, category: content.category, seed: seed, cars: cars)
    defer { world.close(); withExtendedLifetime(content) {} }
    try world.settle()
    let writer = try TelemetryWriter(to: output)
    for tick in 1...ticks {
        for car in 0..<cars { try world.command(scenario.command(tick: tick, car: car), car: car) }
        try world.step()
        try writer.append(world.record(scenario: scenario.identifier))
    }
    try writer.finish()
    let metadata: [String: Any] = ["schema": 1, "scenario": scenario.identifier, "upstream": "TORCS 1.3.9 simuv2",
        "archiveSHA256": "f9c69e86d290295467451b01d7838d85005ba613644a6fe8a3f85a7c6a03cd4c",
        "seed": seed, "cars": cars, "ticks": ticks, "stepSeconds": 0.002, "settlingTicks": 501,
        "startDistanceMetres": 10, "carSpacingMetres": 10, "trackLengthMetres": world.trackLength,
        "trackSegments": world.trackSegments, "physicsFieldsPerCar": try world.sample().count,
        "sourceHashes": ReferenceContent.sourceHashes,
        "executableSHA256": SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))).map { String(format: "%02x", $0) }.joined(),
        "scope": "Original complete vehicle physics and collisions; scripted commands; no race-engine or robot execution",
        "parser": "Original params.cpp, macOS Expat; staged objects.xml encoding declaration corrected to ISO-8859-1"]
    try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathExtension("metadata.json"), options: .atomic)
    print("Wrote \(ticks) full upstream physics ticks (\(cars) cars, \(world.trackSegments) Aalborg segments) to \(output.path)")
}
