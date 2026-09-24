// SPDX-License-Identifier: GPL-2.0-only
// Selected perspective/zero-radius port of PLIB sgFrustum::contains/update.
// Copyright (C) 1998,2002 Steve Baker. LGPL-2.0-or-later portions converted
// to GPL v2 under LGPL v2 section 3, effective 2026-09-23; originals in Upstream.
import simd
import TORCSAssets

struct CarLightFrustum {
    let near,far: Float
    let horizontal,vertical: SIMD2<Float>
    init(camera: SceneCamera,aspect: Float) throws {
        let range=camera.clippingRange
        try self.init(near:range.x,far:range.y,right:range.x*tan(camera.fieldOfView/2)*aspect,top:range.x*tan(camera.fieldOfView/2))
    }
    init(near: Float,far: Float,right: Float,top: Float) throws {
        guard [near,far,right,top].allSatisfy(\.isFinite),near>0,far>near,right>0,top>0 else { throw ACError.invalid("Invalid light frustum") }
        self.near=near;self.far=far
        let x=2*near/(2*right),y=2*near/(2*top)
        let ix:Float=1/sqrt(x*x+1),iy:Float=1/sqrt(y*y+1)
        horizontal=SIMD2(x*ix,-ix);vertical=SIMD2(y*iy,-iy)
    }
    func contains(_ p: SIMD3<Float>,view: simd_float4x4) -> Bool {
        func coordinate(_ i: Int)->Float { p.x*view[0][i]+p.y*view[1][i]+p.z*view[2][i]+view[3][i] }
        let x=coordinate(0),y=coordinate(1),z=coordinate(2)
        guard -z>=near,-z<=far else { return false }
        return horizontal.x*x+horizontal.y*z>=0 && -horizontal.x*x+horizontal.y*z>=0 && vertical.x*y+vertical.y*z>=0 && -vertical.x*y+vertical.y*z>=0
    }
}

/// Original car/light anchor order. Lights are not sorted by distance.
public struct SceneCarLight: Sendable {
    public let carIndex: Int
    public let light: CarLightInstance
    public init(carIndex: Int,light: CarLightInstance) { self.carIndex=carIndex;self.light=light }
}
