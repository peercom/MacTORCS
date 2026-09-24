// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSTrack
import TORCSSimulation
import TORCSReferenceSupport

struct CollisionMetrics {
    var values = EngineMetrics()
    mutating func state(_ n: CollisionState,_ o: RefCollisionState) {
        XCTAssertEqual(n.flags,o.flags); XCTAssertEqual(n.blocked,o.blocked != 0); XCTAssertEqual(n.damage,o.damage)
        for (a,b) in [(n.normal.x,o.normal.x),(n.normal.y,o.normal.y),(n.normal.z,o.normal.z),
                      (n.position.x,o.position.x),(n.position.y,o.position.y),(n.position.z,o.position.z)] { values.check(a,b) }
    }
}
enum EnvironmentTestContext {
    static func chassis(_ n: ChassisState) -> RefChassisOutput {
        var o = RefChassisOutput()
        o.body = ChassisTestContext.dynamics(n.body); o.world = ChassisTestContext.dynamics(n.world); o.previousWorld = ChassisTestContext.dynamics(n.previousWorld)
        o.speed = n.speed
        let p = n.trackPosition
        o.trackPosition = RefTrackPosition(segment:Int32(p.segment),mode:Int32(p.mode.rawValue),toStart:p.toStart,toRight:p.toRight,toMiddle:p.toMiddle,toLeft:p.toLeft)
        withUnsafeMutablePointer(to:&o.corners) { p in p.withMemoryRebound(to:RefChassisCorner.self,capacity:4) { b in
            for i in 0..<4 {
                b[i] = RefChassisCorner(position:ChassisTestContext.vector(n.corners[i].position),bodyVelocity:ChassisTestContext.vector(n.corners[i].bodyVelocity),
                    worldVelocity:ChassisTestContext.vector(n.corners[i].worldVelocity))
            }
        } }
        return o
    }
    static func collision(_ c: CollisionState) -> RefCollisionState {
        .init(flags:c.flags,blocked:c.blocked ? 1 : 0,damage:c.damage,normal:ChassisTestContext.vector(c.normal),position:ChassisTestContext.vector(c.position))
    }
    static func state(d: ChassisDefinition,track: TrackGeometry,local: TrackLocalPosition,height: Float,orientation: SIMD3<Float>,velocity: SIMD3<Float>) throws -> ChassisState {
        let xy = track.localToGlobal(local), z = track.height(local)
        let position = SIMD3(xy.x,xy.y,z+height), rotation = VehicleRotation(roll:orientation.x,pitch:orientation.y,yaw:orientation.z)
        let body = ChassisDynamics(position:position,orientation:orientation,velocity:rotation.toBody(velocity),angularVelocity:SIMD3(0.3,-0.4,8))
        var world = body; world.velocity = velocity
        func corner(_ i: Int) -> ChassisCornerState {
            let cg = d.runningGear.mass.centerOfGravity, p = d.corners[i]
            let point = position+rotation.toWorld(SIMD3(p.x+cg.x,p.y+cg.y,p.z-cg.z))
            // Independently supplied corner impact velocities exercise sequential impulses.
            return ChassisCornerState(position:point,bodyVelocity:body.velocity,worldVelocity:velocity+SIMD3(Float(i)-1.5,Float(i%2)-0.5,0))
        }
        return ChassisState(body:body,world:world,trackPosition:try track.globalToLocal(xy,startingAt:local.segment),speed:30,
            corners:FourWheels(corner(0),corner(1),corner(2),corner(3)))
    }
}
final class EnvironmentCollisionTests: XCTestCase {
    func testGroundImpactThresholdsAndStateGatesAgainstOriginal() throws {
        let road = try ChassisTestContext.road()
        var metrics = ChassisMetrics(), collisions = CollisionMetrics(), count = 0, contacts = 0, crashes = 0, damage = 0
        try EngineTestContext.withWorld { p,_,world in
            let d = try ChassisTestContext.definition(p)
            for index in [0,100,250] {
                let main = road.geometry.mainSegments[index], segment = road.geometry.segments[main]
                for lateral: Float in [6,-2] {
                    let local = TrackLocalPosition(segment:main,toStart:segment.extent*0.5,toRight:lateral)
                    let normal = road.geometry.surfaceNormal(try road.geometry.globalToLocal(road.geometry.localToGlobal(local),startingAt:main,mode:.segment))
                    for height: Float in [0.1,0.5,1.5] {
                        for pose: SIMD3<Float> in [SIMD3(0,0,0),SIMD3(0.3,-0.2,0.5),SIMD3(-0.5,0.4,-0.6)] {
                            for vertical: Float in [-20,-5,Float(-5).nextUp,0,5] {
                                for skill in [0,2,3] {
                                    for flags: UInt32 in [0,0x100,1] {
                                        for factor: Float in [0,1.3] {
                                            var n = try EnvironmentTestContext.state(d:d,track:road.geometry,local:local,height:height,orientation:pose,velocity:normal*vertical)
                                            var c = CollisionState(); c.flags = 4; c.damage = 123; c.normal = SIMD3(1,2,3); c.position = SIMD3(4,5,6)
                                            let before = n.body
                                            let o = try world.collideEnvironment(.init(chassis:EnvironmentTestContext.chassis(n),collision:EnvironmentTestContext.collision(c),
                                                carFlags:flags,skillLevel:Int32(skill),stages:1,damageFactor:factor))
                                            try n.collideWithEnvironment(definition:d,track:road.geometry,collision:&c,carFlags:flags,skillLevel:skill,damageFactor:factor,barriers:false)
                                            metrics.state(n,o.chassis); collisions.state(c,o.collision)
                                            XCTAssertEqual(n.body.position,before.position); XCTAssertEqual(n.body.velocity,before.velocity)
                                            if flags != 0 || skill == 0 || factor == 0 { XCTAssertEqual(c.damage,123) }
                                            if c.flags & 8 != 0 { contacts += 1 }; if c.flags & 16 != 0 { crashes += 1 }; if c.damage>123 { damage += 1 }
                                            count += 1
                                            if max(metrics.values.worst,collisions.values.worst) != 0 { XCTFail("Ground divergence \(count)"); return }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(contacts,0); XCTAssertGreaterThan(crashes,0); XCTAssertGreaterThan(damage,0)
        print("GROUND_COLLISION cases=\(count) fields=\(metrics.values.fields+collisions.values.fields) maxAbsolute=\(max(metrics.values.worst,collisions.values.worst)) contacts=\(contacts) crashes=\(crashes) damaged=\(damage)")
    }
    func testBarrierImpulsesDamageAndSequentialCornersAgainstOriginal() throws {
        let road = try ChassisTestContext.road()
        var metrics = ChassisMetrics(), collisions = CollisionMetrics(), count = 0, blocked = 0, rebounds = 0, damaged = 0
        try EngineTestContext.withWorld { p,_,world in
            let d = try ChassisTestContext.definition(p)
            for index in [0,100,250] {
                let main = road.geometry.mainSegments[index], segment = road.geometry.segments[main]
                for left in [false,true] {
                    var local = TrackLocalPosition(segment:main,toStart:segment.extent*0.5,toRight:6)
                    let full = try road.geometry.globalToLocal(road.geometry.localToGlobal(local),startingAt:main,mode:.track)
                    let rightExtra = full.toRight-6, leftExtra = full.toLeft-(segment.width-6)
                    let barrier = try XCTUnwrap(left ? segment.leftBarrier : segment.rightBarrier)
                    for penetration: Float in [-0.5,3] {
                        local.toRight = left ? segment.width+leftExtra+penetration : -rightExtra-penetration
                        for speed: Float in [-30,0,20] {
                            for yaw: Float in [0,0.6,2.5] {
                                for skill in [0,1,3] {
                                    for flags: UInt32 in [0,0x100,0x40] {
                                        for factor: Float in [0,1.7] {
                                            var n = try EnvironmentTestContext.state(d:d,track:road.geometry,local:local,height:1.1,orientation:SIMD3(0.1,-0.2,yaw),
                                                velocity:SIMD3(barrier.normal.x*speed,barrier.normal.y*speed,-3))
                                            var c = CollisionState(); c.flags = 8; c.damage = 123; c.normal = SIMD3(1,2,3); c.position = SIMD3(4,5,6)
                                            let o = try world.collideEnvironment(.init(chassis:EnvironmentTestContext.chassis(n),collision:EnvironmentTestContext.collision(c),
                                                carFlags:flags,skillLevel:Int32(skill),stages:2,damageFactor:factor))
                                            try n.collideWithEnvironment(definition:d,track:road.geometry,collision:&c,carFlags:flags,skillLevel:skill,damageFactor:factor,ground:false)
                                            metrics.state(n,o.chassis); collisions.state(c,o.collision)
                                            XCTAssertEqual(c.normal.z,3); XCTAssertEqual(c.position.z,6)
                                            if flags != 0 || skill == 0 || factor == 0 { XCTAssertEqual(c.damage,123) }
                                            if c.blocked { blocked += 1 }; if c.flags & 2 != 0 { rebounds += 1 }; if c.damage>123 { damaged += 1 }
                                            count += 1
                                            if max(metrics.values.worst,collisions.values.worst) != 0 { XCTFail("Barrier divergence \(count)"); return }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(blocked,0); XCTAssertGreaterThan(rebounds,0); XCTAssertGreaterThan(damaged,0)
        print("BARRIER_COLLISION cases=\(count) fields=\(metrics.values.fields+collisions.values.fields) maxAbsolute=\(max(metrics.values.worst,collisions.values.worst)) blocked=\(blocked) rebounds=\(rebounds) damaged=\(damaged)")
    }
}
