// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSConfiguration
import TORCSTrack
import TORCSSimulation
import TORCSReferenceSupport

struct ChassisMetrics {
    var values = EngineMetrics()
    mutating func vector(_ n: SIMD3<Float>,_ o: RefTrackVector) {
        values.check(n.x,o.x); values.check(n.y,o.y); values.check(n.z,o.z)
    }
    mutating func dynamics(_ n: ChassisDynamics,_ o: RefChassisDynamics) {
        vector(n.position,o.position); vector(n.orientation,o.orientation); vector(n.velocity,o.velocity)
        vector(n.angularVelocity,o.angularVelocity); vector(n.acceleration,o.acceleration); vector(n.angularAcceleration,o.angularAcceleration)
    }
    mutating func state(_ n: ChassisState,_ original: RefChassisOutput) {
        var o = original
        dynamics(n.body,o.body); dynamics(n.world,o.world); dynamics(n.previousWorld,o.previousWorld)
        withUnsafePointer(to:&o.corners) { p in
            p.withMemoryRebound(to:RefChassisCorner.self,capacity:4) { b in
                for i in 0..<4 { vector(n.corners[i].position,b[i].position); vector(n.corners[i].bodyVelocity,b[i].bodyVelocity); vector(n.corners[i].worldVelocity,b[i].worldVelocity) }
            }
        }
        XCTAssertEqual(n.trackPosition.segment,Int(o.trackPosition.segment)); XCTAssertEqual(n.trackPosition.mode.rawValue,Int(o.trackPosition.mode))
        for (a,b) in [(n.trackPosition.toStart,o.trackPosition.toStart),(n.trackPosition.toRight,o.trackPosition.toRight),
                      (n.trackPosition.toLeft,o.trackPosition.toLeft),(n.trackPosition.toMiddle,o.trackPosition.toMiddle),(n.speed,o.speed)] { values.check(a,b) }
    }
}
enum ChassisTestContext {
    static func road() throws -> TrackRoad {
        let fixtures = try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil))
        return try TrackBuilder.buildRoad(parameters:ParameterDocument.parse(Data(contentsOf:fixtures.appendingPathComponent("aalborg.xml")),entities:[
            "default-surfaces":Data(contentsOf:fixtures.appendingPathComponent("surfaces.xml")),
            "default-objects":Data(contentsOf:fixtures.appendingPathComponent("objects.xml"))],allowLegacyLatin1:true))
    }
    static func definition(_ p: ParameterDocument) throws -> ChassisDefinition {
        let r = try RunningGearConfiguration(parameters:p)
        return try ChassisDefinition(parameters:p,runningGear:r,aerodynamics:AerodynamicsDefinition(parameters:p,centerOfGravityX:r.mass.centerOfGravity.x))
    }
    static func vector(_ v: SIMD3<Float>) -> RefTrackVector { .init(x:v.x,y:v.y,z:v.z) }
    static func dynamics(_ d: ChassisDynamics) -> RefChassisDynamics {
        .init(position:vector(d.position),orientation:vector(d.orientation),velocity:vector(d.velocity),angularVelocity:vector(d.angularVelocity),
              acceleration:vector(d.acceleration),angularAcceleration:vector(d.angularAcceleration))
    }
    static func input(_ n: ChassisState,fuel: Float,wheels: FourWheels<ChassisWheelLoad>,aero: AerodynamicsResult,dt: Float = 0.002) -> RefChassisInput {
        var p = RefChassisInput()
        p.body = dynamics(n.body); p.world = dynamics(n.world); p.fuel = fuel; p.speed = n.speed; p.dt = dt
        p.cachedYawCosine = n.cachedYawCosine; p.cachedYawSine = n.cachedYawSine; p.mainSegment = Int32(n.trackPosition.segment)
        withUnsafeMutablePointer(to:&p.wheels) { ptr in
            ptr.withMemoryRebound(to:RefChassisWheelLoad.self,capacity:4) { b in
                for i in 0..<4 { b[i] = RefChassisWheelLoad(force:vector(wheels[i].force),rideHeight:wheels[i].rideHeight,rollingResistance:wheels[i].rollingResistance) }
            }
        }
        p.aero = RefAeroOutput(airSpeedSquared:aero.airSpeedSquared,drag:aero.drag,frontLift:aero.bodyLift.x,rearLift:aero.bodyLift.y,
                              frontWing:vector(aero.frontWing),rearWing:vector(aero.rearWing))
        return p
    }
    static func loads(_ d: ChassisDefinition,resistance: Float,tick: Int = 0) -> FourWheels<ChassisWheelLoad> {
        func load(_ i: Int) -> ChassisWheelLoad {
            .init(force:SIMD3(120*sin(Float(tick+i)*0.013),60*cos(Float(tick+i)*0.007),d.runningGear.mass.staticWheelLoads[i]),
                  rideHeight:0.16+Float(i)*0.01,rollingResistance:resistance*Float(i+1))
        }
        return FourWheels(load(0),load(1),load(2),load(3))
    }
    static let aero = AerodynamicsResult(airSpeedSquared:625,drag:-220,bodyLift:SIMD2(-110,-190),frontWing:SIMD3(-70,0,-120),rearWing:SIMD3(-80,0,-250))
}
final class ChassisTests: XCTestCase {
    func testOriginalCornerConfiguration() throws {
        var metrics = ChassisMetrics()
        try EngineTestContext.withWorld { p,_,world in
            let d = try ChassisTestContext.definition(p), original = try world.chassisCorners()
            for i in 0..<4 { metrics.vector(d.corners[i],original[i]) }
        }
        print("CHASSIS_CONFIG fields=\(metrics.values.fields) maxAbsolute=\(metrics.values.worst)")
    }
    func testForceIntegrationBoundariesAgainstOriginal() throws {
        let road = try ChassisTestContext.road()
        var metrics = ChassisMetrics(), cases = 0, yawLimits = 0, orientationLimits = 0
        try EngineTestContext.withWorld { p,_,world in
            let d = try ChassisTestContext.definition(p)
            let local = TrackLocalPosition(segment:road.geometry.mainSegments[0],toStart:12,toRight:6)
            let xy = road.geometry.localToGlobal(local), pos = SIMD3(xy.x,xy.y,Float(2))
            for orientation: SIMD3<Float> in [.zero,SIMD3(0.1,-0.2,0.6),SIMD3(1.03,-1.03,Float.pi),SIMD3(-1.04,1.04,-Float.pi),SIMD3(0.5,0.5,12)] {
                for velocity: SIMD3<Float> in [.zero,SIMD3(25,-2,1),SIMD3(-12,8,-0.4)] {
                    for angular: SIMD3<Float> in [.zero,SIMD3(0.2,-0.5,8.99),SIMD3(-0.7,0.1,-9.001)] {
                        for speed: Float in [0,0.00001,Float(0.00001).nextUp,1,80] {
                            for resistance: Float in [0,100,100000000] {
                                for fuel: Float in [0,35,100] {
                                    for dt: Float in [0.002,0.01] {
                                        let rotation = VehicleRotation(roll:orientation.x,pitch:orientation.y,yaw:orientation.z)
                                        var n = ChassisState(body:.init(position:pos,orientation:orientation,velocity:velocity,angularVelocity:angular),
                                            world:.init(position:pos,orientation:orientation,velocity:rotation.toWorld(velocity),angularVelocity:angular,
                                                acceleration:SIMD3(3,4,5),angularAcceleration:SIMD3(0.1,0.2,0.3)),trackPosition:local,speed:speed)
                                        // Exercise both fresh zero caches and explicitly supplied historical values.
                                        if cases%2 == 0 { n.cachedYawCosine = 0.3; n.cachedYawSine = -0.7 }
                                        let loads = ChassisTestContext.loads(d,resistance:resistance)
                                        let input = ChassisTestContext.input(n,fuel:fuel,wheels:loads,aero:ChassisTestContext.aero,dt:dt)
                                        let o = try world.chassisStep(input)
                                        try n.integrate(definition:d,fuel:fuel,wheels:loads,aero:ChassisTestContext.aero,track:road.geometry,dt:dt)
                                        metrics.state(n,o)
                                        if abs(n.world.angularVelocity.z)==9 { yawLimits += 1 }
                                        if abs(n.world.orientation.x)==1.04 || abs(n.world.orientation.y)==1.04 { orientationLimits += 1 }
                                        cases += 1
                                        if metrics.values.worst != 0 { XCTFail("First chassis divergence at case \(cases)"); return }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(yawLimits,0); XCTAssertGreaterThan(orientationLimits,0)
        print("CHASSIS_SWEEP cases=\(cases) fields=\(metrics.values.fields) maxAbsolute=\(metrics.values.worst) yawLimits=\(yawLimits) orientationLimits=\(orientationLimits)")
    }
    func testIndependentChassisSequenceAgainstOriginal() throws {
        let road = try ChassisTestContext.road()
        var metrics = ChassisMetrics()
        try EngineTestContext.withWorld { p,_,world in
            let d = try ChassisTestContext.definition(p)
            let local = TrackLocalPosition(segment:road.geometry.mainSegments[0],toStart:12,toRight:6)
            let xy = road.geometry.localToGlobal(local), pose = SIMD3(xy.x,xy.y,Float(2)), heading = road.geometry.tangent(local)
            let initial = ChassisDynamics(position:pose,orientation:SIMD3(0,0,heading))
            var n = ChassisState(body:initial,world:initial,trackPosition:local)
            var original = RefChassisOutput()
            original.body = ChassisTestContext.dynamics(initial); original.world = original.body
            original.trackPosition.segment = Int32(local.segment)
            let before = try world.sample()
            for tick in 0..<10000 {
                let fuel: Float = max(0,35-Float(tick)*0.001)
                let loads = ChassisTestContext.loads(d,resistance:3,tick:tick)
                var input = ChassisTestContext.input(n,fuel:fuel,wheels:loads,aero:ChassisTestContext.aero)
                // Carry only original outputs into original inputs; native state evolves independently.
                input.body = original.body; input.world = original.world; input.speed = original.speed
                input.mainSegment = original.trackPosition.segment
                original = try world.chassisStep(input)
                try n.integrate(definition:d,fuel:fuel,wheels:loads,aero:ChassisTestContext.aero,track:road.geometry)
                metrics.state(n,original)
                if metrics.values.worst != 0 { XCTFail("First chassis sequence divergence at tick \(tick)"); return }
            }
            XCTAssertEqual(before,try world.sample(),"Isolated chassis oracle must not mutate its configured world")
        }
        print("CHASSIS_SEQUENCE ticks=10000 fields=\(metrics.values.fields) maxAbsolute=\(metrics.values.worst)")
    }
}
