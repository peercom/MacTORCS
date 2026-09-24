// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 simuv2/wheel.cpp SimWheelUpdateForce.
// Copyright (C) 2000-2024 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSTrack

/// Precomputed tire constants. XML configuration and thermal state are separate stages.
public struct WheelForceDefinition: Sendable {
    public let radius, mass, tireWidth, friction, magicB, magicC, magicE: Float
    public let loadMinimum, loadMaximum, loadExponent, operatingLoad: Float
    public internal(set) var camber, caster, toe: Float
    public init(radius: Float, mass: Float, tireWidth: Float, friction: Float,
                magicB: Float, magicC: Float, magicE: Float,
                loadMinimum: Float, loadMaximum: Float, loadExponent: Float, operatingLoad: Float,
                camber: Float, caster: Float, toe: Float) {
        precondition([radius, mass, tireWidth, friction, magicB, magicC, magicE, loadMinimum,
                      loadMaximum, loadExponent, operatingLoad, camber, caster, toe].allSatisfy(\.isFinite))
        precondition(radius > 0 && mass > 0 && tireWidth > 0 && operatingLoad > 0 && abs(toe) < 65536)
        self.radius = radius; self.mass = mass; self.tireWidth = tireWidth; self.friction = friction
        self.magicB = magicB; self.magicC = magicC; self.magicE = magicE
        self.loadMinimum = loadMinimum; self.loadMaximum = loadMaximum
        self.loadExponent = loadExponent; self.operatingLoad = operatingLoad
        self.camber = camber; self.caster = caster; self.toe = toe
    }
}

public struct WheelForceResult: Sendable {
    public let force: SIMD3<Float>
    public let suspensionForce, relativeHeight, relativeCamber, relativeYaw: Float
    public let spinTorque, rollingResistance, slipAngle, longitudinalSlip: Float
    public let tireLoad, tireSlip, skid, sideSlipSpeed, longitudinalSlipSpeed: Float
    public let feedbackSpin, feedbackTorque, feedbackBrakeTorque: Float
    public let otherSurface: Int?
    public let otherSurfaceContribution: Float
}

