// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import TORCSTrack
import TORCSConfiguration
import TORCSReferenceSupport

final class TrackGeometryTests: XCTestCase {
    func withTrack(_ body: (ReferenceWorld, TrackGeometry) throws -> Void) throws {
        let content = try ReferenceContent(fixtures: XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil)))
        let world = try ReferenceWorld(track: content.track, car: content.car, category: content.category)
        defer { world.close(); withExtendedLifetime(content) {} }
        try body(world, world.trackGeometry())
    }
    func testNativeAalborgXMLConstructionAgainstOriginal() throws {
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let parameters = try ParameterDocument.parse(Data(contentsOf: fixture.appendingPathComponent("aalborg.xml")), entities: [
            "default-surfaces": Data(contentsOf: fixture.appendingPathComponent("surfaces.xml")),
            "default-objects": Data(contentsOf: fixture.appendingPathComponent("objects.xml"))], allowLegacyLatin1: true)
        let road = try TrackBuilder.buildRoad(parameters: parameters)
        try withTrack { world, _ in
            try compareRoad(road, with: world)
        }
    }
    func compareRoad(_ road: TrackRoad, with world: ReferenceWorld) throws {
        let original = try world.trackGeometry()
        XCTAssertEqual(road.length, Float(world.trackLength))
        XCTAssertEqual(road.bounds, try world.trackBounds())
        XCTAssertEqual(road.geometry.mainSegments, original.mainSegments)
        XCTAssertEqual(road.geometry.segments.count, original.segments.count)
        // Compare every serialized geometry/surface scalar, not only centerline samples.
        let encode = JSONEncoder()
        var maxError: Double = 0, fields = 0
        func compare(_ a: Any, _ b: Any, path: String) {
            if let x = a as? [String: Any], let y = b as? [String: Any] {
                for (key, value) in x {
                    guard let other = y[key] else { XCTFail("Missing \(path).\(key)"); continue }
                    compare(value, other, path: path + "." + key)
                }
                XCTAssertEqual(Set(x.keys), Set(y.keys))
            } else if let x = a as? [Any], let y = b as? [Any] {
                XCTAssertEqual(x.count, y.count)
                for (i, pair) in zip(x,y).enumerated() { compare(pair.0, pair.1, path: path + "[\(i)]") }
            } else if let x = a as? NSNumber, let y = b as? NSNumber {
                let actual = Double(x.floatValue), expected = Double(y.floatValue)
                maxError = max(maxError, abs(actual - expected)); fields += 1
                XCTAssertEqual(actual, expected, accuracy: 1e-5 + 1e-6 * abs(expected), path)
            } else { XCTAssertEqual(String(describing: a), String(describing: b), path) }
        }
        for index in original.segments.indices {
            compare(try JSONSerialization.jsonObject(with: encode.encode(road.geometry.segments[index])),
                    try JSONSerialization.jsonObject(with: encode.encode(original.segments[index])), path: "segment[\(index)]")
        }
        let pits = try world.trackPits()
        compare(try JSONSerialization.jsonObject(with: encode.encode(road.pits)),
                try JSONSerialization.jsonObject(with: encode.encode(pits)), path: "pits")
        var queries = 0, distanceError: Float = 0
        for stall in pits.positions.indices {
            for index in road.geometry.mainSegments {
                let position = TrackLocalPosition(segment: index, toStart: road.geometry.segments[index].extent * 0.37, toRight: -1.7)
                let actual = try XCTUnwrap(road.distanceToPit(from: position, stall: stall))
                let expected = try world.pitDistance(from: position, stall: stall)
                distanceError = max(distanceError, abs(actual.x - expected.x), abs(actual.y - expected.y))
                XCTAssertEqual(actual.x, expected.x, accuracy: 1e-5 + 1e-6 * abs(expected.x))
                XCTAssertEqual(actual.y, expected.y, accuracy: 1e-5 + 1e-6 * abs(expected.y))
                queries += 1
            }
        }
        print("TRACK_PITS stalls=\(pits.positions.count) queries=\(queries) maxAbsolute=\(distanceError)")
        print("TRACK_BUILD segments=\(original.segments.count) fields=\(fields) maxAbsolute=\(maxError)")
    }
    func testChangingRadiusProfilesAndSideTapersAgainstOriginal() throws {
        let xml = """
        <params name="profile-fixture">
          <section name="Header"><attnum name="version" val="4"/></section>
          <section name="Surfaces"><section name="rough">
            <attnum name="roughness" val="0.03"/><attnum name="roughness wavelength" val="0.41"/>
            <attnum name="friction" val="0.63"/><attnum name="rolling resistance" val="0.017"/>
          </section></section>
          <section name="Main Track">
            <attnum name="width" val="9.37"/><attnum name="profil steps length" val="8"/>
            <section name="Left Side"><attnum name="width" val="2"/><attstr name="banking type" val="tangent"/></section>
            <section name="Right Side"><attnum name="width" val="3"/><attstr name="banking type" val="level"/></section>
            <section name="Left Border"><attnum name="width" val="0.7"/><attnum name="height" val="0.15"/>
              <attstr name="style" val="curb"/><attstr name="surface" val="rough"/></section>
            <section name="Right Border"><attnum name="width" val="0.53"/><attnum name="height" val="0.08"/>
              <attstr name="style" val="curb"/><attstr name="surface" val="rough"/></section>
            <section name="Track Segments">
              <section name="linear"><attstr name="type" val="str"/><attnum name="lg" val="120.73"/>
                <attstr name="profil" val="linear"/><attnum name="z start" val="3.75"/><attnum name="grade" val="0.023"/>
                <attnum name="banking end" unit="deg" val="-7"/>
                <section name="Left Side"><attnum name="start width" val="0"/><attnum name="end width" val="2.4"/></section>
              </section>
              <section name="opening-left"><attstr name="type" val="lft"/><attnum name="radius" val="27.349"/>
                <attnum name="end radius" val="64.917"/><attnum name="arc" unit="deg" val="115"/>
                <attnum name="profil steps" val="7"/><attnum name="banking end" unit="deg" val="12"/>
                <attnum name="profil start tangent left" val="0.043"/><attnum name="profil end tangent right" val="-0.023"/>
                <section name="Right Side"><attnum name="start width" val="3"/><attnum name="end width" val="0"/></section>
              </section>
              <section name="closing-right"><attstr name="type" val="rgt"/><attnum name="radius" val="83.51"/>
                <attnum name="end radius" val="23.59"/><attnum name="arc" unit="deg" val="245"/>
                <attnum name="z end left" val="5.7"/><attnum name="z end right" val="6.2"/>
                <attnum name="profil end tangent" val="0.1"/>
                <section name="Right Side"><attnum name="start width" val="0"/><attnum name="end width" val="1.3"/></section>
              </section>
              <section name="inherited"><attstr name="type" val="str"/><attnum name="lg" val="30"/>
                <attnum name="profil steps" val="3"/><attstr name="surface" val="rough"/>
                <section name="Left Side"><attnum name="width" val="0"/><attnum name="start width" val="0"/></section>
              </section>
            </section>
          </section>
        </params>
        """
        let data = Data(xml.utf8), parameters = try ParameterDocument.parse(data)
        let road = try TrackBuilder.buildRoad(parameters: parameters)
        let content = try ReferenceContent(fixtures: XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil)))
        let url = content.track.deletingLastPathComponent().appendingPathComponent("synthetic.xml")
        try data.write(to: url)
        let world = try ReferenceWorld(track: url, car: content.car, category: content.category)
        defer { world.close(); withExtendedLifetime(content) {} }
        try compareRoad(road, with: world)
        let native = road.geometry
        var count = 0, worst: Float = 0
        for (index, s) in native.segments.enumerated() {
            for progress: Float in [0, 0.17, 0.75, 1] {
                let ts = s.extent * progress, w = native.width(segment: index, toStart: ts)
                for lateral: Float in [-0.2, 0.17, 0.8, 1.2] {
                    let p = TrackLocalPosition(segment: index, toStart: ts, toRight: w * lateral)
                    let ref = try world.trackSample(p), normal = native.surfaceNormal(p), point = native.localToGlobal(p)
                    for (a, b) in [(point.x, ref.x), (point.y, ref.y), (native.height(p), ref.height),
                                   (normal.x, ref.normal.x), (normal.y, ref.normal.y), (normal.z, ref.normal.z)] {
                        worst = max(worst, abs(a - b))
                        XCTAssertEqual(a, b, accuracy: 1e-5 + 1e-6 * abs(b), "Synthetic segment \(index)")
                    }
                    count += 1
                }
            }
        }
        print("TRACK_SYNTHETIC samples=\(count) maxAbsolute=\(worst)")
    }
    func testAllAalborgSegmentsLocalGeometryAgainstOriginal() throws {
        try withTrack { world, native in
            XCTAssertEqual(native.mainSegments.count, 371)
            XCTAssertGreaterThan(native.segments.count, 1000)
            var worst: Float = 0, samples = 0
            func compare(_ actual: Float, _ expected: Float, _ field: String, _ index: Int) {
                worst = max(worst, abs(actual - expected))
                XCTAssertTrue(actual.isFinite && expected.isFinite)
                XCTAssertEqual(actual, expected, accuracy: 1e-5 + 1e-6 * abs(expected), "\(field), segment \(index)")
            }
            for (index, segment) in native.segments.enumerated() {
                for progress: Float in [0, 0.13, 0.5, 0.93, 1] {
                    let ts = segment.extent * progress
                    let width = native.width(segment: index, toStart: ts)
                    for lateral: Float in [-3, -0.05, 0, 0.2, 0.5, 0.8, 1, 1.05, 4] {
                        let right = lateral * width
                        let position = TrackLocalPosition(segment: index, toStart: ts, toRight: right,
                                                          toMiddle: right - width / 2, toLeft: width - right)
                        let ref = try world.trackSample(position)
                        let point = native.localToGlobal(position)
                        compare(point.x, ref.x, "world x", index); compare(point.y, ref.y, "world y", index)
                        compare(native.height(position), ref.height, "height", index)
                        compare(width, ref.width, "width", index)
                        compare(native.tangent(position), ref.tangent, "tangent", index)
                        compare(native.distanceFromStart(position), ref.distance, "distance", index)
                        XCTAssertEqual(native.effectiveSegment(position), Int(ref.effectiveSegment))
                        let normal = native.surfaceNormal(position)
                        compare(normal.x, ref.normal.x, "normal x", index)
                        compare(normal.y, ref.normal.y, "normal y", index)
                        compare(normal.z, ref.normal.z, "normal z", index)
                        for side in [TrackSide.right, .left] {
                            let expected = side == .right ? ref.rightNormal : ref.leftNormal
                            let actual = native.sideNormal(segment: index, at: point, side: side)
                            compare(actual.x, expected.x, "side normal x", index)
                            compare(actual.y, expected.y, "side normal y", index)
                            XCTAssertEqual(native.sideNeighbour(main: segment.mainIndex, current: index, side: side),
                                           try world.trackNeighbour(main: segment.mainIndex, current: index, side: side))
                        }
                        for origin in [TrackLateralOrigin.middle, .left] {
                            let ref = try world.trackSample(position, origin: origin)
                            let point = native.localToGlobal(position, origin: origin)
                            compare(point.x, ref.x, "lateral origin x", index); compare(point.y, ref.y, "lateral origin y", index)
                        }
                        samples += 1
                    }
                }
            }
            print("TRACK_LOCAL samples=\(samples) segments=\(native.segments.count) maxAbsolute=\(worst)")
        }
    }
    func testAalborgGlobalSearchAndSideTransitionsAgainstOriginal() throws {
        try withTrack { world, native in
            var samples = 0, worst: Float = 0
            for index in native.mainSegments {
                let segment = native.segments[index]
                for progress: Float in [-0.1, 0, 0.17, 0.5, 0.99, 1, 1.1] {
                    for right: Float in [-30, -2, -0.1, 0, 3, 9, 12, 14, 50] {
                        let point = native.localToGlobal(.init(segment: index, toStart: segment.extent * progress, toRight: right))
                        for mode in [TrackPositionMode.main, .segment, .track] {
                            let ref = try world.trackPosition(point, startingAt: index, mode: mode)
                            let actual = try native.globalToLocal(point, startingAt: index, mode: mode)
                            XCTAssertEqual(actual.segment, ref.segment, "seed=\(index), progress=\(progress), right=\(right)")
                            for (a, b) in [(actual.toStart, ref.toStart), (actual.toRight, ref.toRight),
                                           (actual.toLeft, ref.toLeft), (actual.toMiddle, ref.toMiddle)] {
                                worst = max(worst, abs(a - b))
                                XCTAssertEqual(a, b, accuracy: 1e-5 + 1e-6 * abs(b))
                            }
                            samples += 1
                        }
                    }
                }
            }
            print("TRACK_GLOBAL samples=\(samples) maxAbsolute=\(worst)")
        }
    }
    static func infrastructureFixture(side: String, wrap: Bool, validMarkers: Bool = true, length: Float = 9.7) -> String {
        let start = validMarkers ? (wrap ? "e" : "b") : "missing"
        return """
        <params name="pit-fixture"><section name="Header"><attnum name="version" val="4"/></section>
          <section name="Surfaces"><section name="barrier-test"><attnum name="friction" val="0.44"/>
            <attnum name="dammage" val="19"/><attnum name="rebound" val="0.3"/></section></section>
          <section name="Main Track"><attnum name="width" val="11"/>
            <section name="Left Side"><attnum name="width" val="6"/></section>
            <section name="Right Side"><attnum name="width" val="7"/></section>
            <section name="Left Border"><attnum name="width" val="0.8"/></section>
            <section name="Right Border"><attnum name="width" val="0.6"/></section>
            <section name="Right Barrier"><attstr name="style" val="wall"/><attnum name="width" val="0.35"/>
              <attstr name="surface" val="barrier-test"/></section>
            <section name="Left Barrier"><attstr name="style" val="fence"/><attnum name="width" val="99"/></section>
            <section name="Pits"><attstr name="side" val="\(side)"/><attstr name="entry" val="\(wrap ? "d" : "a")"/>
              <attstr name="start" val="\(start)"/><attstr name="end" val="\(wrap ? "a" : "c")"/>
              <attstr name="exit" val="\(wrap ? "b" : "d")"/><attnum name="length" val="\(length)"/>
              <attnum name="width" val="2.3"/><attnum name="speed limit" unit="km/h" val="65"/></section>
            <section name="Track Segments">
              <section name="a"><attstr name="type" val="str"/><attnum name="lg" val="40"/>
                <attnum name="profil steps" val="3"/><section name="Left Barrier"><attstr name="style" val="wall"/>
                  <attnum name="width" val="0.7"/><attnum name="height" val="1.1"/></section></section>
              <section name="b"><attstr name="type" val="lft"/><attnum name="radius" val="60"/>
                <attnum name="arc" unit="deg" val="30"/><attnum name="profil steps" val="3"/>
                <section name="Left Barrier"><attstr name="style" val="fence"/><attnum name="width" val="20"/></section></section>
              <section name="c"><attstr name="type" val="str"/><attnum name="lg" val="80"/><attnum name="profil steps" val="5"/>
                <section name="Left Barrier"><attstr name="style" val="wall"/></section></section>
              <section name="d"><attstr name="type" val="rgt"/><attnum name="radius" val="70"/>
                <attnum name="arc" unit="deg" val="40"/><attnum name="profil steps" val="4"/>
                <section name="Right Barrier"><attnum name="height" val="0.9"/></section></section>
              <section name="e"><attstr name="type" val="str"/><attnum name="lg" val="80"/><attnum name="profil steps" val="4"/></section>
            </section>
          </section>
        </params>
        """
    }
    func testPitSidesWraparoundMissingMarkersAndBarrierInheritance() throws {
        let content = try ReferenceContent(fixtures: XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil)))
        defer { withExtendedLifetime(content) {} }
        var cases = 0
        for side in ["left", "right"] {
            for wrap in [false, true] {
                for markers in [true, false] {
                    let data = Data(Self.infrastructureFixture(side: side, wrap: wrap, validMarkers: markers).utf8)
                    let road = try TrackBuilder.buildRoad(parameters: ParameterDocument.parse(data))
                    let url = content.track.deletingLastPathComponent().appendingPathComponent("pits.xml")
                    try data.write(to: url)
                    let world = try ReferenceWorld(track: url, car: content.car, category: content.category)
                    defer { world.close() }
                    try compareRoad(road, with: world)
                    XCTAssertEqual(road.pits.type, markers ? .trackSide : .none)
                    if markers { XCTAssertGreaterThan(road.pits.positions.count, 8) }
                    XCTAssertNil(try road.distanceToPit(from: .init(segment: 0, toStart: 0), stall: nil))
                    XCTAssertThrowsError(try road.distanceToPit(from: .init(segment: 0, toStart: 0), stall: -1))
                    world.close(); cases += 1
                }
            }
        }
        print("TRACK_INFRASTRUCTURE cases=\(cases)")
    }
    func testRejectsInvalidPitAllocationAndBarriers() throws {
        let badLength = Self.infrastructureFixture(side: "right", wrap: false, length: 0)
        let hugeCount = Self.infrastructureFixture(side: "right", wrap: false, length: 0.00001)
        let noSide = Self.infrastructureFixture(side: "left", wrap: false)
            .replacingOccurrences(of: "<attnum name=\"width\" val=\"6\"/>", with: "<attnum name=\"width\" val=\"0\"/>")
            .replacingOccurrences(of: "<attnum name=\"width\" val=\"0.8\"/>", with: "<attnum name=\"width\" val=\"0\"/>")
        let badBarrier = Self.infrastructureFixture(side: "right", wrap: false).replacingOccurrences(of: "val=\"1.1\"", with: "val=\"-1\"")
        for xml in [badLength, hugeCount, noSide, badBarrier] {
            XCTAssertThrowsError(try TrackBuilder.buildRoad(parameters: ParameterDocument.parse(Data(xml.utf8))))
        }
    }
    func testRejectsMalformedRoadDefinitionsBeforeConstruction() throws {
        func xml(_ header: String = "4", _ width: String = "10", _ geometry: String) -> Data {
            Data("<params name='invalid'><section name='Header'><attnum name='version' val='\(header)'/></section><section name='Main Track'><attnum name='width' val='\(width)'/><section name='Track Segments'><section name='bad'>\(geometry)</section></section></section></params>".utf8)
        }
        let straight = "<attstr name='type' val='str'/><attnum name='lg' val='100'/>"
        for data in [xml("3", "10", straight), xml("4", "0", straight),
                     xml("4", "10", "<attstr name='type' val='lft'/><attnum name='radius' val='0'/><attnum name='arc' val='1'/>"),
                     xml("4", "10", straight + "<attnum name='profil steps length' val='0.00000000000000000000000000000001'/>"),
                     xml("4", "10", straight + "<attnum name='profil steps' val='-1'/>")] {
            XCTAssertThrowsError(try TrackBuilder.buildRoad(parameters: ParameterDocument.parse(data)))
        }
    }
    func testRejectsInvalidTopologyAndSearchInputs() throws {
        try withTrack { _, native in
            var segments = native.segments
            let first = native.mainSegments[0]
            segments[first].next = -1
            XCTAssertThrowsError(try TrackGeometry(segments: segments))
            segments = native.segments
            segments[first].right = first
            XCTAssertThrowsError(try TrackGeometry(segments: segments))
            segments = native.segments
            segments[first].longitudinalSlope = .nan
            XCTAssertThrowsError(try TrackGeometry(segments: segments))
            XCTAssertThrowsError(try native.globalToLocal(SIMD2(.nan, 0), startingAt: first))
            XCTAssertThrowsError(try native.globalToLocal(.zero, startingAt: -1))
            segments = native.segments
            let curve = try XCTUnwrap(native.mainSegments.first { segments[$0].curve != .straight })
            segments[curve].centerStart = Float.greatestFiniteMagnitude
            let extreme = try TrackGeometry(segments: segments)
            XCTAssertThrowsError(try extreme.globalToLocal(.zero, startingAt: curve))

            XCTAssertThrowsError(try native.globalToLocal(SIMD2(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude), startingAt: first))
        }
    }
}
