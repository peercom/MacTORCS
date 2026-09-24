// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CryptoKit
import simd
import CReference
@testable import TORCSAssets
@testable import TORCSMetal

final class CarTrackShadowTests:XCTestCase {
    func testRawBoundsAndOriginalDetailedWheelOrder() throws {
        let fixtures=try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil))
        let names=["aalborg/aalborg","155-DTM/155-DTM"]+(0..<4).map{"trb1-3/wheel\($0)"}
        var bounds:[ACLoaderBounds]=[]
        for name in names {
            let path=fixtures.appendingPathComponent("Artwork/\(name).acc"),data=try Data(contentsOf:path)
            let native=try ACScene.parse(data,car:!name.hasPrefix("aalborg"))
            let json=try XCTUnwrap(ref_ac_load_json(path.path,name.hasPrefix("aalborg") ? 0:1,4))
            let reference=try JSONDecoder().decode(ACScene.self,from:Data(String(cString:json).utf8))
            XCTAssertEqual(native.loaderBounds,reference.loaderBounds)
            bounds.append(try XCTUnwrap(native.loaderBounds))
            XCTAssertEqual(try ACMeshCache.decode(ACMeshCache.compile(data)).scene.loaderBounds,native.loaderBounds)
        }
        let track=bounds[0],width=Double(track.maximumX)-Double(track.minimumX),height=Double(track.maximumY)-Double(track.minimumY)
        let ratios=bounds.dropFirst().flatMap { [(Double($0.maximumX)-Double($0.minimumX))/width,(Double($0.maximumY)-Double($0.minimumY))/height] }
        var original=[Float](repeating:0,count:2),loads:Int32=0
        ref_car_shadow_scale_order(ratios,1,&original,&loads)
        XCTAssertEqual(loads,16)
        let detailed=try CarTrackShadowMapping(trackBounds:track,carBounds:bounds[5])
        XCTAssertEqual([detailed.scale.x,detailed.scale.y],original)
        ref_car_shadow_scale_order(ratios,0,&original,&loads)
        XCTAssertEqual(loads,0)
        let body=try CarTrackShadowMapping(trackBounds:track,carBounds:bounds[1])
        XCTAssertEqual([body.scale.x,body.scale.y],original);XCTAssertNotEqual(body.scale,detailed.scale)
        // Selected wheel extents happen to match, so also distinguish every
        // speed model to detect an incorrectly reordered or shortened load loop.
        let distinct:[Double]=[0.11,0.12,0.21,0.22,0.31,0.32,0.41,0.42,0.51,0.52]
        ref_car_shadow_scale_order(distinct,1,&original,&loads)
        XCTAssertEqual(loads,16);XCTAssertEqual(original,[Float(0.51),Float(0.52)])
        ref_car_shadow_scale_order(distinct,0,&original,&loads)
        XCTAssertEqual(loads,0);XCTAssertEqual(original,[Float(0.11),Float(0.12)])
        // An unreferenced vertex affects bounds; transformed/drawn bounds do not.
        let text=String(decoding:ACSceneTests.fixture(primitive:0),as:UTF8.self).replacingOccurrences(of:"numvert 4",with:"numvert 5").replacingOccurrences(of:"numsurf 2",with:"-900 3 700 0 1 0\nnumsurf 2")
        _ = try ACSceneTests().compare(Data(text.utf8),car:false,label:"unused extreme raw vertex")
        let extra=try XCTUnwrap(ACScene.parse(Data(text.utf8)).loaderBounds)
        XCTAssertEqual(extra.minimumX,-900);XCTAssertEqual(extra.minimumY,-700)
        print("CAR_TRACK_BOUNDS files=6 unreferencedVertex=1 exact=1 detailedLoads=16 detailedScale=\(detailed.scale) bodyScale=\(body.scale)")
    }
    func testProjectedMatrixAgainstOriginalAndInvalidBounds() throws {
        var maximum:Float=0
        for i in 0..<2000 {
            let f=Float(i)
            let track=ACLoaderBounds(minimumX:-100.17,maximumX:300+f*0.2,minimumY:20.1,maximumY:900+f)
            let car=ACLoaderBounds(minimumX:-3.7,maximumX:2.11,minimumY:-0.83,maximumY:1.71)
            let mapping=try CarTrackShadowMapping(trackBounds:track,carBounds:car)
            let p=SIMD2(f*0.5-210,f*1.9-450),yaw=Float(i-1000)*0.0491
            let native=try CarReflection(distanceFromStart:0,yaw:yaw,position:p,trackShadow:mapping)
            var original=[Float](repeating:0,count:18)
            ref_car_track_shadow(track.values,car.values,[p.x,p.y],yaw,-3,1,&original)
            let values=[native.shadowLinear.x,native.shadowLinear.y,native.shadowLinear.z,native.shadowLinear.w,native.shadowOffset.x,native.shadowOffset.y,mapping.scale.x,mapping.scale.y]
            for (a,b) in zip(values,[original[0],original[1],original[4],original[5],original[12],original[13],original[16],original[17]]) {
                maximum=max(maximum,abs(a-b));XCTAssertEqual(a,b,accuracy:0.000001)
            }
        }
        let valid=ACLoaderBounds(minimumX:0,maximumX:1,minimumY:0,maximumY:1)
        for bad in [ACLoaderBounds(minimumX:0,maximumX:0,minimumY:0,maximumY:1),ACLoaderBounds(minimumX:2,maximumX:1,minimumY:0,maximumY:1),ACLoaderBounds(minimumX:.nan,maximumX:1,minimumY:0,maximumY:1)] {
            XCTAssertThrowsError(try CarTrackShadowMapping(trackBounds:bad,carBounds:valid))
        }
        let mapping=try CarTrackShadowMapping(trackBounds:valid,carBounds:valid)
        XCTAssertThrowsError(try CarReflection(distanceFromStart:0,yaw:0,position:SIMD2(.infinity,0),trackShadow:mapping))
        print("CAR_TRACK_MATRIX cases=2000 coefficients=16000 maximum=\(maximum)")
    }
    func testVersionOneCacheCompatibilityAndBoundsValidation() throws {
        let source=ACSceneTests.fixture(),v2=try ACMeshCache.compile(source)
        // v2 adds exactly a float count and four bounds after the old payload.
        var legacy=Data(v2.dropLast(20));legacy.replaceSubrange(8..<12,with:[1,0,0,0])
        func authenticate(_ bytes:inout Data) {
            let size=UInt32(bytes.count-88)
            bytes.replaceSubrange(84..<88,with:(0..<4).map{UInt8(truncatingIfNeeded:size>>($0*8))})
            bytes.replaceSubrange(52..<84,with:Array(SHA256.hash(data:bytes.prefix(52)+bytes.suffix(from:88))))
        }
        authenticate(&legacy)
        let old=try ACMeshCache.decode(legacy),new=try ACMeshCache.decode(v2)
        XCTAssertNil(old.scene.loaderBounds);XCTAssertEqual(old.scene.nodes,new.scene.nodes)
        XCTAssertNotEqual(old.cacheKey,new.cacheKey)
        // Bounds are checked even when a hostile payload has a valid checksum.
        var bad=v2;bad.replaceSubrange((bad.count-16)..<(bad.count-12),with:[0,0,192,127]);authenticate(&bad)
        XCTAssertThrowsError(try ACMeshCache.decode(bad))
        var scene=new.scene;scene.loaderBounds=ACLoaderBounds(minimumX:1,maximumX:0,minimumY:0,maximumY:1)
        XCTAssertThrowsError(try scene.validate())
        print("AC_CACHE_V2 boundsRoundTrip=1 legacyRead=1 separateIdentity=1 invalidBoundsRejected=2")
    }
    func testGPUProjectionGatesPositionRotationAndAlpha() async throws {
        try await MainActor.run {
            let texture=try CarReflectionTests.texture("track-shadow") { x,y in y<4 ? (x<4 ? [128,255,255,255]:[255,128,255,255]):[255,255,128,255] }
            let track=ACLoaderBounds(minimumX:0,maximumX:4,minimumY:0,maximumY:8)
            let car=ACLoaderBounds(minimumX:-1,maximumX:1,minimumY:-1,maximumY:1)
            let mapping=try CarTrackShadowMapping(trackBounds:track,carBounds:car)
            for indexed in [false,true] { for level in [-1,-2,-3,1] {
                var mesh=SceneRenderingTests.quad();mesh.mapLevel=level
                // Constant UV3 exposes matrix order and nonuniform scaling.
                mesh.uv[3]=Array(repeating:[Float(0.25),0.5],count:4).flatMap{$0}
                if indexed { mesh.indexed=true;mesh.primitive=5;mesh.indices=[0,1,3,2];mesh.strips=[4] }
                let r=try SceneRenderer(scene:SceneRenderingTests.loaded([mesh]))
                r.camera=SceneCamera(eye:SIMD3(0,0,2),target:.zero,up:SIMD3(0,1,0))
                try r.setCarEnvironment(reflection:nil,shade:nil,trackShadow:texture)
                @MainActor func pixel(_ position:SIMD2<Float>,_ yaw:Float) throws -> [UInt8] {
                    try r.setInstances([SceneInstance(resource:0,reflection:CarReflection(distanceFromStart:0,yaw:yaw,position:position,trackShadow:mapping))])
                    return SceneRenderingTests.pixel(Array(try r.render(width:64,height:64)))
                }
                let enabled=indexed && level == -3
                XCTAssertEqual(try pixel(.zero,0),enabled ? [128,255,255,255]:[255,255,255,255])
                XCTAssertEqual(try pixel(SIMD2(2,0),0),enabled ? [255,128,255,255]:[255,255,255,255])
                XCTAssertEqual(try pixel(SIMD2(0,4),0),enabled ? [255,255,128,255]:[255,255,255,255])
                XCTAssertEqual(try pixel(.zero,.pi/2),enabled ? [255,128,255,255]:[255,255,255,255])
                r.carTrackShadowsEnabled=false;XCTAssertEqual(try pixel(.zero,0),[255,255,255,255])
                r.carTrackShadowsEnabled=true;try r.setCarEnvironment(reflection:nil,shade:nil)
                XCTAssertEqual(try pixel(.zero,0),[255,255,255,255])
            } }
            var cutout=SceneRenderingTests.quad(z:0.1,flags:16)
            cutout.indexed=true;cutout.primitive=5;cutout.indices=[0,1,3,2];cutout.strips=[4];cutout.mapLevel = -3
            let alpha=try CarReflectionTests.texture("shadow-alpha") { _,_ in [255,255,255,102] }
            let r=try SceneRenderer(scene:SceneRenderingTests.loaded([cutout,SceneRenderingTests.quad(color:[0,0,1,1])]))
            r.camera=SceneCamera(eye:SIMD3(0,0,2),target:.zero,up:SIMD3(0,1,0))
            try r.setCarEnvironment(reflection:nil,shade:nil,trackShadow:alpha)
            try r.setInstances([SceneInstance(resource:0,reflection:CarReflection(distanceFromStart:0,yaw:0,trackShadow:mapping))])
            XCTAssertEqual(SceneRenderingTests.pixel(Array(try r.render(width:64,height:64))),[0,0,255,255])
            print("CAR_TRACK_GPU alphaCutoff=1 gateCases=8 positionAxes=2 nonuniformRotation=1 optionalTexture=1 toggle=1")
        }
    }
    func testGPUSharedSceneTexturesUseBytesNotCacheClaims() async throws {
        try await MainActor.run {
            let a=try CarReflectionTests.texture("same") { _,_ in [128,255,255,255] }
            let b=try CarReflectionTests.texture("same") { _,_ in [255,128,255,255] }
            XCTAssertEqual(a.cacheKey,b.cacheKey) // Deliberately identical claimed identity.
            let mesh=SceneRenderingTests.quad(texture:"same")
            let first=SceneRenderingTests.loaded([mesh],textures:["same":a]),second=SceneRenderingTests.loaded([mesh],textures:["same":b])
            let r=try SceneRenderer(scenes:[first,first,second])
            XCTAssertEqual(r.sceneTextureCount,2)
            r.camera=SceneCamera(eye:SIMD3(0,0,2),target:.zero,up:SIMD3(0,1,0))
            for resource in 0..<3 {
                try r.setInstances([SceneInstance(resource:resource)])
                let expected:[UInt8]=resource==2 ? [255,128,255,255]:[128,255,255,255]
                XCTAssertEqual(SceneRenderingTests.pixel(Array(try r.render(width:64,height:64))),expected)
            }
            print("GPU_SHARED_TEXTURES references=3 resources=2 falseIdentitySeparated=1")
        }
    }

}
