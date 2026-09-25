// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 robots/bt/driver.cpp and cardata.cpp.
// Copyright (C) 2002-2004 Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSConfiguration
import TORCSSimulation
import TORCSTrack

/// The published car boundary read by a robot, not the private physics state.
/// Angles and engine speed are radians and rad/s; wheel order is FR, FL, RR, RL.
public struct BTObservation: Sendable {
    public var position: TrackLocalPosition
    public var worldPosition,worldVelocity: SIMD2<Float>
    public var yaw,speed,fuel,rpm,distanceFromStart: Float
    public var wheelSpin: SIMD4<Float>
    public var gear,laps,remainingLaps,lapsBehindLeader: Int
    public var damage: Int32
    public var pitFree: Bool
    /// Original pub.corner world positions: front right, front left, rear right,
    /// rear left. Only the opponent model reads them, so the solo path may omit.
    public var corners: [SIMD2<Float>]
    public init(position: TrackLocalPosition,worldPosition: SIMD2<Float>,worldVelocity: SIMD2<Float>,yaw: Float,speed: Float,
        fuel: Float,rpm: Float,wheelSpin: SIMD4<Float>,gear: Int,laps: Int,remainingLaps: Int,distanceFromStart: Float,
        lapsBehindLeader: Int=0,damage: Int32=0,pitFree: Bool=true,corners: [SIMD2<Float>]=[]) {
        self.position=position;self.worldPosition=worldPosition;self.worldVelocity=worldVelocity;self.yaw=yaw;self.speed=speed
        self.fuel=fuel;self.rpm=rpm;self.wheelSpin=wheelSpin;self.gear=gear;self.laps=laps;self.remainingLaps=remainingLaps
        self.distanceFromStart=distanceFromStart;self.lapsBehindLeader=lapsBehindLeader;self.damage=damage;self.pitFree=pitFree
        self.corners=corners
    }
    public init(published car: VehicleRemovalState,laps: Int,remainingLaps: Int,distanceFromStart: Float) {
        self.init(position:car.trackPosition,worldPosition:SIMD2(car.publicWorld.position.x,car.publicWorld.position.y),
            worldVelocity:SIMD2(car.publicWorld.velocity.x,car.publicWorld.velocity.y),yaw:car.publicBody.orientation.z,
            speed:car.publicBody.velocity.x,fuel:car.publishedFuel,rpm:car.publishedRPM,wheelSpin:car.publishedSpin,
            gear:Int(car.publishedGear),laps:laps,remainingLaps:remainingLaps,distanceFromStart:distanceFromStart,
            damage:car.publishedDamage,pitFree:car.pitOccupant == -1,
            corners:(0..<4).map { SIMD2(car.publishedCorners[$0].x,car.publishedCorners[$0].y) })
    }
}
public struct BTDecision: Sendable {
    public let command: DriverCommand
    public let pitRequested: Bool
}

