// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import TORCSSimulation
import TORCSConfiguration
import TORCSReferenceSupport

final class VehicleMassTests: XCTestCase {
    func testNative155DTMMassPropertiesAgainstOriginalConfiguration() throws {
        let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let content = try ReferenceContent(fixtures: fixtures)
        let car = try ParameterDocument.parse(Data(contentsOf: content.car))
        let category = try ParameterDocument.parse(Data(contentsOf: content.category))
        let native = try VehicleMassProperties(parameters: category.merging(car))
        let world = try ReferenceWorld(track: content.track, car: content.car, category: content.category)
        defer { world.close(); withExtendedLifetime(content) {} }
        let original = try world.massProperties()
        XCTAssertEqual(native.mass, original.mass); XCTAssertEqual(native.inverseMass, original.inverseMass)
        XCTAssertEqual(native.dimensions, SIMD3(original.length, original.width, original.height))
        XCTAssertEqual(native.centerOfGravity, SIMD3(original.cgX, original.cgY, original.cgZ))
        XCTAssertEqual(native.inverseInertia, SIMD3(original.inverseInertiaX, original.inverseInertiaY, original.inverseInertiaZ))
        XCTAssertEqual(native.staticWheelLoads, SIMD4(original.frontRightLoad, original.frontLeftLoad, original.rearRightLoad, original.rearLeftLoad))
        XCTAssertEqual(native.wheelbase, original.wheelbase); XCTAssertEqual(native.wheeltrack, original.wheeltrack)
        XCTAssertEqual(native.tankCapacity, original.tank); XCTAssertEqual(native.initialFuel, original.fuel)
    }
    func testInvalidMassCannotEnterSimulation() throws {
        let invalid = try ParameterDocument.parse(Data("<params name='bad'><section name='Car'><attnum name='mass' val='0'/></section></params>".utf8))
        XCTAssertThrowsError(try VehicleMassProperties(parameters: invalid))
    }
}
