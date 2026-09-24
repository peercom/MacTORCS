// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import TORCSCore

/// A forced-input subsystem inspection bench. This is not a vehicle simulation.
public struct ComponentBench: Sendable {
    public var suspension = SuspensionDefinition()
    public private(set) var steering = SteeringState()
    public private(set) var brake = BrakeState()
    public init() {}
    public mutating func step(tick: UInt64, steeringCommand: Float = 0, brakeCommand: Float = 0) -> SimulationSnapshot {
        let time = Float(Double(tick) * FixedStepClock.step)
        let displacement = 0.2 + 0.06 * sin(time * 4)
        let velocity = 0.24 * cos(time * 4)
        let s = suspension.evaluate(displacement: displacement, velocity: velocity)
        steering.update(command: steeringCommand)
        brake.update(coefficient: 0.00006, radius: 0.1, pressure: brakeCommand * 1_000_000,
                     longitudinalSpeed: 20, wheelSpin: 60)
        return SimulationSnapshot(tick: tick, suspensionTravel: s.displacement, suspensionForce: s.force,
                                  steeringAngle: steering.angle, brakeTemperature: brake.temperature)
    }
}
