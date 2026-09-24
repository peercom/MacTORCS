// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 simuv2/aero.cpp.
// Copyright (C) 2000-2026 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSConfiguration

public struct WingDefinition: Sendable {
    public internal(set) var angle, dragCoefficient, liftCoefficient: Float
    public let position: SIMD3<Float>
    init(parameters p: ParameterDocument, section: String, centerOfGravityX: Float) throws {
        func number(_ key: String) -> Float { p.section(section)?.number(key,default:0) ?? 0 }
        angle = number("angle")
        position = SIMD3(number("xpos")-centerOfGravityX,0,number("zpos"))
        dragCoefficient = -1.23*number("area"); liftCoefficient = 4*dragCoefficient
        guard angle.isFinite, position.x.isFinite, position.z.isFinite, dragCoefficient.isFinite, liftCoefficient.isFinite else {
            throw ParameterError.invalid("Invalid wing configuration: \(section)")
        }
    }
    func forces(bodyVelocity: SIMD3<Float>, airSpeedSquared: Float, damage: Int32) -> SIMD3<Float> {
        var angleOfAttack = atan2(bodyVelocity.z,bodyVelocity.x)
        angleOfAttack += angle
        let sine = sin(angleOfAttack)
        if bodyVelocity.x > 0 {
            return SIMD3(dragCoefficient*airSpeedSquared*(1+Float(damage)/10000)*sine,0,liftCoefficient*airSpeedSquared*sine)
        }
        return .zero
    }
}
/// Traffic is supplied in simulation car-index order. Read it at the original
/// car-update point; a once-per-tick copy could change multi-car update ordering.
public struct AeroTrafficState: Sendable {
    public var position: SIMD2<Float>
    public var yaw, longitudinalSpeed, dragCoefficient: Float
    public init(position: SIMD2<Float>, yaw: Float, longitudinalSpeed: Float, dragCoefficient: Float) {
        self.position = position; self.yaw = yaw; self.longitudinalSpeed = longitudinalSpeed; self.dragCoefficient = dragCoefficient
    }
}
public struct AerodynamicsResult: Sendable {
    public let airSpeedSquared, drag: Float
    public let bodyLift: SIMD2<Float>
    public let frontWing, rearWing: SIMD3<Float>
    public init(airSpeedSquared: Float, drag: Float, bodyLift: SIMD2<Float>, frontWing: SIMD3<Float>, rearWing: SIMD3<Float>) {
        self.airSpeedSquared = airSpeedSquared; self.drag = drag; self.bodyLift = bodyLift
        self.frontWing = frontWing; self.rearWing = rearWing
    }
}
public struct AerodynamicsDefinition: Sendable {
    public internal(set) var bodyDragCoefficient, draftingCoefficient: Float
    public let bodyLiftCoefficients: SIMD2<Float>
    public internal(set) var frontWing, rearWing: WingDefinition
    public init(parameters p: ParameterDocument, centerOfGravityX: Float) throws {
        let aero = p.section("Aerodynamics")
        let cx = aero?.number("Cx",default:0.4) ?? 0.4, area = aero?.number("front area",default:2.5) ?? 2.5
        bodyDragCoefficient = 0.645*cx*area
        bodyLiftCoefficients = SIMD2(aero?.number("front Clift",default:0) ?? 0,aero?.number("rear Clift",default:0) ?? 0)
        frontWing = try WingDefinition(parameters:p,section:"Front Wing",centerOfGravityX:centerOfGravityX)
        rearWing = try WingDefinition(parameters:p,section:"Rear Wing",centerOfGravityX:centerOfGravityX)
        // Only the rear wing contributes to the coefficient used by drafting.
        draftingCoefficient = bodyDragCoefficient-rearWing.dragCoefficient*sin(rearWing.angle)
        guard bodyDragCoefficient.isFinite, draftingCoefficient.isFinite,
              bodyLiftCoefficients.x.isFinite, bodyLiftCoefficients.y.isFinite else {
            throw ParameterError.invalid("Invalid aerodynamics configuration")
        }
    }
    /// Aero precedes wheel ride updates upstream, so rideHeights are from the
    /// preceding tick. Speed is the caller's original 3D speed magnitude.
    public func forces(carIndex: Int, position: SIMD2<Float>, yaw: Float, bodyVelocity: SIMD3<Float>,
                       worldVelocity: SIMD2<Float>, speed: Float, damage: Int32, rideHeights: SIMD4<Float>,
                       traffic: [AeroTrafficState]) -> AerodynamicsResult {
        precondition(yaw.isFinite && abs(yaw) < 65536)
        let airSpeed = bodyVelocity.x, speedAngle = atan2(worldVelocity.y,worldVelocity.x)
        var dragFactor: Float = 1
        if airSpeed > 10 {
            for (index,other) in traffic.enumerated() where index != carIndex {
                precondition(other.yaw.isFinite && abs(other.yaw) < 65536)
                let dx = position.x-other.position.x, dy = position.y-other.position.y
                let relativeAngle = aeroNormalize(speedAngle-atan2(dy,dx))
                let yawDifference = aeroNormalize(yaw-other.yaw)
                if other.longitudinalSpeed > 10 && abs(yawDifference) < 0.1396 {
                    if abs(relativeAngle) > 2.9671 {
                        let factor: Float = 1-exp(-2*sqrt(dx*dx+dy*dy)/(other.dragCoefficient*other.longitudinalSpeed))
                        if factor < dragFactor { dragFactor = factor }
                    } else if abs(relativeAngle) < 0.1396 {
                        let factor: Float = 1-0.15*exp(-8*sqrt(dx*dx+dy*dy)/(draftingCoefficient*airSpeed))
                        if factor < dragFactor { dragFactor = factor }
                    }
                }
            }
        }
        let v2 = airSpeed*airSpeed
        var cosine: Float = 1
        if speed > 1 { cosine = bodyVelocity.x/speed }
        if cosine < 0 { cosine = 0 }
        let sign: Float = bodyVelocity.x < 0 ? -1 : 1
        let drag = -sign*bodyDragCoefficient*v2*(1+Float(damage)/10000)*dragFactor*dragFactor
        var height = 1.5*(rideHeights.x+rideHeights.y+rideHeights.z+rideHeights.w)
        height = height*height; height = height*height; height = 2*exp(-3*height)
        let lift = SIMD2(-bodyLiftCoefficients.x*v2*height*cosine,-bodyLiftCoefficients.y*v2*height*cosine)
        return AerodynamicsResult(airSpeedSquared:v2,drag:drag,bodyLift:lift,
            frontWing:frontWing.forces(bodyVelocity:bodyVelocity,airSpeedSquared:v2,damage:damage),
            rearWing:rearWing.forces(bodyVelocity:bodyVelocity,airSpeedSquared:v2,damage:damage))
    }
}
private func aeroNormalize(_ angle: Float) -> Float {
    var value = angle
    while Double(value) > Double.pi { value -= Float(2*Double.pi) }
    while Double(value) < -Double.pi { value += Float(2*Double.pi) }
    return value
}
