// SPDX-License-Identifier: GPL-2.0-only
// Stage ordering follows TORCS 1.3.9 simuv2/simu.cpp and car.cpp.
// Copyright (C) 2000-2017 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSConfiguration
import TORCSTrack

public struct VehicleDynamicsDefinition: Sendable {
    public internal(set) var chassis: ChassisDefinition
    public let initialPitSetup: PitSetup
    public let engine: EngineDefinition
    public internal(set) var transmission: TransmissionDefinition
    public internal(set) var controls: DriverControlDefinition
    public init(parameters p: ParameterDocument) throws {
        initialPitSetup = PitSetup(parameters:p)
        controls = try DriverControlDefinition(parameters:p)
        let running = try RunningGearConfiguration(parameters:p)
        let aero = try AerodynamicsDefinition(parameters:p,centerOfGravityX:running.mass.centerOfGravity.x)
        chassis = try ChassisDefinition(parameters:p,runningGear:running,aerodynamics:aero)
        engine = try EngineDefinition(parameters:p)
        transmission = try TransmissionDefinition(parameters:p,engine:engine,runningGear:running)
    }
}
/// Inputs at the component boundary, after original control checking, brake
/// repartition and steering slew/Ackermann. Driver-command scheduling is separate.
public struct VehicleDynamicsControls: Sendable {
    public var throttle, clutchTransfer: Float
    public var requestedGear: Int
    public var brakePressures, steering: SIMD4<Float>
    public init(throttle: Float, clutchTransfer: Float, requestedGear: Int, brakePressures: SIMD4<Float>, steering: SIMD4<Float>) {
        self.throttle = throttle; self.clutchTransfer = clutchTransfer; self.requestedGear = requestedGear
        self.brakePressures = brakePressures; self.steering = steering
    }
}
/// Independently owned mechanical state with active-car control scheduling.
/// The owning MultiVehicleSimulation schedules collision dispatch and removal.
public struct VehicleDynamicsState: Sendable {
    public private(set) var definition: VehicleDynamicsDefinition
    public private(set) var pitSetup: PitSetup
    public private(set) var chassis: ChassisState
    public private(set) var engine: EngineState
    public private(set) var transmission: TransmissionState
    public private(set) var runningGear: RunningGearState
    public private(set) var effectiveThrottle: Float = 0
    public private(set) var fuel: Float
    public private(set) var aerodynamics: AerodynamicsResult?
    public private(set) var collision = CollisionState()
    public private(set) var steering = SteeringState()
    public private(set) var driverCommand = DriverCommand()
    public private(set) var brakePressures = SIMD4<Float>.zero
    public private(set) var localTemperature: Float = 0, localPressure: Float = 0
    public private(set) var carFlags: UInt32 = 0
    public var damage: Int32 {
        get { collision.damage }
        set { collision.damage = newValue }
    }
    public init(definition d: VehicleDynamicsDefinition, chassis: ChassisState) {
        definition = d; self.chassis = chassis; pitSetup = d.initialPitSetup
        engine = EngineState(definition:d.engine); transmission = TransmissionState(definition:d.transmission)
        runningGear = RunningGearState(configuration:d.chassis.runningGear); fuel = d.chassis.runningGear.mass.initialFuel
    }
    /// Integrates motion with no environment/car collision response. This explicit
    /// boundary must be extended before representing the result as normal gameplay.
    public mutating func stepWithoutCollision(controls: VehicleDynamicsControls, track: TrackGeometry,
        localTemperature: Float, localPressure: Float, skillLevel: Int, tireFactor: Float,
        preSimulation: Bool = false, carFlags: UInt32 = 0, carIndex: Int = 0,
        traffic: [AeroTrafficState] = [], dt: Float = 0.002, random: () -> Float) throws {
        collision.beginTick()
        var throttle = controls.throttle
        transmission.updateGear(requested:controls.requestedGear,clutchTransfer:controls.clutchTransfer,throttle:&throttle,dt:dt)
        effectiveThrottle = throttle
        engine.updateTorque(definition:definition.engine,throttle:throttle,fuel:&fuel,carFlags:carFlags,dt:dt)
        let pose = chassis.body.orientation, position = chassis.world.position, bodyVelocity = chassis.body.velocity
        var heights = SIMD4<Float>.zero
        for i in 0..<4 { heights[i] = runningGear.wheels[i].contact?.rideHeight ?? 0 }
        // Original aero reads preceding wheel ride heights, before this tick's contacts.
        let aero = definition.chassis.aerodynamics.forces(carIndex:carIndex,position:SIMD2(position.x,position.y),yaw:chassis.world.orientation.z,
            bodyVelocity:bodyVelocity,worldVelocity:SIMD2(chassis.world.velocity.x,chassis.world.velocity.y),speed:chassis.speed,
            damage:damage,rideHeights:heights,traffic:traffic)
        aerodynamics = aero
        try runningGear.updateForces(worldPosition:position,roll:pose.x,pitch:pose.y,yaw:pose.z,bodyVelocity:bodyVelocity,
            yawVelocity:chassis.body.angularVelocity.z,carSegment:chassis.trackPosition.segment,track:track,
            brakePressures:controls.brakePressures,steering:controls.steering,localTemperature:localTemperature,localPressure:localPressure,
            skillLevel:skillLevel,tireFactor:tireFactor,preSimulation:preSimulation,dt:dt)
        let feedback = runningGear.driveFeedback()
        let spins = transmission.update(engineDefinition:definition.engine,engine:&engine,fuel:fuel,feedback:feedback,dt:dt,random:random,
            freeAxle:{ runningGear.freeAxleInputs($0,dt:dt) })
        runningGear.updateRotation(drivetrainSpins:spins,dt:dt)
        try chassis.integrate(definition:definition.chassis,fuel:fuel,wheels:runningGear.chassisLoads(),aero:aero,track:track,dt:dt)
    }
}

