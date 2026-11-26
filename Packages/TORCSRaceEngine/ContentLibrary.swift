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

/// A circuit's outline for menus, loading screens and the HUD's map: the
/// main-segment centreline, fitted into the unit square with its aspect kept
/// and y up, and the transform that puts a world position on it.
public struct TrackMap: Sendable,Equatable,Hashable,Codable {
    public let points: [SIMD2<Float>]
    /// Where the start/finish line is, in the same unit-square space.
    public let start: SIMD2<Float>
    /// Width over height of the fitted outline, so a view can size itself.
    public let aspect: Float
    /// World to unit square: `(world - worldOrigin) * worldScale + offset`.
    public let worldOrigin,offset: SIMD2<Float>
    public let worldScale: Float
    public init(points: [SIMD2<Float>],start: SIMD2<Float>,aspect: Float,worldOrigin: SIMD2<Float> = .zero,
                worldScale: Float = 1,offset: SIMD2<Float> = .zero) {
        self.points=points;self.start=start;self.aspect=aspect
        self.worldOrigin=worldOrigin;self.worldScale=worldScale;self.offset=offset
    }
    /// A world position on the map, for placing cars on the outline.
    public func project(_ world: SIMD2<Float>) -> SIMD2<Float> { (world-worldOrigin)*worldScale+offset }
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
        guard raw.count>=2 else {
            points=[];start=SIMD2(0.5,0.5);aspect=1;worldOrigin = .zero;worldScale=1;offset = .zero;return
        }
        var low=raw[0],high=raw[0]
        for p in raw { low=simd_min(low,p);high=simd_max(high,p) }
        let size=simd_max(high-low,SIMD2<Float>(repeating:1))
        let scale=1/max(size.x,size.y)
        let fit=(SIMD2<Float>(repeating:1)-size*scale)/2
        points=raw.map { (($0-low)*scale)+fit }
        start=points[0]
        aspect=size.x/size.y
        worldOrigin=low;worldScale=scale;offset=fit
    }
}

/// What the menus say about a circuit, read from the track's own header, and
/// where its package is.
public struct TrackDescriptor: Sendable,Equatable,Hashable,Identifiable {
    public let id: String
    public let name,category,author,summary: String
    public let length,width: Float
    /// How many separate bends the main track has.
    public let corners: Int
    public let map: TrackMap
    public let directory: URL
    /// Generated material sets beside the track, which the renderer uses in
    /// place of the original art.
    public let hasMaterials: Bool
    public let preview: URL?
    public init(id: String,name: String,category: String,author: String,summary: String,length: Float,width: Float,
                corners: Int = 0,map: TrackMap,directory: URL = URL(fileURLWithPath:"/"),hasMaterials: Bool = false,preview: URL? = nil) {
        self.id=id;self.name=name;self.category=category;self.author=author;self.summary=summary
        self.length=length;self.width=width;self.corners=corners;self.map=map
        self.directory=directory;self.hasMaterials=hasMaterials;self.preview=preview
    }
    /// The original category names, spelled for a menu.
    public var categoryTitle: String {
        switch category.lowercased() {
        case "road":"Road course";case "oval":"Oval";case "dirt":"Dirt";case "speedway":"Speedway"
        default:category.isEmpty ? "Circuit":category.capitalized
        }
    }
    /// Describe a track package (or a session folder's track) without
    /// loading its models: the document is parsed and the road built.
    public static func describe(_ directory: URL) throws -> TrackDescriptor {
        let search=ContentSearchPath(roots:[directory])
        func read(_ name: String) throws -> Data { try ContentSearchPath.readBounded(search.resolve(name),maximumBytes:8*1024*1024) }
        let index=try ContentPackage.trackIndex(in:directory)
        let parameters=try ParameterDocument.parse(read(index.track),entities:["default-surfaces":read(index.surfaces),"default-objects":read(index.objects)],allowLegacyLatin1:true)
        let road=try TrackBuilder.buildRoad(parameters:parameters)
        let header=parameters.section("Header")
        let stem=URL(fileURLWithPath:index.track).deletingPathExtension().lastPathComponent
        let name=header?.string("name",default:"") ?? ""
        // A bend is a run of same-handed curve segments.
        var corners=0,previous=TrackCurve.straight
        for i in road.geometry.mainSegments {
            let curve=road.geometry.segments[i].curve
            if curve != .straight,curve != previous { corners += 1 }
            previous=curve
        }
        let preview=index.preview.flatMap { try? search.resolve($0) }
        return TrackDescriptor(id:stem,name:name.isEmpty ? stem:name,category:header?.string("category",default:"") ?? "",
            author:header?.string("author",default:"") ?? "",summary:header?.string("description",default:"") ?? "",
            length:road.length,width:road.width,corners:corners,map:TrackMap(geometry:road.geometry),directory:directory.standardizedFileURL,
            hasMaterials:materialsDirectory(for:directory) != nil,preview:preview)
    }
    /// The generated material sets a circuit renders with: its own
    /// `materials` folder, or the one a library shares beside its `tracks`
    /// folder.
    public static func materialsDirectory(for package: URL) -> URL? {
        let package=package.standardizedFileURL
        var candidates=[package.appendingPathComponent("materials")]
        let parent=package.deletingLastPathComponent()
        if parent.lastPathComponent=="tracks" { candidates.append(parent.deletingLastPathComponent().appendingPathComponent("materials")) }
        return candidates.first { FileManager.default.fileExists(atPath:$0.appendingPathComponent("materials.json").path) }
    }
}

