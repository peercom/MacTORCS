// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
@testable import TORCSMetal

final class VegetationFogTests:XCTestCase {
    func testPerspectiveDepthPreservesPartialAndFullFog() async throws {
        let loaded=try VegetationTests.treeScene()
        let graphics=try TrackEnvironmentTests().configuration(["background color R":0.5,"background color G":0.6,"background color B":0.7])
        try await MainActor.run {
            let renderer=try SceneRenderer(scenes:[loaded],vegetationResource:0)
            let forest=try XCTUnwrap(renderer.vegetationForest)
            try renderer.setEnvironment(graphics)
            try renderer.setInstances([SceneInstance(resource:0,anchor:.land)])
            renderer.enhancedVegetation=true
            // Odd dimensions place the center sample exactly on a vertical ray.
            // The CPU canopy intersection supplies an independent eye-depth oracle.
            let width=191,height=143,index=((height/2)*width+width/2)*4
            for family in 0..<3 {
                let tree=try XCTUnwrap(forest.placements.first { $0.family==family })
                let eye=tree.center+SIMD3<Float>(0,0,35)
                let canopy=forest.height(at:SIMD2(tree.center.x,tree.center.y))
                XCTAssertGreaterThan(canopy,tree.center.z)
                let depth=eye.z-canopy
                XCTAssertGreaterThan(depth,0)
                renderer.camera=SceneCamera(eye:eye,target:tree.center,fieldOfView:10 * .pi/180,near:0.1,far:300,up:SIMD3(0,1,0))
                for quality in [false,true] {
                    renderer.smoothEdges=quality;renderer.camera.fogRange=nil
                    let baseline=try renderer.render(width:width,height:height)
                    if !quality {
                        renderer.camera.fogRange=SIMD2(depth*0.5,depth*1.5)
                        let partial=try renderer.render(width:width,height:height)
                        for c in 0..<3 {
                            let expected=Float(baseline[index+c])*0.5+graphics.fogColor[c]*255*0.5
                            XCTAssertEqual(Float(partial[index+c]),expected,accuracy:1.1,"Family \(family), channel \(c)")
                        }
                    }
                    renderer.camera.fogRange=SIMD2(0,depth*0.5)
                    let full=try renderer.render(width:width,height:height)
                    for c in 0..<3 { XCTAssertEqual(Float(full[index+c]),graphics.fogColor[c]*255,accuracy:1) }
                    renderer.camera.fogRange=nil
                    XCTAssertEqual(baseline,try renderer.render(width:width,height:height))
                }
            }
            print("VEGETATION_FOG families=3 partialFogDepthOracle=3 fullFog=6 fogOffRestorationExact=6")
        }
    }
}
