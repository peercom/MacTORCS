// SPDX-License-Identifier: GPL-2.0-only
// Ported from TORCS 1.3.9 simuv2/steer.cpp.
// Copyright (C) 2000-2026 Eric Espie, Bernhard Wymann.
// Upstream permits GPL version 2 or (at your option) any later version.
import Foundation

public struct SteeringState: Sendable {
    public private(set) var angle: Float
    public private(set) var right: Float = 0
    public private(set) var left: Float = 0
    public init(angle: Float = 0) { self.angle = angle }
    public mutating func update(command: Float, lock: Float = 0.43, maximumSpeed: Float = 1,
                                wheelbase: Float = 2.5, wheeltrack: Float = 1.5, dt: Float = 0.002) {
        var steer = command * lock
        let delta = steer - angle
        if abs(delta) / dt > maximumSpeed {
            steer = (delta < 0 ? -1 : 1) * maximumSpeed * dt + angle
        }
        angle = steer
        let tangent = abs(tan(steer))
        let other = atan2(wheelbase * tangent, wheelbase - tangent * wheeltrack)
        if steer > 0 { right = other; left = steer }
        else { right = steer; left = -other }
    }
}
