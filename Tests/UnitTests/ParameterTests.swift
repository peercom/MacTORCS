// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import TORCSConfiguration
import CReference

final class ParameterTests: XCTestCase {
    func testUnitConversionAgainstOriginal() {
        let tokens = ["", "m", "ft", "feet", "deg", "hour", "days", "km", "mm", "cm", "inch", "lbs", "lbf", "slug", "kPa", "MPa", "psi", "rpm", "%", "mph", "unknown", "kg.m/s2", "lbf/in", "km/h", "cm2", "m/s.mm", "N.m"]
        for unit in tokens {
            for value: Float in [-1000, -1, 0, 0.00001, 1, 37, 1000000] {
                XCTAssertEqual(Units.toSI(value, unit: unit), ref_unit_to_si(unit, value), "\(unit) \(value)")
                XCTAssertEqual(Units.fromSI(value, unit: unit), ref_si_to_unit(unit, value), "\(unit) \(value)")
            }
        }
    }
    func testRangesOrderingEscapingAndRoundTrip() throws {
        let xml = """
        <params name="test"><section name="Car"><attnum name="speed" unit="km/h" val="108" min="120" max="90"/><attstr name="label" val="A &amp; B" in="A,B"/><section name="2"/><section name="1"/></section></params>
        """
        let document = try ParameterDocument.parse(Data(xml.utf8)), car = try XCTUnwrap(document.section("Car"))
        XCTAssertEqual(car.number("speed", default: -1), 30, accuracy: 1e-5)
        XCTAssertEqual(car.number("missing", unit: "km/h", default: 108), 108)
        XCTAssertEqual(car.sections.map(\.name), ["2", "1"])
        XCTAssertEqual(car.string("label"), "A & B")
        let roundTrip = try ParameterDocument.parse(document.xmlData())
        XCTAssertEqual(roundTrip.section("Car")?.number("speed", default: -1), car.number("speed", default: -1))
        guard case .number(let n) = car.parameters["speed"] else { return XCTFail("No numeric value") }
        XCTAssertEqual(n.minimum, n.value); XCTAssertEqual(n.maximum, n.value)
    }
    func testRejectsMalformedAndUnsafeXML() {
        for xml in ["<params name='x'><section/></params>", "<params name='x'><attnum name='x' val='NaN'/></params>", "<params name='x'><section name='x'/><section name='x'/></params>", "<!DOCTYPE params [<!ENTITY leak SYSTEM 'file:///etc/passwd'>]><params name='x'>&leak;</params>", "<!DOCTYPE params [<!ENTITY a 'boom'>]><params name='x'>&a;</params>", "<params name='x'>&unknown;</params>"] {
            XCTAssertThrowsError(try ParameterDocument.parse(Data(xml.utf8)), xml)
        }
    }
    func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "xml", subdirectory: "Fixtures")))
    }
    func testOriginalCarTrackRaceRobot() throws {
        let car = try ParameterDocument.parse(fixture("155-DTM"))
        XCTAssertEqual(car.section("Car")?.number("mass", default: -1), 1115)
        let entities = ["default-surfaces": try fixture("surfaces"), "default-objects": try fixture("objects")]
        XCTAssertThrowsError(try ParameterDocument.parse(fixture("aalborg"), entities: entities))
        let track = try ParameterDocument.parse(fixture("aalborg"), entities: entities, allowLegacyLatin1: true)
        XCTAssertEqual(track.section("Header")?.string("name"), "Aalborg")
        XCTAssertGreaterThan(track.section("Main Track/Track Segments")?.sections.count ?? 0, 20)
        XCTAssertNotNil(try ParameterDocument.parse(fixture("quickrace")).section("Tracks"))
        XCTAssertNotNil(try ParameterDocument.parse(fixture("bt")).section("Robots"))
    }
}
