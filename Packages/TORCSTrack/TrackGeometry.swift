// SPDX-License-Identifier: GPL-2.0-only
// Native value representation of TORCS 1.3.9 track.h geometry.
// Copyright (C) Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation

public enum TrackCurve: Int, Sendable, Codable { case right = 1, left = 2, straight = 3 }
public enum TrackRole: Int, Sendable, Codable {
    case main = 1, leftSide = 2, rightSide = 3, leftBorder = 4, rightBorder = 5
    var isRight: Bool { self == .rightSide || self == .rightBorder }
}
public enum TrackStyle: Int, Sendable, Codable { case flat = 0, curb = 1, wall = 2, fence = 3, pitBuilding = 4 }
public enum TrackSide: Int, Sendable, Codable { case right = 0, left = 1 }
public enum TrackLateralOrigin: Int, Sendable { case right = 0, middle = 1, left = 2 }
public enum TrackPositionMode: Int, Sendable, Codable { case main = 0, segment = 1, track = 2 }
extension TrackGeometry {
    /// The texture names of every surface the circuit's segments and their
    /// barriers declare: what trackgen baked its strips under.
    public var surfaceTextures: Set<String> {
        var names: Set<String> = []
        for segment in segments {
            if let texture = segment.surface.texture { names.insert(texture) }
            if let texture = segment.rightBarrier?.surface.texture { names.insert(texture) }
            if let texture = segment.leftBarrier?.surface.texture { names.insert(texture) }
        }
        return names
    }
}

public struct TrackSurface: Sendable, Codable, Equatable {
    public var material: String
    public var friction, rebound, rollingResistance, roughness, roughWaveNumber, damage: Float
    /// The surface's `texture name`, which trackgen bakes its strips under.
    /// Nil where the surface declares none. Runtime only: the encoding is
    /// compared field for field against the original's, so this stays out
    /// of it.
    public var texture: String? = nil
    enum CodingKeys: String, CodingKey {
        case material, friction, rebound, rollingResistance, roughness, roughWaveNumber, damage
    }
    public init(material: String, friction: Float, rebound: Float, rollingResistance: Float,
                roughness: Float, roughWaveNumber: Float, damage: Float, texture: String? = nil) {
        self.material = material; self.friction = friction; self.rebound = rebound
        self.rollingResistance = rollingResistance; self.roughness = roughness
        self.roughWaveNumber = roughWaveNumber; self.damage = damage; self.texture = texture
    }
}
/// Indices, never C pointers. mainIndex identifies the road owning a border/side.
/// toStart is metres on straights and radians on curves, matching TORCS.
public struct TrackSegment: Sendable, Codable {
    public var name: String
    public var upstreamID: Int
    public var curve: TrackCurve
    public var role: TrackRole
    public var style: TrackStyle
    public var mainIndex, previous, next: Int
    public var right, left: Int?
    public var length, width, startWidth, endWidth, distanceFromStart: Float
    public var radius, rightRadius, leftRadius, arc: Float
    public var center, startRight, startLeft, endRight, endLeft: SIMD3<Float>
    public var headingStart, headingEnd, pitchLeft, pitchRight, bankStart, bankEnd, centerStart: Float
    public var longitudinalSlope, bankingSlope, widthSlope, curbHeight: Float
    public var rightNormal: SIMD2<Float>
    public var surface: TrackSurface
    public var rightBarrier, leftBarrier: TrackBarrier?
    public var raceFlags: UInt32
    public var extent: Float { curve == .straight ? length : arc }

