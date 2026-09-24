// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import CryptoKit

public struct ACCompileOptions: Sendable, Equatable {
    public var car: Bool,textureUnits: Int
    public init(car: Bool = false,textureUnits: Int = 4) { self.car=car;self.textureUnits=textureUnits }
}
public struct ACCompiledAsset: Sendable {
    public let scene: ACScene,sourceSHA256: String,cacheKey: String,options: ACCompileOptions
}
/// Versioned little-endian binary scene cache. Every payload is authenticated by
/// SHA-256 for corruption detection; this is not a publisher signature.
public enum ACMeshCache {
    public static let version: UInt32=2
    public static let compiler="torcs-ac-swift-2"
    static let magic=Array("TORCSAC1".utf8)
    public static func compile(_ source: Data,options: ACCompileOptions = .init()) throws -> Data {
        let scene=try ACScene.parse(source,car:options.car,textureUnits:options.textureUnits)
        try scene.validate()
        var w=Writer();w.u32(UInt32(scene.nodes.count))
        for node in scene.nodes {
            w.i32(node.parent);w.i32(node.kind);try w.string(node.name);w.floats(node.matrix);w.bool(node.mesh != nil)
            if let m=node.mesh {
                w.i32(m.primitive);w.i32(m.mapCount);w.i32(m.mapLevel);w.bool(m.indexed);w.bool(m.cull)
                w.floats(m.vertices);w.floats(m.normals);for layer in m.uv { w.floats(layer) };w.floats(m.colors)
                w.integers(m.indices);w.integers(m.strips)
                for state in m.states {
                    w.bool(state != nil)
                    if let s=state { w.floats(s.material);w.u32(s.flags);w.floats([s.alphaClamp]);w.bool(s.texture != nil);if let texture=s.texture { try w.string(texture) } }
                }
            }
        }
        let warnings=scene.warnings ?? [];w.u32(UInt32(warnings.count));for warning in warnings { try w.string(warning) }
        w.floats(scene.loaderBounds?.values ?? [])
        var header=Writer();header.bytes=magic;header.u32(version);header.bool(options.car);header.u32(UInt32(options.textureUnits))
        header.bytes += Array(SHA256.hash(data:source));header.bytes += Array(SHA256.hash(data:Data(header.bytes+w.bytes)))
        header.u32(UInt32(w.bytes.count));header.bytes += w.bytes;return Data(header.bytes)
    }
    public static func decode(_ data: Data,expectedSourceSHA256: String? = nil,expectedOptions: ACCompileOptions? = nil) throws -> ACCompiledAsset {
        guard data.count<=256*1024*1024 else { throw ACError.invalid("Mesh cache exceeds byte limit") }
        var r=Reader(bytes:Array(data));guard try r.take(8)==magic else { throw ACError.invalid("Unsupported mesh cache format") }
        let storedVersion=try r.u32();guard storedVersion==1 || storedVersion==version else { throw ACError.invalid("Unsupported mesh cache version") }
        let car=try r.bool(),units=try r.u32();guard (1...4).contains(units) else { throw ACError.invalid("Invalid cached texture-unit count") }
        let options=ACCompileOptions(car:car,textureUnits:Int(units)),source=try r.take(32)
        let identity=Array(r.bytes.prefix(r.cursor)),digest=try r.take(32),size=try r.u32()
        let hash=source.map { String(format:"%02x",$0) }.joined()
        guard expectedSourceSHA256.map({ $0==hash }) ?? true,expectedOptions.map({ $0==options }) ?? true else { throw ACError.invalid("Mesh cache source or options mismatch") }
        guard Int(size)==r.remaining,Array(SHA256.hash(data:Data(identity+Array(r.bytes[r.cursor...]))))==digest else { throw ACError.invalid("Mesh cache payload is corrupt") }
        let count=try r.count(maximum:100_000);var nodes: [ACNode]=[]
        for _ in 0..<count {
            let parent=try r.i32(),kind=try r.i32(),name=try r.string(),matrix=try r.floats(maximum:16)
            var mesh: ACMesh?
            if try r.bool() {
                let primitive=try r.i32(),maps=try r.i32(),level=try r.i32(),indexed=try r.bool(),cull=try r.bool()
                let vertices=try r.floats(),normals=try r.floats();var uv: [[Float]]=[]
                for _ in 0..<4 { uv.append(try r.floats()) }
                let colors=try r.floats(maximum:4),indices=try r.integers(),strips=try r.integers();var states: [ACRenderState?]=[]
                for layer in 0..<4 {
                    if try r.bool() {
                        let material=try r.floats(maximum:13),flags=try r.u32(),alpha=try r.floats(maximum:1)
                        guard alpha.count==1 else { throw ACError.invalid("Invalid alpha clamp storage") }
                        let texture=try r.bool() ? try r.string():nil
                        states.append(.init(material:material,texture:texture,flags:flags,alphaClamp:alpha[0],alphaCare:ACRenderState.loaderAlphaCare(flags:flags,layer:layer)))
                    } else { states.append(nil) }
                }
                mesh=ACMesh(primitive:primitive,vertices:vertices,normals:normals,uv:uv,colors:colors,indices:indices,strips:strips,indexed:indexed,cull:cull,mapCount:maps,mapLevel:level,states:states)
            }
            nodes.append(.init(parent:parent,kind:kind,name:name,matrix:matrix,mesh:mesh))
        }
        let warningCount=try r.count(maximum:100_000);var warnings: [String]=[]
        for _ in 0..<warningCount { warnings.append(try r.string()) }
        var bounds: ACLoaderBounds?
        if storedVersion>=2 {
            let values=try r.floats(maximum:4)
            guard values.isEmpty || values.count==4 else { throw ACError.invalid("Invalid loader bounds buffer") }
            if values.count==4 { bounds=ACLoaderBounds(minimumX:values[0],maximumX:values[1],minimumY:values[2],maximumY:values[3]) }
        }
        guard r.remaining==0 else { throw ACError.invalid("Trailing mesh cache bytes") }
        let scene=ACScene(nodes:nodes,loaderBounds:bounds,warnings:warnings.isEmpty ? nil:warnings);try scene.validate()
        var key=source;var settings=Writer();settings.u32(storedVersion);settings.bool(car);settings.u32(units);key += settings.bytes
        return ACCompiledAsset(scene:scene,sourceSHA256:hash,cacheKey:SHA256.hash(data:Data(key)).map { String(format:"%02x",$0) }.joined(),options:options)
    }
    struct Writer {
        var bytes: [UInt8]=[]
        mutating func u32(_ v: UInt32) { bytes += [UInt8(truncatingIfNeeded:v),UInt8(truncatingIfNeeded:v>>8),UInt8(truncatingIfNeeded:v>>16),UInt8(truncatingIfNeeded:v>>24)] }
        mutating func i32(_ v: Int) { u32(UInt32(bitPattern:Int32(v))) }
        mutating func bool(_ v: Bool) { u32(v ? 1:0) }
        mutating func string(_ s: String) throws { let data=Array(s.utf8);guard data.count<=1_048_576 else { throw ACError.invalid("Cache string too long") };u32(UInt32(data.count));bytes += data }
        mutating func floats(_ a: [Float]) { u32(UInt32(a.count));for v in a { u32(v.bitPattern) } }
        mutating func integers(_ a: [UInt32]) { u32(UInt32(a.count));for v in a { u32(v) } }
    }
    struct Reader {
        let bytes: [UInt8];var cursor=0
        var remaining: Int { bytes.count-cursor }
        mutating func take(_ count: Int) throws -> [UInt8] { guard count>=0,count<=remaining else { throw ACError.invalid("Truncated mesh cache") };defer { cursor += count };return Array(bytes[cursor..<cursor+count]) }
        mutating func u32() throws -> UInt32 { let b=try take(4);return UInt32(b[0])|UInt32(b[1])<<8|UInt32(b[2])<<16|UInt32(b[3])<<24 }
        mutating func i32() throws -> Int { Int(Int32(bitPattern:try u32())) }
        mutating func bool() throws -> Bool { let n=try u32();guard n<=1 else { throw ACError.invalid("Invalid cached Boolean") };return n==1 }
        mutating func count(maximum: Int) throws -> Int { let n=Int(try u32());guard n<=maximum else { throw ACError.invalid("Cache count limit exceeded") };return n }
        mutating func string() throws -> String { let n=try count(maximum:1_048_576);guard let s=String(bytes:try take(n),encoding:.utf8) else { throw ACError.invalid("Invalid cached UTF-8") };return s }
        mutating func floats(maximum: Int = 24_000_000) throws -> [Float] { let n=try count(maximum:maximum);guard n<=remaining/4 else { throw ACError.invalid("Truncated float buffer") };var a: [Float]=[];a.reserveCapacity(n);for _ in 0..<n { let f=Float(bitPattern:try u32());guard f.isFinite else { throw ACError.invalid("Nonfinite cached geometry") };a.append(f) };return a }
        mutating func integers() throws -> [UInt32] { let n=try count(maximum:8_000_000);guard n<=remaining/4 else { throw ACError.invalid("Truncated index buffer") };var a: [UInt32]=[];a.reserveCapacity(n);for _ in 0..<n { a.append(try u32()) };return a }
    }
}

