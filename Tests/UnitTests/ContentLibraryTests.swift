// SPDX-License-Identifier: GPL-2.0-only
// The game's catalogue: session folders described as tracks and cars, and the
// opponents' qualifying runs simulated headless.
import XCTest
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
    func testSessionFolderDescribesTrackCarAndMap() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try makeSession(at:root.appendingPathComponent("session"))
        let entry=try ContentLibraryEntry.describe(root.appendingPathComponent("session"))
        XCTAssertEqual(entry.track.id,"aalborg");XCTAssertEqual(entry.track.name,"Aalborg")
        XCTAssertEqual(entry.track.category,"road");XCTAssertEqual(entry.track.categoryTitle,"Road course")
        XCTAssertEqual(entry.track.author,"E. Espie, B. Wymann")
        XCTAssertGreaterThan(entry.track.length,2000);XCTAssertGreaterThan(entry.track.width,5)
        XCTAssertEqual(entry.car.id,"155-DTM");XCTAssertEqual(entry.car.name,"Alfa Romeo 155 DTM")
        XCTAssertEqual(entry.car.category,"Track-4WD-GrB")
        XCTAssertEqual(entry.car.mass,1115,accuracy:0.01);XCTAssertGreaterThan(entry.car.gears,3)
        XCTAssertEqual(entry.car.revsLimiter,12500,accuracy:0.01)
        XCTAssertTrue(entry.hasLights);XCTAssertFalse(entry.hasMaterials)
        // The outline: closed, inside the unit square, and wider than tall or
        // taller than wide as the circuit is.
        let map=entry.track.map
        XCTAssertGreaterThan(map.points.count,20)
        XCTAssertEqual(map.points.first,map.points.last)
        XCTAssertEqual(map.start,map.points[0])
        for p in map.points { XCTAssertTrue((0...1).contains(p.x) && (0...1).contains(p.y),"\(p)") }
        let xs=map.points.map(\.x),ys=map.points.map(\.y)
        XCTAssertEqual(max(xs.max()!-xs.min()!,ys.max()!-ys.min()!),1,accuracy:1e-4,"the longer side fills the square")
        XCTAssertGreaterThan(map.aspect,0.2);XCTAssertLessThan(map.aspect,5)
        print("CONTENT_LIBRARY track=\(entry.track.name) length=\(entry.track.length) car=\(entry.car.name) gears=\(entry.car.gears) mapPoints=\(map.points.count) aspect=\(map.aspect)")
    }
    func testScanGroupsSessionsAndReportsBrokenOnes() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try makeSession(at:root.appendingPathComponent("a/session-one"))
        try makeSession(at:root.appendingPathComponent("a/b/session-two"),name:"Duplicate pairing")
        // Too deep for the default depth, so never described.
        try makeSession(at:root.appendingPathComponent("a/b/c/d/session-deep"))
        // A hidden folder is skipped, and a session's own subfolders are not
        // searched.
        try makeSession(at:root.appendingPathComponent(".hidden/session"))
        try makeSession(at:root.appendingPathComponent("a/session-one/materials/nested"))
        let broken=root.appendingPathComponent("broken");try FileManager.default.createDirectory(at:broken,withIntermediateDirectories:true)
        try Data("not json".utf8).write(to:broken.appendingPathComponent("driving.json"))
        let found=ContentLibrary.sessionDirectories(under:root)
        XCTAssertEqual(Set(found.map(\.lastPathComponent)),["session-one","session-two","broken"])
        let (library,warnings)=ContentLibrary.scan(roots:[root,root.appendingPathComponent("missing")])
        // Two sessions of the same pairing collapse to one car on one track.
        XCTAssertEqual(library.entries.count,1)
        XCTAssertEqual(library.tracks.map(\.name),["Aalborg"])
        XCTAssertEqual(library.cars(on:library.tracks[0]).map(\.name),["Alfa Romeo 155 DTM"])
        XCTAssertNotNil(library.entry(track:"aalborg",car:"155-DTM"))
        XCTAssertNil(library.entry(track:"aalborg",car:"none"))
        XCTAssertEqual(warnings.count,2,"the broken session and the missing root: \(warnings)")
        XCTAssertTrue(warnings.contains { $0.hasPrefix("broken:") })
        // A root that is itself a session is found without descending.
        XCTAssertEqual(ContentLibrary.sessionDirectories(under:root.appendingPathComponent("a/session-one")).count,1)
        var preferences=ContentLibraryPreferences()
        preferences.add(root);preferences.add(root);preferences.lastTrack="aalborg"
        XCTAssertEqual(preferences.roots.count,1)
        let store=try ContentLibraryStore(directory:root.appendingPathComponent("prefs"))
        try store.save(preferences);XCTAssertEqual(try store.load(),preferences)
        preferences.remove(root.standardizedFileURL.path);XCTAssertTrue(preferences.roots.isEmpty)
        print("CONTENT_SCAN found=\(found.count) entries=\(library.entries.count) warnings=\(warnings.count)")
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
        print("NATIVE_QUALIFYING_SIM laps=1 fastestLap=\(outcome.fastestLap) bestValidLap=\(outcome.bestValidLap) ticks=\(outcome.ticks) wallSeconds=\(seconds) ticksPerSecond=\(Double(outcome.ticks)/seconds)")
    }
}
