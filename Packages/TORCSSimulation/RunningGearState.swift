// SPDX-License-Identifier: GPL-2.0-only
// Wheel-stage scheduling follows TORCS 1.3.9 simuv2/simu.cpp.
// Copyright (C) 2000-2017 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSTrack

/// Fixed storage in TORCS wheel order; avoids allocating arrays in each physics tick.
public struct FourWheels<Element: Sendable>: Sendable {
    public var frontRight, frontLeft, rearRight, rearLeft: Element
    public init(_ frontRight: Element, _ frontLeft: Element, _ rearRight: Element, _ rearLeft: Element) {
        self.frontRight = frontRight; self.frontLeft = frontLeft; self.rearRight = rearRight; self.rearLeft = rearLeft
    }
    public subscript(index: Int) -> Element {
        get {
            switch index { case 0: return frontRight; case 1: return frontLeft; case 2: return rearRight; case 3: return rearLeft; default: preconditionFailure("Invalid wheel index") }
        }
        _modify {
            switch index { case 0: yield &frontRight; case 1: yield &frontLeft; case 2: yield &rearRight; case 3: yield &rearLeft; default: preconditionFailure("Invalid wheel index") }
        }
    }
}
public struct WheelDynamicState: Sendable {
    public internal(set) var ride: WheelRideState
    public internal(set) var forceHistory: WheelForceState
    public internal(set) var thermal: TireThermalState
    public internal(set) var rotation: WheelRotationState
    public internal(set) var position = SIMD3<Float>.zero
    public internal(set) var bodyVelocity = SIMD2<Float>.zero
    public internal(set) var contact: WheelContact?
    public internal(set) var forces: WheelForceResult?
    init(definition: WheelDefinition) {
        // SimConfig zeroes dynamic storage before SimWheelConfig. Rest travel is
        // not an initial displacement, and tire temperature begins at 20 Celsius.
        ride = WheelRideState(displacement: 0)
        forceHistory = WheelForceState(); rotation = WheelRotationState()
        thermal = TireThermalState(pressure: definition.thermal.pressure, temperature: definition.thermal.initialTemperature)
    }
}

