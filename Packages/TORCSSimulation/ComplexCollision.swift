// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of SOLID BBox.h, BBoxTree.cpp, Complex.cpp and Object.cpp.
// Copyright (C) 1997-1998 Gino van den Bergen. Derived portions converted from
// LGPL v2-or-later to GPL v2 under LGPL v2 section 3, effective 2026-09-23.
// Original imported notices are unchanged; see Upstream/Licenses/SOLID-LGPL-2.0.txt.
import TORCSTrack

public struct CollisionBounds: Sendable {
    public private(set) var center: SIMD3<Double> = .zero
    public private(set) var extent = SIMD3<Double>(repeating:-1e50)
    public init() {}
    init(lower: SIMD3<Double>,upper: SIMD3<Double>) { extent = (upper-lower)/2; center = lower+extent }
    mutating func include(lower: SIMD3<Double>,upper: SIMD3<Double>) {
        let a = center-extent, b = center+extent
        self = .init(lower:SIMD3(min(a.x,lower.x),min(a.y,lower.y),min(a.z,lower.z)),upper:SIMD3(max(b.x,upper.x),max(b.y,upper.y),max(b.z,upper.z)))
    }
    mutating func include(_ p: SIMD3<Double>) { include(lower:p,upper:p) }
    mutating func include(_ b: CollisionBounds) { include(lower:b.center-b.extent,upper:b.center+b.extent) }
    var longestAxis: Int { let i = abs(extent.x)<abs(extent.y) ? 1 : 0; return abs(extent[i])<abs(extent.z) ? 2 : i }
    func intersects(_ b: CollisionBounds) -> Bool {
        abs(center.x-b.center.x)<=extent.x+b.extent.x && abs(center.y-b.center.y)<=extent.y+b.extent.y && abs(center.z-b.center.z)<=extent.z+b.extent.z
    }
    func transformed(_ t: ConvexTransform) -> CollisionBounds {
        var b = self; b.center = t.point(center)
        func magnitude(_ v: SIMD3<Double>) -> SIMD3<Double> { SIMD3(abs(v.x),abs(v.y),abs(v.z)) }
        b.extent = SIMD3(convexDot(magnitude(t.rowX),extent),convexDot(magnitude(t.rowY),extent),convexDot(magnitude(t.rowZ),extent))
        return b
    }
}
extension ConvexShape {
    public mutating func bounds(at t: ConvexTransform) -> CollisionBounds {
        let lower = SIMD3(t.origin.x+convexDot(t.rowX,support(-t.rowX))-1e-10,
            t.origin.y+convexDot(t.rowY,support(-t.rowY))-1e-10,t.origin.z+convexDot(t.rowZ,support(-t.rowZ))-1e-10)
        let upper = SIMD3(t.origin.x+convexDot(t.rowX,support(t.rowX))+1e-10,
            t.origin.y+convexDot(t.rowY,support(t.rowY))+1e-10,t.origin.z+convexDot(t.rowZ,support(t.rowZ))+1e-10)
        return .init(lower:lower,upper:upper)
    }
}
/// Original binary hierarchy over polygon/simplex leaves. Primitive identifiers
/// retain input order even though tree construction partitions leaf storage.
public struct ComplexCollisionShape: Sendable {
    private struct Node: Sendable { var bounds: CollisionBounds; var primitive = -1, left = -1, right = -1 }
    private var nodes: [Node] = []
    public private(set) var primitives: [ConvexShape]
    public init(primitives: [ConvexShape]) throws {
        guard !primitives.isEmpty,primitives.count<=65536,primitives.allSatisfy({ $0.kind != .box }) else { throw TrackError.invalid("Complex collision requires polygon/simplex leaves") }
        self.primitives = primitives
        var leaves = primitives.indices.map { i in
            var b = CollisionBounds(); for p in primitives[i].vertices { b.include(p) }
            return Node(bounds:b,primitive:i)
        }
        _ = build(&leaves,range:leaves.indices)
    }
    private mutating func build(_ leaves: inout [Node],range: Range<Int>) -> Int {
        let index = nodes.count
        if range.count==1 { nodes.append(leaves[range.lowerBound]); return index }
        var bounds = CollisionBounds()
        for i in range { bounds.include(leaves[i].bounds) }
        nodes.append(Node(bounds:bounds))
        let axis = bounds.longestAxis
        var i = range.lowerBound, mid = range.upperBound
        while i<mid {
            if leaves[i].bounds.center[axis]<bounds.center[axis] { i += 1 }
            else { mid -= 1; leaves.swapAt(i,mid) }
        }
        if mid==range.lowerBound || mid==range.upperBound { mid = range.lowerBound+range.count/2 }
        // Original constructs the lower partition as rson, then traverses lson first.
        let right = build(&leaves,range:range.lowerBound..<mid)
        let left = build(&leaves,range:mid..<range.upperBound)
        nodes[index].right = right; nodes[index].left = left
        return index
    }
    public func bounds(at transform: ConvexTransform) -> CollisionBounds { nodes[0].bounds.transformed(transform) }
    public mutating func findPrimitive(intersecting other: inout ConvexShape,first: ConvexTransform,second: ConvexTransform,axis: inout SIMD3<Double>,query: inout ConvexCollisionQuery) throws -> Int? {
        let relative = try second.relative(to:first), box = other.bounds(at:relative)
        return try find(node:0,other:&other,box:box,relative:relative,axis:&axis,query:&query)
    }
    private mutating func find(node: Int,other: inout ConvexShape,box: CollisionBounds,relative: ConvexTransform,axis: inout SIMD3<Double>,query: inout ConvexCollisionQuery) throws -> Int? {
        let n = nodes[node]
        guard n.bounds.intersects(box) else { return nil }
        if n.primitive>=0 {
            return try query.intersectRelative(&primitives[n.primitive],&other,secondToFirst:relative,axis:&axis) ? n.primitive : nil
        }
        if let p = try find(node:n.left,other:&other,box:box,relative:relative,axis:&axis,query:&query) { return p }
        return try find(node:n.right,other:&other,box:box,relative:relative,axis:&axis,query:&query)
    }
    /// SMART contact for a static vertex base. Moving/deforming mesh vertex
    /// bases require separate previous-vertex ownership and are not accepted here.
    public mutating func smartContact(with other: inout ConvexShape,first: ConvexTransform,second: ConvexTransform,
        previousFirst: ConvexTransform,previousSecond: ConvexTransform,query: inout ConvexCollisionQuery) throws -> ObjectCollisionContact? {
        var axis = SIMD3<Double>.zero
        guard let index = try findPrimitive(intersecting:&other,first:first,second:second,axis:&axis,query:&query) else { return nil }
        let points = try query.closestPoints(&primitives[index],&other,first:previousFirst,second:previousSecond)
        return ObjectCollisionContact(firstPoint:points.first,secondPoint:points.second,normal:previousFirst.point(points.first)-previousSecond.point(points.second))
    }
}

