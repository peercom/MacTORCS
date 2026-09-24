// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS grGetHOT, Copyright (C) 2000 Eric Espie, and PLIB
// SSG/SG height traversal, Copyright (C) 1998–2004 Steve Baker and contributors.
// Derived LGPL-2.0-or-later portions converted to GPL v2 under LGPL v2 section 3,
// effective 2026-09-23. Original notices and reference sources retained in Upstream.
import Foundation
import simd
import TORCSAssets

/// Original scene-height query for an ordered, static AC transform/branch/mesh graph.
/// This is a presentation query, not a replacement for physical track height.
public struct SceneHeightQuery: Sendable {
    public struct Result: Sendable, Equatable {
        /// Original grGetHOT sentinel when no retained hit supplies a greater height.
        public fileprivate(set) var height: Float = -1_000_000
        public fileprivate(set) var retainedHits=0
        /// Original diagnostic count from surviving leaves, including after the
        /// hit list fills. A one-point light strip contributes -1 (PLIB n-2),
        /// even though its traversal visits no actual triangles.
        public fileprivate(set) var testedTriangles=0
    }
    private struct Node: Sendable {
        var children: [Int]=[]
        var transform: simd_float4x4?
        var points: [SIMD3<Float>]=[]
        var triangles: [SIMD3<Int>]=[]
        var diagnosticTriangleCount: Int?
        var cull=true
        var sphere=Sphere()
    }
    struct Sphere: Sendable {
        var center=SIMD3<Float>.zero,radius: Float = -1
        mutating func extend(_ other: Sphere) {
            if other.radius<0 { return }
            if radius<0 { self=other;return }
            let d=SceneHeightQuery.length(center-other.center)
            if d+other.radius<=radius { return }
            if d+radius<=other.radius { self=other;return }
            let newRadius=(radius+d+other.radius)/2
            let ratio=(newRadius-radius)/d
            center += (other.center-center)*ratio
            radius=newRadius
        }
    }
    private let nodes: [Node]
    let rootSphere: Sphere
    let maximumDepth: Int
    private let driverSubtree: Int?
    public let triangleCount: Int

    public init(_ scene: ACScene, driverSelector: Bool=false) throws {
        try scene.validate()
        var nodes: [Node]=[],depths: [Int]=[],count=0
        for (index,source) in scene.nodes.enumerated() {
            let depth=source.parent<0 ? 1:depths[source.parent]+1
            guard depth<=128 else { throw ACError.invalid("Scene-height hierarchy exceeds 128 levels") }
            depths.append(depth)
            var node=Node()
            if source.kind==0 {
                let m=SceneGeometry.matrix(source.matrix)
                guard m.columns.0.w==0,m.columns.1.w==0,m.columns.2.w==0,m.columns.3.w==1 else {
                    throw ACError.invalid("Scene-height transform must be affine")
                }
                node.transform=m
            }
            if let mesh=source.mesh {
                let n=mesh.vertices.count/3
                // Original getTriangle returns signed shorts. Reject rather than read
                // outside a legacy vertex buffer when its index range is exceeded.
                guard n<=32768 else { throw ACError.invalid("Scene-height mesh exceeds original signed-short vertex range") }
                node.cull=mesh.cull
                node.points=stride(from:0,to:mesh.vertices.count,by:3).map {
                    SIMD3(mesh.vertices[$0],mesh.vertices[$0+1],mesh.vertices[$0+2])
                }
                // grVtxTable inherits these sequential indices even for indexed
                // strips. Using the renderer's triangleIndices would change HOT.
                let nt=mesh.primitive==4 ? n/3:([5,6].contains(mesh.primitive) ? max(0,n-2):0)
                node.diagnosticTriangleCount=[5,6].contains(mesh.primitive) ? n-2:nt
                node.triangles.reserveCapacity(nt)
                for i in 0..<nt {
                    if mesh.primitive==4 { node.triangles.append(SIMD3(i*3,i*3+1,i*3+2)) }
                    else if mesh.primitive==6 { node.triangles.append(SIMD3(0,i+1,i+2)) }
                    else { node.triangles.append(i%2==0 ? SIMD3(i,i+1,i+2):SIMD3(i+2,i+1,i)) }
                }
                count += nt
                if let first=node.points.first {
                    var low=first,high=first
                    for p in node.points.dropFirst() { low=simd_min(low,p);high=simd_max(high,p) }
                    node.sphere.center=(low+high)*0.5
                    node.sphere.radius=Self.length(node.sphere.center-high)
                }
            }
            nodes.append(node)
            if source.parent>=0 { nodes[source.parent].children.append(index) }
        }
        let driver=driverSelector ? scene.nodes.firstIndex { $0.name=="DRIVER" && $0.kind != 2 && $0.parent>=0 }:nil
        if let driver {
            let parent=scene.nodes[driver].parent
            nodes[parent].children.removeAll { $0==driver };nodes[parent].children.append(driver)
        }
        // Child-order sphere growth matters; reverse node processing alone must
        // not reverse the order in which siblings extend their parent's sphere.
        for i in nodes.indices.reversed() {
            if scene.nodes[i].kind != 2 {
                var sphere=Sphere()
                for child in nodes[i].children { sphere.extend(nodes[child].sphere) }
                if let m=nodes[i].transform,sphere.radius>=0 { sphere.center=Self.point(sphere.center,m) }
                nodes[i].sphere=sphere // Original orthoXform leaves the radius unchanged.
            }
            let s=nodes[i].sphere
            guard s.radius.isFinite,s.center.x.isFinite,s.center.y.isFinite,s.center.z.isFinite else {
                throw ACError.invalid("Scene-height bounds overflow")
            }
        }
        self.nodes=nodes;rootSphere=nodes[0].sphere;triangleCount=count
        // The original driver wrapper adds one traversal level to its subtree.
        if let driver {
            for i in scene.nodes.indices {
                var ancestor=i
                while ancestor>=0 && ancestor != driver { ancestor=scene.nodes[ancestor].parent }
                if ancestor==driver { depths[i] += 1 }
            }
        }
        maximumDepth=depths.max() ?? 0;driverSubtree=driver
        guard maximumDepth<=128 else { throw ACError.invalid("Driver selector exceeds height hierarchy limit") }
    }

