// SPDX-License-Identifier: GPL-2.0-only
// Placement follows TORCS 1.3.9 raceengineclient/raceinit.cpp and the pinned
// headless reference harness. Copyright (C) Eric Espie, Bernhard Wymann;
// upstream GPL-2.0-or-later. Random scaling follows simuv2/sim.h.
import Foundation
import TORCSTrack

/// Matches the macOS reference's rand stream without touching process-global
/// srand/rand state. The recurrence is specified by Apple Libc rand.c:
/// https://github.com/apple-oss-distributions/Libc/blob/main/stdlib/FreeBSD/rand.c
/// This is a platform-compatibility stream, not a claim of
/// replay compatibility with other platforms' libc implementations.
public struct DarwinRandomStream: Sendable {
    public private(set) var state: UInt32
    public private(set) var draws: UInt64 = 0
    public init(seed: UInt32) { state = seed }
    public mutating func next() -> Float {
        draws += 1
        // Park–Miller recurrence with Darwin's zero-seed substitution.
        // UInt64 multiplication expresses the recurrence directly without the
        // libc implementation's division-based overflow avoidance.
        let seed = UInt64(state == 0 ? 123459876 : state)
        state = UInt32((16807*seed)%2147483647)
        return (Float(state)-1)/Float(2147483647)
    }
}

/// One-car facade over shared physics, removal/towing and fixed-wall dispatch.
/// Pit service and race management remain separate work.
public struct SingleVehicleSimulation: Sendable {
    private var simulation: MultiVehicleSimulation
    public var road: TrackRoad { simulation.road }
    public var vehicle: VehicleDynamicsState { simulation.cars[0] }
    public var lifecycle: VehicleRemovalState { simulation.lifecycle[0] }
    public var random: DarwinRandomStream { simulation.random }
    public var tick: Int { simulation.tick }
    public var settlingTicks: Int { simulation.settlingTicks }
    public init(definition: VehicleDynamicsDefinition,road: TrackRoad,seed: UInt32 = 12345,startDistance: Float = 10) throws {
        simulation = try MultiVehicleSimulation(definition:definition,road:road,carCount:1,seed:seed,startDistance:startDistance)
    }
    public mutating func updateCarStatus(flags: UInt32? = nil,fuel: Float? = nil,damage: Int32? = nil,pitOccupant: Int32? = nil) throws {
        try simulation.updateCarStatus(car:0,flags:flags,fuel:fuel,damage:damage,pitOccupant:pitOccupant)
    }
    public mutating func service(_ command: inout PitServiceCommand) throws { try simulation.service(car:0,command:&command) }
    public mutating func settle(ticks: Int = 501) throws { try simulation.settle(ticks:ticks) }
    public mutating func step(command: DriverCommand,mode: VehicleUpdateMode = .running,carFlags: UInt32? = nil,
        damageFactor: Float = 1,tireFactor: Float = 0,maximumDamage: Int32 = 0) throws {
        try simulation.step(commands:[command],mode:mode,carFlags:carFlags.map { [$0] },damageFactor:damageFactor,tireFactor:tireFactor,maximumDamage:maximumDamage)
    }
}

func initiallyPlacedVehicle(definition: VehicleDynamicsDefinition,road: TrackRoad,startDistance: Float,lateralPosition: Float? = nil) throws -> VehicleDynamicsState {
    guard lateralPosition.map({ $0.isFinite }) ?? true,startDistance.isFinite, startDistance >= 0, road.length > 0 else { throw TrackError.invalid("Invalid vehicle placement") }
    var distance = startDistance.truncatingRemainder(dividingBy:road.length), index = road.geometry.mainSegments[0]
    while distance >= road.geometry.segments[index].length {
        distance -= road.geometry.segments[index].length; index = road.geometry.segments[index].next
    }
    let segment = road.geometry.segments[index]
    let local = TrackLocalPosition(segment:index,toStart:segment.curve == .straight ? distance : distance/segment.radius,toRight:lateralPosition ?? segment.width/2)
    let xy = road.geometry.localToGlobal(local)
    var yaw = road.geometry.tangent(local)
    // NORM0_2PI compares in Double but adds/subtracts a Float period.
    while Double(yaw) > 2*Double.pi { yaw -= Float(2*Double.pi) }
    while yaw < 0 { yaw += Float(2*Double.pi) }
    let initial = ChassisDynamics(position:SIMD3(xy.x,xy.y,road.geometry.height(local)+0.3),orientation:SIMD3(0,0,yaw))
    return VehicleDynamicsState(definition:definition,chassis:.init(body:initial,world:initial,trackPosition:local))
}
