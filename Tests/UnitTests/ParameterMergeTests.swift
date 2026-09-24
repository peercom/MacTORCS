// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSConfiguration
import TORCSReferenceSupport

final class ParameterMergeTests: XCTestCase {
    func testAllMergeModesAgainstOriginal() throws {
        let source = """
        <params name="category">
        <section name="Car"><attnum name="mass" val="1200" min="900" max="1500"/>
        <attstr name="drive" val="rear" in="rear,front,all"/><attstr name="fixed" val="base"/>
        <attnum name="source only" val="8"/><section name="empty"/></section>
        <section name="Source"><attnum name="a" val="1"/></section></params>
        """
        let target = """
        <params name="car">
        <section name="Car"><attnum name="mass" val="800" min="700" max="1300"/>
        <attstr name="drive" val="all" in="all,rear,unavailable"/><attstr name="fixed" val="override"/>
        <attnum name="target only" val="9"/><section name="Nested"><attnum name="b" val="2"/></section></section>
        <section name="Target"><attnum name="a" val="3"/></section></params>
        """
        let a = try ParameterDocument.parse(Data(source.utf8)), b = try ParameterDocument.parse(Data(target.utf8))
        for mode in 0...3 {
            var output = [CChar](repeating: 0, count: 65536)
            XCTAssertEqual(ref_merge_xml(source, target, Int32(mode), &output, Int32(output.count)), 1)
            let original = try ParameterDocument.parse(Data(String(cString: output).utf8))
            let native = try a.merging(b, mode: .init(rawValue: mode))
            XCTAssertEqual(native.root.sections, original.root.sections, "Merge mode \(mode)")
        }
        let merged = try a.merging(b)
        XCTAssertEqual(merged.section("Car")?.number("mass", default: -1), 900)
        XCTAssertEqual(merged.section("Car")?.string("fixed"), "base")
        XCTAssertEqual(merged.section("Car")?.parameters["drive"], .string("all", allowed: ["all", "rear", "all", "rear"]))
        XCTAssertNil(merged.section("Car/empty"))
    }
    func testRealCarCategoryMergeAgainstOriginalParameterValues() throws {
        let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let car = try ParameterDocument.parse(Data(contentsOf: fixtures.appendingPathComponent("155-DTM.xml")))
        let category = try ParameterDocument.parse(Data(contentsOf: fixtures.appendingPathComponent("Track-4WD-GrB.xml")))
        let merged = try category.merging(car)
        let content = try ReferenceContent(fixtures: fixtures)
        let world = try ReferenceWorld(track: content.track, car: content.car, category: content.category)
        defer { world.close(); withExtendedLifetime(content) {} }
        var count = 0
        func check(_ section: ParameterSection, parent: String) throws {
            let path = parent.isEmpty ? section.name : parent + "/" + section.name
            for (key, value) in section.parameters {
                switch value {
                case .number(let n): XCTAssertEqual(n.value, try world.parameterNumber(section: path, key: key), "\(path)/\(key)")
                case .string(let s, _): XCTAssertEqual(s, try world.parameterString(section: path, key: key), "\(path)/\(key)")
                }
                count += 1
            }
            for child in section.sections { try check(child, parent: path) }
        }
        for section in merged.root.sections { try check(section, parent: "") }
        XCTAssertEqual(count, 292)
    }
    func testInvalidTypesAndDisjointNumericRange() throws {
        let a = try ParameterDocument.parse(Data("<params name='a'><section name='S'><attnum name='v' val='8' min='7' max='9'/></section></params>".utf8))
        let b = try ParameterDocument.parse(Data("<params name='b'><section name='S'><attstr name='v' val='bad'/></section></params>".utf8))
        XCTAssertThrowsError(try a.merging(b))
        XCTAssertThrowsError(try a.merging(b, mode: .init(rawValue: 8)))
        let c = try ParameterDocument.parse(Data("<params name='c'><section name='S'><attnum name='v' val='1' min='0' max='2'/></section></params>".utf8))
        guard case .number(let n) = try a.merging(c).section("S")?.parameters["v"] else { return XCTFail("Missing merged number") }
        XCTAssertEqual(n.value, 2); XCTAssertEqual(n.minimum, 7); XCTAssertEqual(n.maximum, 2)
    }
}
