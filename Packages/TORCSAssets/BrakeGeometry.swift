// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of initWheel hub/disc/caliper geometry in TORCS 1.3.9 grcar.cpp.
// Copyright (C) 2000 Eric Espie; upstream GPL-2.0-or-later.
import Foundation
import CryptoKit

/// Original non-spinning brake geometry, attached below wheel position/steering
/// and above the separate spinning wheel transform. No texture resources needed.
public struct BrakeGeometry: Sendable {
    /// Hub, heat-colored disc, caliper, in original child order.
    public let parts: [LoadedScene]
    public init(wheel: Int,radius: Float,width: Float) throws {
        guard (0..<4).contains(wheel),radius.isFinite,width.isFinite,radius>0,width>0 else { throw ACError.invalid("Invalid brake geometry dimensions or wheel index") }
        let angle=Float(wheel<2 ? -(Double.pi/2+2*Double.pi/16):(Double.pi/2-2*Double.pi/16))
        let offset=Float(wheel%2==0 ? 0.2-Double(width)/2:Double(width)/2-0.2)
        let normal:[Float]=[0,wheel%2==0 ? -1:1,0]
        var vertices:[[Float]]=[[],[],[]]
        let hub=Float(Double(radius)*0.6)
        vertices[0] += [0,offset,0]
        for i in 0..<16 {
            let alpha=Float(Double(i)*2*Double.pi/15)
            vertices[0] += [hub*cos(alpha),offset,hub*sin(alpha)]
        }
        for part in 1...2 {
            for i in 0..<(part==1 ? 10:6) {
                let alpha=Float(Double(part==1 ? angle:-angle)+Double(i)*2*Double.pi/15)
                let c=cos(alpha),s=sin(alpha)
                let x=part==1 ? radius*c:Float((Double(radius)+0.02)*Double(c))
                let z=part==1 ? radius*s:Float((Double(radius)+0.02)*Double(s))
                vertices[part] += [x,offset,z,Float(Double(radius*c)*0.6),offset,Float(Double(radius*s)*0.6)]
            }
        }
        let names=["hub","disc","caliper"],colors:[Float]=[0,0.1,0.2]
        var result:[LoadedScene]=[]
        for part in 0..<3 {
            let state=ACRenderState(material:Array(repeating:0,count:13),texture:nil,flags:part==1 ? 0:4,alphaClamp:0,alphaCare:0)
            let mesh=ACMesh(primitive:part==0 ? 6:5,vertices:vertices[part],normals:normal,uv:Array(repeating:[],count:4),colors:[colors[part],colors[part],colors[part],1],indices:[],strips:[],indexed:false,cull:false,mapCount:1,mapLevel:0,states:[state,nil,nil,nil])
            let scene=ACScene(nodes:[ACNode(parent:-1,kind:1,name:"Brake \(names[part])",matrix:[],mesh:nil),ACNode(parent:0,kind:2,name:names[part],matrix:[],mesh:mesh)])
            try scene.validate()
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            let hash=SHA256.hash(data:try encoder.encode(scene)).map { String(format:"%02x",$0) }.joined()
            let asset=ACCompiledAsset(scene:scene,sourceSHA256:hash,cacheKey:"generated-brake-1-"+hash,options:.init())
            result.append(LoadedScene(asset:asset,textures:[:],source:"generated:TORCS/initWheel/\(wheel)/\(names[part])"))
        }
        parts=result
    }
}
