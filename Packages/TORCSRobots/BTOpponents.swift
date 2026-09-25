// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 robots/bt/cardata.cpp and opponent.cpp.
// Copyright (C) 2003-2004 Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSTrack

/// The original OPP_* classification of one opponent relative to the driver.
public struct BTOpponentState: OptionSet,Sendable,Equatable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue=rawValue }
    public static let front=Self(rawValue:1<<0)
    public static let back=Self(rawValue:1<<1)
    public static let side=Self(rawValue:1<<2)
    public static let collision=Self(rawValue:1<<3)
    public static let letPass=Self(rawValue:1<<4)
    public static let frontFast=Self(rawValue:1<<5)
}

/// One car's published state, as the original opponent model reads it. Corners
/// are the original pub.corner order: front right, front left, rear right, rear
/// left. Nothing here is private physics state.
public struct BTCarState: Sendable {
    public var position: TrackLocalPosition
    public var worldPosition,worldVelocity: SIMD2<Float>
    public var corners: [SIMD2<Float>]
    public var yaw,length,width,distanceFromStart: Float
    public var laps: Int
    public var damage: Int32
    public var flags: UInt32
    public var teamMate: Bool
    public init(position: TrackLocalPosition,worldPosition: SIMD2<Float>,worldVelocity: SIMD2<Float>,
                corners: [SIMD2<Float>],yaw: Float,length: Float,width: Float,distanceFromStart: Float,
                laps: Int,damage: Int32 = 0,flags: UInt32 = 0,teamMate: Bool = false) {
        self.position=position;self.worldPosition=worldPosition;self.worldVelocity=worldVelocity
        self.corners=corners;self.yaw=yaw;self.length=length;self.width=width
        self.distanceFromStart=distanceFromStart;self.laps=laps;self.damage=damage;self.flags=flags
        self.teamMate=teamMate
    }
    var valid: Bool {
        corners.count==4 && [position.toStart,position.toMiddle,worldPosition.x,worldPosition.y,worldVelocity.x,
            worldVelocity.y,yaw,length,width,distanceFromStart].allSatisfy(\.isFinite) &&
            corners.allSatisfy { $0.x.isFinite && $0.y.isFinite } && length>0 && width>0
    }
}

/// SingleCardata: facts about one car that do not depend on any other car.
struct BTCarData: Sendable {
    let trackAngle,speed,angle,width,alongTrack: Float
    init(_ state: BTCarState,geometry: TrackGeometry) {
        let segment=geometry.segments[state.position.segment]
        // The original recomputes an opponent's distance along the track rather
        // than reading the published one, with the same arithmetic ReManage uses.
        let within=segment.curve == .straight ? state.position.toStart:state.position.toStart*segment.radius
        alongTrack=segment.distanceFromStart+within
        trackAngle=geometry.tangent(state.position)
        // The original projects the world speed onto the track direction.
        speed=state.worldVelocity.x*cos(trackAngle)+state.worldVelocity.y*sin(trackAngle)
        let relative=btNormalized(trackAngle-state.yaw)
        angle=relative
        width=state.length*sin(relative)+state.width*cos(relative)
    }
}

/// One opponent, relative to the driver's own car. The overlap timer persists
/// between callbacks, so a driver owns one value per opponent for the race.
public struct BTOpponent: Sendable {
    static let frontCollisionDistance: Float = 200
    static let backCollisionDistance: Float = 70
    static let lengthMargin: Float = 3
    static let sideMargin: Float = 1
    static let exactDistance: Float = 12
    static let lapBackTimePenalty: Float = -30
    static let overlapWaitTime: Float = 5
    static let speedPassMargin: Float = 5

    public private(set) var state: BTOpponentState=[]
    public private(set) var distance: Float=0
    public private(set) var catchDistance: Float=0
    public private(set) var sideDistance: Float=0
    public private(set) var overlapTimer: Float=0
    public private(set) var width: Float=0
    public private(set) var speed: Float=0
    public private(set) var damage: Int32=0
    public private(set) var laps=0
    public private(set) var teamMate=false
    /// The opponent's live published position, which the original reads straight
    /// off the car pointer whatever the classification is.
    public private(set) var toMiddle: Float=0
    public private(set) var yaw: Float=0
    public private(set) var segment=0
    public init() {}