/// Carries original unfiltered tire forces between ticks (RELAXATION2). The ride
/// state remains the single owner of suspension travel, relative velocity and flags.
public struct WheelForceState: Sendable {
    public private(set) var previousLateral, previousLongitudinal: Float
    public init(previousLateral: Float = 0, previousLongitudinal: Float = 0) {
        self.previousLateral = previousLateral; self.previousLongitudinal = previousLongitudinal
    }
    public mutating func update(ride: inout WheelRideState, contact: TrackLocalPosition,
                                carSegment: Int, track: TrackGeometry, definition d: WheelForceDefinition,
                                suspension: SuspensionDefinition, wheelIndex: Int, skillLevel: Int,
                                bodyVelocity: SIMD2<Float>, steer: Float, spin: Float, axleForce: Float,
                                grip: Float = 1, dt: Float = 0.002) throws -> WheelForceResult {
        guard (0..<4).contains(wheelIndex), (0..<5).contains(skillLevel), dt > 0, dt.isFinite,
              track.segments.indices.contains(carSegment), track.segments[carSegment].role == .main,
              track.segments.indices.contains(contact.segment), contact.toLeft.isFinite, contact.toRight.isFinite,
              bodyVelocity.x.isFinite, bodyVelocity.y.isFinite, steer.isFinite, abs(steer + d.toe) < 65536,
              spin.isFinite, axleForce.isFinite, grip.isFinite, ride.displacement.isFinite,
              ride.suspensionVelocity.isFinite, ride.relativeVelocity.isFinite else {
            throw TrackError.invalid("Invalid wheel force input")
        }
        // Original force stage clears all wheel flags, including ride's ONAIR.
        let flags = ride.suspensionFlags
        let suspensionForce = suspension.force(checkedDisplacement: ride.displacement, velocity: ride.suspensionVelocity)
        var relativeVelocity = ride.relativeVelocity
        let verticalForce: Float
        if flags & 2 != 0 && relativeVelocity <= 0 {
            verticalForce = relativeVelocity / dt * d.mass
            relativeVelocity = 0
        } else {
            verticalForce = axleForce + suspensionForce
            relativeVelocity -= dt * verticalForce / d.mass
        }
        let height = -ride.displacement / suspension.bellcrank + d.radius
        let load: Float = verticalForce < 0 || flags & 4 != 0 ? 0 : verticalForce
        let yaw = steer + d.toe
        let (sine, cosine) = wheelSineCosine(yaw)
        let tangentVelocity = bodyVelocity.x * cosine + bodyVelocity.y * sine
        let speedSquared = bodyVelocity.x * bodyVelocity.x + bodyVelocity.y * bodyVelocity.y
        let speed = sqrt(speedSquared)
        var angle: Float = speed < 0.000001 ? 0 : atan2(bodyVelocity.y, bodyVelocity.x) - yaw
        while Double(angle) > Double.pi { angle -= Float(2 * Double.pi) }
        while Double(angle) < -Double.pi { angle += Float(2 * Double.pi) }
        let rollingSpeed = spin * d.radius
        let sx: Float, sy: Float
        if flags & 4 != 0 { sx = 0; sy = 0 }
        else if speed < 0.000001 { sx = rollingSpeed; sy = 0 }
        else {
            // Deliberately preserve the original vt == 0 singularity; no invented epsilon.
            sx = (tangentVelocity - rollingSpeed) / abs(tangentVelocity); sy = sin(angle)
        }
        let slip = sqrt(sx * sx + sy * sy)
        let skidCandidate = slip * load * 0.0002
        let skid: Float = speed < 2 ? 0 : (1 < skidCandidate ? 1 : skidCandidate)
        let casterCamber = sin(d.caster) * steer
        let camber: Float, camberDelta: Float
        if wheelIndex % 2 != 0 { camber = -d.camber - casterCamber; camberDelta = -casterCamber }
        else { camber = d.camber - casterCamber; camberDelta = casterCamber }
        // Ternary matches upstream MIN's NaN behavior, unlike generic min().
        let limitedSlip: Float = slip < 1.5 ? slip : 1.5
        let bx = d.magicB * limitedSlip
        let skillFactor: Float
        switch skillLevel { case 0: skillFactor = 0.4; case 1: skillFactor = 0.35; case 2: skillFactor = 0.3; default: skillFactor = 0 }
        var force = sin(d.magicC * atan(bx * (1 - d.magicE) + d.magicE * atan(bx))) * (1 + limitedSlip * skillFactor)
        let mu = d.friction * (d.loadMinimum + (d.loadMaximum - d.loadMinimum) * exp(d.loadExponent * load / d.operatingLoad))
        let surface = track.segments[contact.segment].surface
        var friction = surface.friction, rollingResistance = surface.rollingResistance
        var neighbour: Int?, contribution: Float = 0
        if contact.toLeft < d.tireWidth / 2 {
            neighbour = track.sideNeighbour(main: carSegment, current: contact.segment, side: .left)
            contribution = 0.5 - contact.toLeft / d.tireWidth
        } else if contact.toRight < d.tireWidth / 2 {
            neighbour = track.sideNeighbour(main: carSegment, current: contact.segment, side: .right)
            contribution = 0.5 - contact.toRight / d.tireWidth
        }
        if let other = neighbour, contribution > 0 {
            let otherSurface = track.segments[other].surface
            friction = friction * (1 - contribution) + otherSurface.friction * contribution
            rollingResistance = rollingResistance * (1 - contribution) + otherSurface.rollingResistance * contribution
        } else { neighbour = nil; contribution = 0 }
        force *= load * mu * friction * (1 + 0.05 * sin((-d.camber + camberDelta) * 18))
        force *= grip
        var longitudinal: Float = 0, lateral: Float = 0
        if slip > 0.000001 { longitudinal -= force * sx / slip; lateral -= force * sy / slip }
        let rawLateral = lateral, rawLongitudinal = longitudinal
        // Macro's 0.01 is double; store raw target, not the filtered result.
        lateral = Float(Double(previousLateral) + Double(50 * (lateral - previousLateral)) * 0.01)
        longitudinal = Float(Double(previousLongitudinal) + Double(50 * (longitudinal - previousLongitudinal)) * 0.01)
        previousLateral = rawLateral; previousLongitudinal = rawLongitudinal
        ride.applyForce(relativeVelocity: relativeVelocity, flags: flags)
        let torque = longitudinal * d.radius
        return WheelForceResult(force: SIMD3(longitudinal * cosine - lateral * sine, longitudinal * sine + lateral * cosine, verticalForce),
            suspensionForce: suspensionForce, relativeHeight: height, relativeCamber: camber, relativeYaw: yaw,
            spinTorque: torque, rollingResistance: load * rollingResistance, slipAngle: angle, longitudinalSlip: sx,
            tireLoad: load, tireSlip: limitedSlip, skid: skid, sideSlipSpeed: sy * speed, longitudinalSlipSpeed: sx * speed,
            feedbackSpin: spin, feedbackTorque: torque, feedbackBrakeTorque: ride.brake.torque,
            otherSurface: neighbour, otherSurfaceContribution: contribution)
    }
}

// Match the paired libm evaluation used by optimized upstream Clang.
@inline(never) private func wheelSineCosine(_ angle: Float) -> (Float, Float) { (sin(angle), cos(angle)) }
