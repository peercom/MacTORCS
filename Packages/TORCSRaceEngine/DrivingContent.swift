// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import TORCSCore
import TORCSAssets
import TORCSConfiguration
import TORCSTrack
import TORCSSimulation

/// Prepared local session, not a general content installer or a redistribution grant.
///
/// A session folder pairs one track with one car. It reads as a track package
/// and a car package at once, so the content it holds combines with any other.
public struct DrivingSessionIndex: Codable,Sendable {
    public let version: Int
    public let name,car,category,track,surfaces,objects,body,scenery: String
    public let wheels: [String]
    public let shadow: String?
    public let background: String?
    public let reflection,environmentShade,trackShadow: String?
    public let lightTextures: [String:String]?
}
/// A circuit on its own: `track.json` in a folder holding the track document,
/// the shared surfaces and objects, the compiled scenery and its images.
public struct TrackPackageIndex: Codable,Sendable,Equatable {
    public let version: Int
    public let name,track,surfaces,objects,scenery: String
    public let background,reflection,environmentShade,trackShadow: String?
    /// A rendered view of the circuit for the menus, if one was prepared.
    public let preview: String?
    public init(version: Int = 1,name: String,track: String,surfaces: String,objects: String,scenery: String,
                background: String? = nil,reflection: String? = nil,environmentShade: String? = nil,
                trackShadow: String? = nil,preview: String? = nil) {
        self.version=version;self.name=name;self.track=track;self.surfaces=surfaces;self.objects=objects
        self.scenery=scenery;self.background=background;self.reflection=reflection
        self.environmentShade=environmentShade;self.trackShadow=trackShadow;self.preview=preview
    }
}
/// A car on its own: `car.json` in a folder holding the car and category
/// documents, the compiled body and wheels, and its shadow and light images.
public struct CarPackageIndex: Codable,Sendable,Equatable {
    public let version: Int
    public let name,car,category,body: String
    public let wheels: [String]
    public let shadow: String?
    public let lightTextures: [String:String]?
    /// A rendered view of the car for the menus, if one was prepared.
    public let preview: String?
    public init(version: Int = 1,name: String,car: String,category: String,body: String,wheels: [String],
                shadow: String? = nil,lightTextures: [String:String]? = nil,preview: String? = nil) {
        self.version=version;self.name=name;self.car=car;self.category=category;self.body=body
        self.wheels=wheels;self.shadow=shadow;self.lightTextures=lightTextures;self.preview=preview
    }
}
public enum ContentPackage {
    public static let sessionIndexName="driving.json",trackIndexName="track.json",carIndexName="car.json"
    private static func decode<T: Decodable>(_ type: T.Type,_ name: String,in directory: URL) throws -> T? {
        let url=directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath:url.path) else { return nil }
        return try JSONDecoder().decode(type,from:ContentSearchPath.readBounded(ContentSearchPath(roots:[directory]).resolve(name),maximumBytes:65_536))
    }
    private static func session(in directory: URL) throws -> DrivingSessionIndex? {
        guard let index=try decode(DrivingSessionIndex.self,sessionIndexName,in:directory) else { return nil }
        guard index.version==1,index.wheels.count==4,!index.name.isEmpty,index.name.count<=200 else {
            throw ACError.invalid("Unsupported driving session version, name or wheel resources")
        }
        return index
    }
    /// Whether a folder holds a track, a car, or (a session) both.
    public static func kinds(in directory: URL) -> (track: Bool,car: Bool) {
        let has: (String)->Bool = { FileManager.default.fileExists(atPath:directory.appendingPathComponent($0).path) }
        let session=has(sessionIndexName)
        return (session || has(trackIndexName),session || has(carIndexName))
    }
    public static func trackIndex(in directory: URL) throws -> TrackPackageIndex {
        if let index=try decode(TrackPackageIndex.self,trackIndexName,in:directory) {
            guard index.version==1,!index.name.isEmpty,index.name.count<=200 else { throw ACError.invalid("Unsupported track package version or name") }
            return index
        }
        guard let s=try session(in:directory) else { throw ACError.invalid("No track package in \(directory.lastPathComponent)") }
        return TrackPackageIndex(name:s.name,track:s.track,surfaces:s.surfaces,objects:s.objects,scenery:s.scenery,
            background:s.background,reflection:s.reflection,environmentShade:s.environmentShade,trackShadow:s.trackShadow)
    }
    public static func carIndex(in directory: URL) throws -> CarPackageIndex {
        if let index=try decode(CarPackageIndex.self,carIndexName,in:directory) {
            guard index.version==1,index.wheels.count==4,!index.name.isEmpty,index.name.count<=200 else { throw ACError.invalid("Unsupported car package version, name or wheel resources") }
            return index
        }
        guard let s=try session(in:directory) else { throw ACError.invalid("No car package in \(directory.lastPathComponent)") }
        return CarPackageIndex(name:s.name,car:s.car,category:s.category,body:s.body,wheels:s.wheels,shadow:s.shadow,lightTextures:s.lightTextures)
    }
    static func scene(_ reference: String,_ search: ContentSearchPath) throws -> LoadedScene {
        let file=try search.resolve(reference)
        guard file.lastPathComponent=="scene.json" else { throw ACError.invalid("Driving model must reference a scene.json index") }
        return try CompiledScene.load(file.deletingLastPathComponent())
    }
    static func texture(_ reference: String?,_ search: ContentSearchPath) throws -> CompiledTexture? {
        try reference.map { try TextureCache.decode(ContentSearchPath.readBounded(search.resolve($0),maximumBytes:96*1024*1024)) }
    }
}

