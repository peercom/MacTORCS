// SPDX-License-Identifier: GPL-2.0-only
// The game's catalogue of prepared sessions: every driving.json under the
// folders the player has added, described as a track and a car so the menus
// can offer "which circuit, which car" rather than "which folder".
import Foundation
import simd
import TORCSCore
import TORCSAssets
import TORCSConfiguration
import TORCSTrack

/// A circuit's outline for menus and loading screens: the main-segment
/// centreline, fitted into the unit square with its aspect kept and y up.
public struct TrackMap: Sendable,Equatable,Hashable,Codable {
    public let points: [SIMD2<Float>]
    /// Where the start/finish line is, in the same unit-square space.
    public let start: SIMD2<Float>
    /// Width over height of the fitted outline, so a view can size itself.
    public let aspect: Float
    public init(points: [SIMD2<Float>],start: SIMD2<Float>,aspect: Float) { self.points=points;self.start=start;self.aspect=aspect }
    public init(geometry: TrackGeometry) {
        var raw: [SIMD2<Float>]=[]
        for index in geometry.mainSegments {
            let segment=geometry.segments[index]
            let mid=(segment.startLeft+segment.startRight)/2
            raw.append(SIMD2(mid.x,mid.y))
            // A curve is a chord per segment; long arcs get an extra point on
            // the arc's middle so the outline bends rather than folds.
            if segment.curve != .straight,segment.arc>0.35 {
                let end=(segment.endLeft+segment.endRight)/2
                let centre=SIMD2(segment.center.x,segment.center.y)
                let a=SIMD2(mid.x,mid.y)-centre,b=SIMD2(end.x,end.y)-centre
                let radius=(simd_length(a)+simd_length(b))/2
                let angleA=atan2(a.y,a.x)
                var delta=atan2(b.y,b.x)-angleA
                if segment.curve == .left,delta<0 { delta += 2 * .pi }
                if segment.curve == .right,delta>0 { delta -= 2 * .pi }
                raw.append(centre+radius*SIMD2(cos(angleA+delta/2),sin(angleA+delta/2)))
            }
        }
        if let first=raw.first { raw.append(first) }
        guard raw.count>=2 else { points=[];start=SIMD2(0.5,0.5);aspect=1;return }
        var low=raw[0],high=raw[0]
        for p in raw { low=simd_min(low,p);high=simd_max(high,p) }
        let size=simd_max(high-low,SIMD2<Float>(repeating:1))
        let scale=1/max(size.x,size.y)
        let offset=(SIMD2<Float>(repeating:1)-size*scale)/2
        points=raw.map { (($0-low)*scale)+offset }
        start=points[0]
        aspect=size.x/size.y
    }
}

/// What the menus say about a circuit, read from the track's own header.
public struct TrackDescriptor: Sendable,Equatable,Hashable,Codable,Identifiable {
    public let id: String
    public let name,category,author,summary: String
    public let length,width: Float
    public let map: TrackMap
    public init(id: String,name: String,category: String,author: String,summary: String,length: Float,width: Float,map: TrackMap) {
        self.id=id;self.name=name;self.category=category;self.author=author;self.summary=summary
        self.length=length;self.width=width;self.map=map
    }
    /// The original category names, spelled for a menu.
    public var categoryTitle: String {
        switch category.lowercased() {
        case "road":"Road course";case "oval":"Oval";case "dirt":"Dirt";case "speedway":"Speedway"
        default:category.isEmpty ? "Circuit":category.capitalized
        }
    }
}

/// What the menus say about a car, read from its merged category and car
/// parameters.
public struct CarDescriptor: Sendable,Equatable,Hashable,Codable,Identifiable {
    public let id: String
    public let name,category: String
    public let mass: Float
    public let gears: Int
    public let revsLimiter: Float
    public init(id: String,name: String,category: String,mass: Float,gears: Int,revsLimiter: Float) {
        self.id=id;self.name=name;self.category=category;self.mass=mass;self.gears=gears;self.revsLimiter=revsLimiter
    }
}

