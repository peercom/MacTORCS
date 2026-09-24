// SPDX-License-Identifier: GPL-2.0-only
// Scene anchors and car ordering follow TORCS grscene/grscreen/grcam,
// Copyright (C) 2000-2013 Eric Espie and contributors; original notices in Upstream.
import Darwin
import simd
import TORCSAssets

/// Original grInitScene child order. Shadows and carLights use dedicated setters.
public enum SceneAnchor:Int,CaseIterable,Sendable {
    case land,pits,skids,shadows,carLights,cars,smoke,sun
}
public struct SceneCarPlacement:Sendable,Equatable {
    public let index:Int
    public let position:SIMD3<Float>
    public init(index:Int,position:SIMD3<Float>) { self.index=index;self.position=position }
}
/// Optional diagnostics record actual mesh/effect submissions, excluding sky
/// and mirror compositing. Instance indices refer to the published scene.
public enum SceneDrawCommand:Sendable,Equatable {
    case mesh(instance:Int,batch:Int),shadow(car:Int),light(car:Int),vegetation(instance:Int,trees:Int)
}

/// The original screen keeps its car pointer array between view updates. Its
/// comparator returns +1 even for equal distances. Use this host's libc sorting
/// behavior, checked against original qsort; do not pass that invalid strict
/// comparator to Swift.sort or claim portable tie ordering across libc versions.
struct SceneDrawOrder {
    private var order:[Int]=[]
    private var placements:[Int:SceneCarPlacement]=[:]
    private var instances:[SceneInstance]=[]
    private struct Plan { let eye:SIMD2<Float>;let indices:[Int] }
    private var plans:[Bool:Plan]=[:]
    mutating func publish(_ values:[SceneInstance]) throws {
        var next:[Int:SceneCarPlacement]=[:],added:[Int]=[]
        for instance in values {
            guard instance.anchor != .shadows,instance.anchor != .carLights else { throw ACError.invalid("Use dedicated shadow/light submission") }
            if let car=instance.car {
                guard instance.anchor == .cars,(0..<1024).contains(car.index),[car.position.x,car.position.y,car.position.z].allSatisfy(\.isFinite),
                      next[car.index].map({ $0==car }) ?? true else { throw ACError.invalid("Inconsistent car draw placement") }
                if next[car.index]==nil { added.append(car.index) };next[car.index]=car
            }
        }
        let retained=order.filter { next[$0] != nil },known=Set(retained)
        order=retained+added.filter { !known.contains($0) }
        placements=next;instances=values;plans.removeAll(keepingCapacity:true)
    }
    mutating func prepare(eye:SIMD3<Float>,mirror:Bool) throws -> [Int] {
        let xy=SIMD2(eye.x,eye.y)
        guard xy.x.isFinite,xy.y.isFinite else { throw ACError.invalid("Invalid car ordering camera") }
        if let plan=plans[mirror],plan.eye==xy { return plan.indices }
        var distances:[Int:Float]=[:]
        for (id,car) in placements {
            let dx=car.position.x-xy.x,dy=car.position.y-xy.y
            let d=dx*dx+dy*dy
            guard d.isFinite else { throw ACError.invalid("Car draw distance overflow") }
            distances[id]=d
        }
        var next=order
        let keys=distances
        next.withUnsafeMutableBufferPointer { buffer in
            guard let base=buffer.baseAddress,buffer.count>1 else { return }
            qsort_b(base,buffer.count,MemoryLayout<Int>.stride) { a,b in
                keys[a!.assumingMemoryBound(to:Int.self).pointee]! > keys[b!.assumingMemoryBound(to:Int.self).pointee]! ? -1:1
            }
        }
        var result:[Int]=[]
        for anchor in SceneAnchor.allCases {
            if anchor == .cars {
                result += instances.indices.filter { instances[$0].anchor == anchor && instances[$0].car==nil }
                for id in next { result += instances.indices.filter { instances[$0].car?.index==id } }
            } else { result += instances.indices.filter { instances[$0].anchor==anchor } }
        }
        order=next;plans[mirror]=Plan(eye:xy,indices:result);return result
    }
}
