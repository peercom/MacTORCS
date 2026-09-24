// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import TORCSCore
import TORCSAssets
import TORCSConfiguration
import TORCSTrack
import TORCSSimulation

/// Prepared local session, not a general content installer or a redistribution grant.
public struct DrivingSessionIndex: Codable,Sendable {
    public let version: Int
    public let name,car,category,track,surfaces,objects,body,scenery: String
    public let wheels: [String]
    public let shadow: String?
    public let background: String?
    public let reflection,environmentShade,trackShadow: String?
    public let lightTextures: [String:String]?
}
public struct DrivingContent: Sendable {
    public let name: String
    public let scenes: [LoadedScene]
    public let brakeScenes: [LoadedScene]
    public let lights: [CarLightDefinition]
    public let lightTextures: [String:CompiledTexture]
    public var renderScenes: [LoadedScene] { scenes+brakeScenes }
    public var brakeResources: [Int] { Array(6..<18) }
    public let simulation: SingleVehicleSimulation
    public let minimumGear,maximumGear: Int
    public let bonnetPosition,driverPosition: SIMD3<Float>
    public let dimensions: SIMD2<Float>
    public let shadow: CompiledTexture?
    public let graphics: TrackGraphics
    public let background: CompiledTexture?
    public let reflection,environmentShade,trackShadow: CompiledTexture?
    public var trackLoaderBounds: ACLoaderBounds? { scenes[5].asset.scene.loaderBounds }
    // This prepared session always uses detailed wheels. grcar stores sx/sy
    // after initWheel has loaded speed meshes 0...3 for the last wheel.
    public var carShadowLoaderBounds: ACLoaderBounds? { scenes[4].asset.scene.loaderBounds }
    public static func load(_ directory: URL) throws -> DrivingContent {
        let loading=PerformanceSignposts.begin("Asset loading")
        defer { PerformanceSignposts.end("Asset loading",loading) }
        let search=ContentSearchPath(roots:[directory])
        func read(_ name: String) throws -> Data { try ContentSearchPath.readBounded(search.resolve(name),maximumBytes:8*1024*1024) }
        let index=try JSONDecoder().decode(DrivingSessionIndex.self,from:ContentSearchPath.readBounded(search.resolve("driving.json"),maximumBytes:65_536))
        guard index.version==1,index.wheels.count==4,!index.name.isEmpty,index.name.count<=200 else { throw ACError.invalid("Unsupported driving session version, name or wheel resources") }
        let parameters=try ParameterDocument.parse(read(index.category)).merging(ParameterDocument.parse(read(index.car)))
        let definition=try VehicleDynamicsDefinition(parameters:parameters)
        let lights=try CarLightDefinition.load(parameters)
        let trackParameters=try ParameterDocument.parse(read(index.track),entities:["default-surfaces":read(index.surfaces),"default-objects":read(index.objects)],allowLegacyLatin1:true)
        let road=try TrackBuilder.buildRoad(parameters:trackParameters)
        let graphics=try TrackGraphics(parameters:trackParameters)
        let background=try index.background.map { try TextureCache.decode(ContentSearchPath.readBounded(search.resolve($0),maximumBytes:96*1024*1024)) }
        let scenes=try ([index.body]+index.wheels+[index.scenery]).map { reference in
            let file=try search.resolve(reference)
            guard file.lastPathComponent=="scene.json" else { throw ACError.invalid("Driving model must reference a scene.json index") }
            return try CompiledScene.load(file.deletingLastPathComponent())
        }
        func number(_ section: String,_ key: String,_ fallback: Float) -> Float { parameters.section(section)?.number(key,default:fallback) ?? fallback }
        let driver=SIMD3(number("Driver","xpos",0),number("Driver","ypos",0),number("Driver","zpos",0))
        let bonnet=SIMD3(number("Bonnet","xpos",number("Driver","xpos",0)),number("Bonnet","ypos",number("Driver","ypos",0)),number("Bonnet","zpos",number("Driver","zpos",0)))
        let dimensions=SIMD2(number("Car","body length",4.7),number("Car","body width",1.9))
        guard [driver.x,driver.y,driver.z,bonnet.x,bonnet.y,bonnet.z,dimensions.x,dimensions.y].allSatisfy(\.isFinite),dimensions.x>0,dimensions.y>0 else { throw ACError.invalid("Invalid visual car dimensions or bonnet position") }
        let shadow=try index.shadow.map { try TextureCache.decode(ContentSearchPath.readBounded(search.resolve($0),maximumBytes:96*1024*1024)) }
        let reflection=try index.reflection.map { try TextureCache.decode(ContentSearchPath.readBounded(search.resolve($0),maximumBytes:96*1024*1024)) }
        let environmentShade=try index.environmentShade.map { try TextureCache.decode(ContentSearchPath.readBounded(search.resolve($0),maximumBytes:96*1024*1024)) }
        let trackShadow=try index.trackShadow.map { try TextureCache.decode(ContentSearchPath.readBounded(search.resolve($0),maximumBytes:96*1024*1024)) }
        var simulation=try SingleVehicleSimulation(definition:definition,road:road,startDistance:max(0,road.length-10))
        try simulation.settle()
        var lightTextures:[String:CompiledTexture]=[:]
        if let inputs=index.lightTextures {
            let required=Set(lights.map { $0.type.textureName })
            guard Set(inputs.keys)==required else { throw ACError.invalid("Light texture keys must match configured car lights") }
            for (name,path) in inputs {
                let texture=try TextureCache.decode(ContentSearchPath.readBounded(search.resolve(path),maximumBytes:96*1024*1024))
                guard texture.pyramid.levels.count==1 else { throw ACError.invalid("Car lights require original non-mipmapped textures") }
                lightTextures[name]=texture
            }
        }
        let brakeScenes=try (0..<4).flatMap { i in
            let wheel=definition.chassis.runningGear.wheels[i]
            return try BrakeGeometry(wheel:i,radius:wheel.brake.radius,width:wheel.force.tireWidth).parts
        }
        return DrivingContent(name:index.name,scenes:scenes,brakeScenes:brakeScenes,lights:lights,lightTextures:lightTextures,simulation:simulation,
            minimumGear:definition.transmission.minimumGear,maximumGear:definition.transmission.maximumGear,bonnetPosition:bonnet,driverPosition:driver,dimensions:dimensions,shadow:shadow,graphics:graphics,background:background,reflection:reflection,environmentShade:environmentShade,trackShadow:trackShadow)
    }
}
