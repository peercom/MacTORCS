// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import TORCSCore
import TORCSMath

final class CoreTests: XCTestCase {
    func testClockAtDifferentRefreshRates() {
        for hz in [60, 120, 144, 240] {
            var clock = FixedStepClock(), ticks: [UInt64] = []
            for _ in 0..<(hz * 10) { clock.advance(elapsed: 1 / Double(hz)) { ticks.append($0) } }
            XCTAssertEqual(clock.tick, 5000, "\(hz) Hz")
            XCTAssertEqual(ticks, Array(UInt64(1)...5000))
            XCTAssertEqual(clock.time, 10)
        }
    }
    func testBacklogAndInvalidTime() {
        var clock = FixedStepClock()
        clock.advance(elapsed: 1, maximumSteps: 10) { _ in }
        XCTAssertEqual(clock.tick, 10); XCTAssertTrue(clock.isBehind)
        for _ in 0..<49 { clock.advance(elapsed: 0, maximumSteps: 10) { _ in } }
        XCTAssertEqual(clock.tick, 500); XCTAssertFalse(clock.isBehind)
        for dt in [-1, Double.nan, Double.infinity] { XCTAssertEqual(clock.advance(elapsed: dt) { _ in }, 0) }
    }
    func testCoordinatesAndCurveUnits() {
        let origin = SIMD3<Float>(10, 20, 3), local = SIMD3<Float>(2, 0, 1)
        let world = Coordinates.localToWorld(local, origin: origin, yaw: .pi/2)
        XCTAssertEqual(world.x, 10, accuracy: 1e-5); XCTAssertEqual(world.y, 22, accuracy: 1e-5); XCTAssertEqual(world.z, 4)
        let inverse = Coordinates.worldToLocal(world, origin: origin, yaw: .pi/2)
        XCTAssertEqual(inverse.x, 2, accuracy: 1e-5); XCTAssertEqual(inverse.y, 0, accuracy: 1e-5)
        XCTAssertEqual(Coordinates.trackDistance(toStart: .pi/2, radius: 100), Float.pi * 50)
        XCTAssertEqual(Coordinates.trackDistance(toStart: 50, radius: nil), 50)
    }
    func testAtomicConfigurationAndPathValidation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ConfigurationStore(directory: directory)
        try store.save(["seed": 42], name: "settings.json")
        XCTAssertEqual(try store.load([String: Int].self, name: "settings.json"), ["seed": 42])
        XCTAssertThrowsError(try store.save([1], name: "../escape"))
    }
}
