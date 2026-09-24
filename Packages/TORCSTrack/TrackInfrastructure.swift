// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 track/track4.cpp and robottools/rttrack.cpp.
// Copyright (C) 2002-2015, 1999-2024 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation

public struct TrackBarrier: Sendable, Codable, Equatable {
    public var style: TrackStyle
    public var width, height: Float
    public var surface: TrackSurface
    public var normal: SIMD2<Float>
    public init(style: TrackStyle, width: Float, height: Float, surface: TrackSurface, normal: SIMD2<Float>) {
        self.style = style; self.width = width; self.height = height; self.surface = surface; self.normal = normal
    }
}
public enum TrackPitType: Int, Sendable, Codable { case none = 0, trackSide = 1 }
/// Static loader output, before any race-engine assignment or occupancy updates.
public struct TrackPits: Sendable, Codable, Equatable {
    public let type: TrackPitType
    public let side: TrackSide?
    public let entry, start, end, exit: Int?
    public let stallLength, laneWidth, speedLimit: Float
    public let positions: [TrackLocalPosition]
    public init(type: TrackPitType, side: TrackSide?, entry: Int?, start: Int?, end: Int?, exit: Int?,
                stallLength: Float, laneWidth: Float, speedLimit: Float, positions: [TrackLocalPosition]) {
        self.type = type; self.side = side; self.entry = entry; self.start = start; self.end = end; self.exit = exit
        self.stallLength = stallLength; self.laneWidth = laneWidth; self.speedLimit = speedLimit; self.positions = positions
    }
    static let none = TrackPits(type: .none, side: nil, entry: nil, start: nil, end: nil, exit: nil,
                               stallLength: 0, laneWidth: 0, speedLimit: 0, positions: [])
}
extension TrackRoad {
    /// Original RtDistToPit convention. Wraps once and keeps the stored pit-local
    /// coordinate semantics, including the original loader's curved-pit quirk.
    public func distanceToPit(from position: TrackLocalPosition, stall: Int?) throws -> SIMD2<Float>? {
        guard let stall else { return nil }
        guard pits.positions.indices.contains(stall), geometry.segments.indices.contains(position.segment),
              position.toStart.isFinite, position.toRight.isFinite else { throw TrackError.invalid("Invalid pit distance input") }
        let pit = pits.positions[stall], p = geometry.segments[pit.segment], car = geometry.segments[position.segment]
        let pitStart = p.radius != 0 ? pit.toStart * p.radius : pit.toStart
        let carStart = car.radius != 0 ? position.toStart * car.radius : position.toStart
        var distance = p.distanceFromStart - car.distanceFromStart + pitStart - carStart
        if distance < 0 { distance += length } else if distance > length { distance -= length }
        return SIMD2(distance, pit.toRight - position.toRight)
    }
}