    /// Runs original query-relative transforms and keeps the first 99 hits in
    /// traversal order. Alpha/textures do not participate in this legacy query.
    public func query(x: Float,y: Float) throws -> Result {
        guard x.isFinite,y.isFinite else { throw ACError.invalid("Scene-height coordinates must be finite") }
        var matrix=matrix_identity_float4x4
        matrix.columns.3.x = -x;matrix.columns.3.y = -y
        var result=Result()
        if Self.intersects(rootSphere,matrix) { accumulate(matrix:matrix,drawsDriver:true,result:&result) }
        return result
    }
    func accumulate(matrix: simd_float4x4,drawsDriver: Bool,result: inout Result) {
        visit(0,matrix,drawsDriver,&result)
    }
    private func visit(_ index: Int,_ matrix: simd_float4x4,_ drawsDriver: Bool,_ result: inout Result) {
        if index==driverSubtree && !drawsDriver { return }
        let node=nodes[index]
        guard Self.intersects(node.sphere,matrix) else { return }
        let local=node.transform.map { Self.multiply(matrix,$0) } ?? matrix
        if !node.points.isEmpty {
            result.testedTriangles += node.diagnosticTriangleCount ?? node.triangles.count
            for indices in node.triangles {
                let a=Self.point(node.points[indices.x],local)
                let b=Self.point(node.points[indices.y],local)
                let c=Self.point(node.points[indices.z],local)
                if let height=Self.triangleHeight(a,b,c,cull:node.cull),result.retainedHits<99 {
                    result.retainedHits += 1
                    if height>=result.height { result.height=height }
                }
            }
        }
        for child in node.children { visit(child,local,drawsDriver,&result) }
    }
    static func intersects(_ sphere: Sphere,_ m: simd_float4x4) -> Bool {
        guard sphere.radius>=0 else { return false }
        let p=point(sphere.center,m)
        return !(p.x*p.x+p.y*p.y>sphere.radius*sphere.radius)
    }
    private static func triangleHeight(_ a: SIMD3<Float>,_ b: SIMD3<Float>,_ c: SIMD3<Float>,cull: Bool) -> Float? {
        if (0<a.x && 0<b.x && 0<c.x) || (0<a.y && 0<b.y && 0<c.y) ||
           (0>a.x && 0>b.x && 0>c.x) || (0>a.y && 0>b.y && 0>c.y) ||
           (100000<a.z && 100000<b.z && 100000<c.z) { return nil }
        let ab=b-a,ac=c-a
        var normal=SIMD3(ab.y*ac.z-ab.z*ac.y,ab.z*ac.x-ab.x*ac.z,ab.x*ac.y-ab.y*ac.x)
        normal *= 1/length(normal)
        let w = -(normal.x*a.x+normal.y*a.y+normal.z*a.z)
        if cull && normal.z<=0 { return nil }
        let z: Float = normal.z==0 ? 0:-(normal.x*0+normal.y*0+w)/normal.z
        if z>100000 || (z<a.z && z<b.z && z<c.z) || (z>a.z && z>b.z && z>c.z) { return nil }
        let e1: Float=0*a.y-0*a.x,e2: Float=0*b.y-0*b.x,e3: Float=0*c.y-0*c.x
        let ep1=a.x*b.y-a.y*b.x,ep2=b.x*c.y-b.y*c.x,ep3=c.x*a.y-c.y*a.x
        let ap=abs(ep1+ep2+ep3)
        // C++ fabs promotes each Float term to Double before summation.
        let ai=Float(abs(Double(e1+ep1-e2))+abs(Double(e2+ep2-e3))+abs(Double(e3+ep3-e1)))
        if Double(ai)>Double(ap)*1.01 { return nil }
        // Degenerate planes may count as original hits but their NaN heights do
        // not replace grGetHOT's running maximum. Do not silently drop the hit.
        return normal.z==0 ? 0:-w/normal.z
    }
    static func length(_ v: SIMD3<Float>) -> Float { sqrt(v.x*v.x+v.y*v.y+v.z*v.z) }
    static func point(_ p: SIMD3<Float>,_ m: simd_float4x4) -> SIMD3<Float> {
        var result=SIMD3<Float>.zero
        for r in 0..<3 { result[r]=((p.x*m[0][r]+p.y*m[1][r])+p.z*m[2][r])+m[3][r] }
        return result
    }
    static func multiply(_ a: simd_float4x4,_ b: simd_float4x4) -> simd_float4x4 {
        var result=simd_float4x4()
        for c in 0..<4 { for r in 0..<4 {
            result[c][r]=((b[c][0]*a[0][r]+b[c][1]*a[1][r])+b[c][2]*a[2][r])+b[c][3]*a[3][r]
        } }
        return result
    }
    // Exact node sphere evidence for @testable reference comparisons.
    var referenceSpheres: [SIMD4<Float>] { nodes.map { SIMD4($0.sphere.center,$0.sphere.radius) } }
}