/// Four-wheel contact/load/force/thermal integration. The chassis and drivetrain
/// supply their own state; this type does not stand in for either subsystem.
public struct RunningGearState: Sendable {
    public internal(set) var configuration: RunningGearConfiguration
    public private(set) var wheels: FourWheels<WheelDynamicState>
    public init(configuration: RunningGearConfiguration) {
        self.configuration = configuration
        wheels = FourWheels(.init(definition: configuration.wheels[0]), .init(definition: configuration.wheels[1]),
                            .init(definition: configuration.wheels[2]), .init(definition: configuration.wheels[3]))
    }
    public mutating func updateForces(worldPosition: SIMD3<Float>, roll: Float, pitch: Float, yaw: Float,
                                      bodyVelocity: SIMD3<Float>, yawVelocity: Float, carSegment: Int, track: TrackGeometry,
                                      brakePressures: SIMD4<Float>, steering: SIMD4<Float>, localTemperature: Float,
                                      localPressure: Float, skillLevel: Int, tireFactor: Float,
                                      preSimulation: Bool = false, dt: Float = 0.002) throws {
        guard worldPosition.x.isFinite, worldPosition.y.isFinite, worldPosition.z.isFinite,
              roll.isFinite, pitch.isFinite, yaw.isFinite, bodyVelocity.x.isFinite, bodyVelocity.y.isFinite,
              bodyVelocity.z.isFinite, yawVelocity.isFinite, localTemperature.isFinite, localPressure.isFinite,
              tireFactor.isFinite, dt.isFinite, dt > 0, (0..<5).contains(skillLevel),
              track.segments.indices.contains(carSegment), track.segments[carSegment].role == .main else {
            throw TrackError.invalid("Invalid running gear input")
        }
        for i in 0..<4 {
            guard brakePressures[i].isFinite, steering[i].isFinite,
                  abs(steering[i] + configuration.wheels[i].force.toe) < 65536 else {
                throw TrackError.invalid("Invalid wheel control input")
            }
        }
        let pose = WheelKinematics(worldPosition: worldPosition, roll: roll, pitch: pitch, yaw: yaw,
                                   bodyVelocity: SIMD2(bodyVelocity.x, bodyVelocity.y), yawVelocity: yawVelocity)
        // All contacts precede axle load sharing, as in SimUpdate.
        for index in 0..<4 {
            let definition = configuration.wheels[index], k = pose.wheel(at: definition.staticPosition)
            wheels[index].position = k.position; wheels[index].bodyVelocity = k.bodyVelocity
            let contact = try wheels[index].ride.update(position: k.position, carSegment: carSegment, track: track,
                suspension: definition.suspension, brakeCoefficient: definition.brake.coefficient, brakeRadius: definition.brake.radius,
                brakePressure: brakePressures[index], longitudinalSpeed: bodyVelocity.x, wheelSpin: wheels[index].rotation.spin, dt: dt)
            wheels[index].contact = contact
        }
        var axleLoads = SIMD4<Float>.zero
        for axle in 0..<2 {
            let right = wheels[axle*2].ride, left = wheels[axle*2+1].ride
            let forces = configuration.axles[axle].forces(rightDisplacement: right.displacement, leftDisplacement: left.displacement,
                                                        rightVelocity: right.suspensionVelocity, leftVelocity: left.suspensionVelocity)
            axleLoads[axle*2] = forces.rightForce; axleLoads[axle*2+1] = forces.leftForce
        }
        for index in 0..<4 {
            let d = configuration.wheels[index]
            // Local value avoids overlapping Swift accesses; fixed wheel storage has no COW buffer.
            var wheel = wheels[index]
            let forces = try wheel.forceHistory.update(ride: &wheel.ride, contact: wheel.contact!.position,
                carSegment: carSegment, track: track, definition: d.force, suspension: d.suspension,
                wheelIndex: index, skillLevel: skillLevel, bodyVelocity: wheel.bodyVelocity, steer: steering[index],
                spin: wheel.rotation.spin, axleForce: axleLoads[index], grip: wheel.thermal.grip, dt: dt)
            wheel.forces = forces
            wheel.thermal.update(definition: d.thermal, tireLoad: forces.tireLoad, slip: forces.tireSlip,
                spin: wheel.rotation.spin, radius: d.force.radius, localTemperature: localTemperature,
                localPressure: localPressure, skillLevel: skillLevel, tireFactor: tireFactor, dt: dt)
            if preSimulation { wheel.thermal.reset(definition: d.thermal, localTemperature: localTemperature) }
            wheels[index] = wheel
        }
    }
    /// Only for undriven axles, after updateForces and before updateRotation.
    /// Driven axle inputs must come from the original differential/transmission port.
    public mutating func freeAxleInputs(_ axle: Int, dt: Float = 0.002) -> SIMD2<Float> {
        precondition((0..<2).contains(axle))
        var inputs = SIMD2<Float>.zero
        for side in 0..<2 {
            let i = axle*2+side
            precondition(wheels[i].forces != nil, "Wheel forces must precede transmission")
            inputs[side] = wheels[i].rotation.updateFree(tireTorque: wheels[i].forces!.spinTorque,
                brakeTorque: wheels[i].ride.brake.torque, wheelInertia: configuration.wheels[i].inertia,
                axleInertia: configuration.axles[axle].inertia, dt: dt)
        }
        return inputs
    }
    public mutating func updateRotation(drivetrainSpins: SIMD4<Float>, dt: Float = 0.002) {
        for i in 0..<4 { wheels[i].rotation.update(drivetrainSpin: drivetrainSpins[i], dt: dt) }
    }
    public func driveFeedback() -> FourWheels<DriveAxis> {
        func axis(_ i: Int) -> DriveAxis {
            precondition(wheels[i].forces != nil, "Wheel forces must precede transmission")
            let force = wheels[i].forces!
            return DriveAxis(spin:force.feedbackSpin,torque:force.feedbackTorque,brakeTorque:force.feedbackBrakeTorque,
                             inertia:configuration.wheels[i].feedbackInertia)
        }
        return FourWheels(axis(0),axis(1),axis(2),axis(3))
    }
}

extension RunningGearState {
    mutating func applyService(configuration: RunningGearConfiguration,changeAllTires: Bool,localTemperature: Float) {
        self.configuration=configuration
        if changeAllTires {
            for i in 0..<4 { wheels[i].thermal.reset(definition:configuration.wheels[i].thermal,localTemperature:localTemperature) }
        }
    }
}
