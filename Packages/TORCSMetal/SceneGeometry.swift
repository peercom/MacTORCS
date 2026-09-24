// SPDX-License-Identifier: GPL-2.0-only
// TORCS scene/material interpretation follows grloadac.cpp (Steve Baker, 2001)
// and grvtxtable.cpp (Christophe Guionneau, 2001); original attribution retained.
// Derived PLIB scheduling portions converted from LGPL-2.0-or-later to GPL v2
// under LGPL v2 section 3, effective 2026-09-23; original notices in Upstream.
import simd
import TORCSAssets

public struct SceneVertex: Sendable {
    public var position, normal, uv01, uv23: SIMD4<Float>
}
public struct SceneBatch: Sendable {
    public let vertices: [SceneVertex],indices: [UInt32]
    public let transform: simd_float4x4
    public let center: SIMD3<Float>
    public let mesh: ACMesh
    public let isDriver: Bool
}
public struct SceneGeometry: Sendable {
    public let batches: [SceneBatch]
    public let minimum,maximum: SIMD3<Float>
    public let warnings: [String]
    public init(_ scene: ACScene,driverSelector:Bool=false) throws {
        try scene.validate()
        var children=Array(repeating:[Int](),count:scene.nodes.count)
        for i in scene.nodes.indices where scene.nodes[i].parent>=0 { children[scene.nodes[i].parent].append(i) }
        func traversal()->[Int] {
            var result:[Int]=[],stack=[0]
            while let i=stack.popLast() { result.append(i);stack.append(contentsOf:children[i].reversed()) }
            return result
        }
        let driverRoot=traversal().first { scene.nodes[$0].name=="DRIVER" }
        if driverSelector,let driverRoot,scene.nodes[driverRoot].parent>=0 {
            let parent=scene.nodes[driverRoot].parent
            children[parent].removeAll { $0==driverRoot };children[parent].append(driverRoot)
        }
        let nodeOrder=traversal()
        var transforms: [simd_float4x4]=[],batches: [SceneBatch]=[],warnings=Set(scene.warnings ?? [])
        var nodeBatches:[Int:Int]=[:]
        var low=SIMD3<Float>(repeating:.infinity),high=SIMD3<Float>(repeating:-.infinity)
        var driverNodes:[Bool]=[]
        // grcar selects the first DRIVER subtree returned by getByName.
        for (nodeIndex,node) in scene.nodes.enumerated() {
            let driver=nodeIndex==driverRoot || (node.parent>=0 && driverNodes[node.parent])
            driverNodes.append(driver)
            let parent=node.parent<0 ? matrix_identity_float4x4:transforms[node.parent]
            let transform=parent * (node.kind==0 ? Self.matrix(node.matrix):matrix_identity_float4x4)
            guard (0..<4).allSatisfy({ transform[$0].x.isFinite && transform[$0].y.isFinite && transform[$0].z.isFinite && transform[$0].w.isFinite }),
                  abs(simd_determinant(transform))>1e-12,
                  transform.columns.0.w==0,transform.columns.1.w==0,transform.columns.2.w==0,transform.columns.3.w==1 else { throw ACError.invalid("Scene transform must be finite, affine and nonsingular") }
            transforms.append(transform)
            guard let mesh=node.mesh else { continue }
            guard mesh.states[0] != nil else { throw ACError.invalid("Mesh has no base material") }
            let indices=try mesh.triangleIndices()
            if indices.isEmpty { continue }
            if mesh.normals.isEmpty { warnings.insert("Geometry without normals uses (0, 0, 1); inherited legacy GL normal state is not reproduced.") }
            if mesh.states[3] != nil { warnings.insert("Fourth texture state is retained in the cache but not used by the original track draw path.") }
            var vertices: [SceneVertex]=[],center=SIMD3<Float>(repeating:0)
            for i in 0..<mesh.vertices.count/3 {
                let p=SIMD4(mesh.vertices[i*3],mesh.vertices[i*3+1],mesh.vertices[i*3+2],1)
                let q=transform*p,world=SIMD3(q.x,q.y,q.z)
                guard world.x.isFinite,world.y.isFinite,world.z.isFinite else { throw ACError.invalid("Nonfinite world vertex") }
                low=simd_min(low,world);high=simd_max(high,world);center += world/Float(mesh.vertices.count/3)
                let n=mesh.normals.isEmpty ? [Float(0),0,1]:Array(mesh.normals[(mesh.normals.count==3 ? 0:i*3)..<(mesh.normals.count==3 ? 3:i*3+3)])
                func uv(_ layer: Int) -> SIMD2<Float> { mesh.uv[layer].isEmpty ? .zero:SIMD2(mesh.uv[layer][i*2],mesh.uv[layer][i*2+1]) }
                let a=uv(0),b=uv(1),c=uv(2),d=uv(3)
                vertices.append(SceneVertex(position:p,normal:SIMD4(n[0],n[1],n[2],0),uv01:SIMD4(a.x,a.y,b.x,b.y),uv23:SIMD4(c.x,c.y,d.x,d.y)))
            }
            nodeBatches[nodeIndex]=batches.count
            batches.append(SceneBatch(vertices:vertices,indices:indices,transform:transform,center:center,mesh:mesh,isDriver:driver))
        }
        guard !batches.isEmpty,simd_length(high-low).isFinite else { throw ACError.invalid("Scene has no drawable triangles") }
        self.batches=nodeOrder.compactMap { nodeBatches[$0].map { batches[$0] } };minimum=low;maximum=high;self.warnings=warnings.sorted()
    }
    public static func matrix(_ values: [Float]) -> simd_float4x4 {
        precondition(values.count==16)
        return simd_float4x4(columns:(SIMD4(values[0],values[1],values[2],values[3]),SIMD4(values[4],values[5],values[6],values[7]),SIMD4(values[8],values[9],values[10],values[11]),SIMD4(values[12],values[13],values[14],values[15])))
    }
}

