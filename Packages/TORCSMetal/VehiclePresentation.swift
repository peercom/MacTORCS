// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 grcar.cpp wheel placement and update.
// Copyright (C) 2000 Eric Espie; original GPL-2.0-or-later attribution retained.
import simd
import TORCSSimulation
import TORCSAssets

public struct PresentedWheel: Sendable {
    public let transform,brakeTransform: simd_float4x4
    public let level: Int
    public let brakeColor: SIMD3<Float>
}
public struct VehiclePresentation: Sendable {
    public let body: simd_float4x4
    public let wheels: FourWheels<PresentedWheel>
    public init(_ snapshot: VehicleVisualSnapshot) throws {
        let bodyMatrix=Self.matrix(snapshot.body);body=bodyMatrix
        func wheel(_ i: Int) throws -> PresentedWheel {
            let w=snapshot.wheels[i],p=w.pose.position,a=w.pose.orientation
            guard [p.x,p.y,p.z,a.x,a.y,a.z,w.spin,w.radius,w.width,w.brakeTemperature,w.brakeRadius].allSatisfy(\.isFinite),w.radius>0,w.width>0,w.brakeRadius>0 else { throw ACError.invalid("Invalid wheel presentation snapshot") }
            let position=Self.matrix(CollisionTransform(position:p,orientation:SIMD3(a.x,0,a.z)))
            let rotation=Self.matrix(CollisionTransform(position:.zero,orientation:SIMD3(0,a.y,0)))
            let flip=Self.matrix(CollisionTransform(position:.zero,orientation:SIMD3(0,0,i%2==0 ? Float.pi:0)))
            let scale=simd_float4x4(diagonal:SIMD4(w.radius*2,w.width,w.radius*2,1))
            let level=abs(w.spin)<20 ? 0:abs(w.spin)<40 ? 1:abs(w.spin)<70 ? 2:3
            let t=Double(w.brakeTemperature)
            return PresentedWheel(transform:bodyMatrix*position*rotation*flip*scale,brakeTransform:bodyMatrix*position,level:level,
                brakeColor:SIMD3(Float(0.1+t*1.5),Float(0.1+t*0.3),Float(0.1-t*0.3)))
        }
        wheels=try FourWheels(wheel(0),wheel(1),wheel(2),wheel(3))
    }
    public static func matrix(_ transform: CollisionTransform) -> simd_float4x4 {
        let r=transform.rotation
        return simd_float4x4(SIMD4(r.toWorld(SIMD3(1,0,0)),0),SIMD4(r.toWorld(SIMD3(0,1,0)),0),SIMD4(r.toWorld(SIMD3(0,0,1)),0),SIMD4(transform.position,1))
    }
}

extension VehiclePresentation {
    /// Body and four selected wheel meshes share immutable GPU resources.
    public func instances(bodyResource: Int,wheelResources: [Int],reflection: CarReflection? = nil,drawDriver: Bool=true,brakeResources: [Int]?=nil,carIndex:Int=0) throws -> [SceneInstance] {
        guard wheelResources.count==4 else { throw ACError.invalid("Four wheel speed resources required") }
        guard brakeResources == nil || brakeResources?.count==12 else { throw ACError.invalid("Twelve hub/disc/caliper resources required") }
        let car=SceneCarPlacement(index:carIndex,position:SIMD3(body[3].x,body[3].y,body[3].z))
        var instances=[SceneInstance(resource:bodyResource,transform:body,reflection:reflection,hidesDriver:!drawDriver,car:car)]
        for i in 0..<4 {
            if let brakeResources {
                for part in 0..<3 {
                    instances.append(SceneInstance(resource:brakeResources[i*3+part],transform:wheels[i].brakeTransform,colorOverride:part==1 ? SIMD4(wheels[i].brakeColor,1):nil,car:car))
                }
            }
            instances.append(SceneInstance(resource:wheelResources[wheels[i].level],transform:wheels[i].transform,reflection:reflection,car:car))
        }
        return instances
    }
}

extension VehiclePresentation {
    private init(body: simd_float4x4,wheels: FourWheels<PresentedWheel>) { self.body=body;self.wheels=wheels }
    /// Presentation interpolation only: neither endpoint nor physics is mutated.
    /// Endpoint matrices remain exact; interior rotations follow the shortest arc.
    public static func interpolate(previous: VehiclePresentation,current: VehiclePresentation,alpha: Float) throws -> VehiclePresentation {
        guard alpha.isFinite,(0...1).contains(alpha) else { throw ACError.invalid("Invalid presentation interpolation") }
        if alpha==0 { return previous };if alpha==1 { return current }
        func mix(_ a: simd_float4x4,_ b: simd_float4x4) -> simd_float4x4 {
            func decompose(_ m: simd_float4x4) -> (SIMD3<Float>,simd_quatf) {
                let x=SIMD3(m[0].x,m[0].y,m[0].z),y=SIMD3(m[1].x,m[1].y,m[1].z),z=SIMD3(m[2].x,m[2].y,m[2].z)
                let scale=SIMD3(simd_length(x),simd_length(y),simd_length(z))
                return (scale,simd_quatf(simd_float3x3(x/scale.x,y/scale.y,z/scale.z)))
            }
            let (sa,qa)=decompose(a),(sb,qb)=decompose(b),scale=sa+(sb-sa)*alpha
            var m=simd_float4x4(simd_slerp(qa,qb,alpha));m[0] *= scale.x;m[1] *= scale.y;m[2] *= scale.z
            m[3]=a[3]+(b[3]-a[3])*alpha;return m
        }
        func wheel(_ i: Int) -> PresentedWheel {
            let a=previous.wheels[i],b=current.wheels[i]
            return PresentedWheel(transform:mix(a.transform,b.transform),brakeTransform:mix(a.brakeTransform,b.brakeTransform),level:b.level,brakeColor:a.brakeColor+(b.brakeColor-a.brakeColor)*alpha)
        }
        return VehiclePresentation(body:mix(previous.body,current.body),wheels:FourWheels(wheel(0),wheel(1),wheel(2),wheel(3)))
    }
}
