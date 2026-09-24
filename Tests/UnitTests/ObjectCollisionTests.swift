// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSSimulation

private enum ObjectTestContext {
    static func vector(_ v: SIMD3<Double>) -> RefDoubleVector { .init(x:v.x,y:v.y,z:v.z) }
    static func contact(_ n: ObjectCollisionContact) -> RefObjectContact {
        .init(firstPoint:vector(n.firstPoint),secondPoint:vector(n.secondPoint),normal:vector(n.normal))
    }
    static func input(_ b: ObjectCollisionBody) -> RefObjectBody {
        let v = ChassisTestContext.vector
        return .init(index:Int32(b.index),skillLevel:Int32(b.skillLevel),carFlags:b.carFlags,inverseMass:b.inverseMass,inverseYawInertia:b.inverseYawInertia,
            yawVelocity:b.yawVelocity,centerOfGravity:v(b.centerOfGravity),position:v(b.position),velocity:v(b.velocity),
            publicOrientation:v(b.publicOrientation),transformPosition:v(b.transform.position),transformOrientation:v(b.transform.orientation),
            accumulated:v(b.accumulated),collision:EnvironmentTestContext.collision(b.collision))
    }
    static func body(_ i: Int,pose: SIMD3<Float>,speed: Float,flags: UInt32,caseIndex: Int) -> ObjectCollisionBody {
        var b = ObjectCollisionBody(index:i)
        b.inverseMass = 1/Float(800+900*(caseIndex%3)); b.inverseYawInertia = Float(caseIndex%4)*0.0005
        b.centerOfGravity = SIMD3(0.15,-0.06,0.4); b.position = SIMD3(Float(i)*4,2,1.1)
        b.velocity = SIMD3(speed,Float(i)*3,0.4); b.yawVelocity = Float(caseIndex%7)-3
        b.publicOrientation = pose; b.carFlags = flags; b.skillLevel = caseIndex%5
        b.transform = CollisionTransform(position:b.position+SIMD3(0.012,-0.02,-0.4),orientation:pose+SIMD3(0.02,-0.04,0.03))
        b.accumulated = SIMD3(-4,5,0.2)
        b.collision.flags = caseIndex%2 == 0 ? 4 : 9; b.collision.blocked = caseIndex%3 == 0
        b.collision.damage = 17; b.collision.normal = SIMD3(2,3,4); b.collision.position = SIMD3(-3,-4,-5)
        return b
    }
}
private struct ObjectMetrics {
    var values = EngineMetrics(), collisions = CollisionMetrics(), cases = 0, damaged = 0, capped = 0, blocked = 0
    mutating func state(_ n: ObjectCollisionBody,_ reference: RefObjectResponse) {
        var o = reference
        func components(_ v: RefTrackVector) -> SIMD3<Float> { SIMD3(v.x,v.y,v.z) }
        for (a,b) in [(n.position,components(o.position)),(n.velocity,components(o.velocity)),(n.accumulated,components(o.accumulated))] {
            for i in 0..<3 { values.check(a[i],b[i]) }
        }
        values.check(n.yawVelocity,o.yawVelocity)
        let r = n.transform.rotation
        let columns = [r.toWorld(SIMD3(1,0,0)),r.toWorld(SIMD3(0,1,0)),r.toWorld(SIMD3(0,0,1)),n.transform.position]
        withUnsafePointer(to:&o.transform) { ptr in ptr.withMemoryRebound(to:Float.self,capacity:16) { b in
            for col in 0..<4 { for row in 0..<4 { values.check(row==3 ? (col==3 ? 1 : 0) : columns[col][row],b[col*4+row],"matrix \(col),\(row)") } }
        } }
        collisions.state(n.collision,o.collision); cases += 1
        if n.collision.damage>17 { damaged += 1 }; if abs(n.accumulated.z)==3 { capped += 1 }; if n.collision.blocked { blocked += 1 }
    }
    var worst: Float { max(values.worst,collisions.values.worst) }
    var fields: Int { values.fields+collisions.values.fields }
}
final class ObjectCollisionTests: XCTestCase {
    func testPairSeparationAndDamageTruncationBoundariesAgainstOriginal() throws {
        var metrics = ObjectMetrics(), count = 0, fractionalCorrections = 0, truncatedZero = 0
        let threshold = Float(20.0/3.0)
        for distance: Float in [0,0.001,Float(0.05).nextDown,0.05,Float(0.05).nextUp,0.2] {
            for speed: Float in [0,threshold.nextDown,threshold,threshold.nextUp,Float(40.0/3.0)] {
                for normal: Double in [-1,1] {
                    for blocked in [false,true] {
                        var a = ObjectCollisionBody(index:0), b = ObjectCollisionBody(index:1)
                        a.inverseMass = 1; b.inverseMass = 1; a.inverseYawInertia = 0; b.inverseYawInertia = 0
                        a.velocity.x = speed; a.collision.blocked = blocked
                        b.position.x = distance; b.transform = CollisionTransform(position:b.position,orientation:.zero)
                        let contact = ObjectCollisionContact(firstPoint:.zero,secondPoint:.zero,normal:SIMD3(normal,0,0))
                        var oa = RefObjectResponse(), ob = RefObjectResponse()
                        XCTAssertEqual(ref_object_pair_response(ObjectTestContext.input(a),ObjectTestContext.input(b),ObjectTestContext.contact(contact),1,&oa,&ob),1)
                        try ObjectCollisionResponse.pair(first:&a,second:&b,contact:contact,damageFactor:1)
                        metrics.state(a,oa); metrics.state(b,ob); count += 1
                        if !blocked { XCTAssertEqual(a.position.x,Float(normal)*min(distance,0.05)) }
                        if distance>0 && distance<0.05 && !blocked { fractionalCorrections += 1 }
                        if normal<0 && speed==threshold { XCTAssertEqual(a.collision.damage,0); truncatedZero += 1 }
                        if metrics.worst != 0 { XCTFail("First pair boundary divergence at case \(count)"); return }
                    }
                }
            }
        }
        XCTAssertGreaterThan(fractionalCorrections,0); XCTAssertGreaterThan(truncatedZero,0)
        print("OBJECT_BOUNDARY cases=\(count) fields=\(metrics.fields) maxAbsolute=\(metrics.worst) fractionalCorrections=\(fractionalCorrections) truncatedZero=\(truncatedZero)")
    }
    func testAccumulatedContactsAndVelocityCommitAgainstOriginal() throws {
        var bodies = (0..<3).map { ObjectTestContext.body($0,pose:SIMD3(Float($0)*0.1,-0.1,Float($0)*0.3),speed:Float(10-$0*8),flags:$0==2 ? 1 : 0,caseIndex:$0+1) }
        let initial = bodies.map(ObjectTestContext.input)
        var events: [RefObjectEvent] = [], contacts: [ObjectCollisionContact] = []
        for i in 0..<4000 {
            let angle = Double(i)*0.017
            let contact = ObjectCollisionContact(firstPoint:SIMD3(1.2*cos(angle),0.8*sin(angle),0),secondPoint:SIMD3(-1.7,0.6,0),normal:SIMD3(0.03*cos(angle),0.03*sin(angle),0))
            contacts.append(contact)
            let first = i%3, second = (first+1)%3
            events.append(.init(kind:i%7==0 ? 1 : 0,first:Int32(first),second:Int32(second),wallFirst:i%2==0 ? 1 : 0,
                resetBefore:i%4==0 ? 1 : 0,commitAfter:i%4==3 ? 1 : 0,damageFactor:0.8,contact:ObjectTestContext.contact(contact)))
        }
        var original = [RefObjectResponse](repeating:.init(),count:events.count*bodies.count)
        XCTAssertEqual(ref_object_response_sequence(initial,Int32(initial.count),events,Int32(events.count),&original,Int32(original.count)),1)
        var metrics = ObjectMetrics()
        for i in events.indices {
            let event = events[i], a = Int(event.first), b = Int(event.second)
            if event.resetBefore != 0 { for j in bodies.indices { bodies[j].collision.beginTick(); bodies[j].beginDispatch() } }
            if event.kind==0 {
                var first = bodies[a], second = bodies[b]
                try ObjectCollisionResponse.pair(first:&first,second:&second,contact:contacts[i],damageFactor:event.damageFactor)
                bodies[a] = first; bodies[b] = second
            } else {
                try ObjectCollisionResponse.wall(body:&bodies[a],contact:contacts[i],wallIsFirst:event.wallFirst != 0,damageFactor:event.damageFactor)
            }
            if event.commitAfter != 0 { for j in bodies.indices { bodies[j].commitVelocity() } }
            for j in bodies.indices { metrics.state(bodies[j],original[i*bodies.count+j]) }
            if metrics.worst != 0 { XCTFail("First accumulated response divergence at event \(i)"); return }
        }
        XCTAssertGreaterThan(metrics.damaged,0)
        print("OBJECT_SEQUENCE events=4000 bodies=3 fields=\(metrics.fields) maxAbsolute=\(metrics.worst) damagedBodies=\(metrics.damaged) cappedBodies=\(metrics.capped)")
    }
    func testPairResponseOrderingStateGatesAndImpulsesAgainstOriginal() throws {
        var metrics = ObjectMetrics(), count = 0
        let flags: [(UInt32,UInt32)] = [(0,0),(0x100,0),(0,0x100),(1,0),(0,1),(1,1),(2,0),(0,0x81)]
        for pose: SIMD3<Float> in [.zero,SIMD3(0.2,-0.3,0.7),SIMD3(-0.4,0.2,-2.1)] {
            for speed: Float in [-30,0,45] {
                for normal: SIMD3<Double> in [SIMD3(0.1,0,0),SIMD3(-0.3,0.4,0.1),SIMD3(0,-0.002,0),SIMD3(0,0,1),SIMD3(1e-60,1e-60,0)] {
                    for point: SIMD3<Double> in [SIMD3(2,0.8,0),SIMD3(-2,-0.7,0),SIMD3(0.4,1.3,2),SIMD3(0.15,-0.06,-1)] {
                        for (firstFlags,secondFlags) in flags {
                            for damageFactor: Float in [0,1,2.3] {
                                for reverse in [false,true] {
                                    var a = ObjectTestContext.body(reverse ? 9 : 1,pose:pose,speed:speed,flags:firstFlags,caseIndex:count)
                                    var b = ObjectTestContext.body(reverse ? 1 : 9,pose:-pose,speed:-speed*0.4,flags:secondFlags,caseIndex:count+1)
                                    let contact = ObjectCollisionContact(firstPoint:point,secondPoint:-point,normal:normal)
                                    var oa = RefObjectResponse(), ob = RefObjectResponse()
                                    XCTAssertEqual(ref_object_pair_response(ObjectTestContext.input(a),ObjectTestContext.input(b),ObjectTestContext.contact(contact),damageFactor,&oa,&ob),1)
                                    try ObjectCollisionResponse.pair(first:&a,second:&b,contact:contact,damageFactor:damageFactor)
                                    metrics.state(a,oa); metrics.state(b,ob); count += 1
                                    if metrics.worst != 0 { XCTFail("First pair response divergence at case \(count)"); return }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(metrics.damaged,0); XCTAssertGreaterThan(metrics.capped,0)
        print("OBJECT_PAIR cases=\(count) fields=\(metrics.fields) maxAbsolute=\(metrics.worst) damagedBodies=\(metrics.damaged) cappedBodies=\(metrics.capped) blockedBodies=\(metrics.blocked)")
    }
    func testWallResponseObjectOrderAndPenetrationAgainstOriginal() throws {
        var metrics = ObjectMetrics(), count = 0
        for pose: SIMD3<Float> in [.zero,SIMD3(0.2,-0.3,0.7),SIMD3(-0.4,0.2,-2.1)] {
            for speed: Float in [-30,0,45] {
                for length: Double in [0,0.001,0.019999999,0.02,0.02000001,0.04999999,0.05,0.05000001,2] {
                    for point: SIMD3<Double> in [SIMD3(2,0.8,0),SIMD3(-2,-0.7,0),SIMD3(0.4,1.3,2),SIMD3(0.15,-0.06,-1)] {
                        for flags: UInt32 in [0,0x100,1,2] {
                            for damageFactor: Float in [0,1,2.3] {
                                for wallFirst in [false,true] {
                                    var body = ObjectTestContext.body(1,pose:pose,speed:speed,flags:flags,caseIndex:count)
                                    let contact = ObjectCollisionContact(firstPoint:point,secondPoint:-point,normal:SIMD3(length*0.6,length*0.8,0.3))
                                    var o = RefObjectResponse()
                                    XCTAssertEqual(ref_object_wall_response(ObjectTestContext.input(body),ObjectTestContext.contact(contact),wallFirst ? 1 : 0,damageFactor,&o),1)
                                    try ObjectCollisionResponse.wall(body:&body,contact:contact,wallIsFirst:wallFirst,damageFactor:damageFactor)
                                    metrics.state(body,o); count += 1
                                    if metrics.worst != 0 { XCTFail("First wall response divergence at case \(count)"); return }
                                }
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(metrics.damaged,0); XCTAssertGreaterThan(metrics.capped,0)
        print("OBJECT_WALL cases=\(count) fields=\(metrics.fields) maxAbsolute=\(metrics.worst) damagedBodies=\(metrics.damaged) cappedBodies=\(metrics.capped) blockedBodies=\(metrics.blocked)")
    }
}
