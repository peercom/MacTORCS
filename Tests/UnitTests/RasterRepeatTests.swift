// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import TORCSConfiguration
import TORCSTrack
@testable import TORCSAssets
@testable import TORCSMetal

final class RasterRepeatTests:XCTestCase {
    static func difference(_ a:Data,_ b:Data,width:Int,height:Int)->(count:Int,maximum:Int) {
        guard a.count==b.count else { return (max(a.count,b.count),255) }
        var count=0,maximum=0
        a.withUnsafeBytes { (x:UnsafeRawBufferPointer) in b.withUnsafeBytes { (y:UnsafeRawBufferPointer) in
            let xp=x.bindMemory(to:UInt8.self),yp=y.bindMemory(to:UInt8.self),stride=width*4
            for row in 0..<height where memcmp(x.baseAddress!.advanced(by:row*stride),y.baseAddress!.advanced(by:row*stride),stride) != 0 {
                for i in row*stride..<(row+1)*stride where xp[i] != yp[i] {
                    count += 1;maximum=max(maximum,abs(Int(xp[i])-Int(yp[i])))
                }
            }
        } }
        return (count,maximum)
    }
    func testMippedBlendedCarRepeatedFrames() async throws {
        let fixtures=try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil))
        let temporary=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let artwork=fixtures.appendingPathComponent("Artwork/155-DTM")
        try CompiledScene.compile(input:artwork.appendingPathComponent("155-DTM.acc"),output:temporary,roots:[artwork],options:.init(car:true))
        let scene=try CompiledScene.load(temporary)
        let parameters=try ParameterDocument.parse(Data(contentsOf:fixtures.appendingPathComponent("aalborg.xml")),entities:["default-surfaces":Data(contentsOf:fixtures.appendingPathComponent("surfaces.xml")),"default-objects":Data(contentsOf:fixtures.appendingPathComponent("objects.xml"))],allowLegacyLatin1:true)
        let graphics=try TrackGraphics(parameters:parameters)
        try await MainActor.run {
            let renderer=try SceneRenderer(scene:scene)
            try renderer.setEnvironment(graphics)
            // Frozen display pose from the settled 155-DTM/Aalborg reproducer.
            // World-space precision and the pitched body are significant here.
            let body=SceneGeometry.matrix([0.99920386,-0.00014869175,0.03989604,0,0.00014834196,1,0.000011727576,0,-0.03989604,-0.000005799982,0.99920386,0,375.6623,484.54697,11.447632,1])
            try renderer.setInstances([SceneInstance(resource:0,transform:body)])
            let target=SIMD3<Float>(375.6623,484.54697,11.447632)
            let cameras=[
                SceneCamera(eye:SIMD3(355.6623,484.54697,14.447632),target:target,fieldOfView:30 * .pi/180,far:1000,fogRange:SIMD2(500,1000)),
                SceneCamera(eye:SIMD3(383.6623,484.54578,11.995538),target:target,near:0.5,far:1000,fogRange:SIMD2(500,1000)),
                SceneCamera(eye:SIMD3(375.6623,504.54697,14.447632),target:target,fieldOfView:30 * .pi/180,far:1000,fogRange:SIMD2(500,1000)),
                SceneCamera(eye:SIMD3(355.6623,484.54993,12.221105),target:SIMD3(365.6623,484.54846,11.447632),fogRange:SIMD2(300,600))
            ]
            let environment=try CarReflectionTests.texture("environment") { x,y in [UInt8(128+x*16),UInt8(128+y*16),255,255] }
            try renderer.setCarEnvironment(reflection:environment,shade:environment,trackShadow:environment)
            let mapping=try CarTrackShadowMapping(trackBounds:ACLoaderBounds(minimumX:0,maximumX:1000,minimumY:0,maximumY:1000),carBounds:ACLoaderBounds(minimumX:-2,maximumX:2,minimumY:-1,maximumY:1))
            var maximum=0,changed=0
            for smoothing in [false,true] {
            renderer.smoothEdges=smoothing
            for reflectionMode in 0..<3 {
            try renderer.setInstances([SceneInstance(resource:0,transform:body,reflection:reflectionMode>0 ? CarReflection(distanceFromStart:1234,yaw:0.37,position:SIMD2(375.66,484.55),trackShadow:reflectionMode==2 ? mapping:nil):nil)])
            for (index,camera) in cameras.enumerated() {
                renderer.camera=camera
                let first=try renderer.render(captureCommands:true),submission=renderer.lastSubmissionSHA256
                var cameraMaximum=0,cameraChanged=0
                for _ in 0..<30 {
                    let next=try renderer.render(captureCommands:true)
                    XCTAssertEqual(renderer.lastSubmissionSHA256,submission)
                    let delta=Self.difference(first,next,width:960,height:640)
                    cameraMaximum=max(cameraMaximum,delta.maximum);cameraChanged=max(cameraChanged,delta.count)
                }
                XCTAssertLessThanOrEqual(cameraMaximum,1,"Camera \(index) repeated channel difference")
                XCTAssertLessThanOrEqual(cameraChanged,Int(Double(first.count)*0.0001),"Camera \(index) repeated pixel coverage")
                maximum=max(maximum,cameraMaximum);changed=max(changed,cameraChanged)
            }
            }
            }
            print("RASTER_REPEAT cameras=4 reflectionModes=3 smoothingModes=2 repeats=720 maxChannelDelta=\(maximum) maximumChangedChannels=\(changed) toleranceUnchanged=1")
        }
    }
    func testAlphaTestSpecializationPreservesBlendAndCutoff() async throws {
        try await MainActor.run {
            for blend in [false,true] { for test in [false,true] { for alpha:Float in [0.4,0.5,0.6] {
                let flags:UInt32=(blend ? 33:0)|(test ? 16:0)
                let foreground=SceneRenderingTests.quad(z:0.1,color:[1,0,0,alpha],flags:flags)
                let background=SceneRenderingTests.quad(color:[0,0,1,1])
                let pixel=SceneRenderingTests.pixel(try SceneRenderingTests.pixels(SceneRenderingTests.loaded([foreground,background])))
                let expected:[Float]
                if test && alpha<=0.5 { expected=[0,0,255,255] }
                else if blend { expected=[255*alpha,0,255*(1-alpha),255*(alpha*alpha+1-alpha)] }
                else { expected=[255,0,0,255*alpha] }
                for channel in 0..<4 { XCTAssertEqual(Float(pixel[channel]),expected[channel],accuracy:1) }
            } } }
            print("ALPHA_SPECIALIZATION pipelines=4 cutoffAndBlendCases=12")
        }
    }
}
