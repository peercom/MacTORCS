// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of grInitShadow/grDrawShadow, TORCS 1.3.9 grcar.cpp.
// Copyright (C) 2000 Eric Espie; original GPL-2.0-or-later.
import simd
import TORCSAssets

public struct ShadowVertex: Sendable {
    public let position: SIMD4<Float>
    public let uv: SIMD4<Float>
}
/// Original six-vertex strip, projected onto the track at every vertex.
/// Immutable local footprint; only six transformed positions change each frame.
public struct CarShadow: Sendable {
    private let local: [ShadowVertex]
    public init(dimensions: SIMD2<Float>) throws {
        guard dimensions.x.isFinite,dimensions.y.isFinite,dimensions.x>0,dimensions.y>0 else { throw ACError.invalid("Invalid shadow dimensions") }
        var vertices:[ShadowVertex]=[],x=Float(Double(dimensions.x)*1.1/2)
        for i in 0..<3 {
            for side in 0..<2 {
                let y=Float(Double(dimensions.y)*(side==0 ? -1.1:1.1)/2)
                vertices.append(ShadowVertex(position:SIMD4(x,y,0,1),uv:SIMD4(1-Float(i)/2,Float(side),0,0)))
            }
            x=Float(Double(x)-Double(dimensions.x)*1.1/4*2)
        }
        local=vertices
    }
    public func project(body: simd_float4x4,groundHeight:(SIMD2<Float>) throws -> Float) rethrows -> [ShadowVertex] {
        try local.map { vertex in
            var p=body*vertex.position
            p.z=try groundHeight(SIMD2(p.x,p.y))
            return ShadowVertex(position:p,uv:vertex.uv)
        }
    }
}