/// The original BT policy, including its opponent handling: classification,
/// overtaking offsets, collision braking and steering, and letting a faster car
/// through. Own one value per session per car; restarting requires a fresh value
/// (and karma input). Call `drive` with the other cars' published states; the
/// single-argument form is the solo case.
public struct BTDriver: Sendable {
    public let road: TrackRoad
    public let initialFuel: Float
    public private(set) var learning: BTLearning
    public private(set) var calls: UInt64=0
    var strategy: BTStrategy,pit: BTPit
    let mass,ca,cw,tireMu,muFactor,width,redline,tank: Float
    public let steerLock: Float
    /// The original _dimension_x, which the opponent model compares lengths with.
    public let length: Float
    /// One entry per other car, in the order the caller supplies them. The
    /// original keeps these for the whole race because the overlap timer is
    /// stateful.
    public internal(set) var opponents: [BTOpponent]
    public internal(set) var alone=true
    let radii: [Float],wheelRadius: SIMD4<Float>,ratios: [Float],layout: DriveLayout
    /// The original myoffset: the lateral offset from the track middle the
    /// overtaking and collision logic steers to. Readable for diagnostics.
    public internal(set) var offset: Float=0
    var oldLookahead: Float=0,clutchTime: Float=0
    var stuck=0
    /// `fieldSize` is the number of cars in the race, including this one. The
    /// original builds one Opponent per other car when the race starts.
    public init(road: TrackRoad,parameters p: ParameterDocument,setup: ParameterDocument?=nil,totalLaps: Int,
        driverIndex: Int=0,pitStall: Int?=nil,karma: Data?=nil,fieldSize: Int=1) throws {
        guard (1...10000).contains(totalLaps),(0..<10).contains(driverIndex),road.length>0,
              (1...16).contains(fieldSize) else { throw BTError.invalid("Invalid BT race configuration") }
        self.road=road
        let definition=try VehicleDynamicsDefinition(parameters:p)
        func n(_ section: String,_ key: String,_ fallback: Float) -> Float { p.section(section)?.number(key,default:fallback) ?? fallback }
        mass=n("Car","mass",1000);width=definition.chassis.runningGear.mass.dimensions.y
        length=definition.chassis.runningGear.mass.dimensions.x
        opponents=Array(repeating:BTOpponent(),count:max(0,fieldSize-1))
        steerLock=definition.controls.steeringLock;redline=definition.engine.limiter;tank=definition.chassis.runningGear.mass.tankCapacity
        layout=definition.transmission.layout;ratios=definition.transmission.gears.map(\.ratio)
        wheelRadius=SIMD4(definition.chassis.runningGear.wheels[0].force.radius,definition.chassis.runningGear.wheels[1].force.radius,
            definition.chassis.runningGear.wheels[2].force.radius,definition.chassis.runningGear.wheels[3].force.radius)
        muFactor=setup?.section("bt private")?.number("mufactor",default:0.69) ?? 0.69
        let wheels=["Front Right Wheel","Front Left Wheel","Rear Right Wheel","Rear Left Wheel"]
        var h: Float=0,mu=Float.greatestFiniteMagnitude
        for w in wheels { h += n(w,"ride height",0.2);mu=min(mu,n(w,"mu",1)) }
        tireMu=mu
        let wing=1.23*n("Rear Wing","area",0)*sin(n("Rear Wing","angle",0))
        let cl=n("Aerodynamics","front Clift",0)+n("Aerodynamics","rear Clift",0)
        h *= 1.5;h=h*h;h=h*h;h=2*exp(-3*h)
        ca=h*cl+4*wing;cw=0.645*n("Aerodynamics","Cx",0)*n("Aerodynamics","front area",0)
        guard [mass,width,steerLock,redline,tank,tireMu,muFactor,ca,cw].allSatisfy(\.isFinite),mass>0,steerLock>0,redline>0,tireMu>0,muFactor>0 else { throw BTError.invalid("Invalid BT car parameters") }
        radii=try Self.computeRadii(road.geometry)
        learning=try BTLearning(road:road,karma:karma)
        strategy=try BTStrategy(setup:setup,length:road.length,laps:totalLaps,index:driverIndex)
        initialFuel=strategy.initialFuel
        pit=try BTPit(road:road,stall:pitStall)
    }
    static func computeRadii(_ g: TrackGeometry) throws -> [Float] {
        guard let last=g.mainSegments.last,g.mainSegments.contains(where:{g.segments[$0].curve != .straight}),
              Set(g.mainSegments.map { g.segments[$0].upstreamID })==Set(0..<g.mainSegments.count) else { throw BTError.invalid("BT requires a closed track with a turn and contiguous segment IDs") }
        var result=Array(repeating:Float(0),count:g.mainSegments.count),lastArc: Float=0,lastType=TrackCurve.straight,i=last
        repeat {
            let s=g.segments[i]
            if s.curve == .straight { lastType = .straight;result[s.upstreamID] = .greatestFiniteMagnitude }
            else {
                if s.curve != lastType {
                    var arc: Float=0,j=i,visited=0;lastType=s.curve
                    while g.segments[j].curve == lastType && Double(arc)<Double.pi/2 {
                        arc += g.segments[j].arc;j=g.segments[j].next;visited += 1
                        guard visited<=g.mainSegments.count else { throw BTError.invalid("Degenerate BT turn") }
                    }
                    lastArc=Float(Double(arc)/(Double.pi/2))
                }
                result[s.upstreamID]=Float((Double(s.radius)+Double(s.width)/2)/Double(lastArc))
            }
            i=s.next
        } while i != last
        return result
    }
    /// `field` is every other car's published state, in a stable order the caller
    /// keeps for the whole race. The defaults are the solo case, which leaves the
    /// opponent paths inert.
    public mutating func drive(_ car: BTObservation,field: [BTCarState] = [],
                               deltaTime: Double = 0.02) throws -> BTDecision {
        let p=car.position,g=road.geometry
        guard g.segments.indices.contains(p.segment),g.segments[p.segment].role == .main,(-1...8).contains(car.gear),
            [p.toStart,p.toMiddle,car.yaw,car.speed,car.fuel,car.rpm,car.distanceFromStart,car.worldPosition.x,car.worldPosition.y,
             car.worldVelocity.x,car.worldVelocity.y,car.wheelSpin.x,car.wheelSpin.y,car.wheelSpin.z,car.wheelSpin.w].allSatisfy(\.isFinite),abs(car.speed)<1000 else { throw BTError.invalid("Invalid published BT observation") }
        calls += 1
        let segment=g.segments[p.segment],angle=btNormalized(g.tangent(p)-car.yaw)
        let speedAngle=btNormalized(g.tangent(p)-atan2(car.worldVelocity.y,car.worldVelocity.x))
        try updateOpponents(car,field:field,deltaTime:Float(deltaTime))
        strategy.update(car,id:segment.upstreamID,tank:tank)
        if !pit.requested { pit.setRequested(strategy.needsPit(car,assigned:pit.stall != nil),distance:car.distanceFromStart) }
        pit.update(distance:car.distanceFromStart)
        learning.update(car,geometry:g,offset:offset,outside:segment.width/3-0.5,base:radii,alone:alone)
        if abs(angle)>Float(Double(Float(15)/180)*Double.pi),car.speed<5,abs(p.toMiddle)>3 {
            if stuck>100,p.toMiddle*angle<0 { return BTDecision(command:.init(throttle:1,steering:-angle/steerLock,gear:-1),pitRequested:pit.requested) }
            stuck += 1
        } else { stuck=0 }
        let target=targetPoint(car)
        var steering=btNormalized(atan2(target.y-car.worldPosition.y,target.x-car.worldPosition.x)-car.yaw)/steerLock
        steering=filterSteerCollision(steering,car)
        let gear=gear(car)
        var brake=brake(car)
        brake=try pitBrake(brake,car)
        brake=filterBrakeCollision(brake,car)
        let weight=(mass+car.fuel)*9.81
        brake=brake*(weight+ca*(car.speed*car.speed))/(weight+ca*84*84)
        if car.speed>=3 {
            var spin: Float=0
            for i in 0..<4 { spin += car.wheelSpin[i]*wheelRadius[i] }
            let slip=car.speed-spin/4
            if slip>2 { brake -= min(brake,(slip-2)/5) }
        }
        var throttle: Float=0
        if brake==0 {
            let allowed=allowedSpeed(segment,car)
            throttle=car.gear<=0 || allowed>car.speed+1 ? 1:allowed/wheelRadius.z*ratios[car.gear+1]/redline
            throttle=filterOverlap(throttle)
            if !(car.speed<5 || pit.inLane || p.toMiddle*speedAngle>0) {
                if segment.curve == .straight { if abs(p.toMiddle)>(segment.width-width)/2 { throttle=0 } }
                else if p.toMiddle*(segment.curve == .right ? -1:1)<=0,abs(p.toMiddle)>segment.width/3 { throttle=0 }
            }
            let spin: Float
            switch layout {
            case .rear: spin=(car.wheelSpin.z+car.wheelSpin.w)*wheelRadius.w/2
            case .front: spin=(car.wheelSpin.x+car.wheelSpin.y)*wheelRadius.y/2
            case .all: spin=((car.wheelSpin.x+car.wheelSpin.y)*wheelRadius.y+(car.wheelSpin.z+car.wheelSpin.w)*wheelRadius.w)/4
            }
            if spin-car.speed>2 { throttle -= min(throttle,(spin-car.speed-2)/10) }
        }
        let clutch=clutch(car,requestedGear:gear,throttle:throttle)
        return BTDecision(command:.init(throttle:throttle,brake:brake,steering:steering,clutch:clutch,gear:gear),pitRequested:pit.requested)
    }
    public mutating func pitCommand(_ car: BTObservation) -> (fuel: Float,repair: Int32) {
        let fuel=strategy.refuel(car,tank:tank);pit.setRequested(false,distance:car.distanceFromStart)
        return (fuel,car.damage)
    }
    func allowedSpeed(_ s: TrackSegment,_ car: BTObservation) -> Float {
        let mu=s.surface.friction*tireMu*muFactor,dr=learning.radius[s.upstreamID]
        var r=radii[s.upstreamID]
        r += dr<0 ? dr:dr*(1-min(1,abs(offset)*2/s.width));r=max(1,r)
        return sqrt((mu*9.81*r)/(1-min(1,r*ca*mu/(mass+car.fuel))))
    }
    func distanceToEnd(_ car: BTObservation) -> Float {
        let s=road.geometry.segments[car.position.segment]
        return s.curve == .straight ? s.length-car.position.toStart:(s.arc-car.position.toStart)*s.radius
    }
    func brakeDistance(_ speed: Float,_ mu: Float,_ car: BTObservation) -> Float {
        let c=mu*9.81,d=(ca*mu+cw)/(mass+car.fuel),v1=car.speed*car.speed,v2=speed*speed
        return -log((c+v2*d)/(c+v1*d))/(2*d)
    }
    func brake(_ car: BTObservation) -> Float {
        if car.speed < -5 { return 1 }
        let g=road.geometry,s=g.segments[car.position.segment],mu=s.surface.friction
        let lookahead=car.speed*car.speed/(2*mu*9.81),allowed=allowedSpeed(s,car)
        if allowed<car.speed { return min(1,car.speed-allowed) }
        var distance=distanceToEnd(car),i=s.next
        while distance<lookahead {
            let seg=g.segments[i],allowed=allowedSpeed(seg,car)
            if allowed<car.speed,brakeDistance(allowed,mu,car)>distance { return 1 }
            distance += seg.length;i=seg.next
        }
        return 0
    }
    func gear(_ car: BTObservation) -> Int {
        if car.gear<=0 { return 1 }
        if redline/ratios[car.gear+1]*wheelRadius.z*0.9<car.speed { return car.gear+1 }
        if car.gear>1,redline/ratios[car.gear]*wheelRadius.z*0.9>car.speed+4 { return car.gear-1 }
        return car.gear
    }
    mutating func clutch(_ car: BTObservation,requestedGear: Int,throttle: Float) -> Float {
        if car.gear>1 { clutchTime=0;return 0 }
        let drpm=car.rpm-redline/2
        clutchTime=min(2,clutchTime);let timed=(2-clutchTime)/2
        if car.gear==1,throttle>0 { clutchTime += 0.02 }
        if drpm>0 {
            if requestedGear==1 {
                let omega=redline/ratios[car.gear+1],speed=(5+max(0,car.speed))/abs(wheelRadius.z*omega)
                return min(timed,max(0,1-speed*2*drpm/redline))
            }
            clutchTime=0;return 0
        }
        return timed
    }
    mutating func targetPoint(_ car: BTObservation) -> SIMD2<Float> {
        let g=road.geometry
        var length=distanceToEnd(car),i=car.position.segment
        offset=trafficOffset(car)
        var lookahead: Float
        if pit.inLane { lookahead=car.speed*car.speed>pit.speedLimit*pit.speedLimit ? 6+car.speed*0.33:6 }
        else { lookahead=max(17+car.speed*0.33,Float(Double(oldLookahead)-Double(car.speed)*0.02)) }
        oldLookahead=lookahead
        while length<lookahead { i=g.segments[i].next;length += g.segments[i].length }
        let s=g.segments[i]
        length=lookahead-length+s.length
        offset=pit.offset(offset,fromStart:s.distanceFromStart+length)
        let start=SIMD2((s.startLeft.x+s.startRight.x)/2,(s.startLeft.y+s.startRight.y)/2)
        if s.curve == .straight {
            var n=SIMD2((s.endLeft.x-s.endRight.x)/s.length,(s.endLeft.y-s.endRight.y)/s.length)
            n /= sqrt(n.x*n.x+n.y*n.y)
            let d=SIMD2((s.endLeft.x-s.startLeft.x)/s.length,(s.endLeft.y-s.startLeft.y)/s.length)
            return start+d*length+offset*n
        }
        let c=SIMD2(s.center.x,s.center.y),sign:Float=s.curve == .right ? -1:1,arc=length/s.radius*sign
        let d=start-c,sina=sin(arc),cosa=cos(arc)
        let rotated=c+SIMD2(d.x*cosa-d.y*sina,d.x*sina+d.y*cosa)
        var n=c-rotated;n /= sqrt(n.x*n.x+n.y*n.y)
        return rotated+sign*offset*n
    }
    mutating func pitBrake(_ brake: Float,_ car: BTObservation) throws -> Float {
        let mu=road.geometry.segments[car.position.segment].surface.friction*tireMu*0.4
        if pit.requested && !pit.inLane,let d=try road.distanceToPit(from:car.position,stall:pit.stall),d.x<200,brakeDistance(0,mu,car)>d.x { return 1 }
        if pit.inLane {
            let s=pit.coordinate(car.distanceFromStart),squared=car.speed*car.speed
            if pit.requested {
                if s<pit.x[1] { if brakeDistance(pit.speedLimit,mu,car)>pit.x[1]-s { return 1 } }
                else if squared>pit.speedLimit*pit.speedLimit { return pit.speedBrake(squared) }
                let distance=pit.x[3]-s
                if pit.timeout(distance:distance,speed:car.speed) { pit.setRequested(false,distance:car.distanceFromStart);return 0 }
                if brakeDistance(0,mu,car)>distance || s>pit.x[3] { return 1 }
            } else if s<pit.x[5],squared>pit.speedLimit*pit.speedLimit { return pit.speedBrake(squared) }
        }
        return brake
    }
}
func btNormalized(_ input: Float) -> Float {
    var angle=input
    while Double(angle)>Double.pi { angle -= Float(2*Double.pi) }
    while Double(angle)<(-Double.pi) { angle += Float(2*Double.pi) }
    return angle
}
public enum BTError: Error { case invalid(String) }
