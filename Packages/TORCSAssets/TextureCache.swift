// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import CryptoKit

public struct CompiledTexture: Sendable {
    public let sourceSHA256: String, cacheKey: String, filename: String
    public let options: TextureCompileOptions, pyramid: TexturePyramid
}

/// Lossless mip cache. Original channel count is retained; Metal clients expand
/// each level to RGBA8 without premultiplying or applying an implicit gamma curve.
public enum TextureCache {
    public static let version: UInt32=2
    public static let compiler="torcs-texture-swift-2"
    static let magic=Array("TORCSTX1".utf8)
    public static func compileSGI(_ data: Data, filename: String, options: TextureCompileOptions = .init()) throws -> Data {
        try compile(image:TextureImage.decodeSGI(data),source:data,filename:filename,options:options)
    }
    public static func compile(_ data: Data, filename: String, options: TextureCompileOptions = .init()) throws -> Data {
        try compile(image:TextureImage.decode(data),source:data,filename:filename,options:options)
    }
    private static func compile(image: TextureImage, source data: Data, filename: String, options: TextureCompileOptions) throws -> Data {
        let pyramid=try TexturePyramid(image:image,filename:filename,options:options)
        var w=ACMeshCache.Writer();w.bytes=magic;w.u32(version)
        w.bytes += Array(SHA256.hash(data:data));try w.string(filename);w.bool(options.mipmaps);w.u32(UInt32(options.maximumDimension))
        w.u32(UInt32(pyramid.sourceWidth));w.u32(UInt32(pyramid.sourceHeight));w.u32(UInt32(pyramid.levels.count))
        for image in pyramid.levels {
            w.u32(UInt32(image.width));w.u32(UInt32(image.height));w.u32(UInt32(image.channels));w.u32(UInt32(image.pixels.count));w.bytes += image.pixels
        }
        w.bytes += Array(SHA256.hash(data:Data(w.bytes)));return Data(w.bytes)
    }
    public static func decode(_ data: Data, expectedSourceSHA256: String? = nil) throws -> CompiledTexture {
        guard data.count>=32,data.count<=96*1024*1024 else { throw ACError.invalid("Texture cache byte limit or truncation") }
        let payload=Array(data.dropLast(32))
        guard Array(SHA256.hash(data:Data(payload)))==Array(data.suffix(32)) else { throw ACError.invalid("Texture cache checksum mismatch") }
        var r=ACMeshCache.Reader(bytes:payload)
        guard try r.take(8)==magic,try r.u32()==version else { throw ACError.invalid("Unsupported texture cache format") }
        let source=try r.take(32),hash=source.map { String(format:"%02x",$0) }.joined()
        guard expectedSourceSHA256.map({ $0==hash }) ?? true else { throw ACError.invalid("Texture cache source mismatch") }
        let filename=try r.string(),mip=try r.bool(),limit=Int(try r.u32())
        let width=Int(try r.u32()),height=Int(try r.u32()),count=try r.count(maximum:15)
        guard (1...16_384).contains(width),(1...16_384).contains(height),width*height<=16_777_216,
              width & (width-1)==0,height & (height-1)==0,(1...16_384).contains(limit),count>0 else { throw ACError.invalid("Invalid texture cache dimensions") }
        var baseWidth=width,baseHeight=height
        while baseWidth>limit || baseHeight>limit { baseWidth >>= 1;baseHeight >>= 1 }
        guard baseWidth>0,baseHeight>0 else { throw ACError.invalid("Invalid texture cache downsizing") }
        var expectedCount=1,w=baseWidth,h=baseHeight
        if TexturePyramid.usesMipmaps(filename:filename,requested:mip) { while w>1 || h>1 { expectedCount += 1;w=max(1,w/2);h=max(1,h/2) } }
        guard count==expectedCount else { throw ACError.invalid("Incomplete or excess mip levels") }
        var levels: [TextureImage]=[],channels: Int?
        for _ in 0..<count {
            let w=Int(try r.u32()),h=Int(try r.u32()),c=Int(try r.u32()),size=try r.count(maximum:64*1024*1024)
            guard w==baseWidth,h==baseHeight,(1...4).contains(c),channels.map({ $0==c }) ?? true,
                  size==w*h*c else { throw ACError.invalid("Invalid cached mip layout") }
            channels=c;levels.append(try TextureImage(width:w,height:h,channels:c,pixels:r.take(size)))
            baseWidth=max(1,baseWidth/2);baseHeight=max(1,baseHeight/2)
        }
        guard r.remaining==0 else { throw ACError.invalid("Trailing texture cache data") }
        var key=ACMeshCache.Writer();key.bytes=source;key.u32(version);try key.string(filename);key.bool(mip);key.u32(UInt32(limit))
        return CompiledTexture(sourceSHA256:hash,cacheKey:SHA256.hash(data:Data(key.bytes)).map { String(format:"%02x",$0) }.joined(),filename:filename,
            options:.init(mipmaps:mip,maximumDimension:limit),pyramid:.init(sourceWidth:width,sourceHeight:height,levels:levels))
    }
}

extension TexturePyramid {
    init(sourceWidth: Int,sourceHeight: Int,levels: [TextureImage]) {
        self.sourceWidth=sourceWidth;self.sourceHeight=sourceHeight;self.levels=levels
    }
}

/// Ordered, explicitly supplied content roots. No implicit working-directory or
/// network fallback; source files and symlink targets must remain inside a root.
public struct ContentSearchPath: Sendable {
    public let roots: [URL]
    public init(roots: [URL]) { self.roots=roots.map { $0.standardizedFileURL.resolvingSymlinksInPath() } }
    public func resolve(_ name: String) throws -> URL {
        guard !name.isEmpty,!name.contains("\0"),!name.hasPrefix("/"),!name.contains("\\"),!name.contains(":"),
              !name.split(separator:"/").contains("..") else { throw ACError.invalid("Unsafe content reference: \(name)") }
        for root in roots {
            guard root.isFileURL else { throw ACError.invalid("Content roots must be local directories") }
            let candidate=root.appendingPathComponent(name).standardizedFileURL.resolvingSymlinksInPath()
            guard candidate.pathComponents.starts(with:root.pathComponents),candidate.pathComponents.count>root.pathComponents.count else { throw ACError.invalid("Content reference escapes its root") }
            if FileManager.default.fileExists(atPath:candidate.path),try candidate.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile==true { return candidate }
        }
        throw ACError.invalid("Missing content dependency: \(name)")
    }
    public static func readBounded(_ url: URL, maximumBytes: Int = 64*1024*1024) throws -> Data {
        guard maximumBytes>=0,url.isFileURL else { throw ACError.invalid("Invalid content read limit or URL") }
        let file=try FileHandle(forReadingFrom:url);defer { try? file.close() };var data=Data()
        while let chunk=try file.read(upToCount:65_536),!chunk.isEmpty {
            guard chunk.count<=maximumBytes-data.count else { throw ACError.invalid("Content input byte limit exceeded") };data.append(chunk)
        }
        return data
    }
}
