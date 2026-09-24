// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import TORCSReferenceSupport
import TORCSTelemetry

final class FullReferenceTests: XCTestCase {
    func content() throws -> ReferenceContent {
        try ReferenceContent(fixtures: XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil)))
    }
    func create(_ c: ReferenceContent, cars: Int = 1) throws -> ReferenceWorld {
        try ReferenceWorld(track: c.track, car: c.car, category: c.category, cars: cars)
    }
    func testOriginalTrackConstructionStationaryContactAndLifecycle() throws {
        let c = try content(), w = try create(c)
        defer { w.close(); withExtendedLifetime(c) {} }
        XCTAssertEqual(w.trackSegments, 371)
        XCTAssertGreaterThan(w.trackLength, 2500)
        XCTAssertLessThan(w.trackLength, 2700)
        XCTAssertThrowsError(try create(c), "Original global state cannot support two simultaneous worlds")
        try w.settle()
        let initial = try w.sample()
        XCTAssertEqual(initial.count, 142)
        for _ in 0..<1000 { try w.command(.init(brake: 1)); try w.step() }
        let end = try w.sample()
        XCTAssertEqual(end["damage"], 0)
        XCTAssertLessThan(abs(end["velocity.local.x"]!), 0.05)
        XCTAssertEqual(initial["position.x"]!, end["position.x"]!, accuracy: 0.01)
        for wheel in 0..<4 { XCTAssertGreaterThan(end["wheel.\(wheel).load"]!, 1000) }
        XCTAssertThrowsError(try w.settle())
        w.close()
        XCTAssertThrowsError(try w.step()); XCTAssertThrowsError(try w.sample())
    }
    func testAccelerationBrakingAndRestartDeterminism() throws {
        let c = try content()
        defer { withExtendedLifetime(c) {} }
        func run() throws -> [[String: Double]] {
            let w = try create(c); defer { w.close() }
            try w.settle()
            var samples: [[String: Double]] = []
            for tick in 1...3000 {
                try w.command(VehicleScenario.braking.command(tick: tick)); try w.step()
                if tick % 50 == 0 { samples.append(try w.sample()) }
            }
            XCTAssertGreaterThan(samples[29]["velocity.local.x"]!, 15)
            XCTAssertLessThan(abs(samples.last!["velocity.local.x"]!), 0.1)
            XCTAssertLessThan(samples[29]["fuel"]!, samples[0]["fuel"]!)
            return samples
        }
        let first = try run()
        XCTAssertEqual(first, try run(), "All 142 recorded fields must repeat after teardown/rebuild in the same process")
        #if DEBUG
        let baseline = "braking-debug-checkpoints"
        #else
        let baseline = "braking-release-checkpoints"
        #endif
        let url = try XCTUnwrap(Bundle.module.url(forResource: baseline, withExtension: "jsonl", subdirectory: "Fixtures"))
        let golden = try TelemetryIO.read(url)
        XCTAssertEqual(golden.count, first.count)
        for (index, record) in golden.enumerated() {
            XCTAssertEqual(record.tick, (index + 1) * 50)
            let values = Dictionary(uniqueKeysWithValues: first[index].map { ("car.0." + $0.key, $0.value) })
            XCTAssertEqual(values, record.values, "Original physics changed at tick \(record.tick)")
        }
    }
    func testOriginalVehicleCollisionProducesDamage() throws {
        let c = try content(), w = try create(c, cars: 2)
        defer { w.close(); withExtendedLifetime(c) {} }
        try w.settle()
        var collisionTicks = 0, maximumDamage: Double = 0
        for tick in 1...2000 {
            for car in 0..<2 { try w.command(VehicleScenario.carCollision.command(tick: tick, car: car), car: car) }
            try w.step()
            let a = try w.sample(), b = try w.sample(car: 1)
            if a["collision"]! != 0 || b["collision"]! != 0 { collisionTicks += 1 }
            maximumDamage = max(maximumDamage, a["damage"]! + b["damage"]!)
        }
        XCTAssertGreaterThan(collisionTicks, 0)
        XCTAssertGreaterThan(maximumDamage, 0)
        XCTAssertEqual(try w.record(scenario: "collision").values.count, 284)
    }
    func testRejectsUnpinnedFixtureBeforeLegacyParsing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.copyItem(at: XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil)), to: directory)
        try Data("<params name='modified'/>".utf8).write(to: directory.appendingPathComponent("aalborg.xml"))
        XCTAssertThrowsError(try ReferenceContent(fixtures: directory))
    }
}
