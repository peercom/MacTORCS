// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 simuv2/car.cpp SimCarConfig mass/geometry setup.
// Copyright (C) 2000-2017 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSConfiguration

/// Immutable mechanical properties. No XML representation enters dynamic state.
/// Does not include tire/engine/drivetrain configuration or integrate a vehicle.
public struct VehicleMassProperties: Sendable {
    public let mass: Float
    public let inverseMass: Float
    public let dimensions: SIMD3<Float>
    public let centerOfGravity: SIMD3<Float>
    public let inverseInertia: SIMD3<Float>
    /// TORCS order: front right, front left, rear right, rear left.
    public let staticWheelLoads: SIMD4<Float>
    public let wheelbase: Float
    public let wheeltrack: Float
    public let tankCapacity: Float
    public let initialFuel: Float

    public init(parameters: ParameterDocument) throws {
        func number(_ section: String, _ key: String, _ fallback: Float) -> Float {
            parameters.section(section)?.number(key, default: fallback) ?? fallback
        }
        let length = number("Car", "body length", 4.7), width = number("Car", "body width", 1.9)
        let height = number("Car", "body height", 1.2), mass = number("Car", "mass", 1500)
        let front = number("Car", "front-rear weight repartition", 0.5)
        let frontLeft = number("Car", "front right-left weight repartition", 0.5)
        let rearLeft = number("Car", "rear right-left weight repartition", 0.5)
        let cgHeight = number("Car", "GC height", 0.5)
        let centralization = number("Car", "mass repartition coefficient", 1)
        let tank = number("Car", "fuel tank", 80), fuel = number("Car", "initial fuel", 80)
        let frontAxle = number("Front Axle", "xpos", 0), rearAxle = number("Rear Axle", "xpos", 0)
        let wheelNames = ["Front Right Wheel", "Front Left Wheel", "Rear Right Wheel", "Rear Left Wheel"]
        let y = wheelNames.map { number($0, "ypos", 0) }
        let inputs = [length, width, height, mass, front, frontLeft, rearLeft, cgHeight, centralization, tank, fuel, frontAxle, rearAxle] + y
        guard inputs.allSatisfy(\.isFinite), mass > 0, length > 0, width > 0, height > 0,
              tank > 0, fuel >= 0, (0...1).contains(front), (0...1).contains(frontLeft), (0...1).contains(rearLeft) else {
            throw ParameterError.invalid("Invalid vehicle mass, geometry, fuel or weight distribution")
        }
        self.mass = mass; inverseMass = 1 / mass; dimensions = SIMD3(length, width, height)
        let cgX = frontAxle * front + rearAxle * (1 - front)
        let cgY = -(front * frontLeft + (1 - front) * rearLeft) * width + width / 2
        centerOfGravity = SIMD3(cgX, cgY, cgHeight)
        let k = centralization * centralization
        inverseInertia = SIMD3(12 / (mass * (width * width + height * height)),
                              12 / (mass * (length * length + height * height)),
                              12 / (mass * (width * width + k * length * length)))
        let weight = mass * Float(9.80665), frontWeight = weight * front, rearWeight = weight * (1 - front)
        staticWheelLoads = SIMD4(frontWeight * frontLeft, frontWeight * (1 - frontLeft),
                                rearWeight * rearLeft, rearWeight * (1 - rearLeft))
        let fx = frontAxle - cgX, rx = rearAxle - cgX
        wheelbase = (fx + fx - rx - rx) / 2
        wheeltrack = (-(y[3] - cgY) - (y[1] - cgY) + (y[0] - cgY) + (y[2] - cgY)) / 2
        tankCapacity = tank; initialFuel = min(fuel, tank)
    }
}
