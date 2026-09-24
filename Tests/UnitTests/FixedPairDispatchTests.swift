// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSTrack
import TORCSConfiguration
import TORCSSimulation
import TORCSReferenceSupport
import TORCSTelemetry

final class FixedPairDispatchTests: XCTestCase {
    func testOriginalWallPairEarlyReturnAndInvalidCarBoundary() throws {
        let content = try ReferenceContent(fixtures:XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)))
        defer { withExtendedLifetime(content) {} }
        var pairs = 0, hits = 0, unsafe = 0, fields = 0, classified = 0
        for side in ["Left","Right"] { for wrap in [false,true] { for change in [0.0,0.009,0.011] {
            let data = Data(TrackWallCollisionTests.fixture(side:side,both:true,wrap:wrap,change:change).utf8)
            let road = try TrackBuilder.buildRoad(parameters:ParameterDocument.parse(data))
            let url = content.track.deletingLastPathComponent().appendingPathComponent("fixed-pair.xml")
            try data.write(to:url)
            let world = try ReferenceWorld(track:url,car:content.car,category:content.category)
            defer { world.close() }
            var walls = try TrackWallCollision.polygons(track:road.geometry).map { try ComplexCollisionShape(primitives:$0) }, query = ConvexCollisionQuery()
            for j in walls.indices { for i in 0..<j {
                var original = RefFixedPairResult()
                XCTAssertEqual(ref_fixed_pair_query(Int32(i),Int32(j),&original),1)
                let a = Int(original.firstWall), b = Int(original.secondWall)
                var first = walls[a], second = walls[b]
                let contact = try first.smartContact(with:&second,first:ConvexTransform(),second:ConvexTransform(),previousFirst:ConvexTransform(),previousSecond:ConvexTransform(),query:&query)
                walls[a] = first; walls[b] = second
                XCTAssertEqual(contact != nil,original.contact.hit != 0)
                if let c = contact {
                    hits += 1
                    for (n,o) in [(c.firstPoint,original.contact.firstPoint),(c.secondPoint,original.contact.secondPoint),(c.normal,original.contact.axis)] {
                        for (a,b) in [(n.x,o.x),(n.y,o.y),(n.z,o.z)] {
                            if b.isNaN { XCTAssertTrue(a.isNaN); classified += 1 } else { XCTAssertEqual(a,b); fields += 1 }
                        }
                    }
                    if original.wouldAccessCar != 0 { unsafe += 1; XCTAssertThrowsError(try ObjectCollisionResponse.validateFixedPair(contact:c)) }
                    else { XCTAssertNoThrow(try ObjectCollisionResponse.validateFixedPair(contact:c)) }
                }
                pairs += 1
            } }
            world.close()
        } } }
        XCTAssertGreaterThan(hits,0)
        print("FIXED_PAIR_AUDIT pairs=\(pairs) hits=\(hits) invalidCarAccess=\(unsafe) fields=\(fields) classified=\(classified) maxAbsolute=0")
    }
    func testFixedContactsFreezePreviousPosesAgainstOriginalSimUpdate() throws {
        let content = try ReferenceContent(fixtures:XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)))
        defer { withExtendedLifetime(content) {} }
        let data = Data(TrackWallCollisionTests.fixture(side:"Left",both:true,wrap:false,change:0.011).utf8)
        let road = try TrackBuilder.buildRoad(parameters:ParameterDocument.parse(data))
        let url = content.track.deletingLastPathComponent().appendingPathComponent("fixed-contact-run.xml")
        try data.write(to:url)
        let world = try ReferenceWorld(track:url,car:content.car,category:content.category,startDistance:45)
        defer { world.close() }
        let definition = try VehicleDynamicsDefinition(parameters:ParameterDocument.parse(Data(contentsOf:content.category)).merging(ParameterDocument.parse(Data(contentsOf:content.car))))
        var native = try MultiVehicleSimulation(definition:definition,road:road,carCount:1,startDistance:45)
        try world.settle(); try native.settle()
        var fields = 0, fixedTicks = 0, wallTicks = 0
        for tick in 1...3000 {
            try world.command(.init(throttle:1,steering:0.35,gear:1)); try world.step()
            try native.step(commands:[.init(throttle:1,steering:0.35,gear:1)])
            let expected = try world.sample(), actual = VehicleTelemetry.values(native.cars[0],track:road.geometry)
            for (key,value) in expected {
                let n = try XCTUnwrap(actual[key]); XCTAssertEqual(n,value,"tick \(tick) \(key)")
                if n != value { return }; fields += 1
            }
            if native.detectedFixedPairs>0 { fixedTicks += 1 }
            if native.detectedWallPairs>0 { wallTicks += 1 }
        }
        XCTAssertEqual(fixedTicks,3000); XCTAssertGreaterThan(wallTicks,0)
        print("FIXED_PAIR_VEHICLE ticks=3000 fields=\(fields) fixedTicks=\(fixedTicks) wallTicks=\(wallTicks) damage=\(native.cars[0].damage) maxAbsolute=0")
    }
}

