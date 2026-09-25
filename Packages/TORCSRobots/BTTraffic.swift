// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of the opponent-aware paths in TORCS 1.3.9 robots/bt/driver.cpp:
// update, isAlone, getOffset, filterOverlap, filterBColl and filterSColl.
// Copyright (C) 2002-2004 Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSTrack

extension BTDriver {
    static let sideCollisionMargin: Float = 3
    static let borderOvertakeMargin: Float = 0.5
    static let widthDivisor: Float = 3
    /// The original derives this from a float-cast robot interval, so it is
    /// 0.099999998 rather than a plain 0.1.
    static let overtakeOffsetIncrement: Float = 5*Float(0.02)
    static let maximumIncrementFactor: Float = 5
    static let catchFactor: Float = 10
    static let centreDivisor: Float = 0.1
    static let distanceCutoff: Float = 200
    static let teamRearDistance: Float = 50
    static let teamDamageChangeLead: Int32 = 700

    /// Opponents::update, then isAlone. The caller supplies every other car in a
    /// stable order; the original keeps one Opponent per car for the whole race.
    mutating func updateOpponents(_ car: BTObservation,field: [BTCarState],deltaTime: Float) throws {
        guard field.count==opponents.count else { throw BTError.invalid("Opponent count changed during a race") }
        guard field.allSatisfy(\.valid) else { throw BTError.invalid("Invalid published opponent state") }
        let mine=selfState(car)
        let myData=BTCarData(mine,geometry:road.geometry)
        for index in field.indices {
            opponents[index].update(mine:mine,myData:myData,mySpeed:myData.speed,opponent:field[index],
                data:BTCarData(field[index],geometry:road.geometry),trackLength:road.length,deltaTime:deltaTime)
        }
        // isAlone: a collision risk or a car to let through means not alone.
        alone = !opponents.contains { !$0.state.isDisjoint(with:[.collision,.letPass]) }
    }
    func selfState(_ car: BTObservation) -> BTCarState {
        BTCarState(position:car.position,worldPosition:car.worldPosition,worldVelocity:car.worldVelocity,
            corners:car.corners,yaw:car.yaw,length:length,width:width,distanceFromStart:car.distanceFromStart,
            laps:car.laps,damage:car.damage,flags:0)
    }

    /// If we get lapped, reduce the accelerator.
    func filterOverlap(_ accel: Float) -> Float {
        opponents.contains { $0.state.contains(.letPass) } ? min(accel,0.5):accel
    }

    /// Brake filter for collision avoidance.
    func filterBrakeCollision(_ brake: Float,_ car: BTObservation) -> Float {
        let mu=road.geometry.segments[car.position.segment].surface.friction
        for opponent in opponents where opponent.state.contains(.collision) {
            if brakeDistance(opponent.speed,mu,car)>opponent.distance { return 1 }
        }
        return brake
    }

    /// Steer filter for collision avoidance. Mutating: the original writes the
    /// shared offset here so the target point follows the evasive line.
    mutating func filterSteerCollision(_ steer: Float,_ car: BTObservation) -> Float {
        var nearest: BTOpponent?,minimum=Float.greatestFiniteMagnitude,sideDistance: Float=0
        for opponent in opponents where opponent.state.contains(.side) {
            let magnitude=abs(opponent.sideDistance)
            if magnitude<minimum { minimum=magnitude;nearest=opponent;sideDistance=opponent.sideDistance }
        }
        guard let other=nearest else { return steer }
        let segment=road.geometry.segments[car.position.segment]
        var d=abs(sideDistance)-other.width
        guard d<Self.sideCollisionMargin else { return steer }
        let difference=btNormalized(other.yaw-car.yaw)
        // Near and heading toward the other car.
        guard difference*other.sideDistance<0 else { return steer }
        let c=Self.sideCollisionMargin/2
        d=max(0,d-c)
        var parallel=difference/steerLock
        offset=car.position.toMiddle
        let w=segment.width/Self.widthDivisor-Self.borderOvertakeMargin
        if abs(offset)>w { offset=offset>0 ? w: -w }
        if segment.curve == .straight {
            // Near the middle the car can correct less; the other one more.
            if abs(car.position.toMiddle)>abs(other.toMiddle) { parallel=steer*(d/c)+1.5*parallel*(1-d/c) }
            else { parallel=steer*(d/c)+2*parallel*(1-d/c) }
        } else {
            // Whoever is outside can correct harder without leaving the track.
            let outside=car.position.toMiddle-other.toMiddle
            let sign: Float=segment.curve == .right ? 1: -1
            if outside*sign>0 { parallel=steer*(d/c)+1.5*parallel*(1-d/c) }
            else { parallel=steer*(d/c)+2*parallel*(1-d/c) }
        }
        if parallel*steer>0,abs(steer)>abs(parallel) { return steer }
        return parallel
    }