extension ACScene {
    public func validate() throws {
        try loaderBounds?.validate()
        guard !nodes.isEmpty,nodes.count<=100_000 else { throw ACError.invalid("Invalid scene node count") }
        var vertices=0,references=0
        for (i,node) in nodes.enumerated() {
            guard (i==0 ? node.parent == -1:node.parent>=0 && node.parent<i && nodes[node.parent].kind != 2),
                  (0...2).contains(node.kind),node.matrix.count==(node.kind==0 ? 16:0),node.matrix.allSatisfy(\.isFinite),
                  (node.kind==2)==(node.mesh != nil) else { throw ACError.invalid("Invalid scene topology or transform") }
            guard let m=node.mesh else { continue }
            let n=m.vertices.count/3;vertices += n;references += m.indices.count
            guard vertices<=2_000_000,references<=8_000_000,(2...6).contains(m.primitive),
                  m.vertices.count%3==0,m.normals.count==0 || m.normals.count==3 || m.normals.count==n*3,
                  m.uv.count==4,m.uv.allSatisfy({ $0.isEmpty || $0.count==n*2 }),m.colors.count==4,m.states.count==4,
                  (1...4).contains(m.mapCount),m.indices.allSatisfy({ $0<n }),
                  m.indexed ? (m.primitive==5 && m.strips.reduce(UInt64(0),{ $0+UInt64($1) })<=m.indices.count):(m.indices.isEmpty && m.strips.isEmpty) else { throw ACError.invalid("Invalid mesh buffer shape or indices") }
            for a in [m.vertices,m.normals,m.colors]+m.uv { guard a.allSatisfy(\.isFinite) else { throw ACError.invalid("Nonfinite mesh buffer") } }
            for state in m.states.compactMap({ $0 }) {
                guard state.material.count==13,state.material.allSatisfy(\.isFinite),state.alphaClamp.isFinite,state.flags & ~63==0,state.alphaCare & ~3==0 else { throw ACError.invalid("Invalid material state") }
                if let t=state.texture { guard !t.isEmpty,!t.contains("\0"),!t.hasPrefix("/"),!t.contains("\\"),!t.contains(":"),!t.split(separator:"/").contains("..") else { throw ACError.invalid("Unsafe cached texture path") } }
            }
        }
    }
}

extension ACMesh {
    /// Metal-ready triangle indices, preserving each strip boundary and winding.
    /// Degenerate references are retained, as in the original draw calls.
    public func triangleIndices() throws -> [UInt32] {
        guard [4,5,6].contains(primitive) else { throw ACError.invalid("Line geometry requires a line rendering pipeline") }
        let source=indexed ? indices:Array(0..<UInt32(vertices.count/3))
        var result: [UInt32]=[],offset=0
        let batches=indexed ? strips.map(Int.init):[source.count]
        for n in batches {
            guard n<=source.count-offset else { throw ACError.invalid("Strip exceeds index buffer") }
            if primitive==4 { for i in stride(from:0,to:n-n%3,by:3) { result += source[(offset+i)...(offset+i+2)] } }
            else if n>=3 {
                for i in 2..<n {
                    if primitive==6 { result += [source[offset],source[offset+i-1],source[offset+i]] }
                    else if i%2==0 { result += [source[offset+i-2],source[offset+i-1],source[offset+i]] }
                    else { result += [source[offset+i-1],source[offset+i-2],source[offset+i]] }
                }
            }
            offset += n
        }
        return result
    }
}
