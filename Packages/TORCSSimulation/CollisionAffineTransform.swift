// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of SOLID Transform.cpp and 3D Matrix.h, TORCS 1.3.9.
// Copyright (C) 1996-1998 Gino van den Bergen. Derived portions converted from
// LGPL v2-or-later to GPL v2 under LGPL v2 section 3, effective 2026-09-23.
// Original imported notices are unchanged; see Upstream/Licenses/SOLID-LGPL-2.0.txt.
import TORCSTrack

extension ConvexTransform {
    init(_ x: SIMD3<Double>,_ y: SIMD3<Double>,_ z: SIMD3<Double>,origin: SIMD3<Double>,type: Int) {
        rowX = x; rowY = y; rowZ = z; self.origin = origin; self.type = type
    }
    func vector(_ v: SIMD3<Double>) -> SIMD3<Double> { SIMD3(convexDot(rowX,v),convexDot(rowY,v),convexDot(rowZ,v)) }
    var transposedBasis: ConvexTransform {
        .init(SIMD3(rowX.x,rowY.x,rowZ.x),SIMD3(rowX.y,rowY.y,rowZ.y),SIMD3(rowX.z,rowY.z,rowZ.z),origin:.zero,type:type)
    }
    func multipliedBasis(_ b: ConvexTransform,origin: SIMD3<Double>,type: Int) -> ConvexTransform {
        // Matrix multiplication multiplies left-row terms first, unlike v*basis.
        let c = b.transposedBasis
        return .init(SIMD3(convexDot(rowX,c.rowX),convexDot(rowX,c.rowY),convexDot(rowX,c.rowZ)),
            SIMD3(convexDot(rowY,c.rowX),convexDot(rowY,c.rowY),convexDot(rowY,c.rowZ)),
            SIMD3(convexDot(rowZ,c.rowX),convexDot(rowZ,c.rowY),convexDot(rowZ,c.rowZ)),origin:origin,type:type)
    }
    func inverseBasis() throws -> ConvexTransform {
        if type & 4 == 0 { return transposedBasis }
        let co = SIMD3(rowY.y*rowZ.z-rowY.z*rowZ.y,rowY.z*rowZ.x-rowY.x*rowZ.z,rowY.x*rowZ.y-rowY.y*rowZ.x)
        let d = convexDot(rowX,co)
        guard d.isFinite,abs(d)>1e-10 else { throw TrackError.invalid("Singular collision transform") }
        let s = 1/d
        return .init(SIMD3(co.x*s,(rowX.z*rowZ.y-rowX.y*rowZ.z)*s,(rowX.y*rowY.z-rowX.z*rowY.y)*s),
            SIMD3(co.y*s,(rowX.x*rowZ.z-rowX.z*rowZ.x)*s,(rowX.z*rowY.x-rowX.x*rowY.z)*s),
            SIMD3(co.z*s,(rowX.y*rowZ.x-rowX.x*rowZ.y)*s,(rowX.x*rowY.y-rowX.y*rowY.x)*s),origin:.zero,type:type)
    }
    public func inverted() throws -> ConvexTransform {
        let b = try inverseBasis()
        return .init(b.rowX,b.rowY,b.rowZ,origin:-b.vector(origin),type:type)
    }
    public func composed(with b: ConvexTransform) -> ConvexTransform {
        multipliedBasis(b,origin:point(b.origin),type:type|b.type)
    }
    /// Equivalent to original multInverseLeft(first, self), preserving its
    /// subtraction-before-inversion order and type-dependent inverse branch.
    public func relative(to first: ConvexTransform) throws -> ConvexTransform {
        let b = try first.inverseBasis(), v = origin-first.origin
        return b.multipliedBasis(self,origin:first.type & 4 != 0 ? b.vector(v) : first.supportDirection(v),type:first.type|type)
    }
    public func translated(_ v: SIMD3<Double>) -> ConvexTransform {
        .init(rowX,rowY,rowZ,origin:origin+vector(v),type:type|1)
    }
    public func scaled(_ v: SIMD3<Double>) -> ConvexTransform {
        let b = ConvexTransform(SIMD3(v.x,0,0),SIMD3(0,v.y,0),SIMD3(0,0,v.z),origin:.zero,type:4)
        return multipliedBasis(b,origin:origin,type:type|4)
    }
    public func rotated(quaternion q: SIMD4<Double>) throws -> ConvexTransform {
        let d = q.x*q.x+q.y*q.y+q.z*q.z+q.w*q.w
        guard d.isFinite,d>1e-10 else { throw TrackError.invalid("Invalid collision quaternion") }
        let s = 2/d, xs = q.x*s, ys = q.y*s, zs = q.z*s
        let wx = q.w*xs, wy = q.w*ys, wz = q.w*zs, xx = q.x*xs, xy = q.x*ys, xz = q.x*zs, yy = q.y*ys, yz = q.y*zs, zz = q.z*zs
        let b = ConvexTransform(SIMD3(1-(yy+zz),xy-wz,xz+wy),SIMD3(xy+wz,1-(xx+zz),yz-wx),SIMD3(xz-wy,yz+wx,1-(xx+yy)),origin:.zero,type:2)
        return multipliedBasis(b,origin:origin,type:type|2)
    }
}
