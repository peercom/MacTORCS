// SPDX-License-Identifier: GPL-2.0-only
// Publication follows TORCS 1.3.9 simuv2/simu.cpp and car.cpp.
// Copyright (C) 2000-2017 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation

public struct WheelVisualPose: Sendable {
    public let position,orientation: SIMD3<Float>
    public init(position: SIMD3<Float> = .zero,orientation: SIMD3<Float> = .zero) {
        self.position=position;self.orientation=orientation
    }
}
public struct WheelVisualSnapshot: Sendable {
    public let pose: WheelVisualPose
    public let spin,radius,width,brakeTemperature,brakeRadius: Float
    public init(pose: WheelVisualPose,spin: Float,radius: Float,width: Float,brakeTemperature: Float,brakeRadius: Float) {
        self.pose=pose;self.spin=spin;self.radius=radius;self.width=width;self.brakeTemperature=brakeTemperature;self.brakeRadius=brakeRadius
    }
}
/// Immutable presentation values. No renderer can mutate active simulation state.
public struct VehicleVisualSnapshot: Sendable {
    public let tick: Int,flags: UInt32
    public let brakeCommand: Float
    public let lightCommand: UInt32
    public let body: CollisionTransform
    public let wheels: FourWheels<WheelVisualSnapshot>
    public init(tick: Int,published: VehicleRemovalState,configuration: RunningGearConfiguration,command: DriverCommand = .init()) {
        self.tick=tick;flags=published.flags;body=published.publicTransform
        brakeCommand=command.brake;lightCommand=command.lightCommand
        func wheel(_ i: Int) -> WheelVisualSnapshot {
            let d=configuration.wheels[i]
            return WheelVisualSnapshot(pose:published.publishedWheelPose[i],spin:published.publishedSpin[i],
                radius:d.rimRadius+d.tireHeight,width:d.force.tireWidth,brakeTemperature:published.publishedBrakeTemperature[i],brakeRadius:d.brake.radius)
        }
        wheels=FourWheels(wheel(0),wheel(1),wheel(2),wheel(3))
    }
}
extension SingleVehicleSimulation {
    public var visualSnapshot: VehicleVisualSnapshot { .init(tick:tick,published:lifecycle,configuration:vehicle.runningGear.configuration,command:vehicle.driverCommand) }
}
extension MultiVehicleSimulation {
    public func visualSnapshot(car: Int) -> VehicleVisualSnapshot {
        precondition(cars.indices.contains(car))
        return .init(tick:tick,published:lifecycle[car],configuration:cars[car].runningGear.configuration,command:cars[car].driverCommand)
    }
}
