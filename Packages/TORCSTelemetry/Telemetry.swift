// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Darwin

public struct TelemetryRecord: Codable, Sendable {
    public let schema: Int
    public let scenario: String
    public let tick: Int
    public let time: Double
    public let values: [String: Double]
    public init(scenario: String, tick: Int, time: Double, values: [String: Double]) {
        self.schema = 1; self.scenario = scenario; self.tick = tick; self.time = time; self.values = values
    }
}
public enum TelemetryError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String { switch self { case .invalid(let message): message } }
}
public enum TelemetryIO {
    public static func write(_ records: [TelemetryRecord], to url: URL) throws {
        let writer = try TelemetryWriter(to: url)
        for record in records { try writer.append(record) }
        try writer.finish()
    }
    public static func read(_ url: URL) throws -> [TelemetryRecord] {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 128 * 1024 * 1024 else { throw TelemetryError.invalid("Telemetry exceeds the current 128 MiB limit") }
        let data = try Data(contentsOf: url)
        guard data.count <= 128 * 1024 * 1024 else { throw TelemetryError.invalid("Telemetry exceeds the current 128 MiB limit") }
        return try data.split(separator: 10).enumerated().map { i, line in
            do { return try JSONDecoder().decode(TelemetryRecord.self, from: Data(line)) }
            catch { throw TelemetryError.invalid("Line \(i + 1): \(error)") }
        }
    }
}

/// Bounded-memory, atomic publication. An unfinished capture never replaces an existing file.
public final class TelemetryWriter {
    private let destination: URL
    private let temporary: URL
    private var handle: FileHandle?
    private let encoder = JSONEncoder()
    public init(to destination: URL) throws {
        self.destination = destination
        temporary = destination.deletingLastPathComponent().appendingPathComponent(".telemetry-\(UUID().uuidString).tmp")
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw TelemetryError.invalid("Cannot create telemetry capture in \(destination.deletingLastPathComponent().path)")
        }
        do { handle = try FileHandle(forWritingTo: temporary) }
        catch { try? FileManager.default.removeItem(at: temporary); throw error }
    }
    public func append(_ record: TelemetryRecord) throws {
        guard let handle else { throw TelemetryError.invalid("Telemetry capture is closed") }
        var data = try encoder.encode(record); data.append(10)
        try handle.write(contentsOf: data)
    }
    public func finish() throws {
        guard let handle else { throw TelemetryError.invalid("Telemetry capture is closed") }
        try handle.synchronize(); try handle.close(); self.handle = nil
        guard rename(temporary.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
    deinit {
        try? handle?.close()
        try? FileManager.default.removeItem(at: temporary)
    }
}
public struct ErrorSample: Codable, Sendable {
    public let tick: Int
    public let time: Double
    public let absolute: Double
    public let relative: Double
}
public struct FieldReport: Codable, Sendable {
    public let maximumAbsolute: Double
    public let maximumRelative: Double
    public let rms: Double
    public let failures: Int
    public let firstDivergentTick: Int?
    public let divergence: [ErrorSample]
}
public struct DiffReport: Codable, Sendable {
    public let passed: Bool
    public let records: Int
    public let absoluteTolerance: Double
    public let relativeTolerance: Double
    public let fields: [String: FieldReport]
    public var text: String {
        var result = "\(passed ? "PASS" : "FAIL") — \(records) aligned records; abs \(absoluteTolerance), rel \(relativeTolerance)\n"
        for name in fields.keys.sorted() {
            let f = fields[name]!
            result += "\(name): max abs=\(f.maximumAbsolute), max rel=\(f.maximumRelative), RMS=\(f.rms), failures=\(f.failures)\n"
        }
        return result
    }
}

public enum TelemetryDiff {
    /// A sample passes when abs(error) <= absTolerance + relTolerance*abs(reference).
    /// No interpolation or dropped fields can hide a scheduling/schema mismatch.
    public static func compare(reference: [TelemetryRecord], candidate: [TelemetryRecord],
                               absoluteTolerance: Double = 1e-5, relativeTolerance: Double = 1e-6) throws -> DiffReport {
        guard absoluteTolerance.isFinite, relativeTolerance.isFinite, absoluteTolerance >= 0, relativeTolerance >= 0 else {
            throw TelemetryError.invalid("Tolerances must be finite and non-negative")
        }
        guard !reference.isEmpty, reference.count == candidate.count else { throw TelemetryError.invalid("Empty or mismatched record count") }
        let keys = Set(reference[0].values.keys)
        guard !keys.isEmpty else { throw TelemetryError.invalid("No telemetry fields") }
        var samples: [String: [ErrorSample]] = Dictionary(uniqueKeysWithValues: keys.map { ($0, []) })
        var failures: [String: Int] = [:], first: [String: Int] = [:]
        for i in reference.indices {
            let r = reference[i], c = candidate[i]
            guard r.schema == 1, c.schema == r.schema, r.scenario == c.scenario,
                  r.scenario == reference[0].scenario, r.tick >= 0, r.tick == c.tick,
                  r.time.isFinite, r.time >= 0, r.time == c.time,
                  Set(r.values.keys) == keys, Set(c.values.keys) == keys,
                  i == 0 || (r.tick > reference[i-1].tick && r.time > reference[i-1].time) else {
                throw TelemetryError.invalid("Schema, scenario, tick, time, or field mismatch at record \(i + 1)")
            }
            for key in keys {
                let rv = r.values[key]!, cv = c.values[key]!
                guard rv.isFinite, cv.isFinite else { throw TelemetryError.invalid("Non-finite \(key) at tick \(r.tick)") }
                let absolute = abs(cv - rv), relative = absolute / max(abs(rv), 1e-30)
                guard absolute.isFinite, relative.isFinite else { throw TelemetryError.invalid("Error overflow in \(key)") }
                samples[key]!.append(ErrorSample(tick: r.tick, time: r.time, absolute: absolute, relative: relative))
                if absolute > absoluteTolerance + relativeTolerance * abs(rv) {
                    failures[key, default: 0] += 1
                    if first[key] == nil { first[key] = r.tick }
                }
            }
        }
        var fields: [String: FieldReport] = [:]
        for key in keys {
            let values = samples[key]!, maximum = values.map(\.absolute).max()!
            // Scale the sum to avoid squaring overflow.
            let rms = maximum == 0 ? 0 : maximum * sqrt(values.reduce(0) { $0 + pow($1.absolute / maximum, 2) } / Double(values.count))
            fields[key] = FieldReport(maximumAbsolute: maximum, maximumRelative: values.map(\.relative).max()!, rms: rms,
                                      failures: failures[key, default: 0], firstDivergentTick: first[key], divergence: values)
        }
        return DiffReport(passed: failures.isEmpty, records: reference.count, absoluteTolerance: absoluteTolerance,
                          relativeTolerance: relativeTolerance, fields: fields)
    }
}
