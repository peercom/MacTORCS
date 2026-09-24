// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import CReference
@testable import TORCSAssets
@testable import TORCSMetal

final class SceneHeightTests: XCTestCase {
    private let identity: [Float]=[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]
    func oracle(_ scene: ACScene) throws -> UnsafeMutableRawPointer {
        let handle=try XCTUnwrap(ref_scene_height_create())
        for node in scene.nodes {
            let ok=ref_scene_height_add(handle,Int32(node.parent),Int32(node.kind),node.matrix,
                Int32(node.mesh?.primitive ?? 0),node.mesh?.cull == true ? 1:0,node.mesh?.vertices ?? [],Int32((node.mesh?.vertices.count ?? 0)/3))
            if ok != 1 { ref_scene_height_destroy(handle);throw ACError.invalid("Reference scene construction failed") }
        }
        return handle
    }
    @discardableResult private func compare(_ scene: ACScene,_ queries: [SIMD2<Float>],file: StaticString=#filePath,line: UInt=#line) throws -> (hits: Int,triangles: Int) {
        let native=try SceneHeightQuery(scene),reference=try oracle(scene)
        defer { ref_scene_height_destroy(reference) }
        var spheres=Array(repeating:Float(0),count:scene.nodes.count*4)
        ref_scene_height_spheres(reference,&spheres)
        for (i,s) in native.referenceSpheres.enumerated() { for j in 0..<4 {
            XCTAssertEqual(s[j],spheres[i*4+j],"sphere \(i) component \(j)",file:file,line:line)
        } }
        var heights=Array(repeating:Float(0),count:queries.count),hits=Array(repeating:Int32(0),count:queries.count),triangles=hits
        ref_scene_height_query(reference,queries.flatMap { [$0.x,$0.y] },Int32(queries.count),&heights,&hits,&triangles)
        var total=0,totalTriangles=0
        for (i,p) in queries.enumerated() {
            let actual=try native.query(x:p.x,y:p.y)
            XCTAssertEqual(actual.height,heights[i],"height \(i) at \(p)",file:file,line:line)
            XCTAssertEqual(actual.retainedHits,Int(hits[i]),"hits \(i) at \(p)",file:file,line:line)
            XCTAssertEqual(actual.testedTriangles,Int(triangles[i]),"triangles \(i) at \(p)",file:file,line:line)
            total += actual.retainedHits;totalTriangles += actual.testedTriangles
        }
        return (total,totalTriangles)
    }
    private func mesh(_ points: [Float],primitive: Int=4,cull: Bool=true) -> ACMesh {
        var m=SceneRenderingTests.quad(cull:cull)
        m.primitive=primitive;m.vertices=points;m.uv=Array(repeating:[],count:4)
        return m
    }
    private func scene(_ meshes: [ACMesh]) -> ACScene { SceneRenderingTests.loaded(meshes).asset.scene }
    func testOriginalHeightEdgeCullingAndHitLimitRules() throws {
        let ground=mesh([0,0,0,10,0,0,0,10,0])
        let raised=mesh([0,0,12,10,0,12,0,10,12])
        var inverted=raised;inverted.vertices=[0,10,12,10,0,12,0,0,12]
        let vertical=mesh([0,0,-10,0,0,10,0,10,0],cull:false)
        let degenerate=mesh([0,0,0,0,0,0,0,0,0])
        let above=mesh([0,0,100001,10,0,100001,0,10,100001])
        let near=mesh([0,0,-1000001,10,0,-1000001,0,10,-1000001])
        let points: [SIMD2<Float>]=[.zero,SIMD2(2,2),SIMD2(10,0),SIMD2(5,5),SIMD2(5.01,5.01),SIMD2(5.03,5.03),SIMD2(-0.001,0),SIMD2(0,9),SIMD2(10,10),SIMD2(500,500)]
        var cases=[scene([ground]),scene([ground,raised]),scene([ground,inverted]),scene([vertical]),scene([degenerate,ground]),scene([above,ground]),scene([near])]
        inverted.cull=false;cases.append(scene([ground,inverted]))
        var indexed=ground;indexed.primitive=5;indexed.indexed=true
        indexed.vertices += [30,30,50];indexed.indices=[1,3,2];indexed.strips=[3]
        cases.append(scene([indexed])) // Original height must ignore these render indices.
        for s in cases { try compare(s,points) }
        XCTAssertEqual(try SceneHeightQuery(cases[0]).query(x:5.01,y:5.01).height,0)
        XCTAssertEqual(try SceneHeightQuery(cases[0]).query(x:5.03,y:5.03).height,-1_000_000)
        XCTAssertEqual(try SceneHeightQuery(cases[2]).query(x:2,y:2).height,0)
        XCTAssertEqual(try SceneHeightQuery(cases[7]).query(x:2,y:2).height,12)
        XCTAssertEqual(try SceneHeightQuery(cases[3]).query(x:0,y:2).height,0)
        XCTAssertEqual(try SceneHeightQuery(cases[4]).query(x:0,y:0).retainedHits,2)
        let stacked=scene((0..<105).map { h in mesh([0,0,Float(h),10,0,Float(h),0,10,Float(h)]) })
        try compare(stacked,points)
        let hit=try SceneHeightQuery(stacked).query(x:2,y:2)
        XCTAssertEqual(hit.retainedHits,99);XCTAssertEqual(hit.height,98);XCTAssertEqual(hit.testedTriangles,105)
        // Degenerate hits consume the original cap even though they supply no height.
        let capped=scene(Array(repeating:degenerate,count:99)+[raised]);try compare(capped,points)
        XCTAssertEqual(try SceneHeightQuery(capped).query(x:0,y:0).height,-1_000_000)
        print("SCENE_HEIGHT_RULES scenes=11 queries=110 hitCap=99 indexedEnumeration=original edgeAllowance=original")
    }
    func testHierarchyAndPrimitiveHeightAgainstOriginal() throws {
        var queries: [SIMD2<Float>]=[]
        for y in -6...6 { for x in -6...6 { queries.append(SIMD2(Float(x)*0.41,Float(y)*0.39)) } }
        var hits=0,triangles=0
        for i in 0..<48 {
            var m=SceneRenderingTests.quad(z:Float(i%4)-2);m.uv=Array(repeating:[],count:4)
            m.primitive=[4,5,6,2,3][i%5];m.cull=i%3 != 0
            if i%2==0 { m.vertices[2] += 0.2;m.vertices[8] += 0.4 }
            var s=scene([m]);s.nodes[0].matrix=[1.1,0.2,0,0,-0.3,0.9,0.1,0,0.1,0,1.3,0,Float(i%3)*0.5,-0.2,2.8,1]
            let inner=ACNode(parent:0,kind:0,name:"nested",matrix:[0.9,-0.3,0,0,0.3,0.9,0,0,0,0,1,0,-0.3,0.7,0.2,1],mesh:nil)
            s.nodes.insert(inner,at:1);s.nodes[2].parent=1
            let stats=try compare(s,queries);hits += stats.hits;triangles += stats.triangles
        }
        XCTAssertGreaterThan(hits,0)
        print("SCENE_HEIGHT_HIERARCHY scenes=48 queries=\(48*queries.count) retainedHits=\(hits) submittedTriangles=\(triangles) maximumError=0")
    }
    func testSelectedOriginalMeshesAgainstOriginalHeightTraversal() throws {
        let root=try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil))
        var totalQueries=0,totalHits=0,totalTriangles=0
        for (name,car) in [("155-DTM/155-DTM",true),("aalborg/aalborg",false),("trb1-3/wheel0",true)] {
            let s=try ACScene.parse(Data(contentsOf:root.appendingPathComponent("Artwork/\(name).acc")),car:car)
            let g=try SceneGeometry(s)
            var queries: [SIMD2<Float>]=[]
            // Whole bounds plus dense original geometry witnesses, including edges.
            for y in 0..<33 { for x in 0..<37 {
                queries.append(SIMD2(g.minimum.x+(g.maximum.x-g.minimum.x)*Float(x)/36,g.minimum.y+(g.maximum.y-g.minimum.y)*Float(y)/32))
            } }
            for b in g.batches {
                for i in stride(from:0,to:b.indices.count,by:max(3,b.indices.count/12/3*3)) {
                    let a=b.transform*b.vertices[Int(b.indices[i])].position
                    queries.append(SIMD2(a.x,a.y))
                    if i+2<b.indices.count {
                        let c=b.transform*b.vertices[Int(b.indices[i+1])].position,d=b.transform*b.vertices[Int(b.indices[i+2])].position
                        queries.append(SIMD2((a.x+c.x+d.x)/3,(a.y+c.y+d.y)/3))
                    }
                }
            }
            let stats=try compare(s,queries)
            XCTAssertGreaterThan(stats.hits,0)
            totalQueries += queries.count;totalHits += stats.hits;totalTriangles += stats.triangles
            print("SCENE_HEIGHT_ASSET name=\(name) nodes=\(s.nodes.count) queries=\(queries.count) retainedHits=\(stats.hits) submittedTriangles=\(stats.triangles)")
        }
        print("SCENE_HEIGHT_CONTENT files=3 queries=\(totalQueries) retainedHits=\(totalHits) submittedTriangles=\(totalTriangles) maximumError=0")
    }
    func testHeightValidationAndIndependentQueries() throws {
        var s=scene([SceneRenderingTests.quad()]);let q=try SceneHeightQuery(s)
        for value: Float in [.nan,.infinity,-.infinity] {
            XCTAssertThrowsError(try q.query(x:value,y:0));XCTAssertThrowsError(try q.query(x:0,y:value))
        }
        let original=try q.query(x:0,y:0)
        for i in 0..<100 { _=try q.query(x:Float(i),y:Float(-i));XCTAssertEqual(try q.query(x:0,y:0),original) }
        s.nodes[0].matrix[3]=0.1;XCTAssertThrowsError(try SceneHeightQuery(s))
        s=scene([SceneRenderingTests.quad()]);s.nodes[1].mesh!.vertices=Array(repeating:0,count:32769*3);s.nodes[1].mesh!.uv=Array(repeating:[],count:4)
        XCTAssertThrowsError(try SceneHeightQuery(s))
        s=scene([])
        for i in 1...128 { s.nodes.append(ACNode(parent:i-1,kind:0,name:"",matrix:identity,mesh:nil)) }
        XCTAssertThrowsError(try SceneHeightQuery(s))
        XCTAssertEqual(try SceneHeightQuery(scene([])).query(x:0,y:0).height,-1_000_000)
        s=scene([mesh([Float.greatestFiniteMagnitude,0,0,Float.greatestFiniteMagnitude,1,0,Float.greatestFiniteMagnitude,1,1])])
        XCTAssertThrowsError(try SceneHeightQuery(s))
        print("SCENE_HEIGHT_VALIDATION nonfiniteCoordinates=6 depthLimit=128 vertexLimit=32768 independentRepeats=100")
    }
}