/// One prepared session: a folder that pairs a track with a car.
public struct ContentLibraryEntry: Sendable,Equatable,Identifiable {
    public var id: String { directory.path }
    public let directory: URL
    public let name: String
    public let track: TrackDescriptor
    public let car: CarDescriptor
    /// Generated material sets beside the session, which the renderer uses in
    /// place of the original art.
    public let hasMaterials: Bool
    public let hasLights: Bool
    public init(directory: URL,name: String,track: TrackDescriptor,car: CarDescriptor,hasMaterials: Bool,hasLights: Bool) {
        self.directory=directory;self.name=name;self.track=track;self.car=car;self.hasMaterials=hasMaterials;self.hasLights=hasLights
    }
    /// Describe a session folder without compiling or loading its models: the
    /// XML documents are parsed and the road is built for its length and map.
    public static func describe(_ directory: URL) throws -> ContentLibraryEntry {
        let search=ContentSearchPath(roots:[directory])
        func read(_ name: String) throws -> Data { try ContentSearchPath.readBounded(search.resolve(name),maximumBytes:8*1024*1024) }
        let index=try JSONDecoder().decode(DrivingSessionIndex.self,from:ContentSearchPath.readBounded(search.resolve("driving.json"),maximumBytes:65_536))
        guard index.version==1,!index.name.isEmpty else { throw ACError.invalid("Unsupported driving session version or name") }
        let category=try ParameterDocument.parse(read(index.category))
        let car=try ParameterDocument.parse(read(index.car))
        let parameters=try category.merging(car)
        let stem: (String)->String = { URL(fileURLWithPath:$0).deletingPathExtension().lastPathComponent }
        let gears=parameters.section("Gearbox/gears")?.sections.filter { Int($0.name) != nil }.count ?? 0
        let carDescriptor=CarDescriptor(id:stem(index.car),name:car.name.isEmpty ? stem(index.car):car.name,
            category:category.name.isEmpty ? stem(index.category):category.name,
            mass:parameters.section("Car")?.number("mass",default:0) ?? 0,gears:gears,
            revsLimiter:parameters.section("Engine")?.number("revs limiter",unit:"rpm",default:0) ?? 0)
        let trackParameters=try ParameterDocument.parse(read(index.track),entities:["default-surfaces":read(index.surfaces),"default-objects":read(index.objects)],allowLegacyLatin1:true)
        let road=try TrackBuilder.buildRoad(parameters:trackParameters)
        let header=trackParameters.section("Header")
        let trackDescriptor=TrackDescriptor(id:stem(index.track),name:header?.string("name",default:"") ?? "",
            category:header?.string("category",default:"") ?? "",author:header?.string("author",default:"") ?? "",
            summary:header?.string("description",default:"") ?? "",length:road.length,width:road.width,map:TrackMap(geometry:road.geometry))
        let named=trackDescriptor.name.isEmpty
            ? TrackDescriptor(id:trackDescriptor.id,name:stem(index.track),category:trackDescriptor.category,author:trackDescriptor.author,summary:trackDescriptor.summary,length:road.length,width:road.width,map:trackDescriptor.map)
            : trackDescriptor
        let materials=FileManager.default.fileExists(atPath:directory.appendingPathComponent("materials/materials.json").path)
        return ContentLibraryEntry(directory:directory.standardizedFileURL,name:index.name,track:named,car:carDescriptor,
            hasMaterials:materials,hasLights:!(index.lightTextures ?? [:]).isEmpty)
    }
}

/// Every session found under the player's content folders, grouped for the
/// menus: the circuits, and for each circuit the cars prepared on it.
public struct ContentLibrary: Sendable,Equatable {
    public private(set) var entries: [ContentLibraryEntry]
    public init(entries: [ContentLibraryEntry]=[]) {
        // Track then car, so the menus are stable between scans; the first
        // session for a pairing wins, so re-preparing beside an old one does
        // not double the car.
        var seen=Set<String>()
        self.entries=entries.sorted { ($0.track.name,$0.car.name,$0.directory.path)<($1.track.name,$1.car.name,$1.directory.path) }
            .filter { seen.insert($0.track.id+"\u{0}"+$0.car.id).inserted }
    }
    public var isEmpty: Bool { entries.isEmpty }
    /// The circuits, each once, in menu order.
    public var tracks: [TrackDescriptor] {
        var seen=Set<String>()
        return entries.map(\.track).filter { seen.insert($0.id).inserted }
    }
    /// The cars, each once, in menu order.
    public var cars: [CarDescriptor] {
        var seen=Set<String>()
        return entries.map(\.car).filter { seen.insert($0.id).inserted }
    }
    /// The cars prepared on a circuit.
    public func cars(on track: TrackDescriptor) -> [CarDescriptor] { entries.filter { $0.track.id==track.id }.map(\.car) }
    public func entry(track: String,car: String) -> ContentLibraryEntry? { entries.first { $0.track.id==track && $0.car.id==car } }

