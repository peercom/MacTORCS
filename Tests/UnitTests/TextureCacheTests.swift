// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CryptoKit
import TORCSAssets

final class TextureCacheTests: XCTestCase {
    func testCacheRoundTripIdentityAndCorruption() throws {
        let source=TextureImageTests.fixture(),options=TextureCompileOptions(maximumDimension:4)
        let data=try TextureCache.compileSGI(source,filename:"authored.rgb",options:options)
        XCTAssertEqual(data,try TextureCache.compileSGI(source,filename:"authored.rgb",options:options))
        let decoded=try TextureCache.decode(data),image=try TextureImage.decodeSGI(source)
        XCTAssertEqual(decoded.pyramid,try TexturePyramid(image:image,filename:"authored.rgb",options:options))
        XCTAssertEqual(decoded.options,options)
        let other=try TextureCache.decode(TextureCache.compileSGI(source,filename:"authored_n.rgb",options:options))
        XCTAssertNotEqual(other.cacheKey,decoded.cacheKey);XCTAssertEqual(other.pyramid.levels.count,1)
        XCTAssertThrowsError(try TextureCache.decode(data,expectedSourceSHA256:String(repeating:"0",count:64)))
        for i in stride(from:0,to:data.count,by:13) {
            var bad=data;bad[i] ^= 127;XCTAssertThrowsError(try TextureCache.decode(bad))
            XCTAssertThrowsError(try TextureCache.decode(data.prefix(i)))
        }
        // Checksummed malicious payload: header fields still need validation.
        var bad=data;let dimensionOffset=44+4+"authored.rgb".utf8.count+8
        bad.replaceSubrange(dimensionOffset..<dimensionOffset+4,with:[255,255,255,127])
        bad.replaceSubrange(bad.count-32..<bad.count,with:Array(SHA256.hash(data:bad.dropLast(32))))
        XCTAssertThrowsError(try TextureCache.decode(bad))
    }
    func testSelectedTextureCaches() throws {
        let root=try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)).appendingPathComponent("Artwork")
        var bytes=0,files=0
        for name in ["155-DTM","aalborg"] {
            for url in try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent(name),includingPropertiesForKeys:nil) where url.pathExtension=="rgb" {
                let source=try Data(contentsOf:url),cache=try TextureCache.compileSGI(source,filename:url.lastPathComponent)
                let decoded=try TextureCache.decode(cache,expectedSourceSHA256:SHA256.hash(data:source).map { String(format:"%02x",$0) }.joined())
                XCTAssertEqual(decoded.pyramid,try TexturePyramid(image:TextureImage.decodeSGI(source),filename:url.lastPathComponent))
                bytes += cache.count;files += 1
            }
        }
        print("TEXTURE_CACHE files=\(files) bytes=\(bytes) exactRoundTrip=1")
    }
    func testOrderedContentResolutionAndBounds() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let a=root.appendingPathComponent("car"),b=root.appendingPathComponent("shared")
        for folder in [a,b] { try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true) }
        try Data([1]).write(to:a.appendingPathComponent("same.rgb"));try Data([2]).write(to:b.appendingPathComponent("same.rgb"))
        try Data([3]).write(to:b.appendingPathComponent("only.rgb"))
        let search=ContentSearchPath(roots:[a,b])
        XCTAssertEqual(try Data(contentsOf:search.resolve("same.rgb")),Data([1]))
        XCTAssertEqual(try Data(contentsOf:search.resolve("only.rgb")),Data([3]))
        for name in ["missing.rgb","../shared/only.rgb","/etc/passwd","file:outside","bad\0.rgb","..\\outside"] { XCTAssertThrowsError(try search.resolve(name)) }
        try FileManager.default.createSymbolicLink(at:a.appendingPathComponent("escape.rgb"),withDestinationURL:b.appendingPathComponent("only.rgb"))
        XCTAssertThrowsError(try search.resolve("escape.rgb"))
        try FileManager.default.createSymbolicLink(at:a.appendingPathComponent("inside.rgb"),withDestinationURL:a.appendingPathComponent("same.rgb"))
        XCTAssertEqual(try ContentSearchPath.readBounded(search.resolve("inside.rgb"),maximumBytes:1),Data([1]))
        XCTAssertThrowsError(try ContentSearchPath.readBounded(search.resolve("same.rgb"),maximumBytes:0))
        XCTAssertThrowsError(try ContentSearchPath(roots:[URL(string:"https://example.com")!]).resolve("texture.rgb"))
    }
}
