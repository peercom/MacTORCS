// SPDX-License-Identifier: GPL-2.0-only
// Ported from TORCS 1.3.9 simuv2/brake.cpp.
// Copyright (C) 2000-2026 Eric Espie, Bernhard Wymann.
// Upstream permits GPL version 2 or (at your option) any later version.
import Foundation

public struct BrakeState: Sendable {
    public private(set) var torque: Float = 0
    public private(set) var temperature: Float
    public init(temperature: Float = 0) { self.temperature = temperature }
    public mutating func update(coefficient: Float, radius: Float, pressure: Float,
                                longitudinalSpeed: Float, wheelSpin: Float, dt: Float = 0.002) {
        torque = coefficient * pressure
        let cooling = (abs(longitudinalSpeed) * 0.02 + 0.1) * dt
        temperature = max(0, temperature - cooling)
        let heating = (pressure * radius * abs(wheelSpin) * 2.5e-8) * dt
        temperature = min(1, temperature + heating)
    }
}

public struct BrakeSystem: Sendable {
    public var coefficient: Float = 1_000_000
    public var repartition: Float = 0.5
    public var clickValue: Float = 0.0025
    public var maximumClicks: Int32 = 20
    public init() {}
    public func pressures(command: Float, clicks: Int32) -> (front: Float, rear: Float) {
        let c = max(-maximumClicks, min(maximumClicks, clicks))
        let rep = min(1, max(0, repartition + Float(c) * clickValue))
        let pressure = command * coefficient
        return (pressure * rep, pressure * (1 - rep))
    }
}
