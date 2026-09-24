// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 simuv2/wheel.cpp, axle.cpp, susp.cpp, brake.cpp,
// and SimCarConfig's wheel-origin adjustment in car.cpp.
// Copyright (C) 2000-2026 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSConfiguration

public struct BrakeDefinition: Sendable {
    public let coefficient, radius, inertia: Float
}
public struct AxleDefinition: Sendable {
    public internal(set) var position, inertia, rollCenter, antiRollSpring: Float
    public internal(set) var thirdSuspension: SuspensionDefinition
}
public struct WheelDefinition: Sendable {
    /// Static attachment relative to the center of gravity, after SimCarConfig.
    public let staticPosition: SIMD3<Float>
    /// Initial rendering position retains the pre-CG origin and pre-suspension height.
    public let initialRelativePosition: SIMD3<Float>
    public let staticLoad, rollCenter, inertia, feedbackInertia, tireSpringRate: Float
    public let rimRadius, tireHeight, treadThickness: Float
    public internal(set) var suspension: SuspensionDefinition
    public let brake: BrakeDefinition
    public internal(set) var force: WheelForceDefinition
    public let thermal: TireThermalDefinition
}

/// Fresh-car configuration in original axle → wheel → CG-adjustment order.
/// Pit setup changes are a separate operation; this does not reconfigure live state.
public struct RunningGearConfiguration: Sendable {
    public let mass: VehicleMassProperties
    /// Original order: front, rear; front right, front left, rear right, rear left.
    public internal(set) var axles: [AxleDefinition]
    public internal(set) var wheels: [WheelDefinition]
    public init(parameters p: ParameterDocument) throws {
        mass = try VehicleMassProperties(parameters: p)
        func number(_ section: String, _ name: String, _ fallback: Float) -> Float {
            p.section(section)?.number(name, default: fallback) ?? fallback
        }
        axles = try ["Front", "Rear"].map { end in
            let section = end + " Axle"
            let x = number(section, "xpos", 0), inertia = number(section, "inertia", 0.15)
            let rollCenter = number(section, "roll center height", 0.15)
            let spring = number(end + " Anti-Roll Bar", "spring", 0)
            guard [x, inertia, rollCenter, spring].allSatisfy(\.isFinite), inertia >= 0 else {
                throw ParameterError.invalid("Invalid \(section) configuration")
            }
            return AxleDefinition(position: x, inertia: inertia, rollCenter: rollCenter, antiRollSpring: spring,
                thirdSuspension: try .configured(parameters: p, section: section, preload: 0,
                    rest: number(section, "suspension course", 0)))
        }
        var definitions: [WheelDefinition] = []
        for (index, name) in ["Front Right", "Front Left", "Rear Right", "Rear Left"].enumerated() {
            let section = name + " Wheel", axle = axles[index / 2], weight = mass.staticWheelLoads[index]
            func n(_ key: String, _ fallback: Float) -> Float { number(section, key, fallback) }
            let pressure = n("pressure", 275600), rimDiameter = n("rim diameter", 0.33)
            let tireWidth = n("tire width", 0.145), ratio = n("tire height-width ratio", 0.75)
            let friction = n("mu", 1), inertia = n("inertia", 1.5), y = n("ypos", 0)
            let rest = n("ride height", 0.2), toe = n("toe", 0), camber = n("camber", 0), caster = n("caster", 0)
            let ca = n("stiffness", 30), rFactor = max(0.1, min(1, n("dynamic friction", 0.8)))
            let eFactor = min(1, n("elasticity factor", 0.7))
            let loadMin = min(0.8, n("load factor min", 0.8)), loadMax = max(1.6, n("load factor max", 1.6))
            let operatingLoad = n("operating load", weight * 1.2), wheelMass = n("mass", 20)
            let radius = rimDiameter / 2 + tireWidth * ratio
            let patchLength = weight / (tireWidth * pressure)
            let tireSpring = weight / (radius * (1 - cos(asin(patchLength / (2 * radius)))))
            // asin and its multiplication are Float; division by upstream PI is Double.
            let magicC = Float(2 - Double(asin(rFactor) * 2) / Double.pi)
            let magicB = ca / magicC, loadExponent = log((1 - loadMin) / (loadMax - loadMin))
            let thickness = n("tread thickness", 0.005), rimMass = n("rim mass", 7)
            let hysteresis = n("hysteresis", 1), wear = n("wear", 1), idealTemperature = n("ideal temperature", Float(95) + Float(273.15))
            let treadMass = Float(Double(2 * radius - thickness) * Double.pi * Double(tireWidth) * Double(thickness) * 930)
            var baseMass = wheelMass - treadMass - rimMass
            if baseMass < 0 { baseMass = 3 } // Original fallback, not a clamp to zero.
            let innerRadius = rimDiameter / 2
            let sideArea = Float(Double.pi * Double(radius * radius - innerRadius * innerRadius))
            let convectionSurface = Float(2 * (Double.pi * Double(tireWidth) * Double(radius) + Double(sideArea)))
            let temperature = Float(273.15) + Float(20), volume = sideArea * tireWidth
            let gasMass = pressure * volume / (296.8 * temperature)
            let brakeSection = name + " Brake"
            let diameter = number(brakeSection, "disk diameter", 0.2), area = number(brakeSection, "piston area", 0.002)
            let brakeMu = number(brakeSection, "mu", 0.3), brakeInertia = number(brakeSection, "inertia", 0.13)
            let coefficient = diameter * 0.5 * area * brakeMu
            let values = [pressure, rimDiameter, tireWidth, ratio, friction, inertia, y, rest, toe, camber, caster,
                          ca, rFactor, eFactor, loadMin, loadMax, operatingLoad, wheelMass, radius, tireSpring,
                          magicC, magicB, loadExponent, thickness, rimMass, hysteresis, wear, idealTemperature,
                          treadMass, baseMass, convectionSurface, gasMass, diameter, area, brakeMu, brakeInertia, coefficient]
            guard values.allSatisfy(\.isFinite), pressure > 0, radius > 0, tireWidth > 0, wheelMass > 0,
                  operatingLoad > 0, inertia > 0, treadMass >= 0, baseMass >= 0, gasMass >= 0,
                  baseMass + treadMass + gasMass > 0, idealTemperature != temperature,
                  diameter >= 0, brakeInertia >= 0, abs(toe) < 65536 else {
                throw ParameterError.invalid("Invalid or singular \(section) configuration")
            }
            let suspension = try SuspensionDefinition.configured(parameters: p, section: name + " Suspension", preload: weight, rest: rest)
            definitions.append(WheelDefinition(
                staticPosition: SIMD3(axle.position - mass.centerOfGravity.x, y - mass.centerOfGravity.y, -mass.centerOfGravity.z),
                initialRelativePosition: SIMD3(axle.position, y, radius),
                staticLoad: weight, rollCenter: axle.rollCenter, inertia: inertia, feedbackInertia: axle.inertia / 2 + inertia,
                tireSpringRate: tireSpring, rimRadius: innerRadius, tireHeight: tireWidth * ratio, treadThickness: thickness,
                suspension: suspension, brake: BrakeDefinition(coefficient: coefficient, radius: diameter / 2, inertia: brakeInertia),
                force: WheelForceDefinition(radius: radius, mass: wheelMass, tireWidth: tireWidth, friction: friction,
                    magicB: magicB, magicC: magicC, magicE: eFactor, loadMinimum: loadMin, loadMaximum: loadMax,
                    loadExponent: loadExponent, operatingLoad: operatingLoad, camber: camber, caster: caster, toe: toe),
                thermal: TireThermalDefinition(pressure: pressure, initialTemperature: temperature, idealTemperature: idealTemperature,
                    treadMass: treadMass, baseMass: baseMass, gasMass: gasMass, convectionSurface: convectionSurface,
                    hysteresisFactor: hysteresis, wearFactor: wear)))
        }
        wheels = definitions
    }
}

