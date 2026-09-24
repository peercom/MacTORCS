// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// Simulation time is tick-derived; render cadence never changes the timestep.
public struct FixedStepClock: Sendable {
    public static let step: Double = 0.002
    public private(set) var tick: UInt64 = 0
    public private(set) var accumulator: Double = 0
    public var time: Double { Double(tick) * Self.step }
    public var interpolation: Double { min(1, max(0, accumulator / Self.step)) }
    public var isBehind: Bool { accumulator >= Self.step }

    public init() {}

    /// The work cap leaves backlog intact. Pausing is an explicit caller decision.
    @discardableResult
    public mutating func advance(elapsed: Double, maximumSteps: Int = 250,
                                 step: (UInt64) -> Void) -> Int {
        advanceContinuing(elapsed:elapsed,maximumSteps:maximumSteps) { tick in step(tick);return true }
    }

    /// Stops a batch after the callback completes a terminal simulation tick.
    @discardableResult
    public mutating func advanceContinuing(elapsed: Double,maximumSteps: Int=250,
                                          step: (UInt64)->Bool) -> Int {
        guard elapsed.isFinite, elapsed >= 0, maximumSteps > 0 else { return 0 }
        accumulator += elapsed
        var count = 0
        while accumulator + 1e-12 >= Self.step && count < maximumSteps {
            tick += 1
            accumulator = max(0, accumulator - Self.step)
            count += 1
            if !step(tick) { break }
        }
        return count
    }
}

public struct SimulationSnapshot: Sendable {
    public let tick: UInt64
    public let suspensionTravel: Float
    public let suspensionForce: Float
    public let steeringAngle: Float
    public let brakeTemperature: Float
    public init(tick: UInt64, suspensionTravel: Float, suspensionForce: Float,
                steeringAngle: Float, brakeTemperature: Float) {
        self.tick = tick; self.suspensionTravel = suspensionTravel
        self.suspensionForce = suspensionForce; self.steeringAngle = steeringAngle
        self.brakeTemperature = brakeTemperature
    }
}
