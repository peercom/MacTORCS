// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 simuv2/collide.cpp car/car and car/wall responses.
// Copyright (C) 2000-2017 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSTrack

/// SOLID supplies double-precision local contact points and a world normal.
/// Response intentionally converts those values to Float before its 2D math.
public struct ObjectCollisionContact: Sendable {
    public var firstPoint, secondPoint, normal: SIMD3<Double>
    public init(firstPoint: SIMD3<Double>, secondPoint: SIMD3<Double>, normal: SIMD3<Double>) {
        self.firstPoint = firstPoint; self.secondPoint = secondPoint; self.normal = normal
    }
}
public struct CollisionTransform: Sendable {
    public let position, orientation: SIMD3<Float>
    public let rotation: VehicleRotation
    public init(position: SIMD3<Float>, orientation: SIMD3<Float>) {
        self.position = position; self.orientation = orientation
        rotation = VehicleRotation(roll:orientation.x,pitch:orientation.y,yaw:orientation.z)
    }
    public func point(_ value: SIMD3<Float>) -> SIMD3<Float> { rotation.toWorld(value)+position }
}
/// Response-stage state. Public orientation and cached collision transform are
/// distinct from current world motion, as in original carElt versus tCar data.
public struct ObjectCollisionBody: Sendable {
    public var index: Int
    public var carFlags: UInt32 = 0
    public var skillLevel = 3
    public var inverseMass: Float = 1/1500, inverseYawInertia: Float = 0.0003
    public var centerOfGravity = SIMD3<Float>.zero
    public var position = SIMD3<Float>.zero, velocity = SIMD3<Float>.zero
    public var yawVelocity: Float = 0
    public var publicOrientation = SIMD3<Float>.zero
    public var transform = CollisionTransform(position:.zero,orientation:.zero)
    /// XY linear velocity and yaw velocity, committed after collision dispatch.
    public var accumulated = SIMD3<Float>.zero
    public private(set) var transformWasRefreshed = false
    public var collision = CollisionState()
    public init(index: Int) { self.index = index }
    public mutating func beginDispatch() { if carFlags & 0xFF == 0 { accumulated = .zero } }
    public mutating func commitVelocity() {
        if carFlags & 0xFF == 0 && collision.flags & 4 != 0 {
            velocity.x = accumulated.x; velocity.y = accumulated.y; yawVelocity = accumulated.z
        }
    }
    fileprivate mutating func refreshTransform() {
        transformWasRefreshed = true
        transform = CollisionTransform(position:SIMD3(position.x,position.y,position.z-centerOfGravity.z),orientation:publicOrientation)
    }
    fileprivate var skillDamage: Float { switch skillLevel { case 0: 0; case 1: 0.5; case 2: 0.8; default: 1 } }
    fileprivate func validate() throws {
        let scalars = [inverseMass,inverseYawInertia,yawVelocity,centerOfGravity.x,centerOfGravity.y,centerOfGravity.z,
            position.x,position.y,position.z,velocity.x,velocity.y,velocity.z,publicOrientation.x,publicOrientation.y,publicOrientation.z,
            transform.position.x,transform.position.y,transform.position.z,transform.orientation.x,transform.orientation.y,transform.orientation.z,
            accumulated.x,accumulated.y,accumulated.z]
        guard (0..<5).contains(skillLevel), inverseMass > 0, inverseYawInertia >= 0, scalars.allSatisfy(\.isFinite) else {
            throw TrackError.invalid("Invalid object collision body")
        }
    }
}
public enum ObjectCollisionResponse {
    /// A wall/wall contact can contribute to dtTest even when its planar normal
    /// makes the original callback return before accessing the presumed car.
    /// If that gate does not return, upstream dereferences a wall as tCar: reject
    /// the invalid track explicitly instead of inventing a physical response.
    public static func validateFixedPair(contact: ObjectCollisionContact) throws {
        let raw = xy(contact.normal), n = raw*(1/sqrt(dot(raw,raw)))
        guard n.x.isNaN || n.y.isNaN else { throw TrackError.invalid("Fixed wall contact would access a non-car as a car in upstream TORCS") }
    }
    public static func pair(first: inout ObjectCollisionBody, second: inout ObjectCollisionBody,
                            contact: ObjectCollisionContact, damageFactor: Float) throws {
        // PIT is included in NO_SIMU, but remains a collision participant.
        guard (first.carFlags | second.carFlags) & 0xFE == 0 else { return }
        guard first.index != second.index, damageFactor.isFinite else { throw TrackError.invalid("Invalid collision pair") }
        try first.validate(); try second.validate()
        let swapped = first.index > second.index
        var a = swapped ? second : first, b = swapped ? first : second
        let p0 = xy(swapped ? contact.secondPoint : contact.firstPoint), p1 = xy(swapped ? contact.firstPoint : contact.secondPoint)
        let raw = xy(contact.normal)*(swapped ? Float(-1) : Float(1))
        let n = raw*(1/sqrt(dot(raw,raw)))
        guard !n.x.isNaN, !n.y.isNaN else { return }
        let r0 = p0-SIMD2(a.centerOfGravity.x,a.centerOfGravity.y), r1 = p1-SIMD2(b.centerOfGravity.x,b.centerOfGravity.y)
        let rg0 = rotate(r0,a.publicOrientation.z), rg1 = rotate(r1,b.publicOrientation.z)
        let v0 = SIMD2(a.velocity.x-a.yawVelocity*rg0.y,a.velocity.y+a.yawVelocity*rg0.x)
        let v1 = SIMD2(b.velocity.x-b.yawVelocity*rg1.y,b.velocity.y+b.yawVelocity*rg1.x)
        let relative = v0-v1
        let pt0 = a.transform.point(SIMD3(r0.x,r0.y,0)), pt1 = b.transform.point(SIMD3(r1.x,r1.y,0))
        let distance = SIMD2(pt1.x-pt0.x,pt1.y-pt0.y)
        let separation = n*min(sqrt(dot(distance,distance)),0.05)
        if !a.collision.blocked && a.carFlags & 0xFF == 0 {
            a.position.x += separation.x; a.position.y += separation.y; a.collision.blocked = true
        }
        if !b.collision.blocked && b.carFlags & 0xFF == 0 {
            b.position.x -= separation.x; b.position.y -= separation.y; b.collision.blocked = true
        }
        if !(dot(relative,n) > 0) {
            let rp0 = dot(rg0,n), rp1 = dot(rg1,n)
            let sign0 = n.x*rg0.y-n.y*rg0.x, sign1 = -n.x*rg1.y+n.y*rg1.x
            let impulse = -2*dot(relative,n)/((a.inverseMass+b.inverseMass)+rp0*rp0*a.inverseYawInertia+rp1*rp1*b.inverseYawInertia)
            try applyPairImpulse(body:&a,n:n,r:r0,rp:rp0,sign:sign0,impulse:impulse,damageFactor:damageFactor)
            try applyPairImpulse(body:&b,n:n,r:r1,rp:rp1,sign:sign1,impulse:-impulse,damageFactor:damageFactor)
        }
        first = swapped ? b : a; second = swapped ? a : b
    }
    public static func wall(body: inout ObjectCollisionBody,contact: ObjectCollisionContact,wallIsFirst: Bool,damageFactor: Float) throws {
        try body.validate()
        guard damageFactor.isFinite else { throw TrackError.invalid("Invalid collision damage factor") }
        let p = xy(wallIsFirst ? contact.secondPoint : contact.firstPoint)
        let raw = xy(contact.normal)*(wallIsFirst ? Float(-1) : Float(1)), distance = sqrt(dot(raw,raw))
        let n = raw*(1/sqrt(dot(raw,raw)))
        guard !n.x.isNaN, !n.y.isNaN else { return }
        let r = p-SIMD2(body.centerOfGravity.x,body.centerOfGravity.y), rg = rotate(r,body.publicOrientation.z)
        let velocity = SIMD2(body.velocity.x-body.yawVelocity*rg.y,body.velocity.y+body.yawVelocity*rg.x)
        let separation = n*min(max(distance,0.02),0.05)
        if !body.collision.blocked {
            body.position.x += separation.x; body.position.y += separation.y; body.collision.blocked = true
        }
        if dot(velocity,n) > 0 { return }
        let rp = dot(rg,n), sign = n.x*rg.y-n.y*rg.x
        let impulse = -2*dot(velocity,n)/(body.inverseMass+rp*rp*body.inverseYawInertia)
        if body.carFlags & 0x100 == 0 {
            let energy: Float = 0.00002*impulse*impulse
            try body.collision.addDamage(0.1*Double(energy)*Double(damageMultiplier(r))*Double(damageFactor)*Double(body.skillDamage))
        }
        let delta = n*(impulse*body.inverseMass)
        let previous = body.collision.flags & 4 != 0 ? body.accumulated : SIMD3(body.velocity.x,body.velocity.y,body.yawVelocity)
        body.accumulated = SIMD3(previous.x+delta.x,previous.y+delta.y,previous.z+impulse*rp*sign*body.inverseYawInertia*0.5)
        body.accumulated.z = min(3,max(-3,body.accumulated.z))
        body.refreshTransform(); body.collision.flags |= 4
    }
    private static func applyPairImpulse(body: inout ObjectCollisionBody,n: SIMD2<Float>,r: SIMD2<Float>,rp: Float,sign: Float,impulse: Float,damageFactor: Float) throws {
        guard body.carFlags & 0xFF == 0 else { return }
        if body.carFlags & 0x100 == 0 {
            try body.collision.addDamage(0.1*Double(abs(impulse))*Double(damageMultiplier(r))*Double(damageFactor)*Double(body.skillDamage))
        }
        let delta = n*(impulse*body.inverseMass)
        let previous = body.collision.flags & 4 != 0 ? body.accumulated : SIMD3(body.velocity.x,body.velocity.y,body.yawVelocity)
        body.accumulated = SIMD3(previous.x+delta.x,previous.y+delta.y,previous.z+impulse*sign*rp*body.inverseYawInertia)
        body.accumulated.z = min(3,max(-3,body.accumulated.z))
        body.refreshTransform(); body.collision.flags |= 4
    }
    private static func xy(_ v: SIMD3<Double>) -> SIMD2<Float> { SIMD2(Float(v.x),Float(v.y)) }
    private static func dot(_ a: SIMD2<Float>,_ b: SIMD2<Float>) -> Float { a.x*b.x+a.y*b.y }
    private static func damageMultiplier(_ r: SIMD2<Float>) -> Float { Double(abs(atan2(r.y,r.x))) < Double.pi/3 ? 1.5 : 1 }
    @inline(never) private static func rotate(_ r: SIMD2<Float>,_ yaw: Float) -> SIMD2<Float> {
        let s = sin(yaw), c = cos(yaw)
        return SIMD2(r.x*c-r.y*s,r.x*s+r.y*c)
    }
}
