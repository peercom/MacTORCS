// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 robots/bt/pit.cpp and spline.cpp.
// Copyright (C) 2003-2004 Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSTrack

struct BTPit: Sendable {
    let stall: Int?,length: Float,speedLimit: Float,originalLimit: Float,entry: Float,exit: Float
    var x: [Float],y: [Float]
    var requested=false,inLane=false,timer: Float=0
    init(road: TrackRoad,stall: Int?) throws {
        self.stall=stall;length=road.length
        let pits=road.pits,g=road.geometry
        guard let stall else { speedLimit=0;originalLimit=0;entry=0;exit=0;x=[];y=[];return }
        guard pits.positions.indices.contains(stall),let e=pits.entry,let s=pits.start,let n=pits.end,let z=pits.exit else { throw BTError.invalid("Invalid BT pit assignment") }
        speedLimit=pits.speedLimit-0.5;originalLimit=pits.speedLimit
        let p=pits.positions[stall],at=g.segments[p.segment].distanceFromStart+p.toStart
        entry=g.segments[e].distanceFromStart;exit=g.segments[z].distanceFromStart+g.segments[z].length
        let origin=entry,trackLength=length
        x=[entry,g.segments[s].distanceFromStart,at-pits.stallLength,at,at+pits.stallLength,
            g.segments[n].distanceFromStart+g.segments[n].length,exit].map { value in
            var v=value-origin;while v<0 { v += trackLength };return v
        }
        if x[6]<x[5] { x[6]=Float(Double(x[5])+50) }
        if x[1]>x[2] { x[1]=x[2] };if x[4]>x[5] { x[5]=x[4] }
        let sign: Float=pits.side == .left ? 1:-1,middle=abs(pits.positions[0].toMiddle)
        y=Array(repeating:(middle-pits.laneWidth)*sign,count:7);y[0]=0;y[6]=0;y[3]=middle*sign
    }
    func coordinate(_ distance: Float) -> Float { var x=distance-entry;while x<0 { x += length };return x }
    func between(_ distance: Float) -> Bool { entry<=exit ? distance>=entry && distance<=exit:distance<=exit || distance>=entry }
    mutating func setRequested(_ value: Bool,distance: Float) {
        guard stall != nil else { return }
        if !between(distance) { requested=value } else if !value { requested=false;timer=0 }
    }
    mutating func update(distance: Float) {
        guard stall != nil else { return }
        if between(distance) { if requested { inLane=true } } else { inLane=false }
    }
    func offset(_ value: Float,fromStart: Float) -> Float {
        guard stall != nil,inLane || (requested && between(fromStart)) else { return value }
        let z=coordinate(fromStart);var a=0,b=6
        repeat { let i=(a+b)/2;if x[i]<=z { a=i } else { b=i } } while a+1 != b
        let h=x[a+1]-x[a],t=(z-x[a])/h,a0=y[a],a1=y[a+1]-a0,a2=a1-h*0
        var a3=h*0-a1;a3 -= a2
        return a0+(a1+(a2+a3*t)*(t-1))*t
    }
    mutating func timeout(distance: Float,speed: Float) -> Bool {
        if speed>1 || distance>3 || !requested { timer=0;return false }
        timer += 0.02
        if timer>3 { timer=0;return true };return false
    }
    func speedBrake(_ squared: Float) -> Float { (squared-speedLimit*speedLimit)/(originalLimit*originalLimit-speedLimit*speedLimit) }
}
