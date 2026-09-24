// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 simuv2/simu.cpp ctrlCheck and steer/brake setup.
// Copyright (C) 2000-2026 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSConfiguration

public struct DriverCommand: Sendable {
    public var throttle, brake, steering, clutch: Float
    public var gear: Int
    public var brakeRepartitionClicks: Int32
    public var lightCommand: UInt32
    public init(throttle: Float = 0, brake: Float = 0, steering: Float = 0, clutch: Float = 0, gear: Int = 0, brakeRepartitionClicks: Int32 = 0,lightCommand: UInt32 = 0) {
        self.throttle = throttle; self.brake = brake; self.steering = steering; self.clutch = clutch
        self.gear = gear; self.brakeRepartitionClicks = brakeRepartitionClicks; self.lightCommand = lightCommand
    }
    public func checked(carFlags: UInt32, longitudinalSpeed: Float, toRight: Float, trackWidth: Float) -> DriverCommand {
        var c = self
        if !c.throttle.isFinite { c.throttle = 0 }; if !c.brake.isFinite { c.brake = 0 }
        if !c.clutch.isFinite { c.clutch = 0 }; if !c.steering.isFinite { c.steering = 0 }
        if carFlags & (0x200 | 0x800) != 0 {
            c.throttle = 0; c.brake = 0.1; c.gear = 0
            c.steering = Double(toRight) > Double(trackWidth)/2 ? 0.1 : -0.1
        } else if carFlags & 0x100 != 0 {
            c.throttle = Float(min(Double(c.throttle),0.20))
            if longitudinalSpeed > 30 { c.brake = Float(max(Double(c.brake),0.05)) }
        }
        c.throttle = min(1,max(0,c.throttle)); c.brake = min(1,max(0,c.brake)); c.clutch = min(1,max(0,c.clutch))
        c.steering = min(1,max(-1,c.steering))
        return c
    }
    public var clutchTransfer: Float { Float(1.0-Double(clutch)) }
}
public struct DriverControlDefinition: Sendable {
    public internal(set) var steeringLock, maximumSteeringSpeed: Float
    public internal(set) var brakes: BrakeSystem
    public init(parameters p: ParameterDocument) throws {
        steeringLock = p.section("Steer")?.number("steer lock",default:0.43) ?? 0.43
        maximumSteeringSpeed = p.section("Steer")?.number("max steer speed",default:1) ?? 1
        let section = p.section("Brake System")
        var b = BrakeSystem()
        b.repartition = section?.number("front-rear brake repartition",default:0.5) ?? 0.5
        b.coefficient = section?.number("max pressure",default:1000000) ?? 1000000
        b.clickValue = section?.number("brake repartition offset per click",default:0.0025) ?? 0.0025
        let clicks = section?.number("brake repartition max clicks",default:20) ?? 20
        guard steeringLock.isFinite, maximumSteeringSpeed.isFinite, b.repartition.isFinite, b.coefficient.isFinite,
              b.clickValue.isFinite, clicks.isFinite, clicks >= 0, Double(clicks) <= Double(Int32.max) else {
            throw ParameterError.invalid("Invalid driver control configuration")
        }
        b.maximumClicks = Int32(clicks); brakes = b
    }
}
public enum VehicleUpdateMode: UInt32, Sendable { case settling = 0, running = 1, prestart = 16 }