    mutating func update(mine: BTCarState,myData: BTCarData,mySpeed: Float,opponent: BTCarState,
                         data: BTCarData,trackLength: Float,deltaTime: Float) {
        width=data.width;speed=data.speed;damage=opponent.damage;laps=opponent.laps;teamMate=opponent.teamMate
        toMiddle=opponent.position.toMiddle;yaw=opponent.yaw;segment=opponent.position.segment
        state=[]
        // A car out of the simulation is ignored, but one stopped in its pit is
        // still an obstacle: the original masks the pit bit out of NO_SIMU.
        // The original returns here without touching the overlap timer, so it
        // keeps whatever value it had while the car is out.
        if opponent.flags & (0xFF & ~0x1) != 0 { return }
        distance=data.alongTrack-mine.distanceFromStart
        if distance>trackLength/2 { distance -= trackLength }
        else if distance < -trackLength/2 { distance += trackLength }
        let sideCollisionDistance=min(opponent.length,mine.length)
        if distance > -Self.backCollisionDistance,distance<Self.frontCollisionDistance {
            if distance>sideCollisionDistance,speed<mySpeed {
                state.insert(.front)
                distance -= max(opponent.length,mine.length)
                distance -= Self.lengthMargin
                if distance<Self.exactDistance {
                    // The original measures from the driver's front edge to the
                    // nearest corner of the opponent.
                    let anchor=mine.corners[1],other=mine.corners[0]
                    var direction=SIMD2(other.x-anchor.x,other.y-anchor.y)
                    let length=sqrt(direction.x*direction.x+direction.y*direction.y)
                    if length>0 { direction /= length }
                    var minimum=Float.greatestFiniteMagnitude
                    for corner in opponent.corners {
                        let d1=SIMD2(corner.x-anchor.x,corner.y-anchor.y)
                        let projection=direction.x*d1.x+direction.y*d1.y
                        let perpendicular=SIMD2(d1.x-direction.x*projection,d1.y-direction.y*projection)
                        minimum=min(minimum,sqrt(perpendicular.x*perpendicular.x+perpendicular.y*perpendicular.y))
                    }
                    if minimum<distance { distance=minimum }
                }
                catchDistance=mySpeed*distance/(mySpeed-speed)
                var carDistance=opponent.position.toMiddle-mine.position.toMiddle
                sideDistance=carDistance
                carDistance=abs(carDistance)-abs(width/2)-mine.width/2
                if carDistance<Self.sideMargin { state.insert(.collision) }
            } else if distance < -sideCollisionDistance,speed>mySpeed-Self.speedPassMargin {
                catchDistance=mySpeed*distance/(speed-mySpeed)
                state.insert(.back)
                distance -= max(opponent.length,mine.length)
                distance -= Self.lengthMargin
            } else if distance > -sideCollisionDistance,distance<sideCollisionDistance {
                sideDistance=opponent.position.toMiddle-mine.position.toMiddle
                state.insert(.side)
            } else if distance>sideCollisionDistance,speed>mySpeed {
                state.insert(.frontFast)
            }
        }
        updateOverlapTimer(mine:mine,deltaTime:deltaTime)
        if overlapTimer>Self.overlapWaitTime { state.insert(.letPass) }
    }
    private mutating func updateOverlapTimer(mine: BTCarState,deltaTime: Float) {
        guard laps>mine.laps else { overlapTimer=0;return }
        if !state.isDisjoint(with:[.back,.side]) { overlapTimer += deltaTime }
        else if state.contains(.front) { overlapTimer=Self.lapBackTimePenalty }
        else if overlapTimer>0 {
            if state.contains(.frontFast) { overlapTimer=min(0,overlapTimer) }
            else { overlapTimer -= deltaTime }
        } else { overlapTimer += deltaTime }
    }
}
