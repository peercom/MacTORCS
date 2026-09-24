// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 simuv2/wheel.cpp SimWheelUpdateRide.
// Copyright (C) 2000-2024 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSTrack

public struct WheelContact: Sendable {
    public let position: TrackLocalPosition
    public let normal: SIMD3<Float>
    public let roadHeight, rideHeight: Float
}
/// Stateful contact/ride stage, before suspension forces and tire-force updates.
/// Displacement is in spring space between updates, as in the original engine.
public struct WheelRideState: Sendable {
    public private(set) var displacement, suspensionVelocity, relativeVelocity: Float
    public private(set) var flags, suspensionFlags: Int32
    public private(set) var brake: BrakeState
    public init(displacement: Float, relativeVelocity: Float = 0, flags: Int32 = 0, brakeTemperature: Float = 0,
                suspensionVelocity: Float = 0, suspensionFlags: Int32 = 0) {
        self.displacement = displacement; self.relativeVelocity = relativeVelocity; self.flags = flags
        self.suspensionVelocity = suspensionVelocity; self.suspensionFlags = suspensionFlags
        brake = BrakeState(temperature: brakeTemperature)
    }
    mutating func applyForce(relativeVelocity: Float, flags: Int32) {
        self.relativeVelocity = relativeVelocity; self.flags = flags
    }
    @discardableResult
    public mutating func update(position: SIMD3<Float>, carSegment: Int, track: TrackGeometry,
                                suspension: SuspensionDefinition, brakeCoefficient: Float, brakeRadius: Float,
                                brakePressure: Float, longitudinalSpeed: Float, wheelSpin: Float,
                                dt: Float = 0.002) throws -> WheelContact {
        guard dt > 0, dt.isFinite, position.z.isFinite, displacement.isFinite, relativeVelocity.isFinite,
              brakeCoefficient.isFinite, brakeRadius.isFinite, brakePressure.isFinite,
              longitudinalSpeed.isFinite, wheelSpin.isFinite, brake.temperature.isFinite,
              suspension.packers.isFinite, suspension.travel.isFinite else {
            throw TrackError.invalid("Invalid wheel ride state or step")
        }
        let local = try track.globalToLocal(SIMD2(position.x, position.y), startingAt: carSegment, mode: .segment)
        let normal = track.surfaceNormal(local), road = track.height(local)
        let previousWheelTravel = displacement / suspension.bellcrank
        var newTravel = previousWheelTravel - relativeVelocity * dt
        let maximumExtension = (position.z - road) * normal.z
        guard road.isFinite, normal.x.isFinite, normal.y.isFinite, normal.z.isFinite,
              maximumExtension.isFinite, newTravel.isFinite else { throw TrackError.invalid("Non-finite wheel contact") }
        flags &= ~4 // SIM_WH_ONAIR; other wheel flags survive this stage.
        if maximumExtension < newTravel { newTravel = maximumExtension; relativeVelocity = 0 }
        else if newTravel < suspension.packers { newTravel = suspension.packers; relativeVelocity = 0 }
        if newTravel < maximumExtension { flags |= 4 }
        let previous = displacement
        let checked = suspension.checkedTravel(newTravel)
        displacement = checked.displacement; suspensionFlags = checked.state
        suspensionVelocity = (previous - displacement) / dt
        brake.update(coefficient: brakeCoefficient, radius: brakeRadius, pressure: brakePressure,
                     longitudinalSpeed: longitudinalSpeed, wheelSpin: wheelSpin, dt: dt)
        return WheelContact(position: local, normal: normal, roadHeight: road, rideHeight: maximumExtension)
    }
}
