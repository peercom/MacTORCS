// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of track4.cpp camera definitions and normalization.
// Copyright (C) 2002-2015 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSConfiguration

public struct TrackRoadCamera: Sendable, Equatable {
    public let name: String
    public let position: SIMD3<Float>
    static func build(parameters: ParameterDocument, geometry: TrackGeometry, minimum: SIMD3<Float>) throws -> (cameras: [Self], indices: [Int?]) {
        var cameras: [Self] = [], indices = [Int?](repeating: nil, count: geometry.segments.count)
        var first: [String: Int] = [:]
        for i in geometry.mainSegments where first[geometry.segments[i].name] == nil { first[geometry.segments[i].name] = i }
        for definition in parameters.section("Cameras")?.sections ?? [] {
            func segment(_ key: String) throws -> Int {
                let name = definition.string(key)
                guard let index = first[name] else {
                    throw TrackError.invalid("Camera \(definition.name) has missing or unknown \(key)")
                }
                return index
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
        return (cameras, indices)
    }
}
