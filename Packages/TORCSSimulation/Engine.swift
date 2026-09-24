// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 simuv2/engine.cpp.
// Copyright (C) 2000-2026 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSConfiguration

public struct EngineCurveSegment: Sendable {
    public let limit, slope, intercept: Float
}
public struct EngineDefinition: Sendable {
    public let limiter, maximumSpeed, idleSpeed, inertia, fuelConsumption, brakeCoefficient: Float
    public let maximumTorque, maximumPower, maximumTorqueSpeed, maximumPowerSpeed, torqueAtMaximumPower: Float
    /// Original last segment has a duplicate endpoint and NaN coefficients. It
    /// remains present; the strict upper-bound lookup never extrapolates from it.
    public let curve: [EngineCurveSegment]
    public init(parameters p: ParameterDocument, fuelFactor: Float = 1) throws {
        func n(_ key: String, _ fallback: Float) -> Float { p.section("Engine")?.number(key, default: fallback) ?? fallback }
        limiter = n("revs limiter",800); maximumSpeed = n("revs maxi",1000); idleSpeed = n("tickover",150)
        inertia = n("inertia",0.2423); fuelConsumption = n("fuel cons factor",0.0622) * fuelFactor
        brakeCoefficient = n("brake coefficient",0.33)
        guard [limiter,maximumSpeed,idleSpeed,inertia,fuelConsumption,brakeCoefficient].allSatisfy(\.isFinite),
              inertia > 0, maximumSpeed != idleSpeed else { throw ParameterError.invalid("Invalid engine configuration") }
        let count = p.section("Engine/data points")?.sections.count ?? 0
        guard (2...10000).contains(count) else { throw ParameterError.invalid("Engine requires 2...10000 torque points") }
        var points: [(Float,Float)] = []
        for i in 1...count {
            guard let point = p.section("Engine/data points/\(i)") else { throw ParameterError.invalid("Engine torque points must be numbered from one") }
            let speed = point.number("rpm",default:maximumSpeed), torque = point.number("Tq",default:0)
            guard speed.isFinite, torque.isFinite, points.last.map({ speed > $0.0 }) ?? true else {
                throw ParameterError.invalid("Engine torque speeds must increase strictly")
            }
            points.append((speed,torque))
        }
        points.append(points[count-1])
        var segments: [EngineCurveSegment] = [], maxTorque: Float = 0, maxPower: Float = 0
        var maxTorqueRPM: Float = 0, maxPowerRPM: Float = 0, torqueAtPower: Float = 0
        for i in 0..<count {
            let (rpm,tq) = points[i+1]
            if rpm >= idleSpeed && tq > maxTorque && rpm < limiter { maxTorque = tq; maxTorqueRPM = rpm }
            if rpm >= idleSpeed && rpm*tq > maxPower && rpm < limiter {
                torqueAtPower = tq; maxPower = rpm*tq; maxPowerRPM = rpm
            }
            let slope = (tq-points[i].1)/(rpm-points[i].0)
            segments.append(EngineCurveSegment(limit:rpm,slope:slope,intercept:points[i].1-slope*points[i].0))
        }
        curve = segments; maximumTorque = maxTorque; maximumPower = maxPower
        maximumTorqueSpeed = maxTorqueRPM; maximumPowerSpeed = maxPowerRPM; torqueAtMaximumPower = torqueAtPower
    }
}
public enum ClutchPhase: Int32, Sendable { case released = 0, applied = 1, releasing = 2 }
public struct ClutchState: Sendable {
    public var phase: ClutchPhase
    public var transfer, timeToRelease: Float
    public init(phase: ClutchPhase = .releasing, transfer: Float = 0, timeToRelease: Float = 0) {
        self.phase = phase; self.transfer = transfer; self.timeToRelease = timeToRelease
    }
}
public struct EngineState: Sendable {
    public private(set) var speed, torque, pressure, exhaustPressure, smoke: Float
    public init(speed: Float, torque: Float = 0, pressure: Float = 0, exhaustPressure: Float = 0, smoke: Float = 0) {
        self.speed = speed; self.torque = torque; self.pressure = pressure; self.exhaustPressure = exhaustPressure; self.smoke = smoke
    }
    public init(definition: EngineDefinition) { self.init(speed:definition.idleSpeed) }
    public mutating func updateTorque(definition d: EngineDefinition, throttle: Float, fuel: inout Float,
                                      carFlags: UInt32 = 0, dt: Float = 0.002) {
        if fuel <= 0 || carFlags & (0x200 | 0x800) != 0 { speed = 0; torque = 0; return }
        if speed > d.limiter { speed = d.limiter; torque = 0 }
        else {
            for point in d.curve where speed < point.limit {
                let maximum = speed*point.slope + point.intercept
                let braking = d.brakeCoefficient*(speed-d.idleSpeed)/(d.maximumSpeed-d.idleSpeed)
                torque = maximum*(throttle*(1+braking)-braking)
                fuel -= abs(torque)*speed*d.fuelConsumption*0.0000001*dt
                if fuel <= 0 { fuel = 0 }
                return
            }
            // No matching segment retains the previous torque, as upstream does.
        }
    }
    /// Returns zero if no axle correction is required. Randomness is an input
    /// dependency, consumed once for exhaust effects when fuel is available.
    public mutating func updateRPM(definition d: EngineDefinition, axleSpeed: Float, overallRatio: Float,
                                  gear: Int, clutch: inout ClutchState, fuel: Float, dt: Float = 0.002,
                                  random: () -> Float) -> Float {
        if fuel <= 0 { speed = 0; clutch.phase = .applied; clutch.transfer = 0; return 0 }
        var freeSpeed = speed
        freeSpeed += torque/d.inertia*dt
        let previousPressure = pressure
        pressure = pressure*0.9 + 0.1*torque
        var deltaPressure = 0.001*abs(pressure-previousPressure)
        deltaPressure = abs(deltaPressure)
        let threshold = random()
        if deltaPressure > threshold { exhaustPressure += threshold }
        exhaustPressure *= 0.9
        smoke += 5*exhaustPressure; smoke *= 0.99
        if clutch.transfer > 0.01 && gear != 0 {
            let transfer = clutch.transfer*clutch.transfer*clutch.transfer*clutch.transfer
            speed = axleSpeed*overallRatio*transfer + freeSpeed*(1-transfer)
            if speed < d.idleSpeed { speed = d.idleSpeed }
            else if speed > d.maximumSpeed { speed = d.maximumSpeed; return d.maximumSpeed/overallRatio }
        } else { speed = freeSpeed }
        return 0
    }
}

extension EngineState {
    // RemoveCar changes rads only; torque and pressure caches remain untouched.
    mutating func setRemovalSpeed(_ speed: Float) { self.speed = speed }
}
