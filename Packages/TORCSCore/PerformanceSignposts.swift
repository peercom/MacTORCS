// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import os

/// The profiling signposts PORT_SPECIFICATION.md section 24 asks for, in
/// one place so Instruments shows them under one category and a test can
/// check the list is complete.
///
/// Intervals are cheap when no instrument is attached — a signposter that
/// is not enabled returns immediately — so the hot paths keep them on
/// unconditionally. Names are `StaticString` because that is what the
/// system API takes; the list below is the one the call sites use.
public enum PerformanceSignposts {
    public static let signposter = OSSignposter(subsystem: "org.torcs.mac", category: "Performance")

    /// The seven the specification requires, by the names Instruments shows.
    public static let required: [String] = [
        "Simulation tick", "AI update", "Track queries", "Collision processing",
        "Asset loading", "Draw preparation", "GPU duration"]

    @inlinable
    public static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name)
    }

    @inlinable
    public static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }
}