extension ComplexCollisionShape {
    public mutating func findPrimitives(intersecting other: inout ComplexCollisionShape,first: ConvexTransform,second: ConvexTransform,
        axis: inout SIMD3<Double>,query: inout ConvexCollisionQuery) throws -> (first: Int,second: Int)? {
        let b2a = try second.relative(to:first), a2b = try b2a.inverted()
        func absolute(_ t: ConvexTransform) -> ConvexTransform {
            func row(_ r: SIMD3<Double>) -> SIMD3<Double> { SIMD3(abs(r.x),abs(r.y),abs(r.z)) }
            return .init(rowX:row(t.rowX),rowY:row(t.rowY),rowZ:row(t.rowZ))
        }
        return try findPair(node:0,other:&other,otherNode:0,b2a:b2a,a2b:a2b,absB2A:absolute(b2a),absA2B:absolute(a2b),axis:&axis,query:&query)
    }
    private mutating func findPair(node: Int,other: inout ComplexCollisionShape,otherNode: Int,
        b2a: ConvexTransform,a2b: ConvexTransform,absB2A: ConvexTransform,absA2B: ConvexTransform,
        axis: inout SIMD3<Double>,query: inout ConvexCollisionQuery) throws -> (first: Int,second: Int)? {
        let a = nodes[node], b = other.nodes[otherNode]
        let pa = b2a.point(b.bounds.center)-a.bounds.center, pb = a2b.point(a.bounds.center)-b.bounds.center
        let ae = a.bounds.extent, be = b.bounds.extent
        // Preserve SOLID's six bounding-axis rejection tests, not a replacement
        // OBB test with nine extra cross-product axes or expanded tolerances.
        if ae.x+convexDot(absB2A.rowX,be)<abs(pa.x) || ae.y+convexDot(absB2A.rowY,be)<abs(pa.y) || ae.z+convexDot(absB2A.rowZ,be)<abs(pa.z) { return nil }
        if be.x+convexDot(absA2B.rowX,ae)<abs(pb.x) || be.y+convexDot(absA2B.rowY,ae)<abs(pb.y) || be.z+convexDot(absA2B.rowZ,ae)<abs(pb.z) { return nil }
        if a.primitive>=0 && b.primitive>=0 {
            return try query.intersectRelative(&primitives[a.primitive],&other.primitives[b.primitive],secondToFirst:b2a,axis:&axis) ? (a.primitive,b.primitive) : nil
        }
        if a.primitive>=0 || (b.primitive<0 && max(max(ae.x,ae.y),ae.z)<max(max(be.x,be.y),be.z)) {
            if let p = try findPair(node:node,other:&other,otherNode:b.left,b2a:b2a,a2b:a2b,absB2A:absB2A,absA2B:absA2B,axis:&axis,query:&query) { return p }
            return try findPair(node:node,other:&other,otherNode:b.right,b2a:b2a,a2b:a2b,absB2A:absB2A,absA2B:absA2B,axis:&axis,query:&query)
        }
        if let p = try findPair(node:a.left,other:&other,otherNode:otherNode,b2a:b2a,a2b:a2b,absB2A:absB2A,absA2B:absA2B,axis:&axis,query:&query) { return p }
        return try findPair(node:a.right,other:&other,otherNode:otherNode,b2a:b2a,a2b:a2b,absB2A:absB2A,absA2B:absA2B,axis:&axis,query:&query)
    }
    public mutating func smartContact(with other: inout ComplexCollisionShape,first: ConvexTransform,second: ConvexTransform,
        previousFirst: ConvexTransform,previousSecond: ConvexTransform,query: inout ConvexCollisionQuery) throws -> ObjectCollisionContact? {
        var axis = SIMD3<Double>.zero
        guard let p = try findPrimitives(intersecting:&other,first:first,second:second,axis:&axis,query:&query) else { return nil }
        let points = try query.closestPoints(&primitives[p.first],&other.primitives[p.second],first:previousFirst,second:previousSecond)
        return ObjectCollisionContact(firstPoint:points.first,secondPoint:points.second,normal:previousFirst.point(points.first)-previousSecond.point(points.second))
    }
}