/// One car model, loaded: what the physics, the cameras and the renderer need
/// of it. A field holds one of these per distinct model.
public struct CarContent: Sendable {
    public let directory: URL
    public let name: String
    /// The merged category and car parameters, which a race needs to build an
    /// entry for this car.
    public let parameters: ParameterDocument
    public let definition: VehicleDynamicsDefinition
    /// Body, then the four wheel speed resources.
    public let scenes: [LoadedScene]
    public let brakeScenes: [LoadedScene]
    public let lights: [CarLightDefinition]
    public let lightTextures: [String:CompiledTexture]
    public let minimumGear,maximumGear: Int
    public let bonnetPosition,driverPosition: SIMD3<Float>
    public let dimensions: SIMD2<Float>
    public let shadow: CompiledTexture?
    /// How the car sounds: the engine sample its document names and how fast
    /// it plays, the engine's red line in rad/s, and its turbo.
    public struct Sound: Sendable,Equatable {
        public let engineSample: String
        public let rpmScale,redLine: Float
        public let turbo: Bool
        public let turboSpeed,turboLag: Float
    }
    public let sound: Sound
    /// The seventeen scenes a renderer draws this car from: body, wheels, brakes.
    public var renderScenes: [LoadedScene] { scenes+brakeScenes }
    public static func load(_ directory: URL) throws -> CarContent {
        let search=ContentSearchPath(roots:[directory])
        func read(_ name: String) throws -> Data { try ContentSearchPath.readBounded(search.resolve(name),maximumBytes:8*1024*1024) }
        let index=try ContentPackage.carIndex(in:directory)
        let car=try ParameterDocument.parse(read(index.car))
        let parameters=try ParameterDocument.parse(read(index.category)).merging(car)
        let definition=try VehicleDynamicsDefinition(parameters:parameters)
        let lights=try CarLightDefinition.load(parameters)
        let scenes=try ([index.body]+index.wheels).map { try ContentPackage.scene($0,search) }
        func number(_ section: String,_ key: String,_ fallback: Float) -> Float { parameters.section(section)?.number(key,default:fallback) ?? fallback }
        let driver=SIMD3(number("Driver","xpos",0),number("Driver","ypos",0),number("Driver","zpos",0))
        let bonnet=SIMD3(number("Bonnet","xpos",number("Driver","xpos",0)),number("Bonnet","ypos",number("Driver","ypos",0)),number("Bonnet","zpos",number("Driver","zpos",0)))
        let dimensions=SIMD2(number("Car","body length",4.7),number("Car","body width",1.9))
        guard [driver.x,driver.y,driver.z,bonnet.x,bonnet.y,bonnet.z,dimensions.x,dimensions.y].allSatisfy(\.isFinite),dimensions.x>0,dimensions.y>0 else { throw ACError.invalid("Invalid visual car dimensions or bonnet position") }
        let shadow=try ContentPackage.texture(index.shadow,search)
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
        let id=URL(fileURLWithPath:index.car).deletingPathExtension().lastPathComponent
        // The original's defaults: engine-1.wav at scale 1, no turbo, a
        // turbo speed of 100 rad/s and a lag of 1.
        let engine=parameters.section("Engine")
        let sound=Sound(engineSample:parameters.section("Sound")?.string("engine sample",default:"engine-1.wav") ?? "engine-1.wav",
            rpmScale:number("Sound","rpm scale",1),redLine:engine?.number("revs limiter",default:800) ?? 800,
            turbo:engine?.string("turbo",default:"false")=="true",
            turboSpeed:engine?.number("turbo rpm",default:100) ?? 100,turboLag:engine?.number("turbo lag",default:1) ?? 1)
        return CarContent(directory:directory,name:CarDescriptor.displayName(document:car.name,id:id),parameters:parameters,definition:definition,
            scenes:scenes,brakeScenes:brakeScenes,lights:lights,lightTextures:lightTextures,
            minimumGear:definition.transmission.minimumGear,maximumGear:definition.transmission.maximumGear,
            bonnetPosition:bonnet,driverPosition:driver,dimensions:dimensions,shadow:shadow,sound:sound)
    }
}