extension SuspensionDefinition {
    static func configured(parameters: ParameterDocument, section: String, preload: Float, rest: Float) throws -> Self {
        func n(_ name: String, _ fallback: Float) -> Float { parameters.section(section)?.number(name, default: fallback) ?? fallback }
        let spring = n("spring", 175000), travel = n("suspension course", 0.5)
        let bellcrank = n("bellcrank", 1), packers = n("packers", 0)
        let slowBump = n("slow bump", 0), slowRebound = n("slow rebound", 0)
        let fastBump = n("fast bump", slowBump), fastRebound = n("fast rebound", slowRebound)
        let bumpThreshold = n("fast bump threshold", 0.5), reboundThreshold = n("fast rebound threshold", 0.5)
        guard [spring, travel, bellcrank, packers, slowBump, slowRebound, fastBump, fastRebound, bumpThreshold,
               reboundThreshold, preload, rest].allSatisfy(\.isFinite), bellcrank > 0 else {
            throw ParameterError.invalid("Invalid \(section) configuration")
        }
        return Self(springRate: spring, preload: preload, rest: rest, travel: travel, bellcrank: bellcrank, packers: packers,
                    bump: DamperDefinition(slow: slowBump, fast: fastBump, threshold: bumpThreshold),
                    rebound: DamperDefinition(slow: slowRebound, fast: fastRebound, threshold: reboundThreshold))
    }
}