/// What the menus say about a car, read from its merged category and car
/// parameters, and where its package is.
public struct CarDescriptor: Sendable,Equatable,Hashable,Identifiable {
    public let id: String
    public let name,category: String
    public let mass: Float
    public let gears: Int
    /// rpm.
    public let revsLimiter: Float
    /// Peak of the engine's torque curve times speed, in watts.
    public let power: Float
    /// "RWD", "FWD" or "4WD", as the car's drivetrain section says.
    public let drivetrain: String
    public let directory: URL
    public let preview: URL?
    public init(id: String,name: String,category: String,mass: Float,gears: Int,revsLimiter: Float,power: Float = 0,
                drivetrain: String = "",directory: URL = URL(fileURLWithPath:"/"),preview: URL? = nil) {
        self.id=id;self.name=name;self.category=category;self.mass=mass;self.gears=gears;self.revsLimiter=revsLimiter
        self.power=power;self.drivetrain=drivetrain;self.directory=directory;self.preview=preview
    }
    public var horsepower: Int { Int((power/745.7).rounded()) }
    /// The class, spelled for a menu.
    public var categoryTitle: String { Self.categoryTitle(category) }
    public static func categoryTitle(_ category: String) -> String {
        switch category.lowercased() {
        case "trb1":return "TRB1 Touring"
        case "trb3":return "TRB3 Touring"
        case "ow1":return "Open Wheel"
        case "stock1":return "Stock Car"
        case "stock2":return "Stock Car II"
        case "historic":return "Historic"
        case "free":return "Free Formula"
        default:
            // "Track-RWD-GrB" reads "Track RWD · Group B".
            let parts=category.split(separator:"-").map(String.init)
            if parts.count==3,parts[2].lowercased().hasPrefix("gr") {
                let kind=parts[0].lowercased()=="offroad" ? "Rally":parts[0]
                return "\(kind) \(parts[1]) · Group \(parts[2].dropFirst(2))"
            }
            return category.replacingOccurrences(of:"-",with:" ")
        }
    }
    /// The original's class cars are named after their files ("car3-trb1");
    /// a menu calls that one "TRB1 No. 3".
    public static func displayName(document: String,id: String) -> String {
        let raw=document.isEmpty ? id:document
        let parts=raw.split(separator:"-")
        if parts.count==2,parts[0].hasPrefix("car"),let number=Int(parts[0].dropFirst(3)) {
            return "\(parts[1].uppercased()) No. \(number)"
        }
        return raw
    }
    /// Watts per kilogram, the figure that orders a showroom.
    public var powerToWeight: Float { mass>0 ? power/mass:0 }
    public static func describe(_ directory: URL) throws -> CarDescriptor {
        let search=ContentSearchPath(roots:[directory])
        func read(_ name: String) throws -> Data { try ContentSearchPath.readBounded(search.resolve(name),maximumBytes:8*1024*1024) }
        let index=try ContentPackage.carIndex(in:directory)
        let category=try ParameterDocument.parse(read(index.category))
        let car=try ParameterDocument.parse(read(index.car))
        let parameters=try category.merging(car)
        let stem: (String)->String = { URL(fileURLWithPath:$0).deletingPathExtension().lastPathComponent }
        let gears=parameters.section("Gearbox/gears")?.sections.filter { Int($0.name) != nil }.count ?? 0
        // The store keeps rad/s and N·m, so the product is watts.
        let limiter=parameters.section("Engine")?.number("revs limiter",default:.infinity) ?? .infinity
        let power=(parameters.section("Engine/data points")?.sections ?? []).map { point -> Float in
            let speed=point.number("rpm",default:0)
            return speed<=limiter ? speed*point.number("Tq",default:0):0
        }.max() ?? 0
        let preview=index.preview.flatMap { try? search.resolve($0) }
        return CarDescriptor(id:stem(index.car),name:displayName(document:car.name,id:stem(index.car)),
            category:category.name.isEmpty ? stem(index.category):category.name,
            mass:parameters.section("Car")?.number("mass",default:0) ?? 0,gears:gears,
            revsLimiter:parameters.section("Engine")?.number("revs limiter",unit:"rpm",default:0) ?? 0,
            power:power,drivetrain:parameters.section("Drivetrain")?.string("type",default:"") ?? "",
            directory:directory.standardizedFileURL,preview:preview)
    }
}