extension VehicleDynamicsState {
    /// Includes original ground/barrier response and damage, but not car-to-car
    /// collision, full control/state scheduling or race logic.
    public mutating func step(controls: VehicleDynamicsControls, track: TrackGeometry,
        localTemperature: Float, localPressure: Float, skillLevel: Int, tireFactor: Float, damageFactor: Float,
        preSimulation: Bool = false, carFlags: UInt32 = 0, carIndex: Int = 0,
        traffic: [AeroTrafficState] = [], dt: Float = 0.002, random: () -> Float) throws {
        try stepWithoutCollision(controls:controls,track:track,localTemperature:localTemperature,localPressure:localPressure,
            skillLevel:skillLevel,tireFactor:tireFactor,preSimulation:preSimulation,carFlags:carFlags,carIndex:carIndex,
            traffic:traffic,dt:dt,random:random)
        try chassis.collideWithEnvironment(definition:definition.chassis,track:track,collision:&collision,
            carFlags:carFlags,skillLevel:skillLevel,damageFactor:damageFactor)
        chassis.refreshSpeed()
    }
}

extension VehicleDynamicsState {
    /// Isolated active-car update. Use MultiVehicleSimulation for removal/pit
    /// scheduling and object collisions; this lower-level entry point requires
    /// a car that can enter active physics directly.
    public mutating func stepActiveVehicle(command: DriverCommand, track: TrackGeometry,
        mode: VehicleUpdateMode = .running, carFlags: UInt32 = 0, maximumDamage: Int32 = 0,
        skillLevel: Int = 3, damageFactor: Float = 1, tireFactor: Float = 0,
        carIndex: Int = 0, traffic: [AeroTrafficState] = [], dt: Float = 0.002, random: () -> Float) throws {
        guard carFlags & (0xFF | 0x800) == 0, fuel > 0,
              maximumDamage == 0 || damage <= maximumDamage else {
            throw ParameterError.invalid("Vehicle removal/pit lifecycle is not yet supported")
        }
        try stepScheduledVehicle(command:command,track:track,mode:mode,carFlags:carFlags,skillLevel:skillLevel,
            damageFactor:damageFactor,tireFactor:tireFactor,carIndex:carIndex,traffic:traffic,dt:dt,random:random)
    }
    // The owning simulation has already handled removal and may continue coasting
    // with no fuel, excessive damage or elimination, exactly as SimUpdate does.
    mutating func stepScheduledVehicle(command: DriverCommand, track: TrackGeometry,
        mode: VehicleUpdateMode, carFlags: UInt32, skillLevel: Int = 3,
        damageFactor: Float, tireFactor: Float, carIndex: Int, traffic: [AeroTrafficState],
        dt: Float = 0.002, random: () -> Float) throws {
        guard dt.isFinite, dt > 0, (0..<5).contains(skillLevel),
              track.segments.indices.contains(chassis.trackPosition.segment),
              track.segments[chassis.trackPosition.segment].role == .main else { throw ParameterError.invalid("Invalid vehicle update timing, skill or track position") }
        collision.beginTick(); self.carFlags = carFlags
        // Original SimAtmosphereUpdate is a constant placeholder upstream too.
        localTemperature = Float(273.15)+20; localPressure = 101300
        var request = command
        if mode == .prestart { request.gear = 0 }
        driverCommand = request.checked(carFlags:carFlags,longitudinalSpeed:chassis.body.velocity.x,
            toRight:chassis.trackPosition.toRight,trackWidth:track.segments[chassis.trackPosition.segment].width)
        let config = definition.controls, mass = definition.chassis.runningGear.mass
        steering.update(command:driverCommand.steering,lock:config.steeringLock,maximumSpeed:config.maximumSteeringSpeed,
            wheelbase:mass.wheelbase,wheeltrack:mass.wheeltrack,dt:dt)
        if mode == .prestart {
            var throttle = driverCommand.throttle
            transmission.updateGear(requested:driverCommand.gear,clutchTransfer:driverCommand.clutchTransfer,throttle:&throttle,dt:dt)
            effectiveThrottle = throttle
            engine.updateTorque(definition:definition.engine,throttle:throttle,fuel:&fuel,carFlags:carFlags,dt:dt)
            transmission.updatePrestartRPM(engineDefinition:definition.engine,engine:&engine,fuel:fuel,dt:dt,random:random)
        } else {
            let pressure = config.brakes.pressures(command:driverCommand.brake,clicks:driverCommand.brakeRepartitionClicks)
            brakePressures = SIMD4(pressure.front,pressure.front,pressure.rear,pressure.rear)
            let controls = VehicleDynamicsControls(throttle:driverCommand.throttle,clutchTransfer:driverCommand.clutchTransfer,
                requestedGear:driverCommand.gear,brakePressures:brakePressures,steering:SIMD4(steering.right,steering.left,0,0))
            try step(controls:controls,track:track,localTemperature:localTemperature,localPressure:localPressure,
                skillLevel:skillLevel,tireFactor:tireFactor,damageFactor:damageFactor,preSimulation:mode == .settling,
                carFlags:carFlags,carIndex:carIndex,traffic:traffic,dt:dt,random:random)
        }
        driverCommand.throttle = effectiveThrottle
    }
}

