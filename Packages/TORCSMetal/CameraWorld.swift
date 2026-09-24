// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS grscene world dimensions and grcam F6/F7 cameras.
// Copyright (C) 2000 Eric Espie, 2001 Christophe Guionneau; upstream GPL-2.0-or-later.
import simd
import TORCSAssets

public struct CameraWorld: Sendable {
    let x,y,z,maximum: Int
    public init(bounds: SIMD3<Float>) throws {
        let values=[bounds.x,bounds.y,bounds.z]
        guard values.allSatisfy({ $0.isFinite && $0>=0 && $0<46340 }) else { throw ACError.invalid("Unsupported camera world bounds") }
        x=Int(bounds.x+1);y=Int(bounds.y+1);z=Int(bounds.z+1)
        // The original panoramic factory squares and sums signed 32-bit ints.
        guard x*x+y*y<=Int(Int32.max) else { throw ACError.invalid("Camera world dimensions exceed original integer arithmetic") }
        maximum=max(x,y,z)
    }
    func tracksideCamera(zoomed: Bool, position: SIMD3<Float>?, carPosition: SIMD3<Float>,zoomValue: Float=9) -> SceneCamera {
        let eye = position ?? SIMD3(Float(Double(x)*0.5),Float(Double(y)*0.6),120)
        if !zoomed {
            var target = carPosition
            if position != nil { target.z = eye.z }
            return SceneCamera(eye:eye,target:target,fieldOfView:30 * .pi/180,near:1,far:1000,fogRange:SIMD2(500,1000))
        }
        let dx=carPosition.x-eye.x,dy=carPosition.y-eye.y,dz=carPosition.z-eye.z
        let distance=sqrt(dx*dx+dy*dy+dz*dz)
        // Original limitFov is empty: factory min/max do not clamp this update.
        let degrees=Float(Double(atan2(zoomValue,distance))*(180/Double.pi))
        return SceneCamera(eye:eye,target:carPosition,fieldOfView:degrees * .pi/180,near:max(1,dz-5),far:distance+1000,fogRange:SIMD2(500,1000))
    }
    func camera(preset: DrivingCameraPreset,carPosition: SIMD3<Float>) -> SceneCamera {
        if preset == .circuit {
            let eye=SIMD3(Float(Double(x)*0.5),Float(Double(y)*0.6),Float(120))
            let dx=carPosition.x-eye.x,dy=carPosition.y-eye.y,dz=carPosition.z-eye.z
            let distance=sqrt(dx*dx+dy*dy+dz*dz)
            let degrees=Float(Double(atan2(Float(21),distance))*(180/Double.pi))
            return SceneCamera(eye:eye,target:carPosition,fieldOfView:degrees * .pi/180,near:max(1,dz-5),far:distance+1500,fogRange:SIMD2(10500,20500))
        }
        let eye,target,up:SIMD3<Float>
        if preset == .panorama1 {
            eye=SIMD3(Float(x/2),Float(y/2),Float(max(x/2,y*4/3/2)+z))
            target=SIMD3(Float(x/2),Float(y/2),0);up=SIMD3(0,1,0)
        } else {
            let right=preset == .panorama4 || preset == .panorama5
            let top=preset == .panorama3 || preset == .panorama4
            eye=SIMD3(right ? Float(x)*3/2:-Float(x)/2,top ? Float(y)*3/2:-Float(y)/2,Float(0.25*sqrt(Double(x*x+y*y))))
            target=SIMD3(Float(x)/2,Float(y)/2,0);up=SIMD3(0,0,1)
        }
        var camera=SceneCamera(eye:eye,target:target,fieldOfView:74 * .pi/180,near:10,far:Float(maximum*2),up:up,fogRange:SIMD2(Float(maximum*10),Float(maximum*20)))
        camera.drawsBackground=false;return camera
    }
}
