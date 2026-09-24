// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSTrack
import TORCSSimulation

final class FullSingleCarTests: XCTestCase {
    func testDriverCommandsThroughOriginalSimUpdate() throws {
        let road = try ChassisTestContext.road()
        var chassis = ChassisMetrics(), powertrain = TransmissionMetrics(), wheels = RunningGearTests.Metrics()
        var aero = EngineMetrics(), collision = CollisionMetrics(), driver = DriverMetrics()
        var draws = 0, ticks = 0, prestartTicks = 0, moving = 0, barriers = 0, ground = 0
        for scenario in 0..<5 {
            try EngineTestContext.withWorld { p,_,world in
                let d = try VehicleDynamicsDefinition(parameters:p)
                var segment = road.geometry.mainSegments[0], distance: Float = 10
                while distance >= road.geometry.segments[segment].length {
                    distance -= road.geometry.segments[segment].length; segment = road.geometry.segments[segment].next
                }
                let s = road.geometry.segments[segment]
                let local = TrackLocalPosition(segment:segment,toStart:s.curve == .straight ? distance : distance/s.radius,toRight:s.width/2)
                let xy = road.geometry.localToGlobal(local)
                var yaw = road.geometry.tangent(local)
                while yaw < 0 { yaw = Float(Double(yaw)+2*Double.pi) }
                while Double(yaw) > 2*Double.pi { yaw = Float(Double(yaw)-2*Double.pi) }
                let initial = ChassisDynamics(position:SIMD3(xy.x,xy.y,road.geometry.height(local)+0.3),orientation:SIMD3(0,0,yaw))
                var n = VehicleDynamicsState(definition:d,chassis:.init(body:initial,world:initial,trackPosition:local))
                for tick in 0..<4501 {
                    let mode: VehicleUpdateMode = tick < 501 ? .settling : scenario == 4 && tick < 1001 ? .prestart : .running
                    var command = DriverCommand(brake:1)
                    if tick >= 501 {
                        switch scenario {
                        case 1: command = DriverCommand(throttle:1,gear:1)
                        case 2: command = tick < 2001 ? DriverCommand(throttle:1,gear:1) : DriverCommand(brake:1,gear:1)
                        case 3: command = DriverCommand(throttle:0.35,steering:0.2,gear:1)
                        case 4: command = DriverCommand(throttle:0.6,brake:tick<1001 ? 0.7 : 0,steering:0.04*sin(Float(tick)*0.01),
                            clutch:tick<1150 ? 0.8 : 0,gear:tick<2300 ? 1 : 2,brakeRepartitionClicks:35)
                        default: break
                        }
                    }
                    let flags: UInt32 = scenario == 4 && tick>3800 ? 0x100 : 0
                    let seed = UInt32(12345+tick), random = ref_uniform_random(seed)
                    var o = try world.stepSimulation(command:command.reference,carFlags:flags,raceState:mode.rawValue,randomSeed:seed,damageFactor:1,tireFactor:2)
                    try n.stepActiveVehicle(command:command,track:road.geometry,mode:mode,carFlags:flags,tireFactor:2,random:{ draws += 1; return random })
                    chassis.state(n.chassis,o.vehicle.chassis)
                    powertrain.state(n.transmission,o.vehicle.powertrain,throttle:n.effectiveThrottle)
                    powertrain.values.state(n.engine,fuel:n.fuel,clutch:n.transmission.clutch,reaction:0,o.vehicle.powertrain.engine)
                    _ = try compareRunningGear(n.runningGear,&o.vehicle.wheels,tick:tick,preSimulation:mode == .settling,metrics:&wheels)
                    collision.state(n.collision,o.vehicle.collision); driver.command(n.driverCommand,o.command)
                    for (a,b) in [(n.steering.angle,o.steeringAngle),(n.localTemperature,o.localTemperature),(n.localPressure,o.localPressure),
                        (n.brakePressures.x,o.brakePressures.frontRight),(n.brakePressures.y,o.brakePressures.frontLeft),
                        (n.brakePressures.z,o.brakePressures.rearRight),(n.brakePressures.w,o.brakePressures.rearLeft)] { driver.values.check(a,b) }
                    XCTAssertEqual(n.carFlags,o.carFlags); XCTAssertEqual(o.vehicle.collision.flags & 4,0,"SOLID collision not yet implemented")
                    let a = try XCTUnwrap(n.aerodynamics), b = o.vehicle.aero
                    for (x,y) in [(a.airSpeedSquared,b.airSpeedSquared),(a.drag,b.drag),(a.bodyLift.x,b.frontLift),(a.bodyLift.y,b.rearLift),
                        (a.frontWing.x,b.frontWing.x),(a.frontWing.z,b.frontWing.z),(a.rearWing.x,b.rearWing.x),(a.rearWing.z,b.rearWing.z)] { aero.check(x,y) }
                    ticks += 1
                    if mode == .prestart { prestartTicks += 1 }
                    if n.chassis.speed>5 { moving += 1 }
                    if n.collision.flags & 2 != 0 { barriers += 1 }
                    if n.collision.flags & 8 != 0 { ground += 1 }
                    if max(chassis.values.worst,powertrain.values.worst,wheels.worst,aero.worst,collision.values.worst,driver.values.worst) != 0 {
                        XCTFail("First full SimUpdate divergence at scenario \(scenario) tick \(tick)"); return
                    }
                }
            }
        }
        XCTAssertEqual(ticks,22505); XCTAssertEqual(draws,ticks); XCTAssertEqual(prestartTicks,500); XCTAssertGreaterThan(moving,0)
        let fields = chassis.values.fields+powertrain.values.fields+wheels.fields+aero.fields+collision.values.fields+driver.values.fields
        print("FULL_SINGLE_CAR ticks=\(ticks) scenarios=5 fields=\(fields) maxAbsolute=\(max(chassis.values.worst,powertrain.values.worst,wheels.worst,aero.worst,collision.values.worst,driver.values.worst)) randomDraws=\(draws) prestartTicks=\(prestartTicks) movingTicks=\(moving) barrierTicks=\(barriers) groundTicks=\(ground)")
    }
}
