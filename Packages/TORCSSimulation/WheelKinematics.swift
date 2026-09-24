// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 SimCarUpdateWheelPos (car.cpp).
// Copyright (C) 2000-2017 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
// Rotation expressions retain PLIB sgMakeCoordMat4/sgXformVec3 ordering;
// PLIB copyright (C) 1998, 2002 Steve Baker; upstream LGPL-2.0-or-later.
// The PLIB-derived portions of this Swift file are converted to GPL version 2
// under LGPL version 2 section 3, effective 2026-09-22. See LICENSE and
// Upstream/Licenses/PLIB-LGPL-2.0.txt. This entire file is GPL-2.0-only.
import Foundation

/// The original PLIB heading/pitch/roll transform, including radian → degree →
/// radian rounding. General SIMD/quaternion replacement changes contact heights.
public struct VehicleRotation: Sendable {
    private let column0, column1, column2: SIMD3<Float>
    public init(roll: Float, pitch: Float, yaw: Float) {
        func degrees(_ angle: Float) -> Float { Float(Double(angle) * (180 / Double.pi)) }
        let h = degrees(yaw), p = degrees(roll), r = degrees(pitch)
        let (sh, ch) = h == 0 ? (Float(0), Float(1)) : wheelPoseSineCosine(h)
        let (sp, cp) = p == 0 ? (Float(0), Float(1)) : wheelPoseSineCosine(p)
        let sr: Float, cr: Float, srsp: Float, crsp: Float, srcp: Float
        if r == 0 { sr = 0; cr = 1; srsp = 0; srcp = 0; crsp = sp }
        else {
            (sr, cr) = wheelPoseSineCosine(r)
            srsp = sr * sp; crsp = cr * sp; srcp = sr * cp
        }
        column0 = SIMD3(ch * cr - sh * srsp, cr * sh + srsp * ch, -srcp)
        column1 = SIMD3(-sh * cp, ch * cp, sp)
        column2 = SIMD3(sr * ch + sh * crsp, sr * sh - crsp * ch, cr * cp)
    }
    public func toWorld(_ value: SIMD3<Float>) -> SIMD3<Float> {
        value.x * column0 + value.y * column1 + value.z * column2
    }
    public func toBody(_ value: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(value.x*column0.x + value.y*column0.y + value.z*column0.z,
              value.x*column1.x + value.y*column1.y + value.z*column1.z,
              value.x*column2.x + value.y*column2.y + value.z*column2.z)
    }
}
public struct WheelKinematics: Sendable {
    private let rotation: VehicleRotation
    private let origin: SIMD3<Float>
    private let bodyVelocity: SIMD2<Float>
    private let yawVelocity: Float
    public init(worldPosition: SIMD3<Float>, roll: Float, pitch: Float, yaw: Float,
                bodyVelocity: SIMD2<Float>, yawVelocity: Float) {
        origin = worldPosition; self.bodyVelocity = bodyVelocity; self.yawVelocity = yawVelocity
        rotation = VehicleRotation(roll:roll,pitch:pitch,yaw:yaw)
    }
    public func wheel(at attachment: SIMD3<Float>) -> (position: SIMD3<Float>, bodyVelocity: SIMD2<Float>) {
        let transformed = rotation.toWorld(attachment)
        return (origin + transformed,
            SIMD2(bodyVelocity.x - yawVelocity * attachment.y, bodyVelocity.y + yawVelocity * attachment.x))
    }
}
@inline(never) private func wheelPoseSineCosine(_ degrees: Float) -> (Float, Float) {
    let angle = degrees * (Float.pi / 180)
    return (sin(angle), cos(angle))
}
