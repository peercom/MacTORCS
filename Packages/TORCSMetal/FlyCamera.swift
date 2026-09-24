// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of cGrCarCamRoadFly, TORCS 1.3.9 grcam.cpp.
// Copyright (C) 2000 Eric Espie; original GPL-2.0-or-later attribution retained.
import Foundation
import simd
import TORCSAssets
import TORCSSimulation

/// Original F10 camera motion. Owns a presentation-only random stream so frame
/// rate and camera selection cannot change the authoritative simulation's RNG.
/// A scene-height provider must reproduce grGetHOT; road height is insufficient.
public struct FlyCamera: Sendable {
    public private(set) var eye=SIMD3<Float>.zero,target=SIMD3<Float>.zero,speed=SIMD3<Float>.zero
    public private(set) var currentTime: Double=0
    private(set) var currentCar = -1,timer: Float=0,zOffset: Float=0,gain: Float=0,damping: Float=0
    private(set) var offset=SIMD3<Float>(0,0,60)
    private var random: DarwinRandomStream
    public var randomDraws: UInt64 { random.draws }
    public init(seed: UInt32=12345) throws {
        guard seed<=2147483647 else { throw ACError.invalid("Fly-camera seed exceeds the reference signed range") }
        random=DarwinRandomStream(seed:seed)
    }
    public mutating func select() { timer=0;currentCar = -1 }

    /// Equal timestamps hold all state. The first nonzero timestamp also only
    /// initializes the clock, matching upstream. Invalid input/height rolls back
    /// the complete update, including this camera's random draws.
    public mutating func update(time: Double,carIndex: Int,position: SIMD3<Float>,sceneHeight:(SIMD2<Float>) throws -> Float) throws {
        guard time.isFinite,carIndex>=0,carIndex<=Int(Int32.max),position.x.isFinite,position.y.isFinite,position.z.isFinite else {
            throw ACError.invalid("Invalid fly-camera input")
        }
        var next=self
        try next.advance(time:time,carIndex:carIndex,position:position,sceneHeight:sceneHeight)
        self=next
    }
    private mutating func advance(time: Double,carIndex: Int,position: SIMD3<Float>,sceneHeight:(SIMD2<Float>) throws -> Float) throws {
        if currentTime==0 { currentTime=time }
        if currentTime==time { return }
        var reset=false,dt=Float(time-currentTime)
        currentTime=time
        if abs(dt)>1 { dt=0.1;reset=true }
        if timer<0 { reset=true } else { timer -= dt }
        if currentCar != carIndex { zOffset=50;currentCar=carIndex;reset=true } else { zOffset=0 }
        if timer<=0 || zOffset>0 {
            timer=Float(10+Int(5*nextRandom()))
            offset.x=Float(-0.5+nextRandom());offset.y=Float(-0.5+nextRandom())
            offset.z=Float(10+50*nextRandom()+Double(zOffset))
            offset.x=Float(Double(offset.x)*(Double(offset.z)+1))
            offset.y=Float(Double(offset.y)*(Double(offset.z)+1))
            gain=Float(200/Double(10+offset.z));damping=5
        }
        if reset {
            for i in 0..<3 { eye[i]=Float(Double(position[i])+50+50*nextRandom()) }
            speed = .zero
        }
        for i in 0..<3 {
            speed[i] += (gain*(offset[i]+position[i]-eye[i])-speed[i]*damping)*dt
            eye[i] += speed[i]*dt
        }
        target=position
        guard eye.x.isFinite,eye.y.isFinite,eye.z.isFinite else { throw ACError.invalid("Fly-camera motion overflow") }
        let ground=try sceneHeight(SIMD2(eye.x,eye.y))
        guard ground.isFinite else { throw ACError.invalid("Nonfinite fly-camera scene height") }
        let height=Float(Double(ground)+1)
        if eye.z<height {
            timer=Float(10+Int(10*nextRandom()))
            offset.z=Float(Double(height-position.z)+1)
            eye.z=height
        }
        guard offset.z.isFinite,speed.x.isFinite,speed.y.isFinite,speed.z.isFinite else { throw ACError.invalid("Fly-camera state overflow") }
    }
    private mutating func nextRandom() -> Double {
        _=random.next()
        // Fly uses rand()/(RAND_MAX+1.0), not simuv2's Float scaling.
        return Double(random.state)/2147483648.0
    }
    /// No projection is emitted for upstream's initial eye==target state.
    /// The caller must retain its previous valid view until a real update occurs.
    public func camera(zoom: Float=67.5) throws -> SceneCamera? {
        guard zoom.isFinite,zoom>0,zoom<180 else { throw ACError.invalid("Invalid fly-camera zoom") }
        let fov=zoom * .pi/180
        guard fov>0,(1/tan(fov/2)).isFinite else { throw ACError.invalid("Degenerate fly-camera projection") }
        let d=eye-target
        guard d.x*d.x+d.y*d.y>0 else { return nil }
        return SceneCamera(eye:eye,target:target,fieldOfView:fov,near:1,far:1000,fogRange:SIMD2(500,1000))
    }
}
