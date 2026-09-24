// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of grscene.cpp background geometry and grcam.cpp background camera.
// Copyright (C) 2000 Eric Espie, 2001 Christophe Guionneau; upstream GPL-2.0-or-later.
import simd

public enum TrackBackground {
    /// Original types 0 (repeated cylinder), 2 (four atlas strips), 4 (panorama).
    /// Other types draw only the configured clear color, as upstream does.
    public static func strips(type: Int) -> [[ShadowVertex]] {
        guard [0,2,4].contains(type) else { return [] }
        return (0..<(type==2 ? 4:1)).map { strip in
            let range=type==2 ? (strip*9...(strip+1)*9):(0...36)
            return range.flatMap { i -> [ShadowVertex] in
                let angle=Float(Double(i)*2 * .pi/36)
                let x=cos(angle),y=sin(angle)
                let u=type==4 ? Float(1-Double(Float(i)/36)):Float(i)/36*4
                let bottom:Float=type==4 ? -1:-0.5
                let v:Float=type==2 ? Float(strip%2)*0.5:0
                return [ShadowVertex(position:SIMD4(x,y,bottom,1),uv:SIMD4(u,v,0,0)),
                        ShadowVertex(position:SIMD4(x,y,1,1),uv:SIMD4(u,type==2 ? v+0.5:1,0,0))]
            }
        }
    }
    public static func camera(for camera: SceneCamera) -> SceneCamera {
        SceneCamera(eye:.zero,target:camera.target-camera.eye,fieldOfView:max(camera.fieldOfView,60 * .pi/180),near:0.1,far:2000,up:camera.up)
    }
}