extension VehicleDynamicsState {
    func objectCollisionBody(index: Int,publicTransform: CollisionTransform) -> ObjectCollisionBody {
        var result = ObjectCollisionBody(index:index)
        let mass = definition.chassis.runningGear.mass
        result.carFlags = carFlags; result.inverseMass = mass.inverseMass; result.inverseYawInertia = mass.inverseInertia.z
        result.centerOfGravity = mass.centerOfGravity; result.position = chassis.world.position; result.velocity = chassis.world.velocity
        result.yawVelocity = chassis.world.angularVelocity.z; result.publicOrientation = publicTransform.orientation
        result.transform = publicTransform; result.collision = collision
        return result
    }
    mutating func applyObjectCollision(_ response: ObjectCollisionBody) {
        chassis.world.position = response.position; chassis.world.velocity = response.velocity
        chassis.world.angularVelocity.z = response.yawVelocity; collision = response.collision
        // Body motion, speed, corners and track position remain cached upstream.
    }
    var publishedCollisionTransform: CollisionTransform {
        let p = chassis.body.position, cg = definition.chassis.runningGear.mass.centerOfGravity
        return CollisionTransform(position:SIMD3(p.x,p.y,p.z-cg.z),orientation:chassis.body.orientation)
    }
}

extension VehicleDynamicsState {
    mutating func beginScheduledTick(command: DriverCommand, flags: UInt32) {
        collision.beginTick(); driverCommand = command; carFlags = flags
    }
    mutating func setStatus(flags: UInt32?, fuel: Float?, damage: Int32?) {
        if let flags { carFlags = flags }
        if let fuel { self.fuel = fuel }; if let damage { self.damage = damage }
    }
    mutating func applyRemoval(_ state: VehicleRemovalState) {
        carFlags = state.flags; collision.flags = state.collision
        engine.setRemovalSpeed(state.engineRPM); transmission.setRemovalGear(Int(state.gear))
    }
    func removalState() -> VehicleRemovalState {
        var s = VehicleRemovalState(trackPosition:chassis.trackPosition)
        s.cgHeight = definition.chassis.runningGear.mass.centerOfGravity.z
        s.publicBody = chassis.body; s.publicTransform = publishedCollisionTransform
        synchronizeRemoval(&s)
        for i in 0..<4 { s.publishedWheelPose[i]=WheelVisualPose(position:runningGear.configuration.wheels[i].initialRelativePosition) }
        return s
    }
    func synchronizeRemoval(_ s: inout VehicleRemovalState) {
        s.mechanicalBody = chassis.body; s.trackPosition = chassis.trackPosition
        s.damage = damage; s.gear = Int32(transmission.gear); s.engineRPM = engine.speed
        s.collision = collision.flags
    }
    func publish(_ s: inout VehicleRemovalState, mode: VehicleUpdateMode) {
        synchronizeRemoval(&s)
        s.publicBody = chassis.body; s.publicWorld = chassis.world; s.publicSpeed = chassis.speed
        s.publicTransform = publishedCollisionTransform
        s.publishedGear = Int32(transmission.gear); s.publishedRPM = engine.speed
        s.publishedFuel = fuel; s.publishedDamage = damage
        s.publishedCollision |= collision.flags; s.publishedSimCollision = collision.flags
        for i in 0..<4 {
            let wheel = runningGear.wheels[i],d=runningGear.configuration.wheels[i]
            let p=d.initialRelativePosition
            s.publishedWheelPose[i]=WheelVisualPose(position:SIMD3(p.x,p.y,wheel.forces?.relativeHeight ?? p.z),
                orientation:SIMD3(wheel.forces?.relativeCamber ?? 0,wheel.rotation.angle,wheel.forces?.relativeYaw ?? 0))
            s.publishedBrakeTemperature[i] = wheel.ride.brake.temperature
            s.publishedTirePressure[i] = wheel.thermal.pressure; s.publishedTireTemperature[i] = wheel.thermal.temperature
            s.publishedTireGraining[i] = wheel.thermal.graining; s.publishedTireWear[i] = Float(wheel.thermal.wear)
            if mode != .prestart {
                s.publishedSkid[i] = wheel.forces?.skid ?? 0
                s.publishedSpin[i] = wheel.rotation.spin
            }
        }
    }
}

