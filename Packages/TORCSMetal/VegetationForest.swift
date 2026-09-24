// SPDX-License-Identifier: GPL-2.0-only
// Optional original geometry enhancement. Numerical family descriptors identify
// Aalborg's tree-aa1/2/3 models; existing artwork keeps its original license.
import Foundation
import simd
import TORCSAssets

public struct VegetationForest: Sendable {
    public struct Placement: Sendable {
        public let family,variant:Int
        public let batches:[Int]
        public let transform:simd_float4x4
        public let center:SIMD3<Float>
        public let height,radius:Float
    }
    public struct Mesh:Sendable {
        public let vertices:[SceneVertex]
        public let indices:[UInt32]
    }
    public let placements:[Placement]
    public let meshes:[Mesh] // family * 6 + variant * 2 + detail (0 near, 1 middle)
    public let batchPlacement:[Int:Int]
    public static let textureName="allborg-trees_n.rgb"
    struct Family {
        let ranges:[SIMD2<Float>]
        let height:Float
        let widths:SIMD2<Float>
        let top:Float
    }
    static let families:[Family]=[
        .init(ranges:[SIMD2(-0.000749199,0.217693),SIMD2(0.000421695,0.214337)],height:14.23514,widths:SIMD2(8.51475,7.63933),top:0.582586),
        .init(ranges:[SIMD2(0.213165,0.449185),SIMD2(0.211359,0.450712)],height:18.65,widths:SIMD2(8.51475,7.63933),top:0.562273),
        .init(ranges:[SIMD2(0.449736,0.89474),SIMD2(0.448694,0.894436)],height:17.4117,widths:SIMD2(14.38994,12.91047),top:0.562273)
    ]
    private struct Edge:Hashable { let a,b:SIMD3<Float>
        init(_ a:SIMD3<Float>,_ b:SIMD3<Float>) {
            let ordered=a.x != b.x ? a.x<b.x:(a.y != b.y ? a.y<b.y:a.z<b.z)
            self.a=ordered ? a:b;self.b=ordered ? b:a
        }
    }
    private struct Face { let batch:Int;let p:[SIMD3<Float>];let uv:[SIMD2<Float>] }
    private struct Plane { let faces:[Int];let center,up,horizontal:SIMD3<Float>;let height,width:Float;let uv:SIMD2<Float> }
    public init(geometry:SceneGeometry,atlas:TextureImage) {
        var faces:[Face]=[]
        for (index,batch) in geometry.batches.enumerated() {
            guard batch.mesh.states[0]?.texture==Self.textureName,batch.vertices.count==3,batch.indices.count==3,
                  batch.vertices.allSatisfy({ $0.uv01.y>=0 && $0.uv01.y<0.59 }) else { continue }
            let p=batch.vertices.map { v -> SIMD3<Float> in let q=batch.transform*v.position;return SIMD3(q.x,q.y,q.z) }
            faces.append(Face(batch:index,p:p,uv:batch.vertices.map { SIMD2($0.uv01.x,$0.uv01.y) }))
        }
        var edges:[Edge:[Int]]=[:]
        for i in faces.indices { for j in 0..<3 { edges[Edge(faces[i].p[j],faces[i].p[(j+1)%3]),default:[]].append(i) } }
        var used=Set<Int>(),planes:[Plane]=[]
        for i in faces.indices where !used.contains(i) {
            let neighbors=Set((0..<3).flatMap { edges[Edge(faces[i].p[$0],faces[i].p[($0+1)%3])] ?? [] }).subtracting([i])
            guard neighbors.count==1,let j=neighbors.first,!used.contains(j) else { continue }
            let points=Set(faces[i].p+faces[j].p)
            guard points.count==4 else { continue }
            // Sort every set reduction: recognition and generated transforms are
            // independent of Swift's randomized Dictionary/Set iteration order.
            let sorted=points.sorted { a,b in a.x != b.x ? a.x<b.x:(a.y != b.y ? a.y<b.y:a.z<b.z) }
            let center=sorted.reduce(SIMD3<Float>.zero,+)/4
            var counts:[Edge:Int]=[:]
            for f in [i,j] { for k in 0..<3 { counts[Edge(faces[f].p[k],faces[f].p[(k+1)%3]),default:0] += 1 } }
            let boundary=counts.filter { $0.value==1 }.map { $0.key.b-$0.key.a }
            let vertical=boundary.filter { abs($0.z)>simd_length($0)*0.7 }.map { $0.z<0 ? -$0:$0 }
            let horizontal=boundary.filter { abs($0.z)<=simd_length($0)*0.7 }
            guard boundary.count==4,vertical.count==2,horizontal.count==2 else { continue }
            let v=(vertical[0]+vertical[1])*0.5,h=horizontal.sorted { a,b in a.x != b.x ? a.x<b.x:(a.y != b.y ? a.y<b.y:a.z<b.z) }[0]
            guard simd_length(v)>1,simd_length(h)>1,
                  simd_length(vertical[0]-vertical[1])<0.004,
                  abs(simd_length(horizontal[0])-simd_length(horizontal[1]))<0.004,
                  abs(simd_dot(simd_normalize(v),simd_normalize(h)))<0.001,
                  abs(simd_dot(simd_normalize(horizontal[0]),simd_normalize(horizontal[1])))>0.9999 else { continue }
            let uv=faces[i].uv+faces[j].uv
            planes.append(Plane(faces:[i,j],center:center,up:simd_normalize(v),horizontal:simd_normalize(h),height:simd_length(v),width:simd_length(h),uv:SIMD2(uv.map(\.x).min()!,uv.map(\.x).max()!)))
            used.insert(i);used.insert(j)
        }
        var paired=Set<Int>(),placements:[Placement]=[],mapping:[Int:Int]=[:]
        for i in planes.indices where !paired.contains(i) {
            let a=planes[i]
            let neighbors=planes.indices.filter { $0 != i && !paired.contains($0) && simd_distance(a.center,planes[$0].center)<0.005 }
            guard neighbors.count==1,let j=neighbors.first else { continue }
            let b=planes[j]
            guard simd_distance(a.up,b.up)<0.001,abs(a.height-b.height)<0.004,
                  abs(simd_dot(a.horizontal,b.horizontal))<0.03 else { continue }
            var match:(Int,Int)?
            for (family,descriptor) in Self.families.enumerated() { for side in 0..<2 {
                if simd_length(a.uv-descriptor.ranges[side])<0.00002 && simd_length(b.uv-descriptor.ranges[1-side])<0.00002 &&
                    abs(a.height-descriptor.height)<0.01 && abs(a.width-descriptor.widths[side])<0.004 && abs(b.width-descriptor.widths[1-side])<0.004 { match=(family,side) }
            } }
            guard let (family,side)=match else { continue }
            let main=side==0 ? a:b,other=side==0 ? b:a
            let up=simd_normalize(a.up+b.up),right=simd_normalize(main.horizontal-up*simd_dot(main.horizontal,up)),forward=simd_cross(up,right)
            let height=(a.height+b.height)*0.5,center=(a.center+b.center)*0.5,base=center-up*height*0.5
            let transform=simd_float4x4(SIMD4(right*main.width,0),SIMD4(forward*other.width,0),SIMD4(up*height,0),SIMD4(base,1))
            let batches=(a.faces+b.faces).map { faces[$0].batch }.sorted(),index=placements.count
            placements.append(Placement(family:family,variant:index%3,batches:batches,transform:transform,center:center,height:height,radius:sqrt(height*height+max(a.width,b.width)*max(a.width,b.width))*0.5))
            for batch in batches { mapping[batch]=index };paired.insert(i);paired.insert(j)
        }
        self.placements=placements;batchPlacement=mapping
        meshes=(0..<3).flatMap { family in (0..<3).flatMap { variant in [false,true].map { Self.mesh(family:family,variant:variant,middle:$0,atlas:atlas) } } }
    }
    /// Decisions are local to this camera, including mirror viewport height.
    /// 0/1 select volume detail; 2 retains the original tree.
    public func detail(for index:Int,camera:SceneCamera,pixelHeight:Float,transform:simd_float4x4=matrix_identity_float4x4) -> Int {
        let tree=placements[index],p=transform*SIMD4(tree.center,1)
        let scale=simd_length(SIMD3(transform[2].x,transform[2].y,transform[2].z))
        let distance=max(1,simd_distance(camera.eye,SIMD3(p.x,p.y,p.z)))
        let pixels=tree.height*scale*pixelHeight/(2*tan(camera.fieldOfView/2)*distance)
        return pixels>=160 ? 0:(pixels>=35 ? 1:2)
    }
    public func height(at point:SIMD2<Float>) -> Float {
        var result:Float = -1_000_000
        for tree in placements where simd_distance(point,SIMD2(tree.center.x,tree.center.y))<=tree.radius {
            let mesh=meshes[tree.family*6+tree.variant*2]
            let inverse=tree.transform.inverse
            let o=inverse*SIMD4(point.x,point.y,0,1),d=inverse*SIMD4<Float>(0,0,1,0)
            let origin=SIMD3(o.x,o.y,o.z),direction=SIMD3(d.x,d.y,d.z)
            for i in stride(from:0,to:mesh.indices.count,by:3) {
                let p=mesh.vertices[Int(mesh.indices[i])].position
                let q=mesh.vertices[Int(mesh.indices[i+1])].position
                let r=mesh.vertices[Int(mesh.indices[i+2])].position
                let a=SIMD3(p.x,p.y,p.z),b=SIMD3(q.x-p.x,q.y-p.y,q.z-p.z),c=SIMD3(r.x-p.x,r.y-p.y,r.z-p.z)
                let h=simd_cross(direction,c),det=simd_dot(b,h)
                if abs(det)<1e-10 { continue }
                let relative=origin-a,u=simd_dot(relative,h)/det
                if u<0 || u>1 { continue }
                let cross=simd_cross(relative,b),v=simd_dot(direction,cross)/det
                if v>=0 && u+v<=1 { result=max(result,simd_dot(c,cross)/det) }
            }
        }
        return result
    }
    private static func mesh(family:Int,variant:Int,middle:Bool,atlas:TextureImage) -> Mesh {
        let descriptor=families[family],range=descriptor.ranges[0],rgba=atlas.rgba8
        // Select a foliage-dense patch inside this tree's own atlas region.
        // Sampling a whole tree around a surface creates artificial horizontal
        // rings. Small leaf patches retain the source colors without that artifact.
        let x0=max(1,Int(range.x*Float(atlas.width))+1),x1=min(atlas.width-2,Int(range.y*Float(atlas.width))-1)
        let y0=max(1,Int(descriptor.top*0.25*Float(atlas.height))),y1=min(atlas.height-2,Int(descriptor.top*0.82*Float(atlas.height)))
        let tile=max(1,min(24,min(x1-x0,y1-y0)))
        var best=SIMD2(x0,y0),bestScore = -Float.infinity
        if x1-x0>=tile && y1-y0>=tile {
            for y in stride(from:y0,through:y1-tile,by:3) { for x in stride(from:x0,through:x1-tile,by:3) {
                var score:Float=0
                for yy in stride(from:y,to:y+tile,by:2) { for xx in stride(from:x,to:x+tile,by:2) {
                    let i=(yy*atlas.width+xx)*4
                    score += Float(rgba[i+3])*(1+max(0,Float(rgba[i+1])-Float(rgba[i]))/64)
                } }
                if score>bestScore { bestScore=score;best=SIMD2(x,y) }
            } }
        }
        let uvLow=SIMD2((Float(best.x)+0.5)/Float(atlas.width),(Float(best.y)+0.5)/Float(atlas.height))
        let uvSpan=SIMD2(Float(tile-1)/Float(atlas.width),Float(tile-1)/Float(atlas.height))
        func sourceRadius(_ z:Float)->Float {
            let y=min(atlas.height-1,max(0,Int(z*descriptor.top*Float(atlas.height))))
            var radius:Float=0.025
            if x0<=x1 { for yy in max(0,y-1)...min(atlas.height-1,y+1) { for x in x0...x1 where rgba[(yy*atlas.width+x)*4+3]>96 {
                radius=max(radius,abs((Float(x)/Float(atlas.width)-range.x)/(range.y-range.x)-0.5))
            } } }
            return min(0.49,radius)
        }
        var vertices:[SceneVertex]=[],indices:[UInt32]=[]
        var serial=0
        func append(_ position:SIMD3<Float>,_ normal:SIMD3<Float>,_ uv:SIMD4<Float>) {
            vertices.append(SceneVertex(position:SIMD4(position,1),normal:SIMD4(normal,0),uv01:uv,uv23:.zero))
        }
        func cylinder(_ a:SIMD3<Float>,_ b:SIMD3<Float>,_ radius:Float) {
            let direction=simd_normalize(b-a),axis=abs(direction.z)>0.9 ? SIMD3<Float>(1,0,0):SIMD3<Float>(0,0,1)
            let right=simd_normalize(simd_cross(direction,axis)),forward=simd_cross(direction,right)
            let sides=middle ? 5:7,first=UInt32(vertices.count)
            for row in 0...1 { for side in 0...sides {
                let angle=Float(side)*2*Float.pi/Float(sides),n=right*cos(angle)+forward*sin(angle)
                append((row==0 ? a:b)+n*radius*(row==0 ? 1:0.35),n,SIMD4(Float(side)/Float(sides),Float(row)*8,1,1))
            } }
            for side in 0..<sides { let a=first+UInt32(side),b=a+UInt32(sides+1);indices += [a,a+1,b,a+1,b+1,b] }
            for side in 1..<(sides-1) { indices += [first,first+UInt32(side+1),first+UInt32(side),first+UInt32(sides+1),first+UInt32(sides+1+side),first+UInt32(sides+2+side)] }
        }
        func cluster(_ center:SIMD3<Float>,_ scale:SIMD3<Float>,_ shade:Float) {
            // Small, individually oriented blades fill a crown volume. A closed
            // ellipsoid reads as a smooth solid at driving and overhead angles.
            // Generate once with a fixed integer seed; no per-frame leaf work.
            var seed=UInt64(1+family*100_003+variant*10_007+serial*503)
            serial += 1
            func random()->Float {
                seed=seed &* 6364136223846793005 &+ 1442695040888963407
                return Float((seed>>40)&0xFFFFFF)/16777216
            }
            let count=middle ? (family==2 ? 24:20):(family==2 ? 64:48)
            let size:Float=middle ? 0.42:0.30
            for _ in 0..<count {
                let z=random()*2-1,angle=random()*2*Float.pi
                let radial=sqrt(max(0,1-z*z))
                let outward=SIMD3(radial*cos(angle),radial*sin(angle),z)
                let origin=outward*pow(random(),1.0/3.0)*0.82
                let turn=random()*2*Float.pi
                let reference=abs(outward.z)>0.9 ? SIMD3<Float>(1,0,0):SIMD3<Float>(0,0,1)
                let tangent=simd_normalize(simd_cross(outward,reference)),bitangent=simd_cross(outward,tangent)
                let along=tangent*cos(turn)+bitangent*sin(turn)
                let across=simd_cross(outward,along)
                let width=size*(0.65+random()*0.55),length=size*(0.9+random()*0.6)
                let fold=simd_cross(along,across)*size*0.16
                let offsets=[-along*length,across*width+fold,along*length,-across*width+fold]
                let uv=[SIMD2<Float>(0,0.5),SIMD2(0.45,0),SIMD2(1,0.5),SIMD2(0.45,1)]
                // Branch spread may be flat, but individual leaf sprays need
                // thickness/orientations that remain visible from the side.
                let leafScale=SIMD3(scale.x,scale.y,max(scale.z,min(scale.x,scale.y)*0.55))
                let points=offsets.map { center+origin*scale+$0*leafScale }
                let normal=simd_normalize(simd_cross(points[1]-points[0],points[2]-points[0]))
                let tint=shade*(0.78+random()*0.27),first=UInt32(vertices.count)
                for i in 0..<4 {
                    let tex=uvLow+uvSpan*uv[i]
                    append(points[i],normal,SIMD4(tex.x,tex.y,0,tint))
                }
                indices += [first,first+1,first+2,first,first+2,first+3]
            }
        }
        cylinder(.zero,SIMD3(0,0,family==2 ? 0.88:0.97),family==2 ? 0.029:0.023)
        if family<2 {
            let layers=middle ? 7:11,branches=middle ? 3:5
            for layer in 0..<layers {
                let fraction=Float(layer)/Float(layers-1),z:Float=0.15+fraction*0.78
                let radius:Float=family==0 ? 0.39*pow(1-fraction,0.85)+0.02:sourceRadius(z)*0.72
                let phase=Float(layer)*2.399+Float(variant)*1.71
                for branch in 0..<branches {
                    let angle=phase+Float(branch)*2*Float.pi/Float(branches)
                    let reach=radius*(family==0 ? 0.55:0.82)
                    let center=SIMD3(cos(angle)*reach,sin(angle)*reach,z+0.038*sin(angle*3+Float(layer)))
                    let scale=SIMD3(radius*(family==0 ? 0.65:0.58),radius*0.60,family==0 ? max(0.009,radius*0.12):max(0.006,radius*0.17))
                    if !middle { cylinder(SIMD3(0,0,z-0.05),center,0.005*(1-fraction*0.7)) }
                    cluster(center,scale,0.88+fraction*0.12)
                }
                if family==0 { cluster(SIMD3(0,0,z),SIMD3(radius*0.55,radius*0.55,0.02+radius*0.10),0.92) }
            }
        } else {
            cluster(SIMD3(0,0,0.59),SIMD3(0.25,0.25,0.30),0.86)
            let layers=middle ? 3:4,branches=middle ? 5:7
            for layer in 0..<layers {
                let fraction=Float(layer)/Float(layers-1),z:Float=0.34+fraction*0.50
                let reach:Float=0.22*sin((0.22+fraction*0.65)*Float.pi)
                for branch in 0..<branches {
                    let angle=Float(branch)*2*Float.pi/Float(branches)+Float(layer)*2.399+Float(variant)*1.71
                    let center=SIMD3(cos(angle)*reach,sin(angle)*reach,z+0.025*sin(angle*3))
                    if !middle { cylinder(SIMD3(0,0,z-0.13),center,0.008) }
                    cluster(center,SIMD3(0.17,0.17,0.125),0.88+fraction*0.12)
                }
            }
        }
        // Keep source extents, including the existing placement's tilt.
        for i in vertices.indices {
            vertices[i].position.x=min(0.5,max(-0.5,vertices[i].position.x))
            vertices[i].position.y=min(0.5,max(-0.5,vertices[i].position.y))
            vertices[i].position.z=min(1,max(0,vertices[i].position.z))
        }
        return Mesh(vertices:vertices,indices:indices)
    }
}
