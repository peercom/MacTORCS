// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import CReference
@testable import TORCSAssets
@testable import TORCSMetal

final class SceneHeightAssemblyTests: XCTestCase {
    private let identity: [Float]=[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]
    private func floats(_ m: simd_float4x4) -> [Float] { (0..<4).flatMap { c in (0..<4).map { m[c][$0] } } }
    private func scene(_ z: Float) -> ACScene { SceneRenderingTests.loaded([SceneRenderingTests.quad(z:z)]).asset.scene }
    private func append(_ scene: ACScene,to handle: UnsafeMutableRawPointer,parent: Int,offset: Int) throws {
        for node in scene.nodes {
            XCTAssertEqual(ref_scene_height_add(handle,Int32(node.parent<0 ? parent:offset+node.parent),Int32(node.kind),node.matrix,
                Int32(node.mesh?.primitive ?? 0),node.mesh?.cull == true ? 1:0,node.mesh?.vertices ?? [],Int32((node.mesh?.vertices.count ?? 0)/3)),1)
        }
    }
    private func oracle(_ nodes: [SceneHeightAssembly.Node],_ scenes: [ACScene]) throws -> UnsafeMutableRawPointer {
        let h=try XCTUnwrap(ref_scene_height_create())
        for (i,n) in nodes.enumerated() {
            let kind: Int32,matrix: [Float]
            switch n.kind {
            case .transform(let m): kind=0;matrix=floats(m)
            case .selector: kind=3;matrix=identity
            case .rangeSelector: kind=4;matrix=identity
            default: kind=1;matrix=identity
            }
            XCTAssertEqual(ref_scene_height_add(h,Int32(n.parent),kind,matrix,0,0,[],0),1)
            if case .selector(let mask)=n.kind { XCTAssertEqual(ref_scene_height_select(h,Int32(i),mask),1) }
            if case .rangeSelector(let additive)=n.kind { XCTAssertEqual(ref_scene_height_select(h,Int32(i),additive ? 1:0),1) }
        }
        var offset=nodes.count
        for (i,n) in nodes.enumerated() { if case .asset(let resource)=n.kind {
            try append(scenes[resource],to:h,parent:i,offset:offset);offset += scenes[resource].nodes.count
        } }
        return h
    }
    private func compare(_ graph: SceneHeightAssembly,_ reference: UnsafeMutableRawPointer,_ points: [SIMD2<Float>],file: StaticString=#filePath,line: UInt=#line) throws {
        var heights=Array(repeating:Float(0),count:points.count),hits=Array(repeating:Int32(0),count:points.count),triangles=hits
        ref_scene_height_query(reference,points.flatMap { [$0.x,$0.y] },Int32(points.count),&heights,&hits,&triangles)
        for (i,p) in points.enumerated() {
            let result=try graph.query(x:p.x,y:p.y)
            XCTAssertEqual(result.height,heights[i],"height \(i)",file:file,line:line)
            XCTAssertEqual(result.retainedHits,Int(hits[i]),"hits \(i)",file:file,line:line)
            XCTAssertEqual(result.testedTriangles,Int(triangles[i]),"triangles \(i)",file:file,line:line)
        }
    }
    func testMovingSharedResourcesAndOriginalSelectors() throws {
        let scenes=[scene(0),scene(2),scene(4)]
        let nodes: [SceneHeightAssembly.Node]=[
            .init(parent:-1,kind:.branch),.init(parent:0,kind:.transform(matrix_identity_float4x4)),
            .init(parent:1,kind:.selector(3)),.init(parent:2,kind:.asset(0)),.init(parent:2,kind:.asset(1)),
            .init(parent:0,kind:.transform(matrix_identity_float4x4)),.init(parent:5,kind:.rangeSelector(additive:false)),
            .init(parent:6,kind:.asset(0)),.init(parent:6,kind:.asset(2)),
            .init(parent:0,kind:.rangeSelector(additive:true)),.init(parent:9,kind:.asset(1)),.init(parent:9,kind:.asset(2))]
        var graph=try SceneHeightAssembly(nodes:nodes,resources:scenes.map { try SceneHeightQuery($0) })
        let h=try oracle(nodes,scenes);defer { ref_scene_height_destroy(h) }
        var points: [SIMD2<Float>]=[]
        for i in 0..<81 { let x=Float(i%9-4)*0.4,y=Float(i/9-4)*0.4;points.append(SIMD2(x,y)) }
        let count=nodes.count+scenes[0].nodes.count*2+scenes[1].nodes.count*2+scenes[2].nodes.count*2
        for i in 0..<160 {
            var m=matrix_identity_float4x4
            let angle=Float(i)*0.09
            m[0]=SIMD4(cos(angle),sin(angle),0,0);m[1]=SIMD4(-sin(angle),cos(angle),0,0)
            m[3]=SIMD4(Float(i%9-4)*0.2,Float(i%7-3)*0.3,Float(i%5),1)
            let id=i%2==0 ? 1:5
            try graph.setTransform(m,at:id);XCTAssertEqual(ref_scene_height_transform(h,Int32(id),floats(m)),1)
            try graph.setSelection(UInt32(i%4),at:2);XCTAssertEqual(ref_scene_height_select(h,2,UInt32(i%4)),1)
            var spheres=Array(repeating:Float(0),count:count*4);ref_scene_height_spheres(h,&spheres)
            for (n,s) in graph.referenceSpheres.enumerated() { for component in 0..<4 { XCTAssertEqual(s[component],spheres[n*4+component]) } }
            try compare(graph,h,points)
        }
        print("HEIGHT_ASSEMBLY_MOVING updates=160 queries=12960 sharedResources=3 selectorMasks=4 rangeModes=2 maximumError=0")
    }
    func testSharedHitCapAndDriverInsertionOrder() throws {
        // Driver is moved to the final sibling by the original selector insertion.
        // A saturated hit list makes both traversal order and hidden-driver behavior observable.
        var s=scene(200)
        s.nodes.insert(ACNode(parent:0,kind:1,name:"DRIVER",matrix:[],mesh:nil),at:1);s.nodes[2].parent=1
        let low=scene(3).nodes[1].mesh!
        for _ in 0..<100 { s.nodes.append(ACNode(parent:0,kind:2,name:"body",matrix:[],mesh:low)) }
        let nodes: [SceneHeightAssembly.Node]=[.init(parent:-1,kind:.branch),.init(parent:0,kind:.asset(0)),.init(parent:0,kind:.asset(0))]
        var graph=try SceneHeightAssembly(nodes:nodes,resources:[try SceneHeightQuery(s,driverSelector:true)])
        let h=try oracle(nodes,[s]);defer { ref_scene_height_destroy(h) }
        let first=nodes.count,second=first+s.nodes.count
        let a=ref_scene_height_driver_selector(h,Int32(first),Int32(first+1),1)
        let b=ref_scene_height_driver_selector(h,Int32(second),Int32(second+1),1)
        XCTAssertGreaterThan(a,0);XCTAssertGreaterThan(b,0)
        for visible in [true,false,true] {
            try graph.setDriverVisible(visible,at:1);try graph.setDriverVisible(visible,at:2)
            XCTAssertEqual(ref_scene_height_select(h,a,visible ? 1:0),1);XCTAssertEqual(ref_scene_height_select(h,b,visible ? 1:0),1)
            try compare(graph,h,[.zero,SIMD2(0.1,0.2),SIMD2(200,300)])
            XCTAssertEqual(try graph.query(x:0.1,y:0.2).height,3)
            XCTAssertEqual(try graph.query(x:0.1,y:0.2).retainedHits,99)
        }
        // Unsaturated driver remains independently visible.
        s.nodes=Array(s.nodes.prefix(4))
        graph=try SceneHeightAssembly(nodes:nodes,resources:[try SceneHeightQuery(s,driverSelector:true)])
        XCTAssertEqual(try graph.query(x:0.1,y:0.2).height,200)
        try graph.setDriverVisible(false,at:1);try graph.setDriverVisible(false,at:2)
        XCTAssertEqual(try graph.query(x:0.1,y:0.2).height,3)
        print("HEIGHT_ASSEMBLY_DRIVER selectorReordered=1 sharedHitCap=99 visibilityChecked=1")
    }
    func testReplacementShadowAndTransactionalFailures() throws {
        let vertices: [ShadowVertex]=(0..<6).map { ShadowVertex(position:SIMD4(1-Float($0/2),Float($0%2)*2-1,2,1),uv:.zero) }
        let query=try SceneHeightQuery(shadowVertices:vertices)
        var s=scene(0);s.nodes[1].mesh!.vertices=vertices.flatMap { [$0.position.x,$0.position.y,$0.position.z] }
        s.nodes[1].mesh!.primitive=5;s.nodes[1].mesh!.uv=Array(repeating:[],count:4)
        let nodes: [SceneHeightAssembly.Node]=[.init(parent:-1,kind:.branch),.init(parent:0,kind:.transform(matrix_identity_float4x4)),.init(parent:1,kind:.asset(0))]
        var graph=try SceneHeightAssembly(nodes:nodes,resources:[query])
        let h=try oracle(nodes,[s]);defer { ref_scene_height_destroy(h) }
        try compare(graph,h,[.zero,SIMD2(0.5,0.2),SIMD2(8,8)])
        let previous=try graph.query(x:0,y:0),spheres=graph.referenceSpheres
        var invalid=matrix_identity_float4x4;invalid[3].x = .infinity
        XCTAssertThrowsError(try graph.setTransform(invalid,at:1))
        XCTAssertThrowsError(try graph.setTransform(matrix_identity_float4x4,at:2))
        XCTAssertThrowsError(try graph.setSelection(1,at:1))
        XCTAssertThrowsError(try graph.setDriverVisible(false,at:0))
        XCTAssertThrowsError(try graph.replaceResource(1,with:query))
        XCTAssertThrowsError(try graph.replaceResource(0,with:SceneHeightQuery(scene(1))))
        XCTAssertThrowsError(try graph.query(x:.nan,y:0))
        XCTAssertEqual(try graph.query(x:0,y:0),previous);XCTAssertEqual(graph.referenceSpheres,spheres)
        let raised=vertices.map { ShadowVertex(position:$0.position+SIMD4(0,0,5,0),uv:$0.uv) }
        try graph.replaceResource(0,with:SceneHeightQuery(shadowVertices:raised))
        XCTAssertEqual(try graph.query(x:0,y:0).height,7)
        try graph.replaceResource(0,with:SceneHeightQuery(shadowVertices:[]))
        XCTAssertEqual(graph.referenceSpheres[0].w,-1)
        XCTAssertEqual(try graph.query(x:0,y:0).testedTriangles,0)
        try graph.replaceResource(0,with:query)
        // Ancestor overflow must reject without committing an otherwise finite transform.
        var m=matrix_identity_float4x4;m[3].x=Float.greatestFiniteMagnitude
        let overflowNodes: [SceneHeightAssembly.Node]=[.init(parent:-1,kind:.transform(m)),.init(parent:0,kind:.transform(matrix_identity_float4x4)),.init(parent:1,kind:.asset(0))]
        var overflow=try SceneHeightAssembly(nodes:overflowNodes,resources:[query]);let before=overflow.referenceSpheres
        XCTAssertThrowsError(try overflow.setTransform(m,at:1));XCTAssertEqual(overflow.referenceSpheres,before)
        print("HEIGHT_ASSEMBLY_REPLACEMENT shadowStrip=4 invalidUpdatesRollback=1 ancestorOverflowRollback=1")
    }
    func testMalformedAssemblyRejected() throws {
        let q=try SceneHeightQuery(scene(0))
        XCTAssertThrowsError(try SceneHeightAssembly(nodes:[],resources:[]))
        XCTAssertThrowsError(try SceneHeightAssembly(nodes:[.init(parent:0,kind:.branch)],resources:[]))
        XCTAssertThrowsError(try SceneHeightAssembly(nodes:[.init(parent:-1,kind:.asset(1))],resources:[q]))
        XCTAssertThrowsError(try SceneHeightAssembly(nodes:[.init(parent:-1,kind:.asset(0)),.init(parent:0,kind:.branch)],resources:[q]))
        let tooWide=[SceneHeightAssembly.Node(parent:-1,kind:.selector(0))]+(0..<33).map { _ in .init(parent:0,kind:.branch) }
        XCTAssertThrowsError(try SceneHeightAssembly(nodes:tooWide,resources:[]))
        let tooDeep=(0..<128).map { SceneHeightAssembly.Node(parent:$0-1,kind:$0==127 ? .asset(0):.branch) }
        XCTAssertThrowsError(try SceneHeightAssembly(nodes:tooDeep,resources:[q]))
    }
}
