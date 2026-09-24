// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CryptoKit
import TORCSAssets

final class ACMeshCacheTests: XCTestCase {
    func testSelectedMeshesRoundTripDeterministically() throws {
        let root=try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil))
        var size=0,triangles=0
        for name in ["155-DTM","aalborg"] {
            let source=try Data(contentsOf:root.appendingPathComponent("Artwork/\(name)/\(name).acc")),options=ACCompileOptions(car:name=="155-DTM")
            let first=try ACMeshCache.compile(source,options:options),again=try ACMeshCache.compile(source,options:options)
            XCTAssertEqual(first,again)
            let expected=SHA256.hash(data:source).map { String(format:"%02x",$0) }.joined()
            let decoded=try ACMeshCache.decode(first,expectedSourceSHA256:expected,expectedOptions:options)
            XCTAssertEqual(decoded.scene,try ACScene.parse(source,car:options.car));size += first.count
            for mesh in decoded.scene.nodes.compactMap(\.mesh) { let indices=try mesh.triangleIndices();XCTAssertEqual(indices.count%3,0);XCTAssertTrue(indices.allSatisfy { $0<mesh.vertices.count/3 });triangles += indices.count/3 }
        }
        print("ACC_CACHE files=2 bytes=\(size) trianglesIncludingDegenerates=\(triangles) exactRoundTrip=1 repeatable=1")
    }
    func testCacheIdentityCorruptionAndTruncation() throws {
        let source=ACSceneTests.fixture(),data=try ACMeshCache.compile(source),asset=try ACMeshCache.decode(data)
        XCTAssertThrowsError(try ACMeshCache.decode(data,expectedSourceSHA256:String(repeating:"0",count:64)))
        XCTAssertThrowsError(try ACMeshCache.decode(data,expectedOptions:.init(car:true)))
        let changed=try ACMeshCache.decode(ACMeshCache.compile(source+Data("# source identity\n".utf8)))
        XCTAssertNotEqual(asset.cacheKey,changed.cacheKey);XCTAssertEqual(asset.scene,changed.scene)
        let car=try ACMeshCache.decode(ACMeshCache.compile(source,options:.init(car:true)))
        XCTAssertNotEqual(asset.cacheKey,car.cacheKey)
        for index in [0,8,12,16,20,51,52,83,84,88,data.count-1] {
            var corrupt=data;corrupt[index] ^= 0x80;XCTAssertThrowsError(try ACMeshCache.decode(corrupt),"corrupt byte \(index)")
        }
        for count in stride(from:0,to:data.count,by:31) { XCTAssertThrowsError(try ACMeshCache.decode(data.prefix(count))) }
        // Re-authenticate a malicious payload to exercise structural validation,
        // independently of the corruption checksum.
        var malicious=data;malicious.replaceSubrange(88..<92,with:[255,255,255,127])
        let digest=SHA256.hash(data:malicious.prefix(52)+malicious.suffix(from:88));malicious.replaceSubrange(52..<84,with:Array(digest))
        XCTAssertThrowsError(try ACMeshCache.decode(malicious))
    }
    func testTopologyValidationAndStripWinding() throws {
        var scene=try ACScene.parse(ACSceneTests.fixture()),mesh=try XCTUnwrap(scene.nodes.last?.mesh)
        XCTAssertEqual(try mesh.triangleIndices(),[0,1,2,2,1,3,1,0,3,3,0,2])
        mesh.indices[0]=99;scene.nodes[scene.nodes.count-1].mesh=mesh
        XCTAssertThrowsError(try scene.validate())
        scene=try ACScene.parse(ACSceneTests.fixture());scene.nodes[1].parent=1
        XCTAssertThrowsError(try scene.validate())
        scene=try ACScene.parse(ACSceneTests.fixture());scene.nodes[1].matrix[0] = .nan
        XCTAssertThrowsError(try scene.validate())
        for path in ["", "hidden\0.rgb", "../outside.rgb", "/outside.rgb"] {
            scene=try ACScene.parse(ACSceneTests.fixture())
            scene.nodes[scene.nodes.count-1].mesh!.states[0]!.texture=path
            XCTAssertThrowsError(try scene.validate())
        }
        let line=try ACScene.parse(ACSceneTests.fixture(primitive:1));XCTAssertThrowsError(try XCTUnwrap(line.nodes.last?.mesh).triangleIndices())
    }
}