extension FixedPairDispatchTests {
    func testIntersectingWallsRejectOriginalInvalidCarAccess() throws {
        let content = try ReferenceContent(fixtures:XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)))
        defer { withExtendedLifetime(content) {} }
        let definition = try VehicleDynamicsDefinition(parameters:ParameterDocument.parse(Data(contentsOf:content.category)).merging(ParameterDocument.parse(Data(contentsOf:content.car))))
        var cases = 0, hits = 0, invalid = 0
        for radius in [13.7,20,23.41] { for angle in [230,260,270,290] {
            let xml = """
            <params name="crossing-walls"><section name="Header"><attnum name="version" val="4"/></section>
            <section name="Main Track"><attnum name="width" val="11"/>
            <section name="Left Side"><attnum name="width" val="6"/></section>
            <section name="Left Border"><attnum name="width" val="0.6"/><attnum name="height" val="1.2"/></section>
            <section name="Track Segments">
            <section name="approach"><attstr name="type" val="str"/><attnum name="lg" val="40"/>
              <section name="Left Border"><attstr name="style" val="curb"/></section></section>
            <section name="wall-one"><attstr name="type" val="str"/><attnum name="lg" val="40"/>
              <section name="Left Border"><attstr name="style" val="wall"/></section></section>
            <section name="turn"><attstr name="type" val="lft"/><attnum name="radius" val="\(radius)"/><attnum name="arc" unit="deg" val="\(angle)"/>
              <section name="Left Border"><attstr name="style" val="curb"/></section></section>
            <section name="wall-two"><attstr name="type" val="str"/><attnum name="lg" val="90"/>
              <section name="Left Border"><attstr name="style" val="wall"/></section></section>
            <section name="exit"><attstr name="type" val="str"/><attnum name="lg" val="40"/>
              <section name="Left Border"><attstr name="style" val="curb"/></section></section>
            </section></section></params>
            """
            let data = Data(xml.utf8), road = try TrackBuilder.buildRoad(parameters:ParameterDocument.parse(data))
            let url = content.track.deletingLastPathComponent().appendingPathComponent("crossing-walls.xml")
            try data.write(to:url)
            let world = try ReferenceWorld(track:url,car:content.car,category:content.category)
            defer { world.close() }
            XCTAssertEqual(ref_fixed_wall_count(),2)
            var result = RefFixedPairResult()
            XCTAssertEqual(ref_fixed_pair_query(0,1,&result),1)
            if result.contact.hit != 0 { hits += 1 }
            if result.wouldAccessCar != 0 {
                invalid += 1
                var native = try MultiVehicleSimulation(definition:definition,road:road,carCount:1)
                XCTAssertThrowsError(try native.step(commands:[.init(brake:1)])) { error in
                    XCTAssertTrue(String(describing:error).contains("non-car"))
                }
            } else if result.contact.hit != 0 {
                var native = try MultiVehicleSimulation(definition:definition,road:road,carCount:1)
                XCTAssertNoThrow(try native.step(commands:[.init(brake:1)]))
                XCTAssertEqual(native.detectedFixedPairs,1)
            }
            // Do not invoke original SimUpdate for an invalid wall-as-car case.
            world.close(); cases += 1
        } }
        print("FIXED_PAIR_INVALID cases=\(cases) hits=\(hits) invalidCarAccess=\(invalid)")
        XCTAssertGreaterThan(invalid,0)
    }
}
