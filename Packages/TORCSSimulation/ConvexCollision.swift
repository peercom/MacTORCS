// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of SOLID Convex.cpp, Box.cpp, Simplex.cpp, Polygon.cpp and 3D
// transformations bundled with TORCS 1.3.9. Copyright (C) 1996-1998 Gino van den Bergen.
// These derived portions are converted from LGPL version 2-or-later to GPL
// version 2 under LGPL version 2 section 3, effective 2026-09-23. This entire
// file is GPL-2.0-only. See LICENSE and Upstream/Licenses/SOLID-LGPL-2.0.txt.
// Original imported sources and their notices remain unchanged.
import Foundation
import TORCSTrack

@inline(__always) func convexDot(_ a: SIMD3<Double>,_ b: SIMD3<Double>) -> Double { a.x*b.x+a.y*b.y+a.z*b.z }
public struct ConvexTransform: Sendable {
    public let rowX,rowY,rowZ,origin: SIMD3<Double>
    // Matrix import is AFFINE even for an orthonormal matrix. Only operations
    // starting from setIdentity retain the transpose-only inverse branch.
    let type: Int
    public init() { rowX = SIMD3(1,0,0); rowY = SIMD3(0,1,0); rowZ = SIMD3(0,0,1); origin = .zero; type = 0 }
    public init(rowX: SIMD3<Double> = SIMD3(1,0,0),rowY: SIMD3<Double> = SIMD3(0,1,0),rowZ: SIMD3<Double> = SIMD3(0,0,1),origin: SIMD3<Double> = .zero) {
        self.rowX = rowX; self.rowY = rowY; self.rowZ = rowZ; self.origin = origin; type = 7
    }
    public init(_ t: CollisionTransform) {
        type = 7
        let a = t.rotation.toWorld(SIMD3(1,0,0)), b = t.rotation.toWorld(SIMD3(0,1,0)), c = t.rotation.toWorld(SIMD3(0,0,1))
        rowX = SIMD3(Double(a.x),Double(b.x),Double(c.x)); rowY = SIMD3(Double(a.y),Double(b.y),Double(c.y))
        rowZ = SIMD3(Double(a.z),Double(b.z),Double(c.z)); origin = SIMD3(Double(t.position.x),Double(t.position.y),Double(t.position.z))
    }
    public func point(_ p: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(convexDot(rowX,p)+origin.x,convexDot(rowY,p)+origin.y,convexDot(rowZ,p)+origin.z)
    }
    public func supportDirection(_ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(rowX.x*v.x+rowY.x*v.y+rowZ.x*v.z,rowX.y*v.x+rowY.y*v.y+rowZ.y*v.z,rowX.z*v.x+rowY.z*v.y+rowZ.z*v.z)
    }
}
public struct ConvexShape: Sendable {
    public enum Kind: Int32, Sendable { case box = 0, simplex = 1, polygon = 2 }
    public let kind: Kind
    public let dimensions: SIMD3<Double>
    public let vertices: [SIMD3<Double>]
    public private(set) var supportCursor = 0
    public init(box dimensions: SIMD3<Double>) throws {
        guard dimensions.x.isFinite,dimensions.y.isFinite,dimensions.z.isFinite,dimensions.min()>=0 else { throw TrackError.invalid("Invalid collision box") }
        kind = .box; self.dimensions = dimensions; vertices = []
    }
    /// Polygon input must be an ordered convex polygon, as required by SOLID.
    public init(vertices: [SIMD3<Double>], polygon: Bool) throws {
        guard !vertices.isEmpty,vertices.count<=65536,vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { throw TrackError.invalid("Invalid convex vertices") }
        kind = polygon ? .polygon : .simplex; dimensions = .zero; self.vertices = vertices
    }
    public mutating func support(_ direction: SIMD3<Double>) -> SIMD3<Double> {
        switch kind {
        case .box:
            let e = dimensions/2
            return SIMD3(direction.x<0 ? -e.x : e.x,direction.y<0 ? -e.y : e.y,direction.z<0 ? -e.z : e.z)
        case .simplex:
            var index = 0, height = convexDot(vertices[0],direction)
            for i in vertices.indices.dropFirst() {
                let d = convexDot(vertices[i],direction)
                if d>height { index = i; height = d }
            }
            return vertices[index]
        case .polygon:
            var height = convexDot(vertices[supportCursor],direction)
            var next = supportCursor<vertices.count-1 ? supportCursor+1 : 0
            var d = convexDot(vertices[next],direction)
            if d>height {
                repeat {
                    height = d; supportCursor = next; next += 1
                    if next==vertices.count { next = 0 }; d = convexDot(vertices[next],direction)
                } while d>height
            } else {
                next = supportCursor>0 ? supportCursor-1 : vertices.count-1
                d = convexDot(vertices[next],direction)
                while d>height {
                    height = d; supportCursor = next; next = next>0 ? next-1 : vertices.count-1
                    d = convexDot(vertices[next],direction)
                }
            }
            return vertices[supportCursor]
        }
    }
}
public struct ConvexContactPoints: Sendable { public let first,second: SIMD3<Double> }
/// Reusable, independently owned original GJK workspace. Determinant caches are
/// retained between queries, while active simplex masks reset each query.
public struct ConvexCollisionQuery: Sendable {
    private var p = [SIMD3<Double>](repeating:.zero,count:4), q = [SIMD3<Double>](repeating:.zero,count:4), y = [SIMD3<Double>](repeating:.zero,count:4)
    private var det = [SIMD4<Double>](repeating:.zero,count:16), dp = [SIMD4<Double>](repeating:.zero,count:4)
    private var bits = 0, last = 0, lastBit = 0, allBits = 0
    public private(set) var iterations = 0
    public init() {}
    private mutating func begin() { bits = 0; allBits = 0; iterations = 0 }
    private mutating func slot() throws {
        iterations += 1
        // Fail explicitly if malformed/extreme input prevents convergence; never
        // substitute an approximate contact for an uncompleted original query.
        guard iterations<=10000 else { throw TrackError.invalid("Convex query did not converge") }
        last = 0; lastBit = 1
        while bits & lastBit != 0 { last += 1; lastBit <<= 1 }
    }
    private func degenerate(_ w: SIMD3<Double>) -> Bool {
        for i in 0..<4 where allBits & (1<<i) != 0 { if y[i]==w { return true } }
        return false
    }
    private mutating func determinants() {
        for i in 0..<4 where bits & (1<<i) != 0 { let v = convexDot(y[i],y[last]); dp[i][last] = v; dp[last][i] = v }
        dp[last][last] = convexDot(y[last],y[last]); det[lastBit][last] = 1
        for j in 0..<4 where bits & (1<<j) != 0 {
            let sj = 1<<j, s2 = sj|lastBit
            det[s2][j] = dp[last][last]-dp[last][j]; det[s2][last] = dp[j][j]-dp[j][last]
            for k in 0..<j where bits & (1<<k) != 0 {
                let sk = 1<<k, s3 = sk|s2
                det[s3][k] = det[s2][j]*(dp[j][j]-dp[j][k])+det[s2][last]*(dp[last][j]-dp[last][k])
                det[s3][j] = det[sk|lastBit][k]*(dp[k][k]-dp[k][j])+det[sk|lastBit][last]*(dp[last][k]-dp[last][j])
                det[s3][last] = det[sk|sj][k]*(dp[k][k]-dp[k][last])+det[sk|sj][j]*(dp[j][k]-dp[j][last])
            }
        }
        if allBits==15 {
            det[15][0] = det[14][1]*(dp[1][1]-dp[1][0])+det[14][2]*(dp[2][1]-dp[2][0])+det[14][3]*(dp[3][1]-dp[3][0])
            det[15][1] = det[13][0]*(dp[0][0]-dp[0][1])+det[13][2]*(dp[2][0]-dp[2][1])+det[13][3]*(dp[3][0]-dp[3][1])
            det[15][2] = det[11][0]*(dp[0][0]-dp[0][2])+det[11][1]*(dp[1][0]-dp[1][2])+det[11][3]*(dp[3][0]-dp[3][2])
            det[15][3] = det[7][0]*(dp[0][0]-dp[0][3])+det[7][1]*(dp[1][0]-dp[1][3])+det[7][2]*(dp[2][0]-dp[2][3])
        }
    }
    private func valid(_ s: Int) -> Bool {
        for i in 0..<4 where allBits & (1<<i) != 0 {
            let bit = 1<<i
            if s & bit != 0 { if det[s][i]<=0 { return false } }
            else if det[s|bit][i]>0 { return false }
        }
        return true
    }
    private func vector() -> SIMD3<Double> {
        var sum: Double = 0, v = SIMD3<Double>.zero
        for i in 0..<4 where bits & (1<<i) != 0 { sum += det[bits][i]; v += y[i]*det[bits][i] }
        return v*(1/sum)
    }
    private func points() -> ConvexContactPoints {
        var sum: Double = 0, a = SIMD3<Double>.zero, b = SIMD3<Double>.zero
        for i in 0..<4 where bits & (1<<i) != 0 { sum += det[bits][i]; a += p[i]*det[bits][i]; b += q[i]*det[bits][i] }
        let s = 1/sum
        // Original closest_points has a zero-simplex NaN case; retain its output
        // classification for callers to handle, rather than inventing a contact.
        return ConvexContactPoints(first:a*s,second:b*s)
    }
    private mutating func closest(_ v: inout SIMD3<Double>) -> Bool {
        determinants()
        if bits>0 {
            for s in stride(from:bits,through:1,by:-1) where s & bits == s {
                if valid(s|lastBit) { bits = s|lastBit; v = vector(); return true }
            }
        }
        if valid(lastBit) { bits = lastBit; v = y[last]; return true }
        // The original build does not define USE_BACKUP_PROCEDURE.
        return false
    }
    public mutating func intersect(_ a: inout ConvexShape,_ b: inout ConvexShape,first: ConvexTransform,second: ConvexTransform,axis: inout SIMD3<Double>) throws -> Bool {
        begin()
        repeat {
            try slot()
            let w = first.point(a.support(first.supportDirection(-axis)))-second.point(b.support(second.supportDirection(axis)))
            if convexDot(axis,w)>0 || degenerate(w) { return false }
            y[last] = w; allBits = bits|lastBit
            if !closest(&axis) { return false }
        } while bits<15 && !(convexDot(axis,axis)<1e-20)
        return true
    }
    public mutating func commonPoint(_ a: inout ConvexShape,_ b: inout ConvexShape,first: ConvexTransform,second: ConvexTransform,axis: inout SIMD3<Double>) throws -> ConvexContactPoints? {
        begin()
        repeat {
            try slot()
            p[last] = a.support(first.supportDirection(-axis)); q[last] = b.support(second.supportDirection(axis))
            let w = first.point(p[last])-second.point(q[last])
            if convexDot(axis,w)>0 || degenerate(w) { return nil }
            y[last] = w; allBits = bits|lastBit
            if !closest(&axis) { return nil }
        } while bits<15 && !(convexDot(axis,axis)<1e-20)
        return points()
    }
    public mutating func intersectRelative(_ a: inout ConvexShape,_ b: inout ConvexShape,secondToFirst: ConvexTransform,axis: inout SIMD3<Double>) throws -> Bool {
        begin()
        repeat {
            try slot()
            let w = a.support(-axis)-secondToFirst.point(b.support(secondToFirst.supportDirection(axis)))
            if convexDot(axis,w)>0 || degenerate(w) { return false }
            y[last] = w; allBits = bits|lastBit
            if !closest(&axis) { return false }
        } while bits<15 && !(convexDot(axis,axis)<1e-20)
        return true
    }
    public mutating func commonPointRelative(_ a: inout ConvexShape,_ b: inout ConvexShape,secondToFirst: ConvexTransform,axis: inout SIMD3<Double>) throws -> ConvexContactPoints? {
        begin()
        repeat {
            try slot()
            p[last] = a.support(-axis); q[last] = b.support(secondToFirst.supportDirection(axis))
            let w = p[last]-secondToFirst.point(q[last])
            if convexDot(axis,w)>0 || degenerate(w) { return nil }
            y[last] = w; allBits = bits|lastBit
            if !closest(&axis) { return nil }
        } while bits<15 && !(convexDot(axis,axis)<1e-20)
        return points()
    }
    /// Original DT_SMART_RESPONSE: intersect at current poses, closest points
    /// at previous poses. The caller advances all previous poses only when the
    /// complete world dispatch reports no collisions.
    public mutating func smartContact(_ a: inout ConvexShape,_ b: inout ConvexShape,
        first: ConvexTransform,second: ConvexTransform,previousFirst: ConvexTransform,previousSecond: ConvexTransform) throws -> ObjectCollisionContact? {
        var axis = SIMD3<Double>.zero
        guard try intersect(&a,&b,first:first,second:second,axis:&axis) else { return nil }
        let p = try closestPoints(&a,&b,first:previousFirst,second:previousSecond)
        return ObjectCollisionContact(firstPoint:p.first,secondPoint:p.second,normal:previousFirst.point(p.first)-previousSecond.point(p.second))
    }
    public mutating func closestPoints(_ a: inout ConvexShape,_ b: inout ConvexShape,first: ConvexTransform,second: ConvexTransform,relativeTolerance: Double = 0.001) throws -> ConvexContactPoints {
        guard relativeTolerance.isFinite, relativeTolerance>=0 else { throw TrackError.invalid("Invalid convex tolerance") }
        var v = first.point(a.support(.zero))-second.point(b.support(.zero)), distance = sqrt(convexDot(v,v))
        var mu: Double = 0
        begin()
        while bits<15 && distance>1e-10 {
            try slot()
            p[last] = a.support(first.supportDirection(-v)); q[last] = b.support(second.supportDirection(v))
            let w = first.point(p[last])-second.point(q[last]), projection = convexDot(v,w)/distance
            if mu<projection { mu = projection }
            if distance-mu<=distance*relativeTolerance || degenerate(w) { break }
            y[last] = w; allBits = bits|lastBit
            if !closest(&v) { break }
            distance = sqrt(convexDot(v,v))
        }
        return points()
    }
}
