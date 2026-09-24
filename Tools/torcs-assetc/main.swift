// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import TORCSAssets

@main struct AssetCompiler {
    static func main() {
        do {
            var args=Array(CommandLine.arguments.dropFirst()),options=ACCompileOptions(),textureOptions=TextureCompileOptions()
            func flag(_ name: String) -> Bool { if let i=args.firstIndex(of:name) { args.remove(at:i);return true };return false }
            let texture=flag("--texture"),scene=flag("--scene");options.car=flag("--car")
            var roots: [URL]=[]
            while let i=args.firstIndex(of:"--texture-root") {
                guard scene,i+1<args.count else { throw ACError.invalid("--texture-root requires a directory and --scene") }
                roots.append(URL(fileURLWithPath:args[i+1]));args.removeSubrange(i...i+1)
            }
            textureOptions.mipmaps = !flag("--no-mipmaps")
            if let i=args.firstIndex(of:"--texture-units") {
                guard !texture,i+1<args.count,let count=Int(args[i+1]),(1...4).contains(count) else { throw ACError.invalid("--texture-units requires 1…4 and mesh mode") }
                options.textureUnits=count;args.removeSubrange(i...i+1)
            }
            if let i=args.firstIndex(of:"--max-texture-size") {
                guard texture,i+1<args.count,let count=Int(args[i+1]),(1...16_384).contains(count) else { throw ACError.invalid("--max-texture-size requires 1…16384 and --texture") }
                textureOptions.maximumDimension=count;args.removeSubrange(i...i+1)
            }
            guard args.count==2,!(scene && texture),texture ? !options.car:textureOptions.mipmaps else {
                throw ACError.invalid("Usage: torcs-assetc --scene input.acc new-output-directory [--car] [--texture-root directory]; torcs-assetc input output [--car] [--texture-units 1…4]; textures: torcs-assetc --texture input.rgb|png output.torcstex [--no-mipmaps] [--max-texture-size 1…16384]")
            }
            let input=URL(fileURLWithPath:args[0]).standardizedFileURL,output=URL(fileURLWithPath:args[1]).standardizedFileURL
            guard input.resolvingSymlinksInPath() != output.resolvingSymlinksInPath() else { throw ACError.invalid("Output must differ from source") }
            if scene {
                try CompiledScene.compile(input:input,output:output,roots:[input.deletingLastPathComponent()]+roots,options:options)
                print("Compiled scene: \(output.path)")
                return
            }
            let data=try ContentSearchPath.readBounded(input)
            if texture {
                let compiled=try TextureCache.compile(data,filename:input.lastPathComponent,options:textureOptions),asset=try TextureCache.decode(compiled)
                try compiled.write(to:output,options:.atomic)
                print("Compiled texture \(asset.pyramid.sourceWidth)x\(asset.pyramid.sourceHeight), \(asset.pyramid.levels.count) levels, \(compiled.count) bytes")
                print("Source SHA-256: \(asset.sourceSHA256)\nCache key: \(asset.cacheKey)")
            } else {
                let compiled=try ACMeshCache.compile(data,options:options),asset=try ACMeshCache.decode(compiled,expectedOptions:options)
                try compiled.write(to:output,options:.atomic)
                let meshes=asset.scene.nodes.compactMap(\.mesh)
                print("Compiled \(asset.scene.nodes.count) nodes, \(meshes.count) meshes, \(compiled.count) bytes")
                print("Source SHA-256: \(asset.sourceSHA256)\nCache key: \(asset.cacheKey)")
                for warning in asset.scene.warnings ?? [] { FileHandle.standardError.write(Data("Warning: \(warning)\n".utf8)) }
            }
        } catch { FileHandle.standardError.write(Data("torcs-assetc: \(error)\n".utf8));exit(1) }
    }
}
