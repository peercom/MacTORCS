// SPDX-License-Identifier: GPL-2.0-only
// Original PLIB selector/range-selector HOT and ordered sphere propagation.
// Copyright (C) 1998,2002 Steve Baker. Derived LGPL-2.0-or-later portions converted
// to GPL v2 under LGPL v2 section 3, effective 2026-09-23; originals in Upstream.
import simd
import TORCSAssets

/// Mutable placement/selection over shared immutable height-query resources.
/// Resources are prepared once; transform changes update only ancestor bounds.
public struct SceneHeightAssembly: Sendable {
    public enum Kind: Sendable {
        case branch, transform(simd_float4x4), selector(UInt32), rangeSelector(additive: Bool), asset(Int)
    }
    public struct Node: Sendable {
        public let parent: Int,kind: Kind
        public init(parent: Int,kind: Kind) { self.parent=parent;self.kind=kind }
    }
    private struct Entry: Sendable {
        var parent: Int,kind: Kind,children: [Int]=[],drawsDriver=true
        var sphere=SceneHeightQuery.Sphere()
    }
    private var entries: [Entry]
    private var resources: [SceneHeightQuery]
    public init(nodes: [Node],resources: [SceneHeightQuery]) throws {
        guard !nodes.isEmpty,nodes.count<=100_000 else { throw ACError.invalid("Invalid height-assembly node count") }
        var entries: [Entry]=[],depths: [Int]=[]
        for (i,node) in nodes.enumerated() {
            guard i==0 ? node.parent == -1:node.parent>=0 && node.parent<i else { throw ACError.invalid("Invalid height-assembly parent") }
            if node.parent>=0,case .asset=nodes[node.parent].kind { throw ACError.invalid("Height asset cannot have assembly children") }
            let depth=node.parent<0 ? 1:depths[node.parent]+1
            guard depth<=128 else { throw ACError.invalid("Height assembly exceeds depth limit") }
            if case .transform(let m)=node.kind { try Self.validate(m) }
            if case .asset(let resource)=node.kind {
                guard resources.indices.contains(resource),depth+resources[resource].maximumDepth<=128 else { throw ACError.invalid("Invalid height resource or combined depth") }
            }
            entries.append(Entry(parent:node.parent,kind:node.kind));depths.append(depth)
            if node.parent>=0 { entries[node.parent].children.append(i) }
        }
        for entry in entries { if case .selector=entry.kind,entry.children.count>32 { throw ACError.invalid("Height selector exceeds 32 children") } }
        self.entries=entries;self.resources=resources
        for i in entries.indices.reversed() { self.entries[i].sphere=try computedSphere(i) }
    }
    public func query(x: Float,y: Float) throws -> SceneHeightQuery.Result {
        guard x.isFinite,y.isFinite else { throw ACError.invalid("Nonfinite assembled height coordinate") }
        var matrix=matrix_identity_float4x4;matrix[3].x = -x;matrix[3].y = -y
        var result=SceneHeightQuery.Result();visit(0,matrix,&result);return result
    }
    private func visit(_ id: Int,_ matrix: simd_float4x4,_ result: inout SceneHeightQuery.Result) {
        let node=entries[id]
        // Non-additive range HOT bypasses its own bounds and always visits kid 0.
        if case .rangeSelector(additive:false)=node.kind {
            if let child=node.children.first { visit(child,matrix,&result) };return
        }
        guard SceneHeightQuery.intersects(node.sphere,matrix) else { return }
        switch node.kind {
        case .asset(let resource): resources[resource].accumulate(matrix:matrix,drawsDriver:node.drawsDriver,result:&result)
        case .transform(let transform):
            let local=SceneHeightQuery.multiply(matrix,transform)
            for child in node.children { visit(child,local,&result) }
        case .selector(let mask):
            for (i,child) in node.children.enumerated() where mask & (UInt32(1)<<i) != 0 { visit(child,matrix,&result) }
        default: for child in node.children { visit(child,matrix,&result) }
        }
    }
    public mutating func setTransform(_ transform: simd_float4x4,at id: Int) throws {
        guard entries.indices.contains(id),case .transform=entries[id].kind else { throw ACError.invalid("Invalid height transform handle") }
        try Self.validate(transform)
        let sphere=try computedSphere(id,transform:transform)
        try validateAncestors(changed:id,sphere:sphere)
        entries[id].kind = .transform(transform)
        commitAncestors(changed:id,sphere:sphere)
    }
    public mutating func setSelection(_ mask: UInt32,at id: Int) throws {
        guard entries.indices.contains(id),case .selector=entries[id].kind else { throw ACError.invalid("Invalid height selector handle") }
        entries[id].kind = .selector(mask) // Bounds deliberately still include every child.
    }
    public mutating func setDriverVisible(_ visible: Bool,at id: Int) throws {
        guard entries.indices.contains(id),case .asset=entries[id].kind else { throw ACError.invalid("Invalid height asset handle") }
        entries[id].drawsDriver=visible
    }
    /// For small generated geometry, e.g. projected shadows. Static assets are
    /// not rebuilt. A replacement cannot deepen the graph beyond its initial limit.
    public mutating func replaceResource(_ resource: Int,with query: SceneHeightQuery) throws {
        guard resources.indices.contains(resource),query.maximumDepth<=resources[resource].maximumDepth else { throw ACError.invalid("Invalid replacement height resource") }
        // Replacements are infrequent/small; use value rollback for overlapping
        // references. Per-frame body/wheel transforms use the ancestor-only path.
        var next=self;next.resources[resource]=query
        for i in next.entries.indices.reversed() { next.entries[i].sphere=try next.computedSphere(i) }
        self=next
    }
    private func computedSphere(_ id: Int,transform: simd_float4x4?=nil,changedChild: Int?=nil,changedSphere: SceneHeightQuery.Sphere?=nil) throws -> SceneHeightQuery.Sphere {
        var sphere=SceneHeightQuery.Sphere()
        if case .asset(let resource)=entries[id].kind { sphere=resources[resource].rootSphere }
        else {
            for child in entries[id].children { sphere.extend(child==changedChild ? changedSphere!:entries[child].sphere) }
            let matrix: simd_float4x4?
            if let transform { matrix=transform }
            else if case .transform(let m)=entries[id].kind { matrix=m } else { matrix=nil }
            if let matrix,sphere.radius>=0 { sphere.center=SceneHeightQuery.point(sphere.center,matrix) }
        }
        guard sphere.radius.isFinite,sphere.center.x.isFinite,sphere.center.y.isFinite,sphere.center.z.isFinite else { throw ACError.invalid("Height assembly bounds overflow") }
        return sphere
    }
    private func validateAncestors(changed: Int,sphere: SceneHeightQuery.Sphere) throws {
        var child=changed,current=sphere,parent=entries[changed].parent
        while parent>=0 { current=try computedSphere(parent,changedChild:child,changedSphere:current);child=parent;parent=entries[parent].parent }
    }
    private mutating func commitAncestors(changed: Int,sphere: SceneHeightQuery.Sphere) {
        // Same deterministic calculations were validated before any mutation.
        entries[changed].sphere=sphere
        var parent=entries[changed].parent
        while parent>=0 { entries[parent].sphere=try! computedSphere(parent);parent=entries[parent].parent }
    }
    private static func validate(_ matrix: simd_float4x4) throws {
        guard (0..<4).allSatisfy({ c in (0..<4).allSatisfy { matrix[c][$0].isFinite } }),
              matrix[0].w==0,matrix[1].w==0,matrix[2].w==0,matrix[3].w==1 else { throw ACError.invalid("Height transform must be finite and affine") }
    }
    var referenceSpheres: [SIMD4<Float>] { entries.map { SIMD4($0.sphere.center,$0.sphere.radius) } }
}