extension VehicleDynamicsState {
    /// Original SimReConfig. Timing, stall ownership and pit admission are the
    /// race layer's responsibility. This does not leave PIT or publish dynamics.
    public mutating func service(_ command: inout PitServiceCommand) throws {
        if command.fuel>0 { fuel += command.fuel; if fuel>definition.chassis.runningGear.mass.tankCapacity { fuel=definition.chassis.runningGear.mass.tankCapacity } }
        if command.repair>0 {
            let (repaired,overflow)=damage.subtractingReportingOverflow(command.repair)
            guard !overflow else { throw ParameterError.invalid("Repair would overflow original damage storage") }
            damage=max(0,repaired)
        }
        definition.controls.reconfigure(&command.setup)
        for i in 0..<2 {
            definition.chassis.aerodynamics.reconfigureWing(i,setup:&command.setup)
            definition.chassis.runningGear.reconfigureAxle(i,setup:&command.setup)
        }
        for i in 0..<4 { definition.chassis.runningGear.reconfigureWheel(i,setup:&command.setup) }
        runningGear.applyService(configuration:definition.chassis.runningGear,changeAllTires:command.changeAllTires,localTemperature:localTemperature)
        transmission.reconfigure(&command.setup,engineInertia:definition.engine.inertia)
        definition.transmission=transmission.definition; pitSetup=command.setup
    }
}
