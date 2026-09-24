// SPDX-License-Identifier: GPL-2.0-only
import TORCSSimulation
import TORCSTrack

/// Diagnostic schema matching the original headless world. Allocations belong
/// to telemetry capture, not the real-time simulation or rendering loop.
public enum VehicleTelemetry {
    public static func values(_ n: VehicleDynamicsState,track: TrackGeometry) -> [String:Double] {
        var v: [String:Double] = [:]
        func scalar(_ name: String,_ value: Float) { v[name] = Double(value) }
        func vector(_ prefix: String,_ value: SIMD3<Float>) {
            scalar(prefix+".x",value.x); scalar(prefix+".y",value.y); scalar(prefix+".z",value.z)
        }
        let world = n.chassis.world, body = n.chassis.body
        vector("position",world.position); scalar("orientation.roll",world.orientation.x)
        scalar("orientation.pitch",world.orientation.y); scalar("orientation.yaw",world.orientation.z)
        vector("velocity.world",world.velocity); vector("velocity.local",body.velocity); vector("angularVelocity",world.angularVelocity)
        vector("acceleration.world",world.acceleration); vector("angularAcceleration",world.angularAcceleration)
        scalar("engine.radiansPerSecond",n.engine.speed); scalar("engine.torque",n.engine.torque)
        v["gear"] = Double(n.transmission.gear); scalar("clutch.transfer",n.transmission.clutch.transfer)
        scalar("fuel",n.fuel); v["damage"] = Double(n.damage); v["collision"] = Double(n.collision.flags); v["state"] = Double(n.carFlags)
        scalar("command.throttle",n.driverCommand.throttle); scalar("command.brake",n.driverCommand.brake)
        scalar("command.steering",n.driverCommand.steering); scalar("command.clutch",n.driverCommand.clutch); v["command.gear"] = Double(n.driverCommand.gear)
        scalar("aero.drag",n.aerodynamics?.drag ?? 0); scalar("aero.lift.front",n.aerodynamics?.bodyLift.x ?? 0); scalar("aero.lift.rear",n.aerodynamics?.bodyLift.y ?? 0)
        scalar("wing.front.x",n.aerodynamics?.frontWing.x ?? 0); scalar("wing.front.z",n.aerodynamics?.frontWing.z ?? 0)
        scalar("wing.rear.x",n.aerodynamics?.rearWing.x ?? 0); scalar("wing.rear.z",n.aerodynamics?.rearWing.z ?? 0)
        let p = n.chassis.trackPosition, segment = track.segments[p.segment]
        v["track.segment"] = Double(segment.upstreamID); scalar("track.toStart",p.toStart); scalar("track.toRight",p.toRight)
        scalar("track.distance",segment.distanceFromStart+p.toStart*(segment.curve == .straight ? 1 : segment.radius)); scalar("steering.angle",n.steering.angle)
        for i in 0..<4 {
            let w = n.runningGear.wheels[i], prefix = "wheel.\(i)."
            vector(prefix+"position",w.position); scalar(prefix+"spin",w.rotation.spin)
            scalar(prefix+"slipRatio",w.forces?.longitudinalSlip ?? 0); scalar(prefix+"slipAngle",w.forces?.slipAngle ?? 0)
            scalar(prefix+"load",w.forces?.tireLoad ?? 0); vector(prefix+"force",w.forces?.force ?? .zero)
            scalar(prefix+"suspension.travel",w.ride.displacement); scalar(prefix+"suspension.velocity",w.ride.suspensionVelocity)
            scalar(prefix+"suspension.force",w.forces?.suspensionForce ?? 0); scalar(prefix+"brake.pressure",n.brakePressures[i])
            scalar(prefix+"brake.torque",w.ride.brake.torque); scalar(prefix+"brake.temperature",w.ride.brake.temperature)
            scalar(prefix+"steer",i == 0 ? n.steering.right : i == 1 ? n.steering.left : 0)
            scalar(prefix+"rideHeight",w.contact?.rideHeight ?? 0); scalar(prefix+"roadHeight",w.contact?.roadHeight ?? 0)
            scalar(prefix+"tire.pressure",w.thermal.pressure); scalar(prefix+"tire.temperature",w.thermal.temperature)
            v[prefix+"tire.wear"] = w.thermal.wear; v[prefix+"state"] = Double(w.ride.flags)
            v[prefix+"track.segment"] = Double(w.contact.map { track.segments[$0.position.segment].upstreamID } ?? -1)
        }
        return v
    }
    public static func record(_ simulation: SingleVehicleSimulation,scenario: String) -> TelemetryRecord {
        let fields = values(simulation.vehicle,track:simulation.road.geometry)
        return TelemetryRecord(scenario:scenario,tick:simulation.tick,time:Double(simulation.tick)*0.002,
            values:Dictionary(uniqueKeysWithValues:fields.map { ("car.0."+$0.key,$0.value) }))
    }
    public static func record(_ simulation: MultiVehicleSimulation,scenario: String) -> TelemetryRecord {
        var fields: [String:Double] = [:]
        for i in simulation.cars.indices {
            for (name,value) in values(simulation.cars[i],track:simulation.road.geometry) { fields["car.\(i)."+name] = value }
        }
        return TelemetryRecord(scenario:scenario,tick:simulation.tick,time:Double(simulation.tick)*0.002,values:fields)
    }

}