/// One circuit, loaded.
public struct TrackContent: Sendable {
    public let directory: URL
    public let name: String
    public let road: TrackRoad
    public let graphics: TrackGraphics
    public let scenery: LoadedScene
    public let background,reflection,environmentShade,trackShadow: CompiledTexture?
    /// The native starting grid for a full field, for painting the boxes.
    public let gridSlots: [StartingGridSlot]
    public static func load(_ directory: URL) throws -> TrackContent {
        let search=ContentSearchPath(roots:[directory])
        func read(_ name: String) throws -> Data { try ContentSearchPath.readBounded(search.resolve(name),maximumBytes:8*1024*1024) }
        let index=try ContentPackage.trackIndex(in:directory)
        let parameters=try ParameterDocument.parse(read(index.track),entities:["default-surfaces":read(index.surfaces),"default-objects":read(index.objects)],allowLegacyLatin1:true)
        let road=try TrackBuilder.buildRoad(parameters:parameters)
        let graphics=try TrackGraphics(parameters:parameters)
        // The painted grid: the native placement for a full field, the
        // track's own Starting Grid section overriding the defaults.
        let gridConfiguration=try StartingGridConfiguration(race:parameters,raceName:"",track:parameters)
        let gridSlots=(try? StartingGrid.slots(road:road,configuration:gridConfiguration,cars:DrivingContent.paintedGridSlots)) ?? []
        let header=parameters.section("Header")?.string("name",default:"") ?? ""
        return TrackContent(directory:directory,name:header.isEmpty ? index.name:header,road:road,graphics:graphics,
            scenery:try ContentPackage.scene(index.scenery,search),
            background:try ContentPackage.texture(index.background,search),
            reflection:try ContentPackage.texture(index.reflection,search),
            environmentShade:try ContentPackage.texture(index.environmentShade,search),
            trackShadow:try ContentPackage.texture(index.trackShadow,search),gridSlots:gridSlots)
    }
}