extension SceneHeightQuery {
    /// The original projected six-vertex car-shadow strip also participates in HOT.
    /// An empty list represents removal of the shadow, including its bounds.
    public init(shadowVertices: [ShadowVertex]) throws {
        if shadowVertices.isEmpty {
            nodes=[Node()];rootSphere=Sphere();triangleCount=0;maximumDepth=1;driverSubtree=nil;return
        }
        guard shadowVertices.count==6 else { throw ACError.invalid("Scene-height car shadow needs six vertices") }
        var node=Node()
        node.points=shadowVertices.map { SIMD3($0.position.x,$0.position.y,$0.position.z) }
        guard node.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { throw ACError.invalid("Nonfinite height-shadow vertex") }
        for i in 0..<4 { node.triangles.append(i%2==0 ? SIMD3(i,i+1,i+2):SIMD3(i+2,i+1,i)) }
        var low=node.points[0],high=low
        for p in node.points.dropFirst() { low=simd_min(low,p);high=simd_max(high,p) }
        node.sphere.center=(low+high)*0.5;node.sphere.radius=Self.length(node.sphere.center-high)
        guard node.sphere.radius.isFinite else { throw ACError.invalid("Scene-height shadow bounds overflow") }
        nodes=[node];rootSphere=node.sphere;triangleCount=4;maximumDepth=1;driverSubtree=nil
    }
}

extension SceneHeightQuery {
    /// Original car-light leaves contain one world-space vertex and no triangles.
    /// Off lights retain bounds; hidden-current-car lights are removed entirely.
    public init(lightPositions:[SIMD3<Float>]) throws {
        guard lightPositions.count<=14,lightPositions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { throw ACError.invalid("Invalid light height positions") }
        var root=Node(),result:[Node]=[Node()]
        for p in lightPositions {
            var leaf=Node();leaf.points=[p];leaf.cull=false;leaf.sphere=Sphere(center:p,radius:0)
            leaf.diagnosticTriangleCount = -1
            root.children.append(result.count);root.sphere.extend(leaf.sphere);result.append(leaf)
        }
        result[0]=root;nodes=result;rootSphere=root.sphere;triangleCount=0;maximumDepth=2;driverSubtree=nil
    }
}
