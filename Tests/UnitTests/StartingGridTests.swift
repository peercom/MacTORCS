// SPDX-License-Identifier: GPL-2.0-only
// Native initStartingGrid port compared against the original routine running on
// the same pinned Aalborg track, car by car and field by field.
import XCTest
import TORCSConfiguration
import TORCSTrack
import TORCSReferenceSupport

final class StartingGridTests:XCTestCase {
    private func fixtures() throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil))
    }
    private func road() throws -> TrackRoad { try ChassisTestContext.road() }
    private func native(_ grid:ReferenceStartingGrid) throws -> StartingGridConfiguration {
        try StartingGridConfiguration(rows:grid.rows,toStart:grid.toStart,columnDistance:grid.columnDistance,
            columnOffset:grid.columnOffset,initialSpeed:grid.initialSpeed,initialHeight:grid.initialHeight,
            poleLeft:grid.poleLeft)
    }
    func testNativeStartingGridMatchesOriginalPlacement() throws {
        let fixtures=try fixtures(),road=try road()
        var compared=0,maximum:Float=0
        let cases:[(Int,ReferenceStartingGrid)]=[
            (1,.quickRace),(2,.quickRace),(3,.quickRace),(5,.quickRace),(8,.quickRace),(16,.quickRace),
            (5,.codeDefaults),(16,.codeDefaults),
            (4,ReferenceStartingGrid(rows:1,toStart:30,columnDistance:15,columnOffset:0)),
            (9,ReferenceStartingGrid(rows:3,toStart:20,columnDistance:18,columnOffset:6)),
            (12,ReferenceStartingGrid(rows:4,toStart:12.5,columnDistance:21.25,columnOffset:7.5)),
            (6,ReferenceStartingGrid(rows:3,toStart:20,columnDistance:18,columnOffset:6,poleLeft:false)),
            (6,ReferenceStartingGrid(rows:3,toStart:20,columnDistance:18,columnOffset:6,poleLeft:true)),
            (7,ReferenceStartingGrid(rows:2,toStart:40,columnDistance:12,columnOffset:9,poleLeft:true)),
            // A grid deep enough to be walked back across several segments.
            (10,ReferenceStartingGrid(rows:2,toStart:100,columnDistance:60,columnOffset:20))]
        for (cars,grid) in cases {
            let content=try ReferenceContent(fixtures:fixtures)
            let world=try ReferenceWorld(track:content.track,car:content.car,category:content.category,
                cars:cars,grid:grid)
            defer { world.close() }
            let slots=try StartingGrid.slots(road:road,configuration:try native(grid),cars:cars)
            XCTAssertEqual(slots.count,cars)
            for car in 0..<cars {
                let reference=try world.gridSlot(car:car),slot=slots[car]
                let label="cars=\(cars) rows=\(grid.rows) pole=\(grid.poleLeft.map(String.init(describing:)) ?? "default") car=\(car)"
                XCTAssertEqual(slot.position.segment,Int(reference.position.segment),"\(label) segment")
                XCTAssertEqual(slot.position.mode.rawValue,Int(reference.position.mode),"\(label) mode")
                for (native,original,field) in [(slot.position.toStart,reference.position.toStart,"toStart"),
                                                (slot.position.toRight,reference.position.toRight,"toRight"),
                                                (slot.world.x,reference.x,"x"),(slot.world.y,reference.y,"y"),
                                                (slot.world.z,reference.z,"z"),(slot.yaw,reference.yaw,"yaw"),
                                                (slot.speed,reference.speed,"speed")] {
                    XCTAssertEqual(native,original,"\(label) \(field)")
                    maximum=max(maximum,abs(native-original));compared += 1
                }
            }
        }
        print("NATIVE_STARTING_GRID cases=\(cases.count) comparedValues=\(compared) maxAbsolute=\(maximum)")
    }
    func testNativePoleSideFollowsFirstTurn() throws {
        let road=try road()
        // Aalborg's first turn is a right-hander, so the original pole is right:
        // a=0, b=width, and the first column sits at width/(rows+1) from the right.
        XCTAssertFalse(try StartingGrid.defaultPoleLeft(road:road))
        let resolved=try StartingGrid.slots(road:road,configuration:StartingGridConfiguration(),cars:2)
        let forced=try StartingGrid.slots(road:road,configuration:StartingGridConfiguration(poleLeft:false),cars:2)
        XCTAssertEqual(resolved,forced,"an unset pole must resolve to the inside of the first turn")
        let left=try StartingGrid.slots(road:road,configuration:StartingGridConfiguration(poleLeft:true),cars:2)
        XCTAssertEqual(left[0].position.toRight,road.width-resolved[0].position.toRight,accuracy:1e-4)
        print("NATIVE_GRID_POLE defaultLeft=false width=\(road.width) resolvedToRight=\(resolved[0].position.toRight)")
    }
    func testOriginalGridAttributeNamesAndTrackOverride() throws {
        let fixtures=try fixtures()
        let race=try ParameterDocument.parse(Data(contentsOf:fixtures.appendingPathComponent("quickrace.xml")))
        let shipped=try StartingGridConfiguration(race:race,raceName:"Quick Race")
        // The values shipped in the original quickrace.xml.
        XCTAssertEqual(shipped.rows,2);XCTAssertEqual(shipped.toStart,25)
        XCTAssertEqual(shipped.columnDistance,20);XCTAssertEqual(shipped.columnOffset,10)
        XCTAssertEqual(shipped.initialSpeed,0);XCTAssertEqual(shipped.initialHeight,0.2,accuracy:1e-6)
        XCTAssertNil(shipped.poleLeft,"quickrace.xml names no pole side")
        // A missing race section leaves every original code default in place.
        let defaults=try StartingGridConfiguration(race:race,raceName:"No Such Race")
        XCTAssertEqual(defaults.rows,2);XCTAssertEqual(defaults.toStart,10)
        XCTAssertEqual(defaults.columnDistance,10);XCTAssertEqual(defaults.columnOffset,5)
        XCTAssertEqual(defaults.initialHeight,0.3,accuracy:1e-6)
        // The track overrides everything except the initial speed.
        let track=try ParameterDocument.parse(Data("""
        <params name="t"><section name="Starting Grid">\
        <attnum name="rows" val="4"/><attnum name="distance to start" val="55"/>\
        <attnum name="distance between columns" val="33"/><attnum name="offset within a column" val="11"/>\
        <attnum name="initial speed" val="7"/><attnum name="initial height" val="0.45"/>\
        <attstr name="pole position side" val="left"/></section></params>
        """.utf8))
        let overridden=try StartingGridConfiguration(race:race,raceName:"Quick Race",track:track)
        XCTAssertEqual(overridden.rows,4);XCTAssertEqual(overridden.toStart,55)
        XCTAssertEqual(overridden.columnDistance,33);XCTAssertEqual(overridden.columnOffset,11)
        XCTAssertEqual(overridden.initialHeight,0.45,accuracy:1e-6)
        XCTAssertEqual(overridden.poleLeft,true)
        XCTAssertEqual(overridden.initialSpeed,0,"the original track cannot change the initial speed")
        // A track section that names only one value keeps the rest.
        let partial=try ParameterDocument.parse(Data("""
        <params name="t"><section name="Starting Grid"><attnum name="rows" val="3"/></section></params>
        """.utf8))
        let mixed=try StartingGridConfiguration(race:race,raceName:"Quick Race",track:partial)
        XCTAssertEqual(mixed.rows,3);XCTAssertEqual(mixed.toStart,25);XCTAssertNil(mixed.poleLeft)
        print("ORIGINAL_GRID_PARAMETERS shipped=\(shipped) overrides=7 speedOverride=rejected")
    }
    func testNativeGridRejectsWhatTheOriginalLeavesUndefined() throws {
        let road=try road()
        // The original walks back segment by segment and would run off the front
        // of the list; a grid longer than the track is reported instead.
        XCTAssertThrowsError(try StartingGrid.slots(road:road,
            configuration:StartingGridConfiguration(rows:1,toStart:10,columnDistance:road.length/2,columnOffset:0),cars:8))
        XCTAssertThrowsError(try StartingGrid.slots(road:road,configuration:StartingGridConfiguration(),cars:0))
        XCTAssertThrowsError(try StartingGridConfiguration(toStart:.nan))
        // rows below one is clamped by the original after it reads the value.
        let clamped=try StartingGrid.slots(road:road,configuration:StartingGridConfiguration(rows:0),cars:2)
        let single=try StartingGrid.slots(road:road,configuration:StartingGridConfiguration(rows:1),cars:2)
        XCTAssertEqual(clamped,single,"rows below one behaves as a single row")
        print("NATIVE_GRID_BOUNDARIES rejected=3 clampedRows=1")
    }
}
