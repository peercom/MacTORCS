// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import TORCSTelemetry

do {
    let args = Array(CommandLine.arguments.dropFirst())
    guard args.count >= 2 else { throw TelemetryError.invalid("Usage: torcs-diff reference.jsonl native.jsonl [--abs 0.00001] [--rel 0.000001] [--report report.json]") }
    var absolute = 1e-5, relative = 1e-6, reportURL: URL?
    var i = 2
    while i < args.count {
        guard i + 1 < args.count else { throw TelemetryError.invalid("Missing option value") }
        switch args[i] {
        case "--abs": guard let v = Double(args[i+1]) else { throw TelemetryError.invalid("Invalid tolerance") }; absolute = v
        case "--rel": guard let v = Double(args[i+1]) else { throw TelemetryError.invalid("Invalid tolerance") }; relative = v
        case "--report": reportURL = URL(fileURLWithPath: args[i+1])
        default: throw TelemetryError.invalid("Unknown option \(args[i])")
        }
        i += 2
    }
    let report = try TelemetryDiff.compareFiles(reference: URL(fileURLWithPath: args[0]), candidate: URL(fileURLWithPath: args[1]), absoluteTolerance: absolute, relativeTolerance: relative, reportURL: reportURL)
    print(report.text, terminator: "")
    if !report.passed { exit(1) }
} catch {
    FileHandle.standardError.write(Data("torcs-diff: \(error)\n".utf8)); exit(2)
}
