// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import CReference
@testable import TORCSAssets
@testable import TORCSMetal

final class SceneRenderingTests: XCTestCase {
    func testHierarchyAgainstOriginalPLIB() throws {
        let root=try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil))
        var points=0,maxError: Float=0
        var scenes: [ACScene]=[]
        for i in 0..<16 {
            var scene=try ACScene.parse(ACSceneTests.fixture(primitive:0))
            // Exercise nested rotations, scale and translation, not only the
            // mostly identity transforms in the selected original model files.
            scene.nodes[0].matrix=[1.1,0.2,0,0,-0.3,0.9,0.1,0,0,0,1.3,0,Float(i)*1.7,-3.2,2.8,1]
            scenes.append(scene)
        }
        for (name,car) in [("155-DTM/155-DTM",true),("aalborg/aalborg",false),("trb1-3/wheel0",true)] {
            let scene=try ACScene.parse(Data(contentsOf:root.appendingPathComponent("Artwork/\(name).acc")),car:car)
            scenes.append(scene)
        }
        for scene in scenes {
            let geometry=try SceneGeometry(scene)
            var matrices: [[Float]]=[],batch=0
            let identity: [Float]=[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]
            for node in scene.nodes {
                let parent=node.parent<0 ? identity:matrices[node.parent],local=node.kind==0 ? node.matrix:identity
                var matrix=Array(repeating:Float(0),count:16),world=Array(repeating:Float(0),count:3)
                ref_ac_transform(parent,local,[0,0,0],&matrix,&world);matrices.append(matrix)
                guard let mesh=node.mesh,try !mesh.triangleIndices().isEmpty else { continue }
                let native=geometry.batches[batch];batch += 1
                for i in 0..<mesh.vertices.count/3 {
                    let p=Array(mesh.vertices[i*3..<i*3+3])
                    ref_ac_transform(parent,local,p,&matrix,&world)
                    let v=native.transform*SIMD4(p[0],p[1],p[2],1)
                    for c in 0..<3 { maxError=max(maxError,abs(v[c]-world[c]));XCTAssertEqual(v[c],world[c],accuracy:0.0001) }
                    points += 1
                }
            }
            XCTAssertEqual(batch,geometry.batches.count)
        }
        print("SCENE_TRANSFORMS files=3 authored=16 points=\(points) maxAbsolute=\(maxError)")
    }
    func testSceneCompilationBindingsAndFailures() throws {
        let fm=FileManager.default,dir=fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at:dir,withIntermediateDirectories:true);defer { try? fm.removeItem(at:dir) }
        let input=dir.appendingPathComponent("scene.acc"),output=dir.appendingPathComponent("compiled")
        try ACSceneTests.fixture().write(to:input)
        // Missing dependency: no output or partial stage may remain.
        XCTAssertThrowsError(try CompiledScene.compile(input:input,output:output,roots:[dir],options:.init()))
        XCTAssertFalse(fm.fileExists(atPath:output.path))
        for name in ["tree-base.rgb","detail.rgb","skids.png","shade.png"] { try TextureImageTests.fixture().write(to:dir.appendingPathComponent(name)) }
        try CompiledScene.compile(input:input,output:output,roots:[dir],options:.init())
        let scene=try CompiledScene.load(output);XCTAssertEqual(scene.textures.count,4)
        let first=try Data(contentsOf:output.appendingPathComponent("scene.json"))
        XCTAssertThrowsError(try CompiledScene.compile(input:input,output:output,roots:[dir],options:.init()))
        XCTAssertEqual(try Data(contentsOf:output.appendingPathComponent("scene.json")),first)
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:first) as? [String:Any])
        json["mesh"]="../scene.acc"
        try JSONSerialization.data(withJSONObject:json).write(to:output.appendingPathComponent("scene.json"))
        XCTAssertThrowsError(try CompiledScene.load(output))
        try first.write(to:output.appendingPathComponent("scene.json"))
        let index=try JSONDecoder().decode(SceneIndex.self,from:first)
        let path=output.appendingPathComponent(try XCTUnwrap(index.textures.values.first))
        try Data("corrupt cache".utf8).write(to:path)
        XCTAssertThrowsError(try CompiledScene.load(output))
        XCTAssertFalse(try fm.contentsOfDirectory(atPath:dir.path).contains { $0.hasPrefix(".torcs-scene-") })
        print("SCENE_PACKAGE missingDependencies=1 overwritePreserved=1 traversalRejected=1 corruptionRejected=1")
    }
    static func quad(z: Float=0,color: [Float]=[1,1,1,1],flags: UInt32=0,texture: String?=nil,cull: Bool=true) -> ACMesh {
        let material: [Float]=[0,0,0,1,0,0,0,1,1,1,1,1,0]
        let state=ACRenderState(material:material,texture:texture,flags:flags | (texture == nil ? 0:8),alphaClamp:0.5)
        return ACMesh(primitive:6,vertices:[-1,-1,z,1,-1,z,1,1,z,-1,1,z],normals:[0,0,1],uv:Array(repeating:[0,0,1,0,1,1,0,1],count:4),colors:color,indices:[],strips:[],indexed:false,cull:cull,mapCount:1,mapLevel:1,states:[state,nil,nil,nil])
    }
    static func loaded(_ meshes: [ACMesh],textures: [String:CompiledTexture]=[:]) -> LoadedScene {
        let root=ACNode(parent:-1,kind:0,name:"root",matrix:[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1],mesh:nil)
        let scene=ACScene(nodes:[root]+meshes.map { ACNode(parent:0,kind:2,name:"",matrix:[],mesh:$0) })
        return LoadedScene(asset:ACCompiledAsset(scene:scene,sourceSHA256:"test",cacheKey:"test",options:.init()),textures:textures,source:"authored")
    }
    @MainActor static func pixels(_ scene: LoadedScene) throws -> [UInt8] {
        let r=try SceneRenderer(scene:scene);r.camera.target = .zero;r.camera.distance=3;r.camera.yaw = -.pi/2;r.camera.pitch = .pi/2-0.0001
        return Array(try r.render(width:64,height:64))
    }
    static func pixel(_ p: [UInt8],_ x: Int=32,_ y: Int=32) -> [UInt8] { Array(p[(y*64+x)*4..<(y*64+x)*4+4]) }
    func testGPUTextureOrientationAndLayerModulation() async throws {
        try await MainActor.run {
            var texels: [UInt8]=[]
            for y in 0..<8 { for x in 0..<8 { texels += y<4 ? (x<4 ? [255,0,0,255]:[0,255,0,255]):(x<4 ? [0,0,255,255]:[255,255,255,255]) } }
            let pyramid=try TexturePyramid(image:TextureImage(width:8,height:8,channels:4,pixels:texels),filename:"test",options:.init(mipmaps:false))
            let texture=CompiledTexture(sourceSHA256:"test",cacheKey:"test",filename:"test",options:.init(mipmaps:false),pyramid:pyramid)
            let p=try Self.pixels(Self.loaded([Self.quad(texture:"test")],textures:["test":texture]))
            XCTAssertEqual(Self.pixel(p,20,20),[0,0,255,255]);XCTAssertEqual(Self.pixel(p,44,20),[255,255,255,255])
            XCTAssertEqual(Self.pixel(p,20,44),[255,0,0,255]);XCTAssertEqual(Self.pixel(p,44,44),[0,255,0,255])
            let tinted=try TexturePyramid(image:TextureImage(width:1,height:1,channels:4,pixels:[128,64,255,255]),filename:"tint",options:.init(mipmaps:false))
            let tint=CompiledTexture(sourceSHA256:"test",cacheKey:"test",filename:"tint",options:.init(),pyramid:tinted)
            var mesh=Self.quad(texture:"tint");mesh.mapCount=2;mesh.states[1]=mesh.states[0]
            let q=try Self.pixels(Self.loaded([mesh],textures:["tint":tint]))
            let expected=[64,16,255,255]
            for c in 0..<4 { XCTAssertEqual(Int(Self.pixel(q)[c]),expected[c],accuracy:1) }
            print("SCENE_GPU_TEXTURE orientationQuadrants=4 modulatedLayers=2")
        }
    }
    func testGPUDepthCullingAlphaAndEmission() async throws {
        try await MainActor.run {
            let red=Self.quad(z:0.1,color:[1,0,0,1]),blue=Self.quad(color:[0,0,1,1])
            XCTAssertEqual(Self.pixel(try Self.pixels(Self.loaded([red,blue]))),[255,0,0,255])
            var reverse=red;reverse.vertices=Array(stride(from:9,through:0,by:-3)).flatMap { Array(red.vertices[$0..<$0+3]) }
            XCTAssertEqual(Self.pixel(try Self.pixels(Self.loaded([reverse,blue]))),[0,0,255,255])
            reverse.cull=false
            XCTAssertEqual(Self.pixel(try Self.pixels(Self.loaded([reverse,blue]))),[255,0,0,255])
            let cut=Self.quad(z:0.1,color:[1,0,0,0.4],flags:16)
            XCTAssertEqual(Self.pixel(try Self.pixels(Self.loaded([cut,blue]))),[0,0,255,255])
            let blended=Self.quad(z:0.1,color:[1,0,0,0.5],flags:1|32)
            let p=Self.pixel(try Self.pixels(Self.loaded([blended,blue])))
            for (c,v) in [128,0,128,191].enumerated() { XCTAssertEqual(Int(p[c]),v,accuracy:1) }
            var emissive=Self.quad(color:[0,0,0,1],flags:2)
            emissive.states[0]!.material[4]=0.25;emissive.states[0]!.material[5]=0.5
            let e=Self.pixel(try Self.pixels(Self.loaded([emissive])))
            for (c,v) in [64,128,0,255].enumerated() { XCTAssertEqual(Int(e[c]),v,accuracy:1) }
            print("SCENE_GPU_STATE depth=1 cull=2 alphaTest=1 blend=1 emission=1")
        }
    }
}