    /// The session folders under a root: every directory holding a
    /// driving.json, to a bounded depth, never descending into a session or a
    /// hidden folder. Bounded so a careless root such as the home folder does
    /// not become a filesystem walk.
    public static func sessionDirectories(under root: URL,maximumDepth: Int = 3) -> [URL] {
        let root=root.standardizedFileURL
        if FileManager.default.fileExists(atPath:root.appendingPathComponent("driving.json").path) { return [root] }
        guard let enumerator=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isDirectoryKey],
                                                               options:[.skipsHiddenFiles,.skipsPackageDescendants]) else { return [] }
        var found: [URL]=[]
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true else { continue }
            if FileManager.default.fileExists(atPath:url.appendingPathComponent("driving.json").path) {
                found.append(url.standardizedFileURL);enumerator.skipDescendants();continue
            }
            if enumerator.level>=maximumDepth { enumerator.skipDescendants() }
        }
        return found.sorted { $0.path<$1.path }
    }
    /// Scan the roots. A session that cannot be described is reported, not
    /// fatal: one broken folder must not empty the menus.
    public static func scan(roots: [URL],maximumDepth: Int = 3) -> (library: ContentLibrary,warnings: [String]) {
        var entries: [ContentLibraryEntry]=[],warnings: [String]=[]
        var seen=Set<String>()
        for root in roots {
            guard FileManager.default.fileExists(atPath:root.path) else { warnings.append("Missing folder: \(root.path)");continue }
            for directory in sessionDirectories(under:root,maximumDepth:maximumDepth) where seen.insert(directory.path).inserted {
                do { entries.append(try ContentLibraryEntry.describe(directory)) }
                catch { warnings.append("\(directory.lastPathComponent): \(error)") }
            }
        }
        return (ContentLibrary(entries:entries),warnings)
    }
}

/// Which folders the player has added, and what they last drove.
public struct ContentLibraryPreferences: Codable,Sendable,Equatable {
    public var roots: [String]
    public var lastTrack,lastCar: String?
    public init(roots: [String]=[],lastTrack: String? = nil,lastCar: String? = nil) { self.roots=roots;self.lastTrack=lastTrack;self.lastCar=lastCar }
    public var rootURLs: [URL] { roots.map { URL(fileURLWithPath:$0) } }
    public mutating func add(_ url: URL) { let path=url.standardizedFileURL.path;if !roots.contains(path) { roots.append(path) } }
    public mutating func remove(_ path: String) { roots.removeAll { $0==path } }
}
public struct ContentLibraryStore: Sendable {
    private let store: ConfigurationStore
    public init(directory: URL? = nil) throws { store=try ConfigurationStore(directory:directory) }
    /// The folder the app itself suggests for content, created on demand.
    public var defaultContentDirectory: URL { store.directory.appendingPathComponent("Content",isDirectory:true) }
    public func load() throws -> ContentLibraryPreferences {
        let url=store.directory.appendingPathComponent("library.json")
        guard FileManager.default.fileExists(atPath:url.path) else { return ContentLibraryPreferences() }
        guard try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0 <= 65536 else { throw ACError.invalid("Library settings exceed 64 KiB") }
        return try JSONDecoder().decode(ContentLibraryPreferences.self,from:Data(contentsOf:url))
    }
    public func save(_ preferences: ContentLibraryPreferences) throws { try store.save(preferences,name:"library.json") }
}
