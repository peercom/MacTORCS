// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
@testable import TORCSAssets
@testable import TORCSMetal

final class VegetationTests:XCTestCase {
    static func fixture() throws -> (ACScene,CompiledTexture) {
        let root=try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)).appendingPathComponent("Artwork/aalborg")
        let scene=try ACScene.parse(Data(contentsOf:root.appendingPathComponent("aalborg.acc")))
        let atlas=try TextureCache.decode(TextureCache.compile(Data(contentsOf:root.appendingPathComponent(VegetationForest.textureName)),filename:VegetationForest.textureName))
        return (scene,atlas)
    }
    func testRecoverOriginalPlacementsAndRejectDamagedOrUnrelatedGeometry() throws {
        let (scene,atlas)=try Self.fixture(),geometry=try SceneGeometry(scene)
        let forest=VegetationForest(geometry:geometry,atlas:atlas.pyramid.levels[0])
        XCTAssertEqual(forest.placements.count,169);XCTAssertEqual(forest.batchPlacement.count,676)
        XCTAssertEqual((0..<3).map { family in forest.placements.filter { $0.family==family }.count },[81,79,9])
        let atlasBatches=geometry.batches.indices.filter { geometry.batches[$0].mesh.states[0]?.texture==VegetationForest.textureName }
        XCTAssertEqual(atlasBatches.filter { forest.batchPlacement[$0]==nil }.count,5)
        let again=VegetationForest(geometry:geometry,atlas:atlas.pyramid.levels[0])
        XCTAssertEqual(forest.placements.map(\.transform),again.placements.map(\.transform))
        XCTAssertEqual(forest.placements.map(\.batches),again.placements.map(\.batches))
        for (mesh,repeated) in zip(forest.meshes,again.meshes) {
            XCTAssertEqual(mesh.indices,repeated.indices)
            XCTAssertEqual(mesh.vertices.map(\.position),repeated.vertices.map(\.position))
            XCTAssertEqual(mesh.vertices.map(\.normal),repeated.vertices.map(\.normal))
            XCTAssertEqual(mesh.vertices.map(\.uv01),repeated.vertices.map(\.uv01))
        }
        var damaged=scene
        let index=try XCTUnwrap(damaged.nodes.firstIndex { $0.mesh?.states[0]?.texture==VegetationForest.textureName && $0.mesh?.vertices.count==9 })
        damaged.nodes[index].mesh!.vertices[0] += 1
        XCTAssertEqual(VegetationForest(geometry:try SceneGeometry(damaged),atlas:atlas.pyramid.levels[0]).placements.count,168)
        var unrelated=scene
        for i in unrelated.nodes.indices where unrelated.nodes[i].mesh?.states[0]?.texture==VegetationForest.textureName { unrelated.nodes[i].mesh!.states[0]!.texture="unrecognized.rgb" }
        XCTAssertEqual(VegetationForest(geometry:try SceneGeometry(unrelated),atlas:atlas.pyramid.levels[0]).placements.count,0)
        print("VEGETATION_RECOGNITION trees=169 familyCounts=81,79,9 replacedBatches=676 retainedAtlasBatches=5 damagedTreeRejected=1 unrelatedTextureRejected=1 deterministic=1")
    }
    func testVolumeDetailAndCanopyHeight() throws {
        let (scene,atlas)=try Self.fixture(),forest=VegetationForest(geometry:try SceneGeometry(scene),atlas:atlas.pyramid.levels[0])
        XCTAssertEqual(forest.meshes.count,18)
        for mesh in forest.meshes {
            XCTAssertTrue(mesh.indices.allSatisfy { Int($0)<mesh.vertices.count })
            XCTAssertTrue(mesh.vertices.allSatisfy { v in
                (0..<4).allSatisfy { v.position[$0].isFinite && v.normal[$0].isFinite } && abs(simd_length(v.normal)-1)<0.001 &&
                abs(v.position.x)<=0.5 && abs(v.position.y)<=0.5 && (0...1).contains(v.position.z)
            })
            for axis in 0..<3 { XCTAssertGreaterThan(mesh.vertices.map { $0.position[axis] }.max()!-mesh.vertices.map { $0.position[axis] }.min()!,0.2) }
        }
        for family in 0..<3 {
            let index=try XCTUnwrap(forest.placements.firstIndex { $0.family==family }),tree=forest.placements[index]
            let near=SceneCamera(eye:tree.center+SIMD3(0,-25,5),target:tree.center),far=SceneCamera(eye:tree.center+SIMD3(0,-2000,5),target:tree.center)
            XCTAssertEqual(forest.detail(for:index,camera:near,pixelHeight:640),0)
            XCTAssertEqual(forest.detail(for:index,camera:far,pixelHeight:640),2)
            XCTAssertGreaterThanOrEqual(forest.detail(for:index,camera:near,pixelHeight:32),1)
            let top=tree.transform*SIMD4<Float>(0,0,1,1)
            XCTAssertGreaterThan(forest.height(at:SIMD2(top.x,top.y)),tree.center.z)
        }
        XCTAssertEqual(forest.height(at:SIMD2(-1_000_000,-1_000_000)),-1_000_000)
        print("VEGETATION_VOLUME sharedMeshes=18 finiteNormals=1 threeDimensionalExtents=1 perViewDetail=1 canopyHeightFamilies=3")
    }
    static func treeScene() throws -> LoadedScene {
        var (scene,atlas)=try Self.fixture()
        for i in scene.nodes.indices where scene.nodes[i].mesh != nil && scene.nodes[i].mesh?.states[0]?.texture != VegetationForest.textureName { scene.nodes[i].mesh=nil;scene.nodes[i].kind=1 }
        let root=try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)).appendingPathComponent("Artwork/aalborg")
        var textures=[VegetationForest.textureName:atlas]
        let required=Set(scene.nodes.compactMap(\.mesh).flatMap { $0.states.compactMap { $0?.texture } })
        for name in required where textures[name]==nil { textures[name]=try TextureCache.decode(TextureCache.compile(Data(contentsOf:root.appendingPathComponent(name)),filename:name)) }
        return LoadedScene(asset:ACCompiledAsset(scene:scene,sourceSHA256:"test",cacheKey:"test",options:.init()),textures:textures,source:"aalborg tree test")
    }
    func testGPUVolumeOriginalRestorationAndInstancing() async throws {
        let loaded=try Self.treeScene()
        try await MainActor.run {
            let renderer=try SceneRenderer(scenes:[loaded],vegetationResource:0),baseline=try SceneRenderer(scene:loaded)
            let forest=try XCTUnwrap(renderer.vegetationForest)
            XCTAssertEqual(forest.placements.count,169)
            try renderer.setInstances([SceneInstance(resource:0,anchor:.land)])
            try baseline.setInstances([SceneInstance(resource:0,anchor:.land)])
            var comparisons=0
            for family in 0..<3 {
                let tree=try XCTUnwrap(forest.placements.first { $0.family==family })
                for offset:SIMD3<Float> in [SIMD3(0,-30,5),SIMD3(25,-20,15),SIMD3(1,-1,35)] {
                    renderer.camera=SceneCamera(eye:tree.center+offset,target:tree.center,near:0.1,far:300)
                    baseline.camera=renderer.camera
                    for quality in [false,true] {
                        renderer.smoothEdges=quality;baseline.smoothEdges=quality
                        renderer.enhancedVegetation=false
                        let original=try renderer.render(width:192,height:144)
                        XCTAssertEqual(original,try baseline.render(width:192,height:144))
                        renderer.enhancedVegetation=true
                        let enhanced=try renderer.render(width:192,height:144,captureCommands:true),digest=renderer.lastSubmissionSHA256
                        XCTAssertNotEqual(enhanced,original)
                        XCTAssertGreaterThan(renderer.lastVegetationDrawCount,0);XCTAssertLessThanOrEqual(renderer.lastVegetationDrawCount,18)
                        XCTAssertEqual(enhanced,try renderer.render(width:192,height:144,captureCommands:true));XCTAssertEqual(renderer.lastSubmissionSHA256,digest)
                        renderer.enhancedVegetation=false
                        XCTAssertEqual(original,try renderer.render(width:192,height:144));comparisons += 1
                    }
                }
            }
            XCTAssertEqual(renderer.sceneTextureCount,baseline.sceneTextureCount)
            let tree=forest.placements[0]
            var body=matrix_identity_float4x4;body[3]=SIMD4(tree.center+SIMD3(25,0,0),1)
            renderer.enhancedVegetation=true
            renderer.camera=SceneCamera(eye:SIMD3(1_000_000,0,30),target:SIMD3(1_000_010,0,30),far:300)
            renderer.mirror=RearViewMirror(body:body,bonnetPosition:.zero,hiddenInstances:[])
            _=try renderer.render(width:384,height:288,captureCommands:true)
            XCTAssertTrue(renderer.lastMirrorCommands.contains { if case .vegetation(_,let trees)=$0 { return trees>0 };return false })
            XCTAssertFalse(renderer.lastSceneCommands.contains { if case .vegetation(_,let trees)=$0 { return trees>0 };return false })
            renderer.mirror=RearViewMirror(body:body,bonnetPosition:.zero,hiddenInstances:[0])
            _=try renderer.render(width:384,height:288,captureCommands:true)
            XCTAssertFalse(renderer.lastMirrorCommands.contains { if case .vegetation=$0 { return true };return false })
            print("VEGETATION_GPU views=\(comparisons) repeatPairs=\(comparisons) originalRestorationExact=1 instancedDrawsAtMost18=1 newTextures=0")
            print("VEGETATION_MIRROR mainFarMirrorNear=1 hiddenInstancesRespected=1")
        }
    }
}