public struct DrivingContent: Sendable {
    public let name: String
    public let track: TrackContent
    /// The player's car.
    public let car: CarContent
    /// Further car models a field may use, after the player's. Model 0 is the
    /// player's car; model `n` is `opponentCars[n-1]`.
    public let opponentCars: [CarContent]
    /// Body, the four wheels, then the scenery: the classic resource order.
    public var scenes: [LoadedScene] { car.scenes+[track.scenery] }
    public var brakeScenes: [LoadedScene] { car.brakeScenes }
    public var lights: [CarLightDefinition] { car.lights }
    public var lightTextures: [String:CompiledTexture] { car.lightTextures }
    /// Every scene a renderer uploads: the player's car and the scenery in
    /// the classic order (0 body, 1…4 wheels, 5 scenery, 6…17 brakes), then
    /// seventeen per further model (body, four wheels, twelve brake parts).
    public var renderScenes: [LoadedScene] { scenes+brakeScenes+opponentCars.flatMap(\.renderScenes) }
    public var brakeResources: [Int] { Array(6..<18) }
    public static let scenesPerCarModel=17
    /// The first render resource of a car model.
    public static func firstResource(model: Int) -> Int { model==0 ? 0:18+(model-1)*scenesPerCarModel }
    public var models: [CarContent] { [car]+opponentCars }
    public let simulation: SingleVehicleSimulation
    public var minimumGear: Int { car.minimumGear }
    public var maximumGear: Int { car.maximumGear }
    public var bonnetPosition: SIMD3<Float> { car.bonnetPosition }
    public var driverPosition: SIMD3<Float> { car.driverPosition }
    public var dimensions: SIMD2<Float> { car.dimensions }
    public var shadow: CompiledTexture? { car.shadow }
    public var graphics: TrackGraphics { track.graphics }
    public var background: CompiledTexture? { track.background }
    public var reflection: CompiledTexture? { track.reflection }
    public var environmentShade: CompiledTexture? { track.environmentShade }
    public var trackShadow: CompiledTexture? { track.trackShadow }
    public var gridSlots: [StartingGridSlot] { track.gridSlots }
    public var carParameters: ParameterDocument { car.parameters }
    /// Boxes painted on the road, whatever the entry.
    public static let paintedGridSlots = 20
    public var trackLoaderBounds: ACLoaderBounds? { track.scenery.asset.scene.loaderBounds }
    // This prepared session always uses detailed wheels. grcar stores sx/sy
    // after initWheel has loaded speed meshes 0...3 for the last wheel.
    public var carShadowLoaderBounds: ACLoaderBounds? { car.scenes[4].asset.scene.loaderBounds }
    /// A session folder: its own track with its own car.
    public static func load(_ directory: URL) throws -> DrivingContent {
        try load(track:directory,car:directory)
    }
    /// Any prepared track with any prepared car, and the further car models
    /// the field will use. Folders may be sessions or single packages.
    public static func load(track trackDirectory: URL,car carDirectory: URL,opponents: [URL] = []) throws -> DrivingContent {
        let loading=PerformanceSignposts.begin("Asset loading")
        defer { PerformanceSignposts.end("Asset loading",loading) }
        let track=try TrackContent.load(trackDirectory)
        let car=try CarContent.load(carDirectory)
        // A model already loaded is not loaded twice.
        var seen=[carDirectory.standardizedFileURL.path],others: [CarContent]=[]
        for url in opponents where !seen.contains(url.standardizedFileURL.path) {
            seen.append(url.standardizedFileURL.path);others.append(try CarContent.load(url))
        }
        var simulation=try SingleVehicleSimulation(definition:car.definition,road:track.road,startDistance:max(0,track.road.length-10))
        try simulation.settle()
        return DrivingContent(name:"\(car.name) · \(track.name)",track:track,car:car,opponentCars:others,simulation:simulation)
    }
}
