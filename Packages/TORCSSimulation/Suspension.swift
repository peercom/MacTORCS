// SPDX-License-Identifier: GPL-2.0-only
// Ported from TORCS 1.3.9 simuv2/susp.cpp.
// Copyright (C) 2000-2016 Eric Espie, Bernhard Wymann.
// Upstream permits GPL version 2 or (at your option) any later version.
import Foundation

public struct DamperDefinition: Sendable {
    public let slow: Float
    public let fast: Float
    public let threshold: Float
    public init(slow: Float, fast: Float, threshold: Float) {
        self.slow = slow; self.fast = fast; self.threshold = threshold
    }
    func force(_ speed: Float) -> Float {
        speed < threshold ? slow * speed : fast * speed + (slow - fast) * threshold
    }
}

public struct SuspensionDefinition: Sendable {
    public let springRate: Float
    public let preload: Float
    public let rest: Float
    public let travel: Float
    public let bellcrank: Float
    public let packers: Float
    public let bump: DamperDefinition
    public let rebound: DamperDefinition

    public init(springRate: Float = 175000, preload: Float = 3000, rest: Float = 0.2,
                travel: Float = 0.5, bellcrank: Float = 1, packers: Float = 0,
                bump: DamperDefinition = .init(slow: 3000, fast: 1000, threshold: 0.5),
                rebound: DamperDefinition = .init(slow: 5000, fast: 2000, threshold: 0.5)) {
        precondition(bellcrank > 0 && bellcrank.isFinite)
        self.springRate = springRate; self.preload = preload; self.rest = rest
        self.travel = travel; self.bellcrank = bellcrank; self.packers = packers
        self.bump = bump; self.rebound = rebound
    }

    /// Original SimSuspCheckIn, without the later force update. Input is wheel
    /// space; output is spring space. The wheel ride update depends on this order.
    public func checkedTravel(_ displacement: Float) -> (displacement: Float, state: Int32) {
        var x = displacement
        var state: Int32 = 0
        if x < packers { x = packers; state = 1 }
        x *= bellcrank
        if x > travel { x = travel; state = 2 }
        return (x, state)
    }
    /// Input travel is in wheel space; checked travel is in spring space.
    public func evaluate(displacement: Float, velocity: Float) -> SuspensionState {
        let checked = checkedTravel(displacement)
        return SuspensionState(displacement: checked.displacement,
            force: force(checkedDisplacement: checked.displacement, velocity: velocity), state: checked.state)
    }
    /// SimSuspUpdate consumes spring-space travel already checked by the ride stage.
    public func force(checkedDisplacement x: Float, velocity: Float) -> Float {
        let spring = max(0, -springRate * (x - bellcrank * rest) + preload / bellcrank)
        let v = max(-10, min(10, velocity))
        let damper = (v < 0 ? rebound : bump).force(abs(v)) * (v < 0 ? -1 : 1)
        let internalForce = spring + damper
        return internalForce <= 0 ? 0 : internalForce * bellcrank
    }
}

public struct SuspensionState: Sendable {
    public let displacement: Float
    public let force: Float
    /// 0 free, 1 fully compressed, 2 fully extended (upstream flags).
    public let state: Int32
}
