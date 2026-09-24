// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of track4.cpp camera definitions and normalization.
// Copyright (C) 2002-2015 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSConfiguration

public struct TrackRoadCamera: Sendable, Equatable {
    public let name: String
    public let position: SIMD3<Float>
    static func build(parameters: ParameterDocument, geometry: TrackGeometry, minimum: SIMD3<Float>) throws -> (cameras: [Self], indices: [Int?], warnings: [String]) {
        var cameras: [Self] = [], indices = [Int?](repeating: nil, count: geometry.segments.count)
        var warnings: [String] = []
        var first: [String: Int] = [:]
        for i in geometry.mainSegments where first[geometry.segments[i].name] == nil { first[geometry.segments[i].name] = i }
        for definition in parameters.section("Cameras")?.sections ?? [] {
            /// The original resolves a camera's segment reference by looking up
            /// that segment's id, with `GfParmGetNum` defaulting to 0 when the
            /// name does not exist, and then scanning for the segment with that
            /// id. An unknown name therefore silently selects segment 0 rather
            /// than failing.
            ///
            /// Shipped content depends on this: a-speedway writes
            /// `fov start val="segment s2"`, where the value mistakenly
            /// includes the word "segment" and matches nothing. Rejecting it
            /// would make an otherwise valid track unloadable.
            func segment(_ key: String) throws -> Int {
                let name = definition.string(key)
                if let index = first[name] { return index }
                guard let fallback = geometry.mainSegments.first else {
                    throw TrackError.invalid("Camera \(definition.name) references \(key) but the track has no segments")
                }
                // Reported rather than silent. The substitution is upstream's,
                // but a caller should still be able to see that a reference in
                // the content did not resolve.
                warnings.append("Camera \(definition.name) has unknown \(key) '\(name)'; "
                                + "resolved to the first segment, as the original loader does")
                return fallback
            }
            let location = try segment("segment"), start = try segment("fov start"), end = try segment("fov end")
            let local = TrackLocalPosition(segment: location, toStart: definition.number("to start", default: 0), toRight: definition.number("to right", default: 0))
            let height = definition.number("height", default: 0)
            guard local.toStart.isFinite, local.toRight.isFinite, height.isFinite else { throw TrackError.invalid("Nonfinite camera position") }
            let xy = geometry.localToGlobal(local)
            let position = SIMD3(xy.x, xy.y, geometry.height(local) + height) - minimum
            guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { throw TrackError.invalid("Camera position overflow") }
            let id = cameras.count
            cameras.append(Self(name: definition.name, position: position))
            // Start inclusive, end exclusive; equal endpoints cover a full lap.
            // Later XML entries replace earlier assignments in overlapping ranges.
            var current = start
            repeat {
                indices[current] = id
                current = geometry.segments[current].next
            } while current != end
        }
        return (cameras, indices, warnings)
    }
}
