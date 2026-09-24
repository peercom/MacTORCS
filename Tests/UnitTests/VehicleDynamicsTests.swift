// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSTrack
import TORCSSimulation

final class VehicleDynamicsTests: XCTestCase {
    func testIndependentVehicleMotionWithoutCollisionAgainstOriginal() throws { try run(environment:false) }
    func testIndependentVehicleWithEnvironmentAgainstOriginal() throws { try run(environment:true) }
    private func run(environment: Bool) throws {
        let road = try ChassisTestContext.road()
        var chassisMetrics = ChassisMetrics(), powertrainMetrics = TransmissionMetrics(), wheelMetrics = RunningGearTests.Metrics(), aeroMetrics = EngineMetrics()
        var draws = 0, sampledTicks = 0, moved = 0, blended = 0, groundTicks = 0, barrierTicks = 0, damagedTicks = 0
        var collisionMetrics = CollisionMetrics()
        let scenarios = environment ? 5 : 3
        for scenario in 0..<scenarios {
            try EngineTestContext.withWorld { p,_,world in
                let d = try VehicleDynamicsDefinition(parameters:p)
                var local = TrackLocalPosition(segment:road.geometry.mainSegments[0],toStart:10,toRight:6)
                if scenario == 4 {
                    let full = try road.geometry.globalToLocal(road.geometry.localToGlobal(local),startingAt:local.segment,mode:.track)
                    local.toRight = -(full.toRight-local.toRight)-1.2
                }
                let xy = road.geometry.localToGlobal(local), height = road.geometry.height(local)
                let offset: Float = scenario == 3 ? 4 : 0.3
                let pos = SIMD3(xy.x,xy.y,height+d.chassis.runningGear.mass.centerOfGravity.z+offset)
                let yaw = road.geometry.tangent(local), rotation = VehicleRotation(roll:0,pitch:0,yaw:yaw)
                var velocity = SIMD3<Float>.zero
                if scenario == 3 { velocity = rotation.toWorld(SIMD3(5,0,-12)) }
                if scenario == 4 {
                    let normal = try XCTUnwrap(road.geometry.segments[local.segment].rightBarrier).normal
                    velocity = SIMD3(-18*normal.x,-18*normal.y,0)+rotation.toWorld(SIMD3(5,0,0))
                }
                let initial = ChassisDynamics(position:pos,orientation:SIMD3(0,0,yaw),velocity:rotation.toBody(velocity))
                var initialWorld = initial; initialWorld.velocity = velocity
                var native = VehicleDynamicsState(definition:d,chassis:.init(body:initial,world:initialWorld,trackPosition:local))
                let setup = ChassisTestContext.input(native.chassis,fuel:native.fuel,
                    wheels:ChassisTestContext.loads(d.chassis,resistance:0),aero:ChassisTestContext.aero)
                try world.initializeVehicle(setup)
                for tick in 0..<6000 {
                    let pre = tick<501, braking = pre || scenario == 0 || tick>=4000
                    let pressure: Float = braking ? 7000000 : 0, throttle: Float = braking ? 0 : 0.8
                    let steer: Float = scenario == 2 && !pre ? 0.015*sin(Float(tick-501)*0.003) : 0
                    let controls = VehicleDynamicsControls(throttle:throttle,clutchTransfer:1,requestedGear:pre ? 0 : tick<2500 ? 1 : 2,
                        brakePressures:SIMD4(pressure,pressure,pressure*0.7,pressure*0.7),steering:SIMD4(steer,steer*0.9,0,0))
                    let control = RefVehicleControl(powertrain:.init(requestedGear:Int32(controls.requestedGear),updateEngineTorque:1,
                        clutchTransfer:controls.clutchTransfer,throttle:controls.throttle,dt:0.002,carFlags:0,randomSeed:UInt32(12345+tick)),
                        brakePressures:.init(frontRight:controls.brakePressures.x,frontLeft:controls.brakePressures.y,rearRight:controls.brakePressures.z,rearLeft:controls.brakePressures.w),
                        steering:.init(frontRight:controls.steering.x,frontLeft:controls.steering.y,rearRight:0,rearLeft:0),
                        localTemperature:288.15,localPressure:96000,tireFactor:2,skillLevel:3,preSimulation:pre ? 1 : 0)
                    let random = ref_uniform_random(control.powertrain.randomSeed)
                    var original: RefVehicleOutput
                    if environment {
                        original = try world.stepVehicle(control,damageFactor:1)
                        try native.step(controls:controls,track:road.geometry,localTemperature:288.15,localPressure:96000,
                            skillLevel:3,tireFactor:2,damageFactor:1,preSimulation:pre,random:{ draws += 1; return random })
                        collisionMetrics.state(native.collision,original.collision)
                        if native.collision.flags & 8 != 0 { groundTicks += 1 }
                        if native.collision.flags & 2 != 0 { barrierTicks += 1 }
                        if native.damage>0 { damagedTicks += 1 }
                    } else {
                        original = try world.stepVehicleWithoutCollision(control)
                        try native.stepWithoutCollision(controls:controls,track:road.geometry,localTemperature:288.15,localPressure:96000,
                            skillLevel:3,tireFactor:2,preSimulation:pre,random:{ draws += 1; return random })
                    }
                    chassisMetrics.state(native.chassis,original.chassis)
                    powertrainMetrics.state(native.transmission,original.powertrain,throttle:native.effectiveThrottle)
                    powertrainMetrics.values.state(native.engine,fuel:native.fuel,clutch:native.transmission.clutch,reaction:0,original.powertrain.engine)
                    let counts = try compareRunningGear(native.runningGear,&original.wheels,tick:tick,preSimulation:pre,metrics:&wheelMetrics)
                    blended += counts.blended
                    let aero = try XCTUnwrap(native.aerodynamics), o = original.aero
                    for (a,b) in [(aero.airSpeedSquared,o.airSpeedSquared),(aero.drag,o.drag),(aero.bodyLift.x,o.frontLift),(aero.bodyLift.y,o.rearLift),
                        (aero.frontWing.x,o.frontWing.x),(aero.frontWing.z,o.frontWing.z),(aero.rearWing.x,o.rearWing.x),(aero.rearWing.z,o.rearWing.z)] { aeroMetrics.check(a,b) }
                    sampledTicks += 1
                    if native.chassis.speed>5 { moved += 1 }
                    if max(chassisMetrics.values.worst,powertrainMetrics.values.worst,wheelMetrics.worst,aeroMetrics.worst,collisionMetrics.values.worst) != 0 {
                        XCTFail("First independent vehicle divergence at scenario \(scenario), tick \(tick)"); return
                    }
                }
                if scenario>0 { XCTAssertLessThan(native.fuel,d.chassis.runningGear.mass.initialFuel) }
                XCTAssertThrowsError(try world.initializeVehicle(setup))
            }
        }
        XCTAssertEqual(sampledTicks,scenarios*6000); XCTAssertEqual(draws,scenarios*6000); XCTAssertGreaterThan(moved,0)
        if environment { XCTAssertGreaterThan(groundTicks,0); XCTAssertGreaterThan(barrierTicks,0); XCTAssertGreaterThan(damagedTicks,0) }
        let label = environment ? "VEHICLE_ENVIRONMENT" : "VEHICLE_NO_COLLISION"
        print("\(label) ticks=\(sampledTicks) scenarios=\(scenarios) chassisFields=\(chassisMetrics.values.fields) powertrainFields=\(powertrainMetrics.values.fields) wheelFields=\(wheelMetrics.fields) aeroFields=\(aeroMetrics.fields) maxAbsolute=\(max(chassisMetrics.values.worst,powertrainMetrics.values.worst,wheelMetrics.worst,aeroMetrics.worst)) randomDraws=\(draws) movingTicks=\(moved) blended=\(blended) collisionFields=\(collisionMetrics.values.fields) groundTicks=\(groundTicks) barrierTicks=\(barrierTicks) damagedTicks=\(damagedTicks)")
    }
}
