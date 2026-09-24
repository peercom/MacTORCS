// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 simuv2/wheel.cpp SimUpdateFreeWheels/SimWheelUpdateRotation.
// Copyright (C) 2000-2024 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation

public struct WheelRotationState: Sendable {
    public private(set) var spin, previousSpin, angle: Float
    public init(spin: Float = 0, previousSpin: Float = 0, angle: Float = 0) {
        self.spin = spin; self.previousSpin = previousSpin; self.angle = angle
    }
    /// Undriven axle stage. Returns the original wheel.in.spinVel value for the
    /// later rotation stage; driven axles will obtain it from the differential.
    @discardableResult
    public mutating func updateFree(tireTorque: Float, brakeTorque: Float, wheelInertia: Float,
                                    axleInertia: Float, dt: Float = 0.002) -> Float {
        let inertia = wheelInertia + axleInertia / 2
        precondition(inertia.isFinite && inertia > 0 && dt.isFinite && dt > 0)
        let acceleration = dt * tireTorque / inertia
        spin -= acceleration
        let brake = -(spin < 0 ? Float(-1) : Float(1)) * brakeTorque
        var delta = dt * brake / inertia
        if abs(delta) > abs(spin) { delta = -spin }
        spin += delta
        return spin
    }
    public mutating func update(drivetrainSpin: Float, dt: Float = 0.002) {
        precondition(drivetrainSpin.isFinite && previousSpin.isFinite && angle.isFinite && dt.isFinite && dt > 0)
        spin = Float(Double(previousSpin) + Double(50 * (drivetrainSpin - previousSpin)) * 0.01)
        previousSpin = drivetrainSpin
        angle += spin * dt
        precondition(angle.isFinite && abs(angle) < 65536)
        while Double(angle) > Double.pi { angle -= Float(2 * Double.pi) }
        while Double(angle) < -Double.pi { angle += Float(2 * Double.pi) }
    }
}
