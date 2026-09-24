// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSSimulation

private enum ComplexContext {
    static func vector(_ v: SIMD3<Double>) -> RefDoubleVector { .init(x:v.x,y:v.y,z:v.z) }
    static func vector(_ v: RefDoubleVector) -> SIMD3<Double> { SIMD3(v.x,v.y,v.z) }
    static func transform(_ t: ConvexTransform) -> RefConvexTransform { .init(rowX:vector(t.rowX),rowY:vector(t.rowY),rowZ:vector(t.rowZ),origin:vector(t.origin)) }
    static func shape(_ s: ConvexShape) -> RefConvexShape { .init(kind:s.kind.rawValue,vertexCount:Int32(s.vertices.count),dimensions:vector(s.dimensions)) }
    static func affine(mode: Int,t: Double) -> RefAffineInput {
        .init(mode:Int32(mode),matrix:transform(.init(rowX:SIMD3(1.3,0.2,-0.1),rowY:SIMD3(-0.1,0.8,0.03),rowZ:SIMD3(0.04,-0.3,1.1),origin:SIMD3(0.3,-0.4,0.2))),
            translation:vector(SIMD3(7*sin(t),3*cos(t*0.3),0.4*sin(t*0.7))),quaternion:vector(SIMD3(0.1*sin(t),0.2*cos(t),0.3*sin(t*0.5))),
            scale:vector(SIMD3(1.2+0.1*sin(t),-0.7,1.5)),quaternionW:0.9)
    }
    static func native(_ a: RefAffineInput) throws -> ConvexTransform {
        var t = a.mode & 8 != 0 ? ConvexTransform(rowX:vector(a.matrix.rowX),rowY:vector(a.matrix.rowY),rowZ:vector(a.matrix.rowZ),origin:vector(a.matrix.origin)) : ConvexTransform()
        if a.mode & 1 != 0 { t = t.translated(vector(a.translation)) }
        if a.mode & 2 != 0 { t = try t.rotated(quaternion:SIMD4(a.quaternion.x,a.quaternion.y,a.quaternion.z,a.quaternionW)) }
        if a.mode & 4 != 0 { t = t.scaled(vector(a.scale)) }
        return t
    }
    static func wall(x: Double,y: Double = 0,halfLength: Double = 3) throws -> ConvexShape {
        try .init(vertices:[SIMD3(x,y-halfLength,-1),SIMD3(x,y+halfLength,-1),SIMD3(x,y+halfLength,2),SIMD3(x,y-halfLength,2)],polygon:true)
    }
}
private struct ComplexMetrics {
    var fields = 0, classified = 0, hits = 0, misses = 0, worst: Double = 0
    mutating func check(_ a: SIMD3<Double>,_ b: RefDoubleVector,file: StaticString = #filePath,line: UInt = #line) {
        let b = ComplexContext.vector(b)
        for i in 0..<3 {
            if b[i].isNaN { XCTAssertTrue(a[i].isNaN,file:file,line:line); classified += 1 }
            else if b[i].isInfinite { XCTAssertEqual(a[i],b[i],file:file,line:line); classified += 1 }
            else { XCTAssertTrue(a[i].isFinite,file:file,line:line); XCTAssertEqual(a[i],b[i],accuracy:1e-11+1e-10*abs(b[i]),file:file,line:line); fields += 1; worst = max(worst,abs(a[i]-b[i])) }
        }
    }
    mutating func check(_ a: ConvexTransform,_ b: RefConvexTransform) {
        check(a.rowX,b.rowX); check(a.rowY,b.rowY); check(a.rowZ,b.rowZ); check(a.origin,b.origin)
    }
}
final class ComplexCollisionTests: XCTestCase {
    func testAffineOperationsAndTypeBranchesAgainstOriginal() throws {
        var metrics = ComplexMetrics()
        for mode in 0..<16 { for i in 0..<100 {
            let a = ComplexContext.affine(mode:mode,t:Double(i)*0.031), b = ComplexContext.affine(mode:(mode+i)%16,t:Double(i)*0.039)
            var out = [RefConvexTransform](repeating:.init(),count:5)
            XCTAssertEqual(ref_affine_query(a,b,&out),1)
            let na = try ComplexContext.native(a), nb = try ComplexContext.native(b)
            let values = try [na,nb,na.inverted(),na.composed(with:nb),nb.relative(to:na)]
            for j in values.indices { metrics.check(values[j],out[j]) }
            if metrics.worst != 0 { XCTFail("Affine arithmetic diverged: mode \(mode) input \(i) error \(metrics.worst)"); return }
        } }
        XCTAssertThrowsError(try ConvexTransform().scaled(SIMD3(0,1,1)).inverted())
        XCTAssertThrowsError(try ConvexTransform().rotated(quaternion:.zero))
        print("COLLISION_AFFINE cases=1600 fields=\(metrics.fields) maxAbsolute=\(metrics.worst)")
    }
    func testComplexPrimitiveSelectionAndBoundsAgainstOriginal() throws { try run(mode:0) }
    func testComplexPreviousPoseContactsAgainstOriginal() throws { try run(mode:1) }
    private func run(mode: Int) throws {
        let coincident = try (0..<9).map { _ in try ComplexContext.wall(x:0) }
        let grid = try (0..<31).map { try ComplexContext.wall(x:Double($0%7)-3,y:Double($0/7)-2,halfLength:1.4) }
        let fixtures = [[try ComplexContext.wall(x:0)],coincident,grid]
        var metrics = ComplexMetrics(), cases = 0, selected = Set<Int>()
        for (fixture,polygons) in fixtures.enumerated() { for firstMode in [0,3,15] { for partner in 0..<2 {
            let first = ComplexContext.affine(mode:firstMode,t:0.37), initial = ComplexContext.affine(mode:3,t:1.3)
            let poses = (0..<500).map { ComplexContext.affine(mode:3,t:Double($0)*0.031) }
            var other = partner==0 ? try ConvexShape(box:SIMD3(2.4,1.9,1.3)) : try ConvexShape(vertices:[SIMD3(-2,-1,0),SIMD3(2,-1,0),SIMD3(2,1,0),SIMD3(-2,1,0)],polygon:true)
            var original = [RefComplexResult](repeating:.init(),count:poses.count)
            XCTAssertEqual(ref_complex_sequence(polygons.map(ComplexContext.shape),polygons.flatMap(\.vertices).map(ComplexContext.vector),Int32(polygons.count),ComplexContext.shape(other),other.vertices.map(ComplexContext.vector),first,initial,poses,Int32(poses.count),Int32(mode),&original),1)
            var shape = try ComplexCollisionShape(primitives:polygons), query = ConvexCollisionQuery(), previous = try ComplexContext.native(initial)
            let firstNative = try ComplexContext.native(first)
            for i in poses.indices {
                let current = try ComplexContext.native(poses[i]), o = original[i]
                if mode==0 {
                    var axis = SIMD3<Double>.zero
                    let p = try shape.findPrimitive(intersecting:&other,first:firstNative,second:current,axis:&axis,query:&query)
                    XCTAssertEqual(p.map(Int32.init) ?? -1,o.primitive,"fixture \(fixture) firstMode \(firstMode) partner \(partner) tick \(i)")
                    metrics.check(axis,o.contact.axis)
                    if let p { selected.insert(p) }
                } else {
                    let contact = try shape.smartContact(with:&other,first:firstNative,second:current,previousFirst:firstNative,previousSecond:previous,query:&query)
                    XCTAssertEqual(contact != nil,o.contact.hit != 0)
                    if let contact { metrics.check(contact.firstPoint,o.contact.firstPoint); metrics.check(contact.secondPoint,o.contact.secondPoint); metrics.check(contact.normal,o.contact.axis) }
                    else { previous = current }
                }
                let bounds = shape.bounds(at:firstNative)
                metrics.check(bounds.center,o.center); metrics.check(bounds.extent,o.extent)
                metrics.check(other.support(SIMD3(0,0,1)),o.contact.probeSecond)
                if o.contact.hit != 0 { metrics.hits += 1 } else { metrics.misses += 1 }
                cases += 1
                if metrics.worst != 0 { XCTFail("Complex arithmetic diverged fixture \(fixture) mode \(mode) firstMode \(firstMode) tick \(i) error \(metrics.worst)"); return }
            }
        } } }
        XCTAssertGreaterThan(metrics.hits,0); XCTAssertGreaterThan(metrics.misses,0)
        if mode==0 { XCTAssertGreaterThan(selected.count,10) }
        print("COLLISION_COMPLEX mode=\(mode) cases=\(cases) fields=\(metrics.fields) classified=\(metrics.classified) hits=\(metrics.hits) misses=\(metrics.misses) selected=\(selected.count) maxAbsolute=\(metrics.worst)")
    }
}

