// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// Deterministic excitation inputs shared by the two executables, never outputs.
/// Each sample resets suspension travel/velocity; brake and steering state persist.
public struct ComponentInput: Sendable {
    public let displacement: Float
    public let velocity: Float
    public let steering: Float
    public let brake: Float
    public let speed: Float
    public let spin: Float
    public let clicks: Int32
    public static let scenario = "component-sweep-v1"
    public init(tick: Int) {
        let travels: [Float] = [-0.1, 0, 0.01, 0.05, 0.199, 0.2, 0.201, 0.4, 0.5, 0.6]
        let velocities: [Float] = [-20, -10, -0.501, -0.5, -0.1, 0, 0.1, 0.5, 0.501, 10, 20]
        displacement = travels[tick % travels.count]
        velocity = velocities[(tick / travels.count) % velocities.count]
        steering = Float((tick / 125) % 3 - 1)
        brake = Float(tick % 101) / 100
        speed = Float(tick % 81 - 40)
        spin = Float(tick % 401 - 200)
        clicks = Int32(tick % 61 - 30)
    }
}

public enum ComponentCLI {
    public static func options(_ arguments: [String]) throws -> (ticks: Int, output: URL) {
        var ticks = 2000, output: URL?
        var i = 0
        while i < arguments.count {
            guard i + 1 < arguments.count else { throw TelemetryError.invalid("Missing value for \(arguments[i])") }
            switch arguments[i] {
            case "--ticks":
                guard let value = Int(arguments[i+1]), (1...100_000).contains(value) else { throw TelemetryError.invalid("Ticks must be 1…100000") }
                ticks = value
            case "--telemetry": output = URL(fileURLWithPath: arguments[i+1])
            default: throw TelemetryError.invalid("Unknown option \(arguments[i]); currently supports component bench only")
            }
            i += 2
        }
        guard let output else { throw TelemetryError.invalid("Usage: --ticks 2000 --telemetry output.jsonl (component bench, not a race)") }
        return (ticks, output)
    }
}
