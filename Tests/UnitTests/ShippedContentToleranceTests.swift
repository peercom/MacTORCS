// SPDX-License-Identifier: GPL-2.0-only
// What the original's parameter reader accepts in shipped content, which a
// stricter reader would refuse: a number with a trailing tail, text between
// elements, and a reference to an entity the document never declares.
import XCTest
import TORCSConfiguration

final class ShippedContentToleranceTests: XCTestCase {
    private func parse(_ xml: String,entities: [String:Data]=[:]) throws -> ParameterDocument {
        try ParameterDocument.parse(Data(xml.utf8),entities:entities)
    }
    func testNumbersAreReadByLeadingPrefixAsScanfDoes() throws {
        // car3-trb1: max="350.0.0".
        let document=try parse(#"<params name="p"><section name="s"><attnum name="Tq" min="0.0" max="350.0.0" val="350.0"/><attnum name="a" val="12abc"/><attnum name="h" val="0x10"/></section></params>"#)
        guard case .number(let torque)=document.section("s")!.parameters["Tq"] else { return XCTFail() }
        XCTAssertEqual(torque.value,350);XCTAssertEqual(torque.maximum,350);XCTAssertEqual(torque.minimum,0)
        XCTAssertEqual(document.section("s")!.number("a",default:0),12)
        XCTAssertEqual(document.section("s")!.number("h",default:0),16)
        // No leading number is still refused.
        XCTAssertThrowsError(try parse(#"<params name="p"><section name="s"><attnum name="a" val="abc"/></section></params>"#))
        XCTAssertThrowsError(try parse(#"<params name="p"><section name="s"><attnum name="a" val=""/></section></params>"#))
    }
    func testTextBetweenElementsIsIgnored() throws {
        // corkscrew: a comment closed twice leaves "-->" as text in a section.
        let document=try parse("<params name=\"p\"><section name=\"s\"><!-- a --> \n --> <attnum name=\"a\" val=\"3\"/> stray</section></params>")
        XCTAssertEqual(document.section("s")!.number("a",default:0),3)
    }
    func testUndeclaredEntityReferenceIsSkippedButADeclaredOneMustResolve() throws {
        // e-track-4 declares default-surfaces and also references default-objects.
        let xml="""
        <?xml version="1.0"?>
        <!DOCTYPE params SYSTEM "params.dtd" [
        <!ENTITY default-surfaces SYSTEM "surfaces.xml">
        ]>
        <params name="p"><section name="Surfaces">&default-surfaces;</section><section name="Objects">&default-objects;</section><section name="t"><attstr name="n" val="a &amp; b"/></section></params>
        """
        let surfaces=Data(#"<section name="asphalt"><attnum name="friction" val="1.2"/></section>"#.utf8)
        let document=try parse(xml,entities:["default-surfaces":surfaces,"default-objects":Data("<section name=\"tree\"/>".utf8)])
        XCTAssertEqual(document.section("Surfaces/asphalt")!.number("friction",default:0),1.2,accuracy:1e-6)
        XCTAssertEqual(document.section("Objects")!.sections.count,0,"the undeclared reference contributes nothing, as upstream")
        XCTAssertEqual(document.section("t")!.string("n"),"a & b","predefined entities are untouched")
        // A declared entity with nothing supplied for it is still an error.
        XCTAssertThrowsError(try parse(xml))
    }
}
