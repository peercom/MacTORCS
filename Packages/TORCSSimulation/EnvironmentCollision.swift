// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 simuv2/collide.cpp SimCarCollideZ/SimCarCollideXYScene.
// Copyright (C) 2000-2017 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSTrack

public struct CollisionState: Sendable {
    public var flags: UInt32 = 0
    public var blocked = false
    public var damage: Int32 = 0
    public var normal = SIMD3<Float>.zero, position = SIMD3<Float>.zero
    public init() {}
    /// Upstream resets these two fields each simulation tick; impact metadata persists.
    public mutating func beginTick() { flags = 0; blocked = false }
    mutating func addDamage(_ value: Float) throws { try addDamage(Double(value)) }
    mutating func addDamage(_ value: Double) throws {
        guard value.isFinite, value >= Double(Int32.min), value <= Double(Int32.max) else {
            throw TrackError.invalid("Collision damage exceeds supported integer range")
        }
        let (sum,overflow) = damage.addingReportingOverflow(Int32(value))
        guard !overflow else { throw TrackError.invalid("Accumulated collision damage overflow") }
        damage = sum
    }
}
extension ChassisState {
    /// Ground response precedes barriers. Only global pose/velocity changes;
    /// body records, corner samples and track location remain as upstream left them.
    public mutating func collideWithEnvironment(definition d: ChassisDefinition, track: TrackGeometry,
        collision: inout CollisionState, carFlags: UInt32, skillLevel: Int, damageFactor: Float,
        ground: Bool = true, barriers: Bool = true) throws {
        guard carFlags & 0xFF == 0 else { return }
        precondition((0..<5).contains(skillLevel) && damageFactor.isFinite)
        let skill: Float
        switch skillLevel { case 0: skill = 0; case 1: skill = 0.5; case 2: skill = 0.8; default: skill = 1 }
        if ground {
            let rotation = VehicleRotation(roll:body.orientation.x,pitch:body.orientation.y,yaw:body.orientation.z)
            let center = SIMD2(world.position.x,world.position.y), main = trackPosition.segment
            let normalPosition = try track.globalToLocal(center,startingAt:main,mode:.segment)
            let normal = track.surfaceNormal(normalPosition), localNormal = rotation.toBody(normal)
            var depthSum: Float = 0
            for i in 0..<4 {
                let corner = corners[i].position
                let local = try track.globalToLocal(SIMD2(corner.x,corner.y),startingAt:main,mode:.segment)
                let depth = corner.z-track.height(local)
                depthSum += depth
                if depth < 0 {
                    world.orientation.y += depth/d.corners[i].x*abs(localNormal.x)
                    world.orientation.x -= depth/d.corners[i].y*abs(localNormal.y)
                    collision.flags |= 0x01 | 0x08
                }
            }
            if depthSum > 0 { depthSum = 0 }
            let roadHeight = try track.height(at:center,startingAt:main)
            let depth = world.position.z-(d.runningGear.mass.centerOfGravity.z-depthSum)/normal.z-roadHeight
            if depth < 0 {
                let dot = world.velocity.x*normal.x+world.velocity.y*normal.y+world.velocity.z*normal.z
                if dot < 0 {
                    if dot < -5 { collision.flags |= 0x10 }
                    collision.flags |= 0x01 | 0x08
                    world.velocity -= normal*dot
                    if carFlags & 0x100 == 0 {
                        try collision.addDamage(track.segments[normalPosition.segment].surface.damage*abs(dot)*damageFactor*skill)
                    }
                }
            }
        }
        if barriers {
            for i in 0..<4 {
                let corner = corners[i]
                let local = try track.globalToLocal(SIMD2(corner.position.x,corner.position.y),startingAt:trackPosition.segment,mode:.track)
                let segment = track.segments[local.segment]
                let barrier: TrackBarrier?, toSide: Float
                if local.toRight < 0 { barrier = segment.rightBarrier; toSide = local.toRight }
                else if local.toLeft < 0 { barrier = segment.leftBarrier; toSide = local.toLeft }
                else { continue }
                guard let barrier else { throw TrackError.invalid("Missing collision barrier") }
                let nx = barrier.normal.x, ny = barrier.normal.y
                world.position.x -= nx*toSide; world.position.y -= ny*toSide
                let cx = corner.position.x-world.position.x, cy = corner.position.y-world.position.y
                collision.blocked = true; collision.flags |= 0x01
                let initialDot = nx*corner.worldVelocity.x+ny*corner.worldVelocity.y
                let speed = max(Float(1),sqrt(world.velocity.x*world.velocity.x+world.velocity.y*world.velocity.y))
                let normalSpeed = world.velocity.x*nx+world.velocity.y*ny
                let cosine = normalSpeed/speed, damageDot = normalSpeed*cosine
                var dot = initialDot*barrier.surface.friction
                world.velocity.x -= nx*dot; world.velocity.y -= ny*dot
                let distanceDot = nx*cx+ny*cy
                world.angularVelocity.z -= distanceDot*dot/10
                if abs(world.angularVelocity.z) > 6 { world.angularVelocity.z = world.angularVelocity.z < 0 ? -6 : 6 }
                dot = initialDot
                let damage: Float
                if dot < 0 && carFlags & 0x100 == 0 {
                    damage = barrier.surface.damage*(0.5*damageDot*damageDot+0.005*abs(1-cosine)*speed)*damageFactor*skill
                    try collision.addDamage(damage)
                } else { damage = 0 }
                dot *= barrier.surface.rebound
                if dot < 0 {
                    collision.flags |= 0x02
                    collision.normal.x = nx*damage; collision.normal.y = ny*damage
                    collision.position.x = corner.position.x; collision.position.y = corner.position.y
                    world.velocity.x -= nx*dot; world.velocity.y -= ny*dot
                }
            }
        }
    }
}
