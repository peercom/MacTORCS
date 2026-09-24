// SPDX-License-Identifier: GPL-2.0-only
// Stage order follows TORCS 1.3.9 simuv2/simu.cpp and collide.cpp.
// Copyright (C) 2000-2017 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import TORCSTrack

/// Ordered vehicle simulation with removal/towing and original SMART contacts.
/// Pit assignment/service and race logic remain outside this physics scheduler.
/// Fixed pairs preserve upstream's degenerate-normal gate;
/// contacts that would dereference a wall as a car produce a diagnostic.
public struct MultiVehicleSimulation: Sendable {
    public let road: TrackRoad
    public private(set) var cars: [VehicleDynamicsState]
    public private(set) var random: DarwinRandomStream
    public private(set) var tick = 0, settlingTicks = 0, detectedPairs = 0
    public private(set) var detectedWallPairs = 0
    public private(set) var detectedFixedPairs = 0
    public var wallCount: Int { walls.count }
    private var walls: [ComplexCollisionShape]
    private var shapes: [ConvexShape]
    public private(set) var lifecycle: [VehicleRemovalState]
    private var collisionTransforms: [CollisionTransform]
    private var collisionTransformLoaded: [Bool]
    private var accumulated: [SIMD3<Float>]
    private var previousTransforms: [ConvexTransform]
    private var query = ConvexCollisionQuery()
    public init(definition: VehicleDynamicsDefinition,road: TrackRoad,carCount: Int,seed: UInt32 = 12345,startDistance: Float = 10,spacing: Float = 10,lateralPosition: Float? = nil) throws {
        guard (1...16).contains(carCount), spacing.isFinite, spacing>=5 else { throw TrackError.invalid("Invalid multi-car grid") }
        self.road = road; random = DarwinRandomStream(seed:seed)
        walls = try TrackWallCollision.polygons(track:road.geometry).map { try ComplexCollisionShape(primitives:$0) }
        cars = try (0..<carCount).map { try initiallyPlacedVehicle(definition:definition,road:road,startDistance:startDistance+Float($0)*spacing,lateralPosition:lateralPosition) }
        let dimensions = definition.chassis.runningGear.mass.dimensions
        shapes = try (0..<carCount).map { _ in try ConvexShape(box:SIMD3(Double(dimensions.x),Double(dimensions.y),Double(dimensions.z))) }
        lifecycle = cars.map { $0.removalState() }
        collisionTransforms = Array(repeating:CollisionTransform(position:.zero,orientation:.zero),count:carCount)
        accumulated = Array(repeating:.zero,count:carCount)
        collisionTransformLoaded = Array(repeating:false,count:carCount)
        // SOLID creates each object at identity before the first physics dispatch.
        previousTransforms = Array(repeating:ConvexTransform(),count:carCount)
    }
    /// External race/status changes; published values update at the original copy-back stage.
    /// Pit occupancy represents an assigned stall; service and assignment policy live above physics.
    public mutating func updateCarStatus(car: Int,flags: UInt32? = nil,fuel: Float? = nil,
        damage: Int32? = nil,pitOccupant: Int32? = nil) throws {
        guard cars.indices.contains(car), fuel.map({ $0.isFinite && $0>=0 }) ?? true else { throw TrackError.invalid("Invalid car status") }
        if let flags {
            guard lifecycle[car].collisionRegistered || flags & 0xFF != 0 else { throw TrackError.invalid("Removed cars cannot be reactivated without configuration") }
            lifecycle[car].flags = flags
        }
        if let pitOccupant { lifecycle[car].pitOccupant = pitOccupant }
        cars[car].setStatus(flags:flags,fuel:fuel,damage:damage)
        cars[car].synchronizeRemoval(&lifecycle[car])
    }
    public mutating func settle(ticks: Int = 501) throws {
        guard tick==0,settlingTicks==0,(0...10000).contains(ticks) else { throw TrackError.invalid("Settling requires a fresh simulation") }
        let commands = Array(repeating:DriverCommand(brake:1),count:cars.count)
        for _ in 0..<ticks { try advance(commands:commands,mode:.settling); settlingTicks += 1 }
    }
    /// ReRaceStart staging: one uncommanded update, previous-position capture,
    /// then one second of braked settling. Measured tick numbering stays at zero.
    public mutating func settleForRace(tireFactor: Float = 1) throws -> [TrackLocalPosition] {
        guard tick==0,settlingTicks==0,tireFactor.isFinite,tireFactor>=0 else { throw TrackError.invalid("Race settling requires a fresh simulation") }
        try advance(commands:Array(repeating:DriverCommand(),count:cars.count),mode:.settling,tireFactor:tireFactor)
        settlingTicks=1
        let previous=lifecycle.map(\.trackPosition)
        let commands=Array(repeating:DriverCommand(brake:1),count:cars.count)
        for _ in 0..<500 { try advance(commands:commands,mode:.settling,tireFactor:tireFactor);settlingTicks += 1 }
        return previous
    }
    public mutating func step(commands: [DriverCommand],mode: VehicleUpdateMode = .running,carFlags: [UInt32]? = nil,
        damageFactor: Float = 1,tireFactor: Float = 0,maximumDamage: Int32 = 0,skillLevels: [Int]? = nil) throws {
        try advance(commands:commands,mode:mode,carFlags:carFlags,damageFactor:damageFactor,tireFactor:tireFactor,maximumDamage:maximumDamage,skillLevels:skillLevels); tick += 1
    }
    private func contactTransform(_ body: ObjectCollisionBody,index: Int) -> ConvexTransform {
        // An object that has never entered active dispatch retains SOLID's
        // identity type flag, not an imported identity matrix's AFFINE type.
        if body.transformWasRefreshed { return ConvexTransform(body.transform) }
        return collisionTransformLoaded[index] ? ConvexTransform(collisionTransforms[index]) : ConvexTransform()
    }
    private mutating func advance(commands: [DriverCommand],mode: VehicleUpdateMode,carFlags: [UInt32]? = nil,
        damageFactor: Float = 1,tireFactor: Float = 0,maximumDamage: Int32 = 0,skillLevels: [Int]? = nil) throws {
        guard commands.count==cars.count,carFlags == nil || carFlags?.count == cars.count else { throw TrackError.invalid("One command/flag entry is required per car") }
        guard skillLevels.map({ $0.count==cars.count && $0.allSatisfy { (0..<5).contains($0) } }) ?? true else { throw TrackError.invalid("Invalid per-car skill levels") }
        for i in cars.indices {
            if let carFlags { try updateCarStatus(car:i,flags:carFlags[i]) }
            cars[i].beginScheduledTick(command:commands[i],flags:lifecycle[i].flags)
        }
        for i in cars.indices {
            let wasInactive = lifecycle[i].flags & 0xFF != 0
            cars[i].synchronizeRemoval(&lifecycle[i]); lifecycle[i].maximumDamage = maximumDamage
            if wasInactive || (maximumDamage != 0 && cars[i].damage>maximumDamage) || cars[i].fuel == 0 || lifecycle[i].flags & 0x800 != 0 {
                try lifecycle[i].remove(track:road.geometry)
                cars[i].applyRemoval(lifecycle[i])
                if wasInactive || lifecycle[i].flags & 0xFF != 0 { continue }
            }
            // Read other cars at this point in the sequential update, not from a
            // single frozen tick snapshot: the original drafting code does so.
            let traffic = cars.map { car in
                let p = car.chassis.world.position
                return AeroTrafficState(position:SIMD2(p.x,p.y),yaw:car.chassis.world.orientation.z,
                    longitudinalSpeed:car.chassis.body.velocity.x,dragCoefficient:car.definition.chassis.aerodynamics.draftingCoefficient)
            }
            try cars[i].stepScheduledVehicle(command:commands[i],track:road.geometry,mode:mode,carFlags:lifecycle[i].flags,skillLevel:skillLevels?[i] ?? 3,
                damageFactor:damageFactor,tireFactor:tireFactor,carIndex:i,traffic:traffic,random:{ random.next() })
        }
        for i in cars.indices where lifecycle[i].flags & 0xFF == 0 {
            collisionTransforms[i] = lifecycle[i].publicTransform; collisionTransformLoaded[i] = true
        }
        var bodies = cars.indices.map { cars[$0].objectCollisionBody(index:$0,publicTransform:lifecycle[$0].publicTransform) }
        for i in bodies.indices {
            bodies[i].publicOrientation = lifecycle[i].publicBody.orientation
            bodies[i].accumulated = accumulated[i]; bodies[i].beginDispatch()
        }
        detectedPairs = 0; detectedWallPairs = 0; detectedFixedPairs = 0
        for j in walls.indices { for i in 0..<j {
            var first = walls[i], second = walls[j]
            let contact = try first.smartContact(with:&second,first:ConvexTransform(),second:ConvexTransform(),
                previousFirst:ConvexTransform(),previousSecond:ConvexTransform(),query:&query)
            walls[i] = first; walls[j] = second
            if let contact {
                detectedFixedPairs += 1
                try ObjectCollisionResponse.validateFixedPair(contact:contact)
            }
        } }
        // Stable car identity replaces allocation addresses in native traversal.
        // Original fixed-object references precede the allocated car table on
        // the reference host: each car visits fixed walls, then earlier cars.
        for j in cars.indices where lifecycle[j].collisionRegistered {
            for wall in walls.indices {
                if let contact = try walls[wall].smartContact(with:&shapes[j],first:ConvexTransform(),second:contactTransform(bodies[j],index:j),
                    previousFirst:ConvexTransform(),previousSecond:previousTransforms[j],query:&query) {
                    detectedWallPairs += 1
                    try ObjectCollisionResponse.wall(body:&bodies[j],contact:contact,wallIsFirst:true,damageFactor:damageFactor)
                }
            }
            for i in 0..<j where lifecycle[i].collisionRegistered {
                var shapeA = shapes[i], shapeB = shapes[j]
                let contact = try query.smartContact(&shapeA,&shapeB,first:contactTransform(bodies[i],index:i),second:contactTransform(bodies[j],index:j),
                    previousFirst:previousTransforms[i],previousSecond:previousTransforms[j])
                shapes[i] = shapeA; shapes[j] = shapeB
                if let contact {
                    detectedPairs += 1
                    var first = bodies[i], second = bodies[j]
                    try ObjectCollisionResponse.pair(first:&first,second:&second,contact:contact,damageFactor:damageFactor)
                    bodies[i] = first; bodies[j] = second
                }
            }
        }
        if detectedPairs+detectedWallPairs+detectedFixedPairs==0 { previousTransforms = bodies.indices.map { contactTransform(bodies[$0],index:$0) } }
        for i in bodies.indices { bodies[i].commitVelocity(); cars[i].applyObjectCollision(bodies[i]) }
        for i in cars.indices {
            accumulated[i] = bodies[i].accumulated
            if bodies[i].transformWasRefreshed {
                lifecycle[i].publicTransform = bodies[i].transform; collisionTransformLoaded[i] = true
                collisionTransforms[i] = bodies[i].transform
            }
            cars[i].synchronizeRemoval(&lifecycle[i])
            if lifecycle[i].flags & 0xFF == 0 { cars[i].publish(&lifecycle[i],mode:mode) }
        }
    }
}

extension MultiVehicleSimulation {
    public mutating func service(car: Int,command: inout PitServiceCommand) throws {
        guard cars.indices.contains(car) else { throw TrackError.invalid("Invalid service car") }
        try cars[car].service(&command)
        cars[car].synchronizeRemoval(&lifecycle[car])
    }
}