    public init(name: String, upstreamID: Int, curve: TrackCurve, role: TrackRole, style: TrackStyle,
                mainIndex: Int, previous: Int, next: Int, right: Int? = nil, left: Int? = nil,
                length: Float, width: Float, startWidth: Float, endWidth: Float, distanceFromStart: Float,
                radius: Float, rightRadius: Float, leftRadius: Float, arc: Float,
                center: SIMD3<Float>, startRight: SIMD3<Float>, startLeft: SIMD3<Float>, endRight: SIMD3<Float>, endLeft: SIMD3<Float>,
                headingStart: Float, headingEnd: Float, pitchLeft: Float, pitchRight: Float,
                bankStart: Float, bankEnd: Float, centerStart: Float,
                longitudinalSlope: Float, bankingSlope: Float, widthSlope: Float, curbHeight: Float,
                rightNormal: SIMD2<Float>, surface: TrackSurface, raceFlags: UInt32 = 0,
                rightBarrier: TrackBarrier? = nil, leftBarrier: TrackBarrier? = nil) {
        self.name = name; self.upstreamID = upstreamID; self.curve = curve; self.role = role; self.style = style
        self.mainIndex = mainIndex; self.previous = previous; self.next = next; self.right = right; self.left = left
        self.length = length; self.width = width; self.startWidth = startWidth; self.endWidth = endWidth
        self.distanceFromStart = distanceFromStart; self.radius = radius; self.rightRadius = rightRadius
        self.leftRadius = leftRadius; self.arc = arc; self.center = center; self.startRight = startRight
        self.startLeft = startLeft; self.endRight = endRight; self.endLeft = endLeft
        self.headingStart = headingStart; self.headingEnd = headingEnd; self.pitchLeft = pitchLeft; self.pitchRight = pitchRight
        self.bankStart = bankStart; self.bankEnd = bankEnd; self.centerStart = centerStart
        self.longitudinalSlope = longitudinalSlope; self.bankingSlope = bankingSlope; self.widthSlope = widthSlope
        self.curbHeight = curbHeight; self.rightNormal = rightNormal; self.surface = surface; self.raceFlags = raceFlags
        self.rightBarrier = rightBarrier; self.leftBarrier = leftBarrier
    }
    func side(_ side: TrackSide) -> Int? { side == .right ? right : left }
}
public struct TrackLocalPosition: Sendable, Codable, Equatable {
    public var segment: Int
    public var toStart, toRight, toMiddle, toLeft: Float
    public var mode: TrackPositionMode
    public init(segment: Int, toStart: Float, toRight: Float = 0, toMiddle: Float = 0, toLeft: Float = 0,
                mode: TrackPositionMode = .main) {
        self.segment = segment; self.toStart = toStart; self.toRight = toRight
        self.toMiddle = toMiddle; self.toLeft = toLeft; self.mode = mode
    }
}
public enum TrackError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String { switch self { case .invalid(let message): message } }
}
/// Validated immutable topology. No XML, reference engine, or renderer dependency.
public struct TrackGeometry: Sendable {
    public let segments: [TrackSegment]
    public let mainSegments: [Int]
    public init(segments: [TrackSegment]) throws {
        guard !segments.isEmpty, segments.count <= 1_000_000 else { throw TrackError.invalid("Invalid track segment count") }
        let mains = segments.indices.filter { segments[$0].role == .main }
        guard !mains.isEmpty else { throw TrackError.invalid("Track has no main road") }
        for (i, s) in segments.enumerated() {
            let scalars = [s.length, s.width, s.startWidth, s.endWidth, s.distanceFromStart, s.radius, s.rightRadius, s.leftRadius,
                           s.arc, s.headingStart, s.headingEnd, s.pitchLeft, s.pitchRight, s.bankStart, s.bankEnd, s.centerStart,
                           s.longitudinalSlope, s.bankingSlope, s.widthSlope, s.curbHeight, s.rightNormal.x, s.rightNormal.y,
                           s.surface.friction, s.surface.rebound, s.surface.rollingResistance, s.surface.roughness,
                           s.surface.roughWaveNumber, s.surface.damage]
            let vectors = [s.center, s.startRight, s.startLeft, s.endRight, s.endLeft]
            guard scalars.allSatisfy(\.isFinite), vectors.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
                  s.length >= 0, s.startWidth >= 0, s.endWidth >= 0, s.width >= 0,
                  s.extent > 0, (s.curve == .straight || s.radius > 0),
                  s.style != .curb || s.width > 0,
                  [s.mainIndex, s.previous, s.next].allSatisfy(segments.indices.contains),
                  [s.right, s.left].compactMap({ $0 }).allSatisfy(segments.indices.contains),
                  segments[s.mainIndex].role == .main else { throw TrackError.invalid("Invalid geometry at segment \(i)") }
            for barrier in [s.rightBarrier, s.leftBarrier].compactMap({ $0 }) {
                let surface = barrier.surface
                guard [barrier.width, barrier.height, barrier.normal.x, barrier.normal.y, surface.friction, surface.rebound,
                       surface.rollingResistance, surface.roughness, surface.roughWaveNumber, surface.damage].allSatisfy(\.isFinite),
                      barrier.width >= 0, barrier.height >= 0, s.role == .main else { throw TrackError.invalid("Invalid barrier at segment \(i)") }
            }
            if s.role == .main {
                guard s.mainIndex == i, segments[s.previous].next == i, segments[s.next].previous == i,
                      segments[s.previous].role == .main, segments[s.next].role == .main else {
                    throw TrackError.invalid("Broken main road ring at segment \(i)")
                }
            } else if s.left != nil && s.right != nil {
                throw TrackError.invalid("Side segments must point outward only")
            }
        }
        var visited = Set<Int>(), cursor = mains[0]
        while visited.insert(cursor).inserted { cursor = segments[cursor].next }
        guard cursor == mains[0], visited.count == mains.count else { throw TrackError.invalid("Disconnected main road rings") }
        var owned = Set(mains)
        for main in mains {
            for side in [TrackSide.right, .left] {
                var cursor = segments[main].side(side)
                while let index = cursor {
                    let s = segments[index]
                    guard owned.insert(index).inserted, s.mainIndex == main,
                          s.role != .main, s.role.isRight == (side == .right),
                          s.side(side == .right ? .left : .right) == nil else { throw TrackError.invalid("Invalid side chain") }
                    cursor = s.side(side)
                }
            }
        }
        guard owned.count == segments.count else { throw TrackError.invalid("Unreachable track geometry") }
        self.segments = segments; mainSegments = mains
    }
}
