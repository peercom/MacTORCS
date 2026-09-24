// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSTrack
import TORCSConfiguration
import TORCSSimulation
import TORCSReferenceSupport
import TORCSTelemetry

final class TrackWallCollisionTests: XCTestCase {
    func testTrackWallVerticesAgainstOriginalBuilder() throws {
        let content = try ReferenceContent(fixtures:XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)))
        defer { withExtendedLifetime(content) {} }
        var cases = 0, objects = 0, polygons = 0, fields = 0
        func check(_ road: TrackRoad,_ url: URL) throws {
            let world = try ReferenceWorld(track:url,car:content.car,category:content.category)
            defer { world.close() }
            let native = try TrackWallCollision.polygons(track:road.geometry)
            XCTAssertEqual(native.count,Int(ref_fixed_wall_count()))
            for wall in native.indices {
                XCTAssertEqual(native[wall].count,Int(ref_fixed_wall_polygon_count(Int32(wall))))
                for polygon in native[wall].indices {
                    var out = [RefDoubleVector](repeating:.init(),count:4)
                    XCTAssertEqual(ref_fixed_wall_vertices(Int32(wall),Int32(polygon),&out,4),4)
                    XCTAssertEqual(native[wall][polygon].vertices.count,4)
                    for vertex in 0..<4 {
                        XCTAssertEqual(native[wall][polygon].vertices[vertex],SIMD3(out[vertex].x,out[vertex].y,out[vertex].z),"case \(cases) object \(wall) polygon \(polygon) vertex \(vertex)")
                        fields += 3
                    }
                    polygons += 1
                }
                objects += 1
            }
            cases += 1
        }
        try check(ChassisTestContext.road(),content.track)
        for both in [false,true] { for side in ["Left","Right"] { for wrap in [false,true] { for change in [0.0,0.009,0.011] {
            let data = Data(Self.fixture(side:side,both:both,wrap:wrap,change:change).utf8)
            let road = try TrackBuilder.buildRoad(parameters:ParameterDocument.parse(data))
            let url = content.track.deletingLastPathComponent().appendingPathComponent("wall-fixture.xml")
            try data.write(to:url); try check(road,url)
        } } } }
        XCTAssertGreaterThan(objects,20); XCTAssertGreaterThan(polygons,100)
        print("COLLISION_WALL_GEOMETRY cases=\(cases) objects=\(objects) polygons=\(polygons) fields=\(fields) maxAbsolute=0")
    }
    static func fixture(side: String,both: Bool,wrap: Bool,change: Double) -> String {
        let sections = (0..<7).map { i in
            let active = wrap ? [0,1,4,6].contains(i) : [1,2,4].contains(i)
            let borders = ["Left","Right"].map { name in
                let style = active && (both || name==side) ? "wall" : "curb"
                return """
                <section name="\(name) Border"><attstr name="style" val="\(style)"/><attnum name="width" val="0.6"/>
                <attnum name="height" val="\(1.2+(i==2 ? change : 0))"/></section>
                """
            }.joined()
            return """
            <section name="s\(i)"><attstr name="type" val="\(i==4 ? "lft" : "str")"/><attnum name="lg" val="37"/>
            <attnum name="radius" val="50"/><attnum name="arc" unit="deg" val="30"/><attnum name="profil steps" val="3"/>
            <attnum name="banking end" unit="deg" val="\(i%2==0 ? 2 : -1)"/>\(borders)</section>
            """
        }.joined()
        return """
        <params name="wall-fixture"><section name="Header"><attnum name="version" val="4"/></section>
        <section name="Main Track"><attnum name="width" val="11"/>
        <section name="Left Side"><attnum name="width" val="6"/></section><section name="Right Side"><attnum name="width" val="7"/></section>
        <section name="Track Segments">\(sections)</section></section></params>
        """
    }
}

extension TrackWallCollisionTests {
    func testIntegratedWallStrikeAgainstOriginalSimUpdate() throws {
        let content = try ReferenceContent(fixtures:XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)))
        defer { withExtendedLifetime(content) {} }
        var fields = 0, contactTicks = 0, damage = 0
        for side in ["Left","Right"] {
            let data = Data(Self.fixture(side:side,both:false,wrap:false,change:0).utf8)
            let road = try TrackBuilder.buildRoad(parameters:ParameterDocument.parse(data))
            let url = content.track.deletingLastPathComponent().appendingPathComponent("wall-strike.xml")
            try data.write(to:url)
            let world = try ReferenceWorld(track:url,car:content.car,category:content.category,startDistance:45)
            defer { world.close() }
            let car = try ParameterDocument.parse(Data(contentsOf:content.category)).merging(ParameterDocument.parse(Data(contentsOf:content.car)))
            var native = try MultiVehicleSimulation(definition:VehicleDynamicsDefinition(parameters:car),road:road,carCount:1,startDistance:45)
            XCTAssertGreaterThan(native.wallCount,0)
            try world.settle(); try native.settle()
            var contacts = 0
            for tick in 1...3000 {
                let steering: Float = side=="Left" ? 0.35 : -0.35
                try world.command(.init(throttle:1,steering:steering,gear:1)); try world.step()
                try native.step(commands:[.init(throttle:1,steering:steering,gear:1)])
                let expected = try world.sample(), actual = VehicleTelemetry.values(native.cars[0],track:road.geometry)
                for (key,value) in expected {
                    let n = try XCTUnwrap(actual[key]); XCTAssertEqual(n,value,"\(side) tick \(tick) \(key)")
                    if n != value { return }; fields += 1
                }
                if native.detectedWallPairs>0 { contacts += 1 }
            }
            XCTAssertGreaterThan(contacts,0,"\(side) must strike a fixed wall")
            contactTicks += contacts; damage += Int(native.cars[0].damage)
            world.close()
        }
        XCTAssertGreaterThan(damage,0)
        print("COLLISION_WALL_VEHICLE scenarios=2 ticks=6000 fields=\(fields) contactTicks=\(contactTicks) damage=\(damage) maxAbsolute=0")
    }
}
