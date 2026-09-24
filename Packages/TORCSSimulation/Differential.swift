// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 simuv2/differential.cpp.
// Copyright (C) 2000-2026 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSConfiguration

public enum DifferentialType: Int32, Sendable { case none = 0, spool = 1, free = 2, limitedSlip = 3, viscous = 4 }
public struct DriveAxis: Sendable {
    public var spin, torque, brakeTorque, inertia: Float
    public init(spin: Float = 0, torque: Float = 0, brakeTorque: Float = 0, inertia: Float) {
        self.spin = spin; self.torque = torque; self.brakeTorque = brakeTorque; self.inertia = inertia
    }
}
public struct DifferentialDefinition: Sendable {
    public let type: DifferentialType
    public internal(set) var inertia, efficiency, ratio, minimumTorqueBias, torqueBiasRange, maximumSlipBias: Float
    public internal(set) var lockingTorque, brakingLockingTorque, viscosity, feedbackInertia: Float
    public init(parameters p: ParameterDocument, section: String, inputInertias: SIMD2<Float>) throws {
        func n(_ key: String,_ fallback: Float) -> Float { p.section(section)?.number(key,default:fallback) ?? fallback }
        inertia = n("inertia",0.1); efficiency = n("efficiency",1); ratio = n("ratio",1)
        minimumTorqueBias = n("min torque bias",0.05)
        torqueBiasRange = max(0,n("max torque bias",0.8)-minimumTorqueBias)
        maximumSlipBias = n("max slip bias",0.03)
        lockingTorque = n("locking input torque",3000); brakingLockingTorque = n("locking brake input torque",lockingTorque*0.33)
        viscosity = n("viscosity factor",1)
        switch p.section(section)?.string("type",default:"NONE") ?? "NONE" {
        case "SPOOL": type = .spool
        case "FREE": type = .free
        case "LIMITED SLIP": type = .limitedSlip
        case "VISCOUS COUPLER": type = .viscous
        default: type = .none
        }
        feedbackInertia = inertia*ratio*ratio + (inputInertias.x+inputInertias.y)/efficiency
        guard [inertia,efficiency,ratio,minimumTorqueBias,torqueBiasRange,maximumSlipBias,lockingTorque,
               brakingLockingTorque,viscosity,feedbackInertia].allSatisfy(\.isFinite), efficiency > 0,
              inputInertias.x > 0, inputInertias.y > 0,
              type != .limitedSlip || (lockingTorque > 0 && brakingLockingTorque > 0) else {
            throw ParameterError.invalid("Invalid differential configuration: \(section)")
        }
    }
    /// Engine coupling is called once on the primary differential, and never on
    /// secondary AWD axle differentials. It returns zero when no correction applies.
    public func update(driveTorque: Float, first: DriveAxis, second: DriveAxis, outputInertias: SIMD2<Float>,
                       dt: Float = 0.002, primary: Bool = false, engineReaction: (Float) -> Float = { _ in 0 }) -> (first: DriveAxis, second: DriveAxis) {
        precondition(outputInertias.x > 0 && outputInertias.y > 0 && dt > 0)
        func spool() -> (DriveAxis,DriveAxis) {
            let inertia = outputInertias.x+outputInertias.y
            let inputTorque = first.torque+second.torque, brakeTorque = first.brakeTorque+second.brakeTorque
            let acceleration = dt*(driveTorque-inputTorque)/inertia
            var spin = first.spin+acceleration
            spin = differentialBrake(spin:spin,torque:brakeTorque,inertia:inertia,dt:dt)
            if primary { let reaction = engineReaction(spin); if reaction != 0 { spin = reaction } }
            return (DriveAxis(spin:spin,torque:(spin-first.spin)/dt*outputInertias.x,inertia:outputInertias.x),
                    DriveAxis(spin:spin,torque:(spin-second.spin)/dt*outputInertias.y,inertia:outputInertias.y))
        }
        if type == .spool { return spool() }
        var speed0 = first.spin, speed1 = second.spin
        let commonSpeed = abs(speed0)+abs(speed1)
        let torque0: Float, torque1: Float
        if commonSpeed != 0 {
            let speedRatio = abs(speed0-speed1)/commonSpeed
            switch type {
            case .free:
                let spider = second.torque-first.torque
                torque0 = (driveTorque+spider)*0.5; torque1 = (driveTorque-spider)*0.5
            case .limitedSlip:
                if driveTorque > lockingTorque || driveTorque < -brakingLockingTorque { return spool() }
                let lock: Float = driveTorque >= 0 ? lockingTorque : -brakingLockingTorque
                let sign: Float = driveTorque >= 0 ? 1 : -1
                let maximumRatio = maximumSlipBias-driveTorque*maximumSlipBias/lock
                var bias: Float = 0
                if speedRatio > maximumRatio {
                    let delta = (speedRatio-maximumRatio)*commonSpeed/2
                    if speed0 > speed1 { speed0 -= delta; speed1 += delta; bias = -(speedRatio-maximumRatio) }
                    else { speed0 += delta; speed1 -= delta; bias = speedRatio-maximumRatio }
                }
                let spider = second.torque-first.torque
                torque0 = (driveTorque*(1+bias*sign)+spider)*0.5
                torque1 = (driveTorque*(1-bias*sign)-spider)*0.5
            case .viscous:
                if speed0 >= speed1 { torque0 = driveTorque*minimumTorqueBias; torque1 = driveTorque*(1-minimumTorqueBias) }
                else {
                    let delta = minimumTorqueBias+(1-exp(-abs(viscosity*(speed0-speed1))))*torqueBiasRange
                    torque0 = driveTorque*delta; torque1 = driveTorque*(1-delta)
                }
            default: torque0 = 0; torque1 = 0
            }
        } else { torque0 = driveTorque/2; torque1 = driveTorque/2 }
        speed0 += dt*(torque0-first.torque)/outputInertias.x
        speed1 += dt*(torque1-second.torque)/outputInertias.y
        speed0 = differentialBrake(spin:speed0,torque:first.brakeTorque,inertia:outputInertias.x,dt:dt)
        speed1 = differentialBrake(spin:speed1,torque:second.brakeTorque,inertia:outputInertias.y,dt:dt)
        if primary {
            let mean = (speed0+speed1)/2
            var reaction = engineReaction(mean)
            if mean != 0 {
                reaction /= mean
                if reaction != 0 { speed1 *= reaction; speed0 *= reaction }
            }
        }
        return (DriveAxis(spin:speed0,torque:(speed0-first.spin)/dt*outputInertias.x,inertia:outputInertias.x),
                DriveAxis(spin:speed1,torque:(speed1-second.spin)/dt*outputInertias.y,inertia:outputInertias.y))
    }
}
private func differentialBrake(spin: Float, torque: Float, inertia: Float, dt: Float) -> Float {
    let brake = -(spin < 0 ? Float(-1) : Float(1))*torque
    var delta = dt*brake/inertia
    if delta*spin < 0 && abs(delta)>abs(spin) { delta = -spin }
    if spin == 0 && delta < 0 { delta = 0 }
    return spin+delta
}
