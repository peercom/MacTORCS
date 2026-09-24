// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import TORCSCore

final class PerformanceSignpostsTests: XCTestCase {
    /// The specification lists seven; the list is the contract the call
    /// sites are written against.
    func testTheSpecificationsSevenAreListed() {
        let names = PerformanceSignposts.required
        XCTAssertEqual(names.count, 7)
        XCTAssertEqual(Set(names).count, 7)
        for expected in ["Simulation tick", "AI update", "Track queries", "Collision processing",
                         "Asset loading", "Draw preparation", "GPU duration"] {
            XCTAssertTrue(names.contains(expected), expected)
        }
    }

    /// Every listed name is used as a signpost somewhere in the sources:
    /// a name on the list with no call site is a promise, not a signpost.
    func testEveryListedNameHasACallSite() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var sources = ""
        for directory in ["App", "Packages"] {
            let base = root.appendingPathComponent(directory)
            guard let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in files where url.pathExtension == "swift" {
                sources += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
        }
        for name in PerformanceSignposts.required {
            XCTAssertTrue(sources.contains("begin(\"\(name)\")"), "no call site begins \"\(name)\"")
        }
    }

    func testIntervalsBeginAndEndWithoutAnInstrument() {
        let state = PerformanceSignposts.begin("Simulation tick")
        PerformanceSignposts.end("Simulation tick", state)
    }
}
