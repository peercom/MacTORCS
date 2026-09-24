// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 robottools/rttrack.cpp.
// Copyright (C) 1999-2024 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation

extension TrackGeometry {
    public func width(segment: Int, toStart: Float) -> Float {
        let s = segments[segment]
        return abs(s.startWidth + toStart * s.widthSlope)
    }
    /// Extrapolates within the supplied segment; does not advance to the next segment.
    public func localToGlobal(_ p: TrackLocalPosition, origin: TrackLateralOrigin = .right) -> SIMD2<Float> {
        let s = segments[p.segment]
        let right: Float
        switch origin {
        case .right: right = p.toRight
        case .middle: right = Float(Double(width(segment: p.segment, toStart: p.toStart)) / 2 + Double(p.toMiddle))
        case .left: right = width(segment: p.segment, toStart: p.toStart) - p.toLeft
        }
        if s.curve == .straight {
            let c = cos(s.headingStart), sine = sin(s.headingStart)
            let tr = s.role.isRight ? right - s.widthSlope * p.toStart : right
            return SIMD2(s.startRight.x + p.toStart * c - tr * sine,
                         s.startRight.y + p.toStart * sine + tr * c)
        }
        let sign: Float = s.curve == .left ? 1 : -1
        let a = s.headingStart + sign * p.toStart
        let r = s.role.isRight
            ? s.leftRadius + sign * (s.startWidth + s.widthSlope * p.toStart - right)
            : s.rightRadius - sign * right
        return SIMD2(s.center.x + sign * r * sin(a), s.center.y - sign * r * cos(a))
    }
    /// Retains TORCS's directional search and side-relative coordinate conventions.
    /// Invalid/nonconvergent positions fail instead of looping indefinitely.
    public func globalToLocal(_ point: SIMD2<Float>, startingAt start: Int,
                              mode: TrackPositionMode = .main) throws -> TrackLocalPosition {
        guard segments.indices.contains(start), segments[start].role == .main,
              point.x.isFinite, point.y.isFinite else { throw TrackError.invalid("Invalid track search input") }
        var index = start, direction = 0
        var p = TrackLocalPosition(segment: start, toStart: 0, mode: mode)
        var found = false
        for _ in 0...mainSegments.count {
            let s = segments[index]
            let before: Bool, after: Bool
            p.segment = index
            if s.curve == .straight {
                let sine = sin(s.headingStart), cosine = cos(s.headingStart)
                let x = point.x - s.startRight.x, y = point.y - s.startRight.y
                p.toStart = x * cosine + y * sine
                p.toRight = y * cosine - x * sine
                before = p.toStart < 0; after = p.toStart > s.length
            } else {
                let x = point.x - s.center.x, y = point.y - s.center.y
                let half = s.arc / 2
                var theta = s.curve == .left ? atan2(y, x) - (s.centerStart + half) : s.centerStart - half - atan2(y, x)
                guard theta.isFinite, abs(theta) <= 65536 else { throw TrackError.invalid("Track angle exceeds normalization range") }
                // Original macro compares with double PI, but subtracts float 2*PI.
                while Double(theta) > Double.pi { theta -= Float(2 * Double.pi) }
                while Double(theta) < -Double.pi { theta += Float(2 * Double.pi) }
                p.toStart = theta + half
                let radial = sqrt(x * x + y * y)
                p.toRight = s.curve == .left ? s.rightRadius - radial : radial - s.rightRadius
                before = theta < -half; after = theta > half
            }
            if before && direction < 1 { index = s.previous; direction = -1 }
            else if after && direction > -1 { index = s.next; direction = 1 }
            else { found = true; break }
        }
        guard found, p.toStart.isFinite, p.toRight.isFinite else { throw TrackError.invalid("Track position search did not converge") }
        let s = segments[p.segment]
        p.toMiddle = Float(Double(p.toRight) - Double(s.width) / 2)
        p.toLeft = s.width - p.toRight
        if mode == .track {
            for side in [TrackSide.right, .left] {
                var cursor = s.side(side)
                while let index = cursor {
                    let w = width(segment: index, toStart: p.toStart)
                    if side == .right { p.toRight += w } else { p.toLeft += w }
                    cursor = segments[index].side(side)
                }
            }
        } else if mode == .segment {
            let side: TrackSide
            if p.toRight < 0 && s.right != nil { side = .right }
            else if p.toLeft < 0 && s.left != nil { side = .left }
            else { return p }
            var previousWidth = s.width
            while (side == .right ? p.toRight : p.toLeft) < 0, let next = segments[p.segment].side(side) {
                p.segment = next
                let w = width(segment: next, toStart: p.toStart)
                if side == .right {
                    p.toLeft -= previousWidth; p.toRight += w
                    p.toMiddle += (previousWidth + w) / 2
                } else {
                    p.toRight -= previousWidth; p.toLeft += w
                    p.toMiddle += -(previousWidth + w) / 2
                }
                previousWidth = w
            }
        }
        return p
    }
    public func height(_ p: TrackLocalPosition) -> Float {
        var tr = p.toRight, index = p.segment
        if tr < 0, let right = segments[index].right {
            index = right; tr += segments[index].width
            if tr < 0, let right = segments[index].right {
                index = right; tr += width(segment: index, toStart: p.toStart)
            }
        } else if tr > segments[index].width, let left = segments[index].left {
            tr -= segments[index].width; index = left
            if tr > segments[index].width, let left = segments[index].left {
                tr -= width(segment: index, toStart: p.toStart); index = left
            }
        }
        let s = segments[index]
        let distance = s.curve == .straight ? p.toStart : p.toStart * s.radius
        let rightHeight = s.startRight.z + p.toStart * s.longitudinalSlope
        let bankHeight = tr * tan(s.bankStart + p.toStart * s.bankingSlope)
        let base = rightHeight + bankHeight
        if s.style == .curb {
            let alpha = s.role == .rightBorder ? s.width - tr : tr
            let roughness = s.surface.roughness * sin(s.surface.roughWaveNumber * distance)
            return base + alpha * (s.curbHeight + roughness) / s.width
        }
        return base + s.surface.roughness * sin(s.surface.roughWaveNumber * tr) * sin(s.surface.roughWaveNumber * distance)
    }
    public func height(at point: SIMD2<Float>, startingAt segment: Int) throws -> Float {
        height(try globalToLocal(point, startingAt: segment, mode: .segment))
    }
    /// Original contact surface selection uses at most border + outer side.
    public func effectiveSegment(_ p: TrackLocalPosition) -> Int {
        var tr = p.toRight, index = p.segment
        if tr < 0, let right = segments[index].right {
            index = right; tr += segments[index].width
            if tr < 0, let right = segments[index].right { index = right }
        } else if tr > segments[index].width, let left = segments[index].left {
            tr -= segments[index].width; index = left
            if tr > segments[index].width, let left = segments[index].left { index = left }
        }
        return index
    }
    public func sideNeighbour(main: Int, current: Int, side: TrackSide) -> Int {
        if let outer = segments[current].side(side) { return outer }
        let other: TrackSide = side == .left ? .right : .left
        var neighbour = main, inner = main
        while let next = segments[neighbour].side(other) {
            inner = neighbour
            if next == current { break }
            neighbour = next
        }
        return inner
    }
    public func tangent(_ p: TrackLocalPosition) -> Float {
        let s = segments[p.segment]
        switch s.curve {
        case .straight: return s.headingStart
        case .right: return s.headingStart - p.toStart
        case .left: return s.headingStart + p.toStart
        }
    }
    public func distanceFromStart(_ p: TrackLocalPosition) -> Float {
        let s = segments[p.segment]
        return s.distanceFromStart + (s.curve == .straight ? p.toStart : p.toStart * s.radius)
    }
    public func sideNormal(segment: Int, at point: SIMD2<Float>, side: TrackSide) -> SIMD2<Float> {
        let s = segments[segment]
        if s.curve == .straight { return side == .right ? s.rightNormal : -s.rightNormal }
        let sameSide = (side == .right && s.curve == .right) || (side == .left && s.curve == .left)
        let d = sameSide ? point - SIMD2(s.center.x, s.center.y) : SIMD2(s.center.x, s.center.y) - point
        let inverse: Float = 1 / sqrt(d.x * d.x + d.y * d.y)
        return SIMD2(d.x * inverse, d.y * inverse)
    }
    /// Original chord-based normal, including the zero-vector fallback. Deliberately
    /// not replaced by a smooth analytic normal, which would change tire forces.
    public func surfaceNormal(_ p: TrackLocalPosition) -> SIMD3<Float> {
        let s = segments[p.segment]
        func point(_ toStart: Float, _ toRight: Float) -> SIMD3<Float> {
            let local = TrackLocalPosition(segment: p.segment, toStart: toStart, toRight: toRight)
            let xy = localToGlobal(local)
            return SIMD3(xy.x, xy.y, height(local))
        }
        let start = point(0, p.toRight), end = point(s.extent, p.toRight)
        let ts: Float = s.endWidth > s.startWidth ? p.toStart : 0
        let w = s.endWidth > s.startWidth ? s.endWidth : s.startWidth
        let right = point(ts, 0), left = point(ts, w)
        let v1 = end - start, v2 = left - right
        var normal = SIMD3(v1.y * v2.z - v2.y * v1.z, v2.x * v1.z - v1.x * v2.z, v1.x * v2.y - v2.x * v1.y)
        let length = sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z)
        let inverse: Float = length == 0 ? 1 : 1 / length
        normal.x *= inverse; normal.y *= inverse; normal.z *= inverse
        return normal
    }
}
