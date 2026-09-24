// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// A compiled inspection scene. Caches retain their original content hashes.
/// This directory is not a redistributable content package or a license grant.
public struct SceneIndex: Codable, Sendable {
    public let version: Int
    public let mesh: String
    public let textures: [String: String]
    public let source: String
}
public struct LoadedScene: Sendable {
    public let asset: ACCompiledAsset
    public let textures: [String: CompiledTexture]
    public let source: String
}
public enum CompiledScene {
    public static func load(_ directory: URL) throws -> LoadedScene {
        let search=ContentSearchPath(roots:[directory])
        let index=try JSONDecoder().decode(SceneIndex.self,from:ContentSearchPath.readBounded(search.resolve("scene.json"),maximumBytes:1_048_576))
        guard index.version==1,index.textures.count<=4096 else { throw ACError.invalid("Unsupported scene version or texture count") }
        let asset=try ACMeshCache.decode(ContentSearchPath.readBounded(search.resolve(index.mesh),maximumBytes:256*1024*1024))
        let required=Set(asset.scene.nodes.compactMap(\.mesh).flatMap { $0.states.compactMap { $0?.texture } })
        guard Set(index.textures.keys)==required else { throw ACError.invalid("Scene texture bindings do not match mesh dependencies") }
        var textures: [String:CompiledTexture]=[:],total=0
        for name in required.sorted() {
            let data=try ContentSearchPath.readBounded(search.resolve(index.textures[name]!),maximumBytes:96*1024*1024)
            total += data.count
            guard total<=512*1024*1024 else { throw ACError.invalid("Scene texture budget exceeded") }
            let texture=try TextureCache.decode(data)
            guard texture.filename==name else { throw ACError.invalid("Scene texture filename mismatch: \(name)") }
            textures[name]=texture
        }
        return LoadedScene(asset:asset,textures:textures,source:index.source)
    }
    /// Compiles in a sibling staging directory, publishing only a complete scene.
    /// Existing output is never overwritten. Explicit roots preserve lookup order.
    public static func compile(input: URL, output: URL, roots: [URL], options: ACCompileOptions) throws {
        let fm=FileManager.default
        guard !fm.fileExists(atPath:output.path) else { throw ACError.invalid("Scene destination already exists") }
        let mesh=try ACMeshCache.compile(ContentSearchPath.readBounded(input),options:options)
        let decoded=try ACMeshCache.decode(mesh)
        let required=Set(decoded.scene.nodes.compactMap(\.mesh).flatMap { $0.states.compactMap { $0?.texture } })
        guard required.count<=4096 else { throw ACError.invalid("Scene texture count exceeded") }
        let search=ContentSearchPath(roots:roots)
        let stage=output.deletingLastPathComponent().appendingPathComponent(".torcs-scene-"+UUID().uuidString)
        try fm.createDirectory(at:stage,withIntermediateDirectories:false)
        defer { try? fm.removeItem(at:stage) }
        try mesh.write(to:stage.appendingPathComponent("model.torcsmesh"))
        var bindings: [String:String]=[:],total=0
        for (i,name) in required.sorted().enumerated() {
            let data=try TextureCache.compile(ContentSearchPath.readBounded(search.resolve(name)),filename:name)
            total += data.count
            guard total<=512*1024*1024 else { throw ACError.invalid("Scene texture budget exceeded") }
            let path="texture-\(i).torcstex";bindings[name]=path
            try data.write(to:stage.appendingPathComponent(path))
        }
        let index=SceneIndex(version:1,mesh:"model.torcsmesh",textures:bindings,source:input.lastPathComponent)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(index).write(to:stage.appendingPathComponent("scene.json"))
        _ = try load(stage)
        try fm.moveItem(at:stage,to:output)
    }
}