extension ComplexCollisionTests {
    func testComplexPairPrimitiveSelectionAgainstOriginal() throws { try runPairs(mode:0) }
    func testComplexPairPreviousPoseContactsAgainstOriginal() throws { try runPairs(mode:1) }
    private func runPairs(mode: Int) throws {
        let grid = try (0..<7).map { try ComplexContext.wall(x:Double($0%3)-1,y:Double($0/3)-1) }
        let triangles: [ConvexShape] = try (0..<19).map { i in
            let x = Double(i%5), y = Double(i/5)
            return try ConvexShape(vertices:[SIMD3(x-2,y-2,-0.3),SIMD3(x,y-2,0.4),SIMD3(x,y,0.7)],polygon:i%2==0)
        }
        let fixtures: [[ConvexShape]] = [[try ComplexContext.wall(x:0)],grid,triangles]
        var metrics = ComplexMetrics(), cases = 0, selected = Set<String>()
        for (ai,ap) in fixtures.enumerated() { for (bi,bp) in fixtures.enumerated() { for firstMode in [0,3,15] {
            let first = ComplexContext.affine(mode:firstMode,t:0.17), initial = ComplexContext.affine(mode:3,t:1.8)
            let poses = (0..<400).map { ComplexContext.affine(mode:$0%3==0 ? 15 : 3,t:Double($0)*0.037) }
            var original = [RefComplexPairResult](repeating:.init(),count:poses.count)
            XCTAssertEqual(ref_complex_pair_sequence(ap.map(ComplexContext.shape),ap.flatMap(\.vertices).map(ComplexContext.vector),Int32(ap.count),
                bp.map(ComplexContext.shape),bp.flatMap(\.vertices).map(ComplexContext.vector),Int32(bp.count),first,initial,poses,Int32(poses.count),Int32(mode),&original),1)
            var a = try ComplexCollisionShape(primitives:ap), b = try ComplexCollisionShape(primitives:bp), query = ConvexCollisionQuery()
            let an = try ComplexContext.native(first)
            var previous = try ComplexContext.native(initial)
            for i in poses.indices {
                let bn = try ComplexContext.native(poses[i]), o = original[i]
                if mode==0 {
                    var axis = SIMD3<Double>.zero
                    let pair = try a.findPrimitives(intersecting:&b,first:an,second:bn,axis:&axis,query:&query)
                    XCTAssertEqual(pair.map { Int32($0.first) } ?? -1,o.firstPrimitive,"fixture \(ai)/\(bi) transform \(firstMode) tick \(i)")
                    XCTAssertEqual(pair.map { Int32($0.second) } ?? -1,o.secondPrimitive)
                    metrics.check(axis,o.contact.axis)
                    if let pair { selected.insert("\(ai)/\(bi)/\(pair.first)/\(pair.second)") }
                } else {
                    let contact = try a.smartContact(with:&b,first:an,second:bn,previousFirst:an,previousSecond:previous,query:&query)
                    XCTAssertEqual(contact != nil,o.contact.hit != 0)
                    if let contact { metrics.check(contact.firstPoint,o.contact.firstPoint); metrics.check(contact.secondPoint,o.contact.secondPoint); metrics.check(contact.normal,o.contact.axis) }
                    else { previous = bn }
                }
                if o.contact.hit != 0 { metrics.hits += 1 } else { metrics.misses += 1 }
                cases += 1
                if metrics.worst != 0 { XCTFail("Complex pair arithmetic diverged: \(metrics.worst)"); return }
            }
        } } }
        XCTAssertGreaterThan(metrics.hits,500); XCTAssertGreaterThan(metrics.misses,500)
        if mode==0 { XCTAssertGreaterThan(selected.count,100) }
        print("COLLISION_COMPLEX_PAIR mode=\(mode) cases=\(cases) fields=\(metrics.fields) classified=\(metrics.classified) hits=\(metrics.hits) misses=\(metrics.misses) selected=\(selected.count) maxAbsolute=\(metrics.worst)")
    }
}
