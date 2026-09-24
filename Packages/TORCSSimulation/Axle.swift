// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 simuv2/axle.cpp SimAxleUpdate.
// Copyright (C) 2000-2026 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation

public struct AxleForceResult: Sendable {
    public let rightForce, leftForce, thirdDisplacement, thirdVelocity, thirdForce: Float
}
extension AxleDefinition {
    /// Wheel travel is already in spring space. The third element does not call
    /// suspension check-in; its contribution is gated by a strict travel bound.
    public func forces(rightDisplacement: Float, leftDisplacement: Float,
                       rightVelocity: Float, leftVelocity: Float) -> AxleForceResult {
        let antiRoll = antiRollSpring * (leftDisplacement - rightDisplacement)
        let travel = (leftDisplacement + rightDisplacement) / 2
        let velocity = (leftVelocity + rightVelocity) / 2
        let force = thirdSuspension.force(checkedDisplacement: travel, velocity: velocity)
        let halfForce: Float = travel < thirdSuspension.travel && force > 0 ? force / 2 : 0
        return AxleForceResult(rightForce: antiRoll + halfForce, leftForce: -antiRoll + halfForce,
                               thirdDisplacement: travel, thirdVelocity: velocity, thirdForce: force)
    }
}
