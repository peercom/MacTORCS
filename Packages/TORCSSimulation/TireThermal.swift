// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 simuv2/wheel.cpp SimWheelUpdateTire/SimWheelResetWear.
// Copyright (C) 2000-2024 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation

public struct TireThermalDefinition: Sendable {
    public let pressure, initialTemperature, idealTemperature, treadMass, baseMass: Float
    public let gasMass, convectionSurface, hysteresisFactor, wearFactor: Float
    public init(pressure: Float, initialTemperature: Float, idealTemperature: Float, treadMass: Float,
                baseMass: Float, gasMass: Float, convectionSurface: Float, hysteresisFactor: Float, wearFactor: Float) {
        precondition([pressure, initialTemperature, idealTemperature, treadMass, baseMass, gasMass,
                      convectionSurface, hysteresisFactor, wearFactor].allSatisfy(\.isFinite))
        precondition(initialTemperature > 0 && idealTemperature != initialTemperature && baseMass >= 0 && treadMass >= 0 && gasMass >= 0 && baseMass + treadMass + gasMass > 0)
        self.pressure = pressure; self.initialTemperature = initialTemperature; self.idealTemperature = idealTemperature
        self.treadMass = treadMass; self.baseMass = baseMass; self.gasMass = gasMass; self.convectionSurface = convectionSurface
        self.hysteresisFactor = hysteresisFactor; self.wearFactor = wearFactor
    }
}

public struct TireThermalState: Sendable {
    public private(set) var pressure, temperature, graining, grip: Float
    /// Upstream deliberately stores wear at double precision.
    public private(set) var wear: Double
    public init(pressure: Float, temperature: Float, wear: Double = 0, graining: Float = 0, grip: Float = 1) {
        self.pressure = pressure; self.temperature = temperature; self.wear = wear; self.graining = graining; self.grip = grip
    }
    public mutating func reset(definition: TireThermalDefinition, localTemperature: Float) {
        pressure = definition.pressure; temperature = localTemperature; wear = 0; graining = 0; grip = 1
    }
    /// Called after force calculation, before drivetrain/rotation. Updated grip
    /// therefore affects the next force tick, not the force that supplied this load.
    public mutating func update(definition d: TireThermalDefinition, tireLoad: Float, slip: Float,
                                spin: Float, radius: Float, localTemperature: Float, localPressure: Float,
                                skillLevel: Int, tireFactor: Float, dt: Float = 0.002) {
        guard tireFactor > 0 && skillLevel == 3 else { return }
        let speed = abs(spin * radius)
        let deltaTemperature = temperature - localTemperature
        let elasticity = (d.pressure - localPressure) / (pressure - localPressure)
        let hysteresis = Float((Double(Float(0.05)) * sqrt(1 - wear) * Double(elasticity) + Double(0.5 * slip)) * Double(d.hysteresisFactor))
        let energyGain = tireLoad * speed * dt * hysteresis
        let energyLoss = (5.9 + speed * 3.7) * deltaTemperature * d.convectionSurface * dt
        let deltaEnergy = energyGain - energyLoss
        let celsius = temperature - 273.15
        let cpRubber = 2009 - 1.962 * celsius + 3.077 * celsius * celsius / 100
        let rubberMass = Float(Double(d.treadMass) * (1 - wear) + Double(d.baseMass))
        let cvNitrogen: Float = 1041 - 296.8
        let heatCapacity = cpRubber * rubberMass + cvNitrogen * d.gasMass
        temperature += deltaEnergy / heatCapacity
        pressure = temperature / d.initialTemperature * d.pressure
        let wearProduct = (pressure - localPressure) * slip * speed * dt * tireLoad * d.wearFactor
        let deltaWear = Double(wearProduct) * 0.00000000000009
        wear += deltaWear * Double(tireFactor)
        if wear > 1 { wear = 1 }
        let grainTemperature = (d.idealTemperature - d.initialTemperature) * 3 / 4 + d.initialTemperature
        var deltaGraining = Float(Double(grainTemperature - temperature) * deltaWear)
        if deltaGraining > 0 { deltaGraining = Float(Double(deltaGraining) * wear) }
        graining += deltaGraining
        if graining > 1 { graining = 1 } else if graining < 0 { graining = 0 }
        let di = (temperature - d.idealTemperature) / (d.idealTemperature - d.initialTemperature)
        let squared = di * di
        grip = ((1 - (squared < 1 ? squared : 1)) / 4 + 3 / 4) * (1 - graining / 10)
    }
}
