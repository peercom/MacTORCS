// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 raceinit.cpp initStartingGrid.
// Copyright (C) 2002-2017 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSConfiguration

/// Original race-manager "Starting Grid" values.
///
/// The original reads each value from the race manager first and then lets the
/// track XML override it, except the initial speed, which the track cannot
/// change. `poleLeft` is nil until resolved: the original default is the inside
/// of the first turn, which only the road can answer.
public struct StartingGridConfiguration: Sendable, Equatable {
    public var rows: Int
    public var toStart, columnDistance, columnOffset, initialSpeed, initialHeight: Float
    public var poleLeft: Bool?
    public init(rows: Int = 2,toStart: Float = 10,columnDistance: Float = 10,columnOffset: Float = 5,
                initialSpeed: Float = 0,initialHeight: Float = 0.3,poleLeft: Bool? = nil) throws {
        guard [toStart,columnDistance,columnOffset,initialSpeed,initialHeight].allSatisfy(\.isFinite),
              (-10000...10000).contains(rows) else { throw TrackError.invalid("Invalid starting grid values") }
        self.rows=rows;self.toStart=toStart;self.columnDistance=columnDistance;self.columnOffset=columnOffset
        self.initialSpeed=initialSpeed;self.initialHeight=initialHeight;self.poleLeft=poleLeft
    }
    /// The values shipped in the original quickrace.xml. The plain initializer's
    /// defaults are raceinit.cpp's own fallbacks.
    public static func quickRace() throws -> Self {
        try Self(rows:2,toStart:25,columnDistance:20,columnOffset:10,initialSpeed:0,initialHeight:0.2)
    }
    /// The original attribute names, read from `<race name>/Starting Grid` and
    /// then overridden by the track's own top-level `Starting Grid` section.
    public init(race: ParameterDocument,raceName: String,track: ParameterDocument? = nil) throws {
        let manager=race.section(raceName+"/Starting Grid")
        let override=track?.section("Starting Grid")
        func number(_ key: String,_ fallback: Float,trackOverride: Bool = true) -> Float {
            let value=manager?.number(key,default:fallback) ?? fallback
            guard trackOverride,let override else { return value }
            return override.number(key,default:value)
        }
        // An absent attribute keeps the previous value, so the original default
        // survives a track section that sets only some of the grid values.
        var pole: String?=manager.map { $0.string("pole position side",default:"") }.flatMap { $0.isEmpty ? nil:$0 }
        if let override {
            let value=override.string("pole position side",default:"")
            if !value.isEmpty { pole=value }
        }
        try self.init(rows:Int(number("rows",2)),toStart:number("distance to start",10),
            columnDistance:number("distance between columns",10),columnOffset:number("offset within a column",5),
            initialSpeed:number("initial speed",0,trackOverride:false),
            initialHeight:number("initial height",0.3),
            // Only an explicit "left" selects the left side, exactly as the
            // original string comparison does; anything else means right.
            poleLeft:pole.map { $0=="left" })
    }
}

/// One car's original grid placement, before any physics step.
public struct StartingGridSlot: Sendable, Equatable {
    public let position: TrackLocalPosition
    public let world: SIMD3<Float>
    public let yaw, speed: Float
}

public enum StartingGrid {
    /// The original normalization, including its strict upper comparison: a yaw
    /// of exactly 2π is left alone, and the addition/subtraction uses the float
    /// constant while the comparison is made in double.
    static func normalized(_ input: Float) -> Float {
        var angle=input
        while Double(angle)>2*Double.pi { angle -= Float(2*Double.pi) }
        while angle<0 { angle += Float(2*Double.pi) }
        return angle
    }
    /// The inside of the first turn, which is the original default pole side.
    /// A track with no turn has no original answer, so it is rejected.
    public static func defaultPoleLeft(road: TrackRoad) throws -> Bool {
        let g=road.geometry
        guard var index=g.mainSegments.first else { throw TrackError.invalid("Starting grid requires a road") }
        var visited=0
        while g.segments[index].curve == .straight {
            index=g.segments[index].next;visited += 1
            guard visited<=g.mainSegments.count else { throw TrackError.invalid("Starting grid requires a track with a turn") }
        }
        return g.segments[index].curve == .left
    }
    /// Original placement for `cars` drivers, in grid order from the pole back.
    ///
    /// The original walks back from the last segment and would run off the front
    /// of the segment list for a grid longer than the track; that is undefined
    /// upstream, so it is reported here instead.
    public static func slots(road: TrackRoad,configuration: StartingGridConfiguration,cars: Int) throws -> [StartingGridSlot] {
        guard (1...64).contains(cars) else { throw TrackError.invalid("A starting grid holds 1…64 cars") }
        let g=road.geometry
        guard let last=g.mainSegments.last else { throw TrackError.invalid("Starting grid requires a road") }
        let poleLeft=try configuration.poleLeft ?? defaultPoleLeft(road:road)
        let a:Float=poleLeft ? road.width:0, b:Float=poleLeft ? -road.width:road.width
        // The original clamps only the lower bound, after reading the value.
        let rows=max(1,configuration.rows)
        var slots:[StartingGridSlot]=[]
        for car in 0..<cars {
            let column=Float(car/rows)*configuration.columnDistance
            let offset=Float(car%rows)*configuration.columnOffset
            let startPosition=road.length-(configuration.toStart+column+offset)
            let toRight=a+b*Float(car%rows+1)/Float(rows+1)
            var index=last,visited=0
            while startPosition<g.segments[index].distanceFromStart {
                index=g.segments[index].previous;visited += 1
                guard visited<g.mainSegments.count else {
                    throw TrackError.invalid("Starting grid for \(cars) cars does not fit on this track")
                }
            }
            let segment=g.segments[index]
            let along=startPosition-segment.distanceFromStart
            let toStart=segment.curve == .straight ? along:along/segment.radius
            let position=TrackLocalPosition(segment:index,toStart:toStart,toRight:toRight,mode:.main)
            let plane=g.localToGlobal(position,origin:.right)
            var yaw=segment.headingStart
            switch segment.curve {
            case .straight:break
            case .right:yaw -= toStart
            case .left:yaw += toStart
            }
            slots.append(StartingGridSlot(position:position,
                world:SIMD3(plane.x,plane.y,g.height(position)+configuration.initialHeight),
                yaw:normalized(yaw),speed:configuration.initialSpeed))
        }
        return slots
    }
}
