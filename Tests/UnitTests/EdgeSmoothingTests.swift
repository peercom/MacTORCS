// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
@testable import TORCSAssets
@testable import TORCSMetal

final class EdgeSmoothingTests:XCTestCase {
    // Independently integrate triangle coverage by clipping it to each pixel.
    static func coverage(_ polygon:[SIMD2<Double>],x:Int,y:Int) -> Double {
        var p=polygon
        for (axis,bound,greater) in [(0,Double(x),true),(0,Double(x+1),false),(1,Double(y),true),(1,Double(y+1),false)] {
            var result:[SIMD2<Double>]=[]
            guard !p.isEmpty else { return 0 }
            for i in p.indices {
                let a=p[i],b=p[(i+1)%p.count]
                let ai=greater ? a[axis]>=bound:a[axis]<=bound,bi=greater ? b[axis]>=bound:b[axis]<=bound
                if ai { result.append(a) }
                if ai != bi { result.append(a+(b-a)*((bound-a[axis])/(b[axis]-a[axis]))) }
            }
            p=result
        }
        guard p.count>=3 else { return 0 }
        return abs(p.indices.reduce(0) { sum,i in let a=p[i],b=p[(i+1)%p.count];return sum+a.x*b.y-b.x*a.y })/2
    }
    func testGeometricCoverageAgainstAnalyticPixelArea() async throws {
        try await MainActor.run {
            let polygon:[SIMD2<Double>]=[SIMD2(5.3,8.7),SIMD2(57.4,17.2),SIMD2(19.6,58.1)]
            var mesh=SceneRenderingTests.quad(cull:false)
            mesh.vertices=polygon.flatMap { [Float(($0.x/64*2-1)*2),Float((1-$0.y/64*2)*2),0] }
            mesh.uv=Array(repeating:[0,0,0,0,0,0],count:4)
            let r=try SceneRenderer(scene:SceneRenderingTests.loaded([mesh]))
            guard r.supportsEdgeSmoothing else { throw XCTSkip("4× MSAA unsupported") }
            try r.setEnvironment(TrackEnvironmentTests().configuration(["background color R":0,"background color G":0,"background color B":0]))
            r.camera=SceneCamera(eye:SIMD3(0,0,2),target:.zero,fieldOfView:.pi/2,near:0.1,far:10,up:SIMD3(0,1,0))
            let classic=Array(try r.render(width:64,height:64));r.smoothEdges=true
            let smooth=Array(try r.render(width:64,height:64))
            var errors=[Double](repeating:0,count:2),partial=0
            for y in 0..<64 { for x in 0..<64 {
                let expected=Self.coverage(polygon,x:x,y:y),i=(y*64+x)*4
                for (j,frame) in [classic,smooth].enumerated() { errors[j] += pow(Double(frame[i])/255-expected,2) }
                if smooth[i]>0 && smooth[i]<255 { partial += 1 }
                if expected<1e-10 || expected>1-1e-10 { XCTAssertEqual(smooth[i],classic[i]) }
            } }
            XCTAssertGreaterThan(partial,50);XCTAssertLessThan(errors[1],errors[0]*0.5)
            XCTAssertEqual(r.rasterSampleCount,4);XCTAssertEqual(r.multisampleAllocationCount,1)
            for _ in 0..<10 { XCTAssertEqual(Array(try r.render(width:64,height:64)),smooth) }
            XCTAssertEqual(r.multisampleAllocationCount,1)
            r.smoothEdges=false;XCTAssertEqual(Array(try r.render(width:64,height:64)),classic)
            print("MSAA_COVERAGE classicSquaredError=\(errors[0]) smoothSquaredError=\(errors[1]) partialPixels=\(partial) interiorsUnchanged=1 repeats=10 memoryless=\(r.usesMemorylessMultisampling)")
        }
    }
    func testMaterialCutoffBlendAndDepthRemainCorrect() async throws {
        try await MainActor.run {
            for blend in [false,true] { for test in [false,true] { for alpha:Float in [0.4,0.5,0.6] {
                let foreground=SceneRenderingTests.quad(z:0.1,color:[1,0,0,alpha],flags:(blend ? 33:0)|(test ? 16:0))
                let r=try SceneRenderer(scene:SceneRenderingTests.loaded([foreground,SceneRenderingTests.quad(color:[0,0,1,1])]))
                guard r.supportsEdgeSmoothing else { throw XCTSkip("4× MSAA unsupported") }
                r.camera=SceneCamera(eye:SIMD3(0,0,2),target:.zero,up:SIMD3(0,1,0))
                let before=SceneRenderingTests.pixel(Array(try r.render(width:64,height:64)))
                r.smoothEdges=true
                let after=SceneRenderingTests.pixel(Array(try r.render(width:64,height:64)))
                for i in 0..<4 { XCTAssertEqual(Float(after[i]),Float(before[i]),accuracy:1) }
            } } }
            print("MSAA_MATERIALS pipelineVariants=4 cutoffBlendCases=12 centerPixelsPreserved=1")
        }
    }
    func testMirrorMultisamplingResizeAndToggleReuse() async throws {
        try await MainActor.run {
            let r=try SceneRenderer(scene:SceneRenderingTests.loaded([SceneRenderingTests.quad()]))
            guard r.supportsEdgeSmoothing else { throw XCTSkip("4× MSAA unsupported") }
            let body=simd_float4x4(SIMD4(0,0,1,0),SIMD4(1,0,0,0),SIMD4(0,1,0,0),SIMD4(0,0,2,1))
            let mirror=RearViewMirror(body:body,bonnetPosition:.zero,hiddenInstances:[])
            r.camera=try mirror.camera(width:96,height:72);r.mirror=mirror
            let original=try r.render(width:96,height:72)
            r.smoothEdges=true
            let smooth=try r.render(width:96,height:72,captureCommands:true),digest=r.lastSubmissionSHA256
            XCTAssertEqual(r.multisampleAllocationCount,2)
            for _ in 0..<10 { XCTAssertEqual(try r.render(width:96,height:72,captureCommands:true),smooth);XCTAssertEqual(r.lastSubmissionSHA256,digest) }
            XCTAssertEqual(r.multisampleAllocationCount,2)
            let odd=try r.render(width:97,height:73)
            XCTAssertEqual(try r.render(width:97,height:73),odd);XCTAssertEqual(r.multisampleAllocationCount,3)
            XCTAssertEqual(try r.render(width:96,height:72),smooth);XCTAssertEqual(r.multisampleAllocationCount,4)
            r.smoothEdges=false;XCTAssertEqual(try r.render(width:96,height:72),original)
            XCTAssertEqual(r.multisampleAllocationCount,4)
            print("MSAA_MIRROR repeats=10 resizeRestore=1 targetsReused=1 classicRestored=1")
        }
    }
}
