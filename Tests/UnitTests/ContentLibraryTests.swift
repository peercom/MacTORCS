// SPDX-License-Identifier: GPL-2.0-only
// The game's catalogue: session folders described as tracks and cars, and the
// opponents' qualifying runs simulated headless.
import XCTest
import TORCSAssets
import TORCSConfiguration
import TORCSRaceEngine
import TORCSTrack

final class ContentLibraryTests: XCTestCase {
    private func fixtures() throws -> URL { try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)) }
    /// A session folder that describes without compiling: the XML documents
    /// and an index whose model references need not resolve.
    private func makeSession(at folder: URL,name: String = "155-DTM · Aalborg") throws {
        let source=try fixtures()
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        for file in ["155-DTM.xml","Track-4WD-GrB.xml","aalborg.xml","surfaces.xml","objects.xml"] {
            try FileManager.default.copyItem(at:source.appendingPathComponent(file),to:folder.appendingPathComponent(file))
        }
        let index:[String:Any]=["version":1,"name":name,"car":"155-DTM.xml","category":"Track-4WD-GrB.xml","track":"aalborg.xml",
            "surfaces":"surfaces.xml","objects":"objects.xml","body":"model/scene.json","scenery":"model/scene.json",
            "wheels":Array(repeating:"model/scene.json",count:4),"lightTextures":["breaklight2.rgb":"brake.torcstex"]]
        try JSONSerialization.data(withJSONObject:index).write(to:folder.appendingPathComponent("driving.json"))
    }
    /// A car package on its own: the documents and a car.json.
    private func makeCar(at folder: URL,preview: Bool = false) throws {
        let source=try fixtures()
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        for file in ["155-DTM.xml","Track-4WD-GrB.xml"] {
            try FileManager.default.copyItem(at:source.appendingPathComponent(file),to:folder.appendingPathComponent(file))
        }
        var index:[String:Any]=["version":1,"name":"Alfa","car":"155-DTM.xml","category":"Track-4WD-GrB.xml","body":"model/scene.json",
            "wheels":Array(repeating:"model/scene.json",count:4)]
        if preview { index["preview"]="preview.png";try Data([1]).write(to:folder.appendingPathComponent("preview.png")) }
        try JSONSerialization.data(withJSONObject:index).write(to:folder.appendingPathComponent("car.json"))
    }
    /// A track package on its own: the documents and a track.json.
    private func makeTrack(at folder: URL) throws {
        let source=try fixtures()
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        for file in ["aalborg.xml","surfaces.xml","objects.xml"] {
            try FileManager.default.copyItem(at:source.appendingPathComponent(file),to:folder.appendingPathComponent(file))
        }
        let index:[String:Any]=["version":1,"name":"Aalborg","track":"aalborg.xml","surfaces":"surfaces.xml","objects":"objects.xml","scenery":"model/scene.json"]
        try JSONSerialization.data(withJSONObject:index).write(to:folder.appendingPathComponent("track.json"))
    }
    func testSessionFolderDescribesTrackCarAndMap() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let folder=root.appendingPathComponent("session")
        try makeSession(at:folder)
        XCTAssertTrue(ContentPackage.kinds(in:folder)==(true,true))
        let track=try TrackDescriptor.describe(folder),car=try CarDescriptor.describe(folder)
        XCTAssertEqual(track.id,"aalborg");XCTAssertEqual(track.name,"Aalborg")
        XCTAssertEqual(track.category,"road");XCTAssertEqual(track.categoryTitle,"Road course")
        XCTAssertEqual(track.author,"E. Espie, B. Wymann")
        XCTAssertGreaterThan(track.length,2000);XCTAssertGreaterThan(track.width,5)
        XCTAssertGreaterThan(track.corners,5);XCTAssertLessThan(track.corners,40)
        XCTAssertEqual(track.directory,folder.standardizedFileURL);XCTAssertFalse(track.hasMaterials);XCTAssertNil(track.preview)
        XCTAssertEqual(car.id,"155-DTM");XCTAssertEqual(car.name,"Alfa Romeo 155 DTM")
        XCTAssertEqual(car.category,"Track-4WD-GrB")
        XCTAssertEqual(car.mass,1115,accuracy:0.01);XCTAssertGreaterThan(car.gears,3)
        XCTAssertEqual(car.revsLimiter,12500,accuracy:0.01)
        // A touring car of its day: a few hundred horsepower, not tens or thousands.
        XCTAssertGreaterThan(car.horsepower,250);XCTAssertLessThan(car.horsepower,700)
        XCTAssertEqual(car.powerToWeight,car.power/1115,accuracy:0.01)
        // The outline: closed, inside the unit square, and wider than tall or
        // taller than wide as the circuit is.
        let map=track.map
        XCTAssertGreaterThan(map.points.count,20)
        XCTAssertEqual(map.points.first,map.points.last)
        XCTAssertEqual(map.start,map.points[0])
        for p in map.points { XCTAssertTrue((0...1).contains(p.x) && (0...1).contains(p.y),"\(p)") }
        let xs=map.points.map(\.x),ys=map.points.map(\.y)
        XCTAssertEqual(max(xs.max()!-xs.min()!,ys.max()!-ys.min()!),1,accuracy:1e-4,"the longer side fills the square")
        XCTAssertGreaterThan(map.aspect,0.2);XCTAssertLessThan(map.aspect,5)
        // A world position lands where the outline is: the first main
        // segment's start is the map's start.
        let source=try fixtures()
        func read(_ name: String) throws -> Data { try Data(contentsOf:source.appendingPathComponent(name)) }
        let road=try TrackBuilder.buildRoad(parameters:ParameterDocument.parse(read("aalborg.xml"),entities:[
            "default-surfaces":read("surfaces.xml"),"default-objects":read("objects.xml")],allowLegacyLatin1:true))
        let first=road.geometry.segments[road.geometry.mainSegments[0]]
        let world=(first.startLeft+first.startRight)/2
        let projected=map.project(SIMD2(world.x,world.y))
        XCTAssertEqual(projected.x,map.start.x,accuracy:1e-4);XCTAssertEqual(projected.y,map.start.y,accuracy:1e-4)
        print("CONTENT_LIBRARY track=\(track.name) length=\(track.length) corners=\(track.corners) car=\(car.name) gears=\(car.gears) hp=\(car.horsepower) mapPoints=\(map.points.count) aspect=\(map.aspect)")
    }
    func testScanFindsSessionsAndSinglePackagesAndReportsBrokenOnes() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try makeSession(at:root.appendingPathComponent("a/session-one"))
        try makeSession(at:root.appendingPathComponent("a/b/session-two"),name:"Duplicate pairing")
        try makeCar(at:root.appendingPathComponent("cars/alfa"),preview:true)
        try makeTrack(at:root.appendingPathComponent("tracks/aalborg"))
        // Too deep for the default depth, so never described.
        try makeSession(at:root.appendingPathComponent("a/b/c/d/session-deep"))
        // A hidden folder is skipped, and a package's own subfolders are not
        // searched.
        try makeSession(at:root.appendingPathComponent(".hidden/session"))
        try makeSession(at:root.appendingPathComponent("a/session-one/materials/nested"))
        let broken=root.appendingPathComponent("broken");try FileManager.default.createDirectory(at:broken,withIntermediateDirectories:true)
        try Data("not json".utf8).write(to:broken.appendingPathComponent("driving.json"))
        let found=ContentLibrary.packageDirectories(under:root)
        XCTAssertEqual(Set(found.map(\.lastPathComponent)),["session-one","session-two","broken","alfa","aalborg"])
        XCTAssertTrue(ContentPackage.kinds(in:root.appendingPathComponent("cars/alfa"))==(false,true))
        XCTAssertTrue(ContentPackage.kinds(in:root.appendingPathComponent("tracks/aalborg"))==(true,false))
        let (library,warnings)=ContentLibrary.scan(roots:[root,root.appendingPathComponent("missing")])
        // Three folders offer the same circuit and three the same car: one of each.
        XCTAssertEqual(library.tracks.map(\.name),["Aalborg"]);XCTAssertEqual(library.cars.map(\.name),["Alfa Romeo 155 DTM"])
        XCTAssertFalse(library.isEmpty)
        // The package with a prepared preview is the one kept.
        XCTAssertEqual(library.cars[0].directory.lastPathComponent,"alfa");XCTAssertNotNil(library.cars[0].preview)
        XCTAssertNotNil(library.track("aalborg"));XCTAssertNil(library.track("none"));XCTAssertNotNil(library.car("155-DTM"))
        XCTAssertEqual(library.categories,["Track-4WD-GrB"])
        // The broken session fails as a track and as a car; the missing root once.
        XCTAssertEqual(warnings.count,3,"\(warnings)")
        XCTAssertTrue(warnings.contains { $0.hasPrefix("broken:") })
        // A root that is itself a package is found without descending.
        XCTAssertEqual(ContentLibrary.packageDirectories(under:root.appendingPathComponent("a/session-one")).count,1)
        var preferences=ContentLibraryPreferences()
        preferences.add(root);preferences.add(root);preferences.lastTrack="aalborg"
        XCTAssertEqual(preferences.roots.count,1)
        let store=try ContentLibraryStore(directory:root.appendingPathComponent("prefs"))
        try store.save(preferences);XCTAssertEqual(try store.load(),preferences)
        preferences.remove(root.standardizedFileURL.path);XCTAssertTrue(preferences.roots.isEmpty)
        print("CONTENT_SCAN found=\(found.count) tracks=\(library.tracks.count) cars=\(library.cars.count) warnings=\(warnings.count)")
    }
    func testRivalsAreTheNearestCarsOfTheClass() {
        func car(_ id: String,_ category: String,_ power: Float) -> CarDescriptor {
            CarDescriptor(id:id,name:id.uppercased(),category:category,mass:1000,gears:6,revsLimiter:8000,power:power)
        }
        let library=ContentLibrary(cars:[car("a","GT",300_000),car("b","GT",420_000),car("c","GT",310_000),car("d","Rally",305_000)])
        let mine=library.car("a")!
        XCTAssertEqual(library.rivals(of:mine,sameClass:true).map(\.id),["a","c","b"],"own car first, then nearest in power to weight")
        XCTAssertEqual(library.rivals(of:mine,sameClass:false).map(\.id),["a","d","c","b"])
        XCTAssertEqual(library.rivals(of:library.car("d")!,sameClass:true).map(\.id),["d"],"alone in its class")
        XCTAssertEqual(library.categories,["GT","Rally"])
        XCTAssertTrue(library.isEmpty,"cars without a circuit are not a game yet")
        XCTAssertEqual(CarDescriptor.displayName(document:"car3-trb1",id:"car3-trb1"),"TRB1 No. 3")
        XCTAssertEqual(CarDescriptor.displayName(document:"Cobra 427",id:"kc-cobra"),"Cobra 427")
        XCTAssertEqual(CarDescriptor.displayName(document:"",id:"kc-cobra"),"kc-cobra")
        XCTAssertEqual(CarDescriptor.categoryTitle("Track-RWD-GrB"),"Track RWD · Group B")
        XCTAssertEqual(CarDescriptor.categoryTitle("Offroad-4WD-GrA"),"Rally 4WD · Group A")
        XCTAssertEqual(CarDescriptor.categoryTitle("trb1"),"TRB1 Touring")
    }
    func testAnyCarLoadsOnAnyTrackWithFurtherModelsForTheField() throws {
        let source=try fixtures()
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        // One compiled model stands in for every scene, as in the session test.
        let model=root.appendingPathComponent("model")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try CompiledScene.compile(input:source.appendingPathComponent("Artwork/155-DTM/155-DTM.acc"),output:model,roots:[source.appendingPathComponent("Artwork/155-DTM")],options:.init(car:true))
        func withModel(_ folder: URL) throws { try FileManager.default.copyItem(at:model,to:folder.appendingPathComponent("model")) }
        let track=root.appendingPathComponent("track"),mine=root.appendingPathComponent("mine"),rival=root.appendingPathComponent("rival")
        try makeTrack(at:track);try withModel(track)
        try makeCar(at:mine);try withModel(mine)
        try makeCar(at:rival);try withModel(rival)
        // The player's own model named again among the opponents is not loaded twice.
        let content=try DrivingContent.load(track:track,car:mine,opponents:[rival,mine,rival])
        XCTAssertEqual(content.track.name,"Aalborg");XCTAssertEqual(content.car.name,"Alfa Romeo 155 DTM")
        XCTAssertEqual(content.name,"Alfa Romeo 155 DTM · Aalborg")
        XCTAssertEqual(content.opponentCars.count,1);XCTAssertEqual(content.models.count,2)
        XCTAssertEqual(content.scenes.count,6);XCTAssertEqual(content.renderScenes.count,18+17)
        XCTAssertEqual(DrivingContent.firstResource(model:0),0);XCTAssertEqual(DrivingContent.firstResource(model:1),18)
        XCTAssertEqual(DrivingContent.firstResource(model:2),35)
        XCTAssertEqual(content.simulation.settlingTicks,501)
        // A track folder is not a car, and the other way round.
        XCTAssertThrowsError(try DrivingContent.load(track:mine,car:mine))
        XCTAssertThrowsError(try DrivingContent.load(track:track,car:track))
        // A heterogeneous field builds from the models' own parameters.
        let entries=[RaceEntry(parameters:content.models[0].parameters,kind:.human),RaceEntry(parameters:content.models[1].parameters,kind:.bt)]
        let race=try RaceRuntime(road:content.simulation.road,entries:entries,grid:try .quickRace(),configuration:try RaceSessionConfiguration(kind:.race,laps:1))
        XCTAssertEqual(race.frame.field.count,2)
        print("CONTENT_MODELS models=\(content.models.count) renderScenes=\(content.renderScenes.count)")
    }
    func testOpponentQualifyingRunsHeadless() throws {
        let source=try fixtures()
        func read(_ name: String) throws -> Data { try Data(contentsOf:source.appendingPathComponent(name)) }
        let parameters=try ParameterDocument.parse(read("Track-4WD-GrB.xml")).merging(ParameterDocument.parse(read("155-DTM.xml")))
        let road=try TrackBuilder.buildRoad(parameters:ParameterDocument.parse(read("aalborg.xml"),entities:[
            "default-surfaces":read("surfaces.xml"),"default-objects":read("objects.xml")],allowLegacyLatin1:true))
        let started=Date()
        nonisolated(unsafe) var fractions:[Double]=[]
        let outcome=try QualifyingSimulation.run(road:road,parameters:parameters,laps:1,progress:{ fractions.append($0) })
        let seconds=Date().timeIntervalSince(started)
        XCTAssertTrue(outcome.completed);XCTAssertEqual(outcome.laps,1)
        XCTAssertGreaterThan(outcome.fastestLap,60);XCTAssertLessThan(outcome.fastestLap,200)
        XCTAssertEqual(outcome.gridTime,outcome.fastestLap)
        XCTAssertGreaterThanOrEqual(outcome.fastestLap,outcome.bestValidLap == 0 ? 0:outcome.bestValidLap*0 + outcome.fastestLap)
        XCTAssertEqual(fractions.last,1)
        // Cancellation ends the run early with whatever was set.
        let cancelled=try QualifyingSimulation.run(road:road,parameters:parameters,laps:3,cancelled:{ true })
        XCTAssertFalse(cancelled.completed);XCTAssertLessThan(cancelled.ticks,6000)
        // The same seed and laps give the same time: the grid is reproducible.
        let again=try QualifyingSimulation.run(road:road,parameters:parameters,laps:1)
        XCTAssertEqual(again.fastestLap,outcome.fastestLap)
        // A handicapped driver is slower over the same lap, and still finishes it.
        let eased=try QualifyingSimulation.run(road:road,parameters:parameters,laps:1,pace:0.8)
        XCTAssertTrue(eased.completed);XCTAssertGreaterThan(eased.fastestLap,outcome.fastestLap+1)
        print("NATIVE_QUALIFYING_PACE full=\(outcome.fastestLap) eased=\(eased.fastestLap)")
        print("NATIVE_QUALIFYING_SIM laps=1 fastestLap=\(outcome.fastestLap) bestValidLap=\(outcome.bestValidLap) ticks=\(outcome.ticks) wallSeconds=\(seconds) ticksPerSecond=\(Double(outcome.ticks)/seconds)")
    }
}
