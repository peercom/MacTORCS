// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 simuv2/car.cpp force, speed, corner and position stages.
// Copyright (C) 2000-2017 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSConfiguration
import TORCSTrack

/// The original local and global records both hold world-space position, but
/// their velocities/accelerations differ. Collision stages may leave poses unequal.
public struct ChassisDynamics: Sendable {
    public var position, orientation, velocity, angularVelocity, acceleration, angularAcceleration: SIMD3<Float>
    public init(position: SIMD3<Float> = .zero, orientation: SIMD3<Float> = .zero, velocity: SIMD3<Float> = .zero,
                angularVelocity: SIMD3<Float> = .zero, acceleration: SIMD3<Float> = .zero, angularAcceleration: SIMD3<Float> = .zero) {
        self.position = position; self.orientation = orientation; self.velocity = velocity
        self.angularVelocity = angularVelocity; self.acceleration = acceleration; self.angularAcceleration = angularAcceleration
    }
}
public struct ChassisWheelLoad: Sendable {
    public var force: SIMD3<Float>
    public var rideHeight, rollingResistance: Float
    public init(force: SIMD3<Float>, rideHeight: Float, rollingResistance: Float) {
        self.force = force; self.rideHeight = rideHeight; self.rollingResistance = rollingResistance
    }
}
public struct ChassisCornerState: Sendable {
    public internal(set) var position, bodyVelocity, worldVelocity: SIMD3<Float>
    public init(position: SIMD3<Float> = .zero, bodyVelocity: SIMD3<Float> = .zero, worldVelocity: SIMD3<Float> = .zero) {
        self.position = position; self.bodyVelocity = bodyVelocity; self.worldVelocity = worldVelocity
    }
}
public struct ChassisDefinition: Sendable {
    public internal(set) var runningGear: RunningGearConfiguration
    public internal(set) var aerodynamics: AerodynamicsDefinition
    public let corners: FourWheels<SIMD3<Float>>
    public init(parameters p: ParameterDocument, runningGear: RunningGearConfiguration, aerodynamics: AerodynamicsDefinition) throws {
        self.runningGear = runningGear; self.aerodynamics = aerodynamics
        let m = runningGear.mass, cg = m.centerOfGravity
        let width = p.section("Car")?.number("overall width",default:m.dimensions.y) ?? m.dimensions.y
        guard width.isFinite, width > 0 else { throw ParameterError.invalid("Invalid overall car width") }
        let front = Float(Double(m.dimensions.x)*0.5-Double(cg.x)), rear = Float(-Double(m.dimensions.x)*0.5-Double(cg.x))
        let right = Float(-Double(width)*0.5-Double(cg.y)), left = Float(Double(width)*0.5-Double(cg.y))
        corners = FourWheels(SIMD3(front,right,0),SIMD3(front,left,0),SIMD3(rear,right,0),SIMD3(rear,left,0))
    }
}
public struct ChassisState: Sendable {
    public var body, world: ChassisDynamics
    public private(set) var previousWorld = ChassisDynamics()
    public private(set) var corners = FourWheels(ChassisCornerState(),ChassisCornerState(),ChassisCornerState(),ChassisCornerState())
    public private(set) var trackPosition: TrackLocalPosition
    public private(set) var speed: Float
    /// Simuv2 reads these legacy caches for corner velocity but never updates
    /// them. Fresh configured cars keep both zero; do not substitute sin/cos(yaw).
    public var cachedYawCosine: Float = 0, cachedYawSine: Float = 0
    public init(body: ChassisDynamics, world: ChassisDynamics, trackPosition: TrackLocalPosition, speed: Float = 0, corners: FourWheels<ChassisCornerState>? = nil) {
        self.body = body; self.world = world; self.trackPosition = trackPosition; self.speed = speed
        if let corners { self.corners = corners }
    }
    /// Force → velocity → corner → position integration, before environment
    /// response. This does not implement ground, barrier or car-to-car collision.
    public mutating func integrate(definition d: ChassisDefinition, fuel: Float,
                                   wheels: FourWheels<ChassisWheelLoad>, aero: AerodynamicsResult,
                                   track: TrackGeometry, dt: Float = 0.002) throws {
        let mass = d.runningGear.mass, totalMass = mass.mass+fuel
        precondition(totalMass > 0 && dt > 0 && dt.isFinite)
        previousWorld = world
        let inverseMass = Float(1.0/Double(totalMass)), weight = -totalMass*Float(9.80665)
        let rotation = VehicleRotation(roll:body.orientation.x,pitch:body.orientation.y,yaw:body.orientation.z)
        var force = rotation.toBody(SIMD3(0,0,weight)), moment = SIMD3<Float>.zero
        for i in 0..<4 {
            let wheel = wheels[i], config = d.runningGear.wheels[i], f = wheel.force, p = config.staticPosition
            force += f
            moment.x += f.z*p.y + f.y*config.rollCenter
            moment.y -= f.z*p.x + f.x*(mass.centerOfGravity.z+wheel.rideHeight)
            moment.z += -f.x*p.y + f.y*p.x
        }
        force.x += aero.drag
        for i in 0..<2 {
            let wingForce = i == 0 ? aero.frontWing : aero.rearWing
            let wing = i == 0 ? d.aerodynamics.frontWing : d.aerodynamics.rearWing
            force.z += wingForce.z+aero.bodyLift[i]; force.x += wingForce.x
            moment.y -= wingForce.z*wing.position.x + wingForce.x*wing.position.z
            moment.y -= aero.bodyLift[i]*(d.runningGear.axles[i].position-mass.centerOfGravity.x)
        }
        var resistance: Float = 0
        for i in 0..<4 { resistance += wheels[i].rollingResistance }
        var velocityResistance: Float = 0
        if speed > 0.00001 {
            velocityResistance = resistance/speed
            if velocityResistance*inverseMass*dt > speed { velocityResistance = speed*totalMass/dt }
        }
        let angularResistance: Float
        // Original literals make these two expressions Double after R*wheelbase.
        if Double(resistance*mass.wheelbase)/2*Double(mass.inverseInertia.z) > Double(abs(world.angularVelocity.z)) {
            angularResistance = world.angularVelocity.z/mass.inverseInertia.z
        } else {
            let sign: Float = world.angularVelocity.z < 0 ? -1 : 1
            angularResistance = Float(Double(sign*resistance*mass.wheelbase)/2)
        }
        body.acceleration = (force-velocityResistance*body.velocity)*inverseMass
        world.acceleration = rotation.toWorld(body.acceleration)
        let angular = SIMD3(moment.x*mass.inverseInertia.x,moment.y*mass.inverseInertia.y,
                            (moment.z-angularResistance)*mass.inverseInertia.z)
        body.angularAcceleration = angular; world.angularAcceleration = angular
        world.velocity += world.acceleration*dt
        world.angularVelocity += world.angularAcceleration*dt
        if abs(world.angularVelocity.z) > 9 { world.angularVelocity.z = world.angularVelocity.z < 0 ? -9 : 9 }
        body.angularVelocity = world.angularVelocity
        body.velocity = rotation.toBody(world.velocity)
        // Corners precede position/orientation advancement, using updated speed.
        for i in 0..<4 {
            let corner = d.corners[i]
            let local = SIMD3(corner.x+mass.centerOfGravity.x,corner.y+mass.centerOfGravity.y,corner.z-mass.centerOfGravity.z)
            corners[i].position = world.position+rotation.toWorld(local)
            var v = SIMD3(-body.angularVelocity.z*local.y,body.angularVelocity.z*local.x,
                          body.angularVelocity.x*local.y-body.angularVelocity.y*local.x)
            corners[i].worldVelocity = SIMD3(world.velocity.x+v.x*cachedYawCosine-v.y*cachedYawSine,
                world.velocity.y+v.x*cachedYawSine+v.y*cachedYawCosine,world.velocity.z+v.z)
            v += body.velocity; corners[i].bodyVelocity = v
        }
        world.position += world.velocity*dt; world.orientation += world.angularVelocity*dt
        precondition(world.orientation.z.isFinite && abs(world.orientation.z) < 65536)
        while Double(world.orientation.z) > Double.pi { world.orientation.z -= Float(2*Double.pi) }
        while Double(world.orientation.z) < -Double.pi { world.orientation.z += Float(2*Double.pi) }
        world.orientation.x = min(1.04,max(-1.04,world.orientation.x))
        world.orientation.y = min(1.04,max(-1.04,world.orientation.y))
        body.position = world.position; body.orientation = world.orientation
        trackPosition = try track.globalToLocal(SIMD2(world.position.x,world.position.y),startingAt:trackPosition.segment)
        refreshSpeed()
    }
    /// The original full car update refreshes this after environment response.
    public mutating func refreshSpeed() {
        speed = sqrt(body.velocity.x*body.velocity.x+body.velocity.y*body.velocity.y+body.velocity.z*body.velocity.z)
    }
}
extension RunningGearState {
    public func chassisLoads() -> FourWheels<ChassisWheelLoad> {
        func load(_ i: Int) -> ChassisWheelLoad {
            precondition(wheels[i].forces != nil,"Wheel forces must precede chassis integration")
            return ChassisWheelLoad(force:wheels[i].forces!.force,rideHeight:wheels[i].contact!.rideHeight,
                rollingResistance:wheels[i].forces!.rollingResistance)
        }
        return FourWheels(load(0),load(1),load(2),load(3))
    }
}
