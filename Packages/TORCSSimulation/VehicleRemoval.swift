// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 simuv2/simu.cpp RemoveCar.
// Copyright (C) 2000-2017 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSTrack

/// Removal owns the published state separately from frozen mechanical dynamics.
/// This kernel does not schedule race/pit decisions or active-car physics.
public struct VehicleRemovalState: Sendable {
    public var flags: UInt32 = 0
    public var publicBody = ChassisDynamics(), mechanicalBody = ChassisDynamics(), parking = ChassisDynamics()
    public var publicWorld = ChassisDynamics()
    public var publicSpeed: Float = 0, publishedFuel: Float = 0
    public var publishedDamage: Int32 = 0
    public var publicTransform = CollisionTransform(position:.zero,orientation:.zero)
    public var trackPosition: TrackLocalPosition
    public var cgHeight: Float = 0
    public var damage: Int32 = 0, maximumDamage: Int32 = 0
    public var gear: Int32 = 0, publishedGear: Int32 = 0
    public var engineRPM: Float = 0, publishedRPM: Float = 0
    public var collision: UInt32 = 0, publishedCollision: UInt32 = 0, publishedSimCollision: UInt32 = 0
    public var publishedWheelPose = FourWheels(WheelVisualPose(),WheelVisualPose(),WheelVisualPose(),WheelVisualPose())
    /// Original pub.corner world positions, in the original wheel order: front
    /// right, front left, rear right, rear left. A robot reads these.
    public var publishedCorners = FourWheels(SIMD3<Float>.zero,SIMD3<Float>.zero,SIMD3<Float>.zero,SIMD3<Float>.zero)
    public var publishedSkid = SIMD4<Float>.zero, publishedSpin = SIMD4<Float>.zero, publishedBrakeTemperature = SIMD4<Float>.zero
    public var publishedTirePressure = SIMD4<Float>.zero, publishedTireTemperature = SIMD4<Float>.zero
    public var publishedTireGraining = SIMD4<Float>.zero, publishedTireWear = SIMD4<Float>.zero
    public var collisionRegistered = true
    public var pitOccupant: Int32?
    public init(trackPosition: TrackLocalPosition) { self.trackPosition = trackPosition }
    /// Executes one original RemoveCar invocation, not a whole simulation tick.
    public mutating func remove(track: TrackGeometry,dt: Float = 0.002) throws {
        guard dt.isFinite,dt>0,track.segments.indices.contains(trackPosition.segment) else { throw TrackError.invalid("Invalid removal timing or track position") }
        if flags & 4 != 0 {
            publicBody.position.z += parking.velocity.z*dt
            publicBody.orientation.z += parking.angularVelocity.z*dt
            publicBody.orientation.x += parking.angularVelocity.x*dt
            publicBody.orientation.y += parking.angularVelocity.y*dt
            refreshTransform()
            if publicBody.position.z>parking.position.z+3 { flags &= ~4; flags |= 8 }
            return
        }
        if flags & 8 != 0 {
            let dx = parking.position.x-publicBody.position.x, dy = parking.position.y-publicBody.position.y
            let travel = sqrt(dx*dx+dy*dy)/Float(0.5)
            parking.velocity.x = dx/travel; parking.velocity.y = dy/travel
            publicBody.position.x += parking.velocity.x*dt; publicBody.position.y += parking.velocity.y*dt
            refreshTransform()
            if abs(parking.position.x-publicBody.position.x)<0.5 && abs(parking.position.y-publicBody.position.y)<0.5 { flags &= ~8; flags |= 16 }
            return
        }
        if flags & 16 != 0 {
            publicBody.position.z -= parking.velocity.z*dt; refreshTransform()
            if publicBody.position.z<parking.position.z { flags &= ~16; flags |= 0x102 }
            return
        }
        if flags & 0xFE != 0 { return }
        if flags & 1 != 0 {
            if maximumDamage != 0 && damage>maximumDamage {
                guard pitOccupant != nil else { throw TrackError.invalid("Broken pit car has no assigned pit") }
                flags &= ~1; pitOccupant = -1
            } else { return }
        }
        if maximumDamage != 0 && damage>maximumDamage { flags |= 0x200 } else { flags |= 0x400 }
        gear = 0; publishedGear = 0; engineRPM = 0; publishedRPM = 0
        if flags & 2 == 0 && abs(publicBody.velocity.x)>1 { return }
        flags |= 4; collisionRegistered = false
        collision = 0; publishedCollision = 0; publishedSimCollision = 0
        publishedSkid = .zero; publishedSpin = .zero; publishedBrakeTemperature = .zero
        publicBody = mechanicalBody; publicBody.velocity.x = 0
        var local = trackPosition
        let left = local.toRight>track.segments[local.segment].width/2
        while let next = left ? track.segments[local.segment].left : track.segments[local.segment].right { local.segment = next }
        if left { local.toLeft = -3 } else { local.toRight = -3 }
        local.mode = .segment
        let xy = track.localToGlobal(local,origin:left ? .left : .right)
        parking.position = SIMD3(xy.x,xy.y,track.height(local)+cgHeight)
        parking.orientation = SIMD3(0,0,track.tangent(local)); parking.velocity.z = 0.5
        let travel = (parking.position.z+3-publicBody.position.z)/parking.velocity.z
        func normalized(_ a: Float) -> Float {
            var a = a
            while Double(a)>Double.pi { a -= Float(2*Double.pi) }
            while Double(a)<(-Double.pi) { a += Float(2*Double.pi) }
            return a
        }
        parking.angularVelocity.z = normalized(parking.orientation.z-publicBody.orientation.z)/travel
        parking.angularVelocity.x = normalized(parking.orientation.x-publicBody.orientation.x)/travel
        parking.angularVelocity.y = normalized(parking.orientation.y-publicBody.orientation.y)/travel
        // The original does not refresh posMat on this transition.
    }
    private mutating func refreshTransform() {
        let p = publicBody.position
        publicTransform = CollisionTransform(position:SIMD3(p.x,p.y,p.z-cgHeight),orientation:publicBody.orientation)
    }
}