    /// Offset from the track middle for overtaking or letting a car through.
    mutating func trafficOffset(_ car: BTObservation) -> Float {
        let g=road.geometry
        var minimumCatch=Float.greatestFiniteMagnitude,minimumDistance: Float = -1000
        var chosen: BTOpponent?
        // Speed-dependent increment.
        let reduction=min(abs(car.speed)/Self.maximumIncrementFactor,Self.maximumIncrementFactor-1)
        let increment=Self.maximumIncrementFactor-reduction
        // Let a lapping car, or a less damaged team mate, through.
        for opponent in opponents {
            let letPass=opponent.state.contains(.letPass) && !opponent.teamMate
            let teamOrder=opponent.teamMate && car.damage-opponent.damage>Self.teamDamageChangeLead
                && opponent.distance > -Self.teamRearDistance && opponent.distance < -length
                && car.laps==opponent.laps
            guard letPass || teamOrder else { continue }
            // Behind, so larger distances are more negative.
            if opponent.distance>minimumDistance { minimumDistance=opponent.distance;chosen=opponent }
        }
        if let other=chosen {
            let side=car.position.toMiddle-other.toMiddle
            let w=g.segments[car.position.segment].width/Self.widthDivisor-Self.borderOvertakeMargin
            if side>0 { if offset<w { offset += Self.overtakeOffsetIncrement*increment } }
            else { if offset > -w { offset -= Self.overtakeOffsetIncrement*increment } }
            return offset
        }
        // Overtake.
        chosen=nil
        for opponent in opponents {
            guard opponent.state.contains(.front),!(opponent.teamMate && car.laps<=opponent.laps) else { continue }
            let catchDistance=min(opponent.catchDistance,opponent.distance*Self.catchFactor)
            if catchDistance<minimumCatch { minimumCatch=catchDistance;chosen=opponent }
        }
        guard let other=chosen else {
            // Nothing to overtake: the offset returns slowly to zero.
            if offset>Self.overtakeOffsetIncrement { offset -= Self.overtakeOffsetIncrement }
            else if offset < -Self.overtakeOffsetIncrement { offset += Self.overtakeOffsetIncrement }
            else { offset=0 }
            return offset
        }
        let otherSegment=g.segments[other.segment]
        let w=otherSegment.width/Self.widthDivisor-Self.borderOvertakeMargin
        let otm=other.toMiddle
        let wm=otherSegment.width*Self.centreDivisor
        if otm>wm,offset > -w { offset -= Self.overtakeOffsetIncrement*increment }
        else if otm < -wm,offset<w { offset += Self.overtakeOffsetIncrement*increment }
        else {
            // The opponent is near the middle: move toward the inside of the
            // turn the track is about to make.
            var index=car.position.segment
            var length=distanceToEnd(car),segmentLength=length,previousLength: Float=0
            var left: Float=0,right: Float=0
            let cutoff=min(minimumCatch,Self.distanceCutoff)
            var visited=0
            repeat {
                switch g.segments[index].curve {
                case .left:left += segmentLength
                case .right:right += segmentLength
                case .straight:break
                }
                index=g.segments[index].next
                segmentLength=g.segments[index].length
                previousLength=length
                length += segmentLength
                visited += 1
                guard visited<=g.mainSegments.count else { break }
            } while previousLength<cutoff
            if left==0,right==0 {
                // On a straight: look ahead for the next turn.
                var guardCount=0
                while g.segments[index].curve == .straight,guardCount<=g.mainSegments.count {
                    index=g.segments[index].next;guardCount += 1
                }
                if g.segments[index].curve == .left { left=1 } else { right=1 }
            }
            // Inside, so the border is reachable.
            let maximum=(otherSegment.width-self.width)/2-Self.borderOvertakeMargin
            if left>right { if offset<maximum { offset += Self.overtakeOffsetIncrement*increment } }
            else { if offset > -maximum { offset -= Self.overtakeOffsetIncrement*increment } }
        }
        return offset
    }
}
