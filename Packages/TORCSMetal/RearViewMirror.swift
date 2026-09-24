// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS grcam/grscreen mirror camera and layout.
// Copyright (C) 2000 Eric Espie; upstream GPL-2.0-or-later.
import simd
import TORCSAssets

public struct RearViewMirror: Sendable {
    public let body: simd_float4x4
    public let bonnetPosition: SIMD3<Float>
    /// Instance indices belonging to the current car, including its wheels.
    public let hiddenInstances: Set<Int>
    public let currentCar: Int
    public init(body: simd_float4x4,bonnetPosition: SIMD3<Float>,hiddenInstances: Set<Int>,currentCar: Int=0) {
        self.body=body;self.bonnetPosition=bonnetPosition;self.hiddenInstances=hiddenInstances;self.currentCar=currentCar
    }
    public func camera(width: Int,height: Int) throws -> SceneCamera {
        let aspect=Float(width)/Float(height)
        guard width>=2,height>=6,aspect>0.5 else { throw ACError.invalid("Rear-view mirror requires an aspect ratio greater than 1:2") }
        let eye=body*SIMD4(bonnetPosition,1),target=body*SIMD4(bonnetPosition-SIMD3(30,0,0),1)
        let degrees=Float(90.0/Double(aspect))
        return SceneCamera(eye:SIMD3(eye.x,eye.y,eye.z),target:SIMD3(target.x,target.y,target.z),fieldOfView:degrees * .pi/180,near:0.3,far:300,up:SIMD3(body[2].x,body[2].y,body[2].z),fogRange:SIMD2(200,300))
    }
}

/// Original integer pixel rectangles, converted from GL bottom-up to Metal top-down.
struct MirrorLayout {
    let width,height,x,y,sourceX,sourceY: Int
    init(width w: Int,height h: Int) {
        width=w/2;height=h/6;x=w/4;y=h-(5*h/6-h/10+height)
        sourceX=(w-width)/2;sourceY=h-((h-height)/2+height)
    }
}
