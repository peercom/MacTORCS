// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import TORCSTelemetry

final class TelemetryTests: XCTestCase {
    func testStreamingCapturePublishesOnlyWhenFinished() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("capture.jsonl")
        let existing = Data("existing capture".utf8)
        try existing.write(to: url)
        do {
            let writer = try TelemetryWriter(to: url)
            try writer.append(record())
            XCTAssertThrowsError(try writer.append(record(2, .nan)))
            XCTAssertEqual(try Data(contentsOf: url), existing)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["capture.jsonl"])
        let writer = try TelemetryWriter(to: url)
        try writer.append(record()); try writer.append(record(2, 3)); try writer.finish()
        XCTAssertThrowsError(try writer.append(record(3)))
        let loaded = try TelemetryIO.read(url)
        XCTAssertEqual(loaded.map(\.tick), [1, 2])
        XCTAssertEqual(loaded[1].values["x"], 3)
    }
    func record(_ tick: Int = 1, _ value: Double = 2, key: String = "x") -> TelemetryRecord {
        .init(scenario: "test", tick: tick, time: Double(tick)*0.002, values: [key: value])
    }
    func testMetricsAndThresholds() throws {
        let report = try TelemetryDiff.compare(reference: [record(1, 2),record(2, 4)], candidate: [record(1, 3),record(2, 2)], absoluteTolerance: 0, relativeTolerance: 0)
        XCTAssertFalse(report.passed)
        let field = try XCTUnwrap(report.fields["x"])
        XCTAssertEqual(field.maximumAbsolute, 2); XCTAssertEqual(field.maximumRelative, 0.5)
        XCTAssertEqual(field.rms, sqrt(2.5), accuracy: 1e-12)
        XCTAssertEqual(field.firstDivergentTick, 1)
        XCTAssertTrue(try TelemetryDiff.compare(reference: [record()], candidate: [record(1, 2.01)], absoluteTolerance: 0.02).passed)
    }
    func testInvalidComparisonsCannotPass() {
        for records in [[], [record(2)], [record(1, 2, key: "y")], [record(1, .infinity)]] {
            XCTAssertThrowsError(try TelemetryDiff.compare(reference: [record()], candidate: records))
        }
        XCTAssertThrowsError(try TelemetryDiff.compare(reference: [record(), record()], candidate: [record(), record()]))
        XCTAssertThrowsError(try TelemetryDiff.compare(reference: [record()], candidate: [record()], absoluteTolerance: -.infinity))
    }
}