/// Inspection orbit in TORCS world coordinates: Z up. Driving cameras follow later.
public struct SceneCamera: Sendable {
    public var target: SIMD3<Float>,distance: Float,yaw: Float,pitch: Float
    public var up=SIMD3<Float>(0,0,1)
    public var fogRange: SIMD2<Float>?
    public var drawsBackground=true
    private var fixedEye: SIMD3<Float>?
    public internal(set) var fieldOfView: Float = .pi/4
    private var clipping: SIMD2<Float>?
    public init(eye: SIMD3<Float>,target: SIMD3<Float>,fieldOfView: Float = 40 * .pi/180,near: Float = 1,far: Float = 600,up: SIMD3<Float> = SIMD3(0,0,1),fogRange: SIMD2<Float>? = nil) {
        self.target=target;distance=simd_length(eye-target);yaw=0;pitch=0
        fixedEye=eye;self.up=up;self.fogRange=fogRange;self.fieldOfView=fieldOfView;clipping=SIMD2(near,far)
    }
    public init(geometry: SceneGeometry) {
        target=(geometry.minimum+geometry.maximum)*0.5
        distance=max(1,simd_length(geometry.maximum-geometry.minimum)*1.2)
        yaw = -Float.pi/3;pitch=0.45
    }
    public var eye: SIMD3<Float> { fixedEye ?? (target+distance*SIMD3(cos(yaw)*cos(pitch),sin(yaw)*cos(pitch),sin(pitch))) }
    public func view() -> simd_float4x4 {
        let z=normalize(eye-target),x=normalize(cross(up,z)),y=cross(z,x)
        return simd_float4x4(SIMD4(x.x,y.x,z.x,0),SIMD4(x.y,y.y,z.y,0),SIMD4(x.z,y.z,z.z,0),SIMD4(-dot(x,eye),-dot(y,eye),-dot(z,eye),1))
    }
    public func viewProjection(aspect: Float) -> simd_float4x4 {
        let y: Float=1/tan(fieldOfView/2),near=clipping?.x ?? max(0.01,distance/10_000),far=clipping?.y ?? max(100,distance*10)
        let projection=simd_float4x4(SIMD4(y/aspect,0,0,0),SIMD4(0,y,0,0),SIMD4(0,0,far/(near-far),-1),SIMD4(0,0,near*far/(near-far),0))
        return projection*view()
    }
    var clippingRange: SIMD2<Float> { clipping ?? SIMD2(max(0.01,distance/10_000),max(100,distance*10)) }
}