extension ContentPackage {
    /// Where a package's sound files are: its own folder first, then the
    /// `sounds` folder its library shares beside `tracks` and `cars`.
    public static func soundDirectories(for package: URL) -> [URL] {
        let package=package.standardizedFileURL,parent=package.deletingLastPathComponent()
        var found=[package]
        if ["tracks","cars"].contains(parent.lastPathComponent) { found.append(parent.deletingLastPathComponent().appendingPathComponent("sounds")) }
        return found
    }
    public static func sound(_ name: String,for package: URL) -> URL? {
        guard !name.isEmpty,!name.contains("/"),!name.contains("..") else { return nil }
        return soundDirectories(for:package).map { $0.appendingPathComponent(name) }.first { FileManager.default.fileExists(atPath:$0.path) }
    }
}

/// Every circuit and car found under the player's content folders. A folder
/// may hold a track package, a car package, or a session with both; any car
/// drives on any circuit.
public struct ContentLibrary: Sendable,Equatable {
    public private(set) var tracks: [TrackDescriptor]
    public private(set) var cars: [CarDescriptor]
    public init(tracks: [TrackDescriptor]=[],cars: [CarDescriptor]=[]) {
        // Name order, so the menus are stable between scans; the first
        // package found for an id wins, a prepared preview or material set
        // breaking the tie, so re-preparing beside an old folder does not
        // double the entry.
        var seenTracks=Set<String>(),seenCars=Set<String>()
        self.tracks=tracks.sorted { (($0.preview==nil ? 1:0)+($0.hasMaterials ? 0:1),$0.directory.path)<(($1.preview==nil ? 1:0)+($1.hasMaterials ? 0:1),$1.directory.path) }
            .filter { seenTracks.insert($0.id).inserted }.sorted { ($0.name,$0.id)<($1.name,$1.id) }
        self.cars=cars.sorted { ($0.preview==nil ? 1:0,$0.directory.path)<($1.preview==nil ? 1:0,$1.directory.path) }
            .filter { seenCars.insert($0.id).inserted }.sorted { ($0.category,$0.name,$0.id)<($1.category,$1.name,$1.id) }
    }
    public var isEmpty: Bool { tracks.isEmpty || cars.isEmpty }
    public func track(_ id: String?) -> TrackDescriptor? { tracks.first { $0.id==id } }
    public func car(_ id: String?) -> CarDescriptor? { cars.first { $0.id==id } }
    /// The car classes present, in menu order.
    public var categories: [String] {
        var seen=Set<String>()
        return cars.map(\.category).filter { seen.insert($0).inserted }
    }
    /// The cars a field of opponents is drawn from, the player's own model
    /// first: its class when `sameClass`, every car otherwise.
    public func rivals(of car: CarDescriptor,sameClass: Bool) -> [CarDescriptor] {
        let pool=cars.filter { $0.id != car.id && (!sameClass || $0.category==car.category) }
        // Closest in power-to-weight first, so a mixed grid stays a contest.
        return [car]+pool.sorted { abs($0.powerToWeight-car.powerToWeight)<abs($1.powerToWeight-car.powerToWeight) }
    }

    static let indexNames=[ContentPackage.sessionIndexName,ContentPackage.trackIndexName,ContentPackage.carIndexName]
    private static func isPackage(_ url: URL) -> Bool {
        indexNames.contains { FileManager.default.fileExists(atPath:url.appendingPathComponent($0).path) }
    }
    /// The package folders under a root: every directory holding a session,
    /// track or car index, to a bounded depth, never descending into a package
    /// or a hidden folder. Bounded so a careless root such as the home folder
    /// does not become a filesystem walk.
    public static func packageDirectories(under root: URL,maximumDepth: Int = 3) -> [URL] {
        let root=root.standardizedFileURL
        if isPackage(root) { return [root] }
        guard let enumerator=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isDirectoryKey],
                                                               options:[.skipsHiddenFiles,.skipsPackageDescendants]) else { return [] }
        var found: [URL]=[]
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true else { continue }
            if isPackage(url) { found.append(url.standardizedFileURL);enumerator.skipDescendants();continue }
            if enumerator.level>=maximumDepth { enumerator.skipDescendants() }
        }
        return found.sorted { $0.path<$1.path }
    }
    /// Scan the roots. A package that cannot be described is reported, not
    /// fatal: one broken folder must not empty the menus.
    public static func scan(roots: [URL],maximumDepth: Int = 3) -> (library: ContentLibrary,warnings: [String]) {
        var tracks: [TrackDescriptor]=[],cars: [CarDescriptor]=[],warnings: [String]=[]
        var seen=Set<String>()
        for root in roots {
            guard FileManager.default.fileExists(atPath:root.path) else { warnings.append("Missing folder: \(root.path)");continue }
            for directory in packageDirectories(under:root,maximumDepth:maximumDepth) where seen.insert(directory.path).inserted {
                let kinds=ContentPackage.kinds(in:directory)
                if kinds.track {
                    do { tracks.append(try TrackDescriptor.describe(directory)) }
                    catch { warnings.append("\(directory.lastPathComponent): \(error)") }
                }
                if kinds.car {
                    do { cars.append(try CarDescriptor.describe(directory)) }
                    catch { warnings.append("\(directory.lastPathComponent): \(error)") }
                }
            }
        }
        return (ContentLibrary(tracks:tracks,cars:cars),warnings)
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
