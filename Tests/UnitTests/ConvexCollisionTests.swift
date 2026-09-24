// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSSimulation

private enum ConvexTestContext {
    static func vector(_ p: SIMD3<Double>) -> RefDoubleVector { .init(x:p.x,y:p.y,z:p.z) }
    static func vector(_ p: RefDoubleVector) -> SIMD3<Double> { SIMD3(p.x,p.y,p.z) }
    static func shape(_ s: ConvexShape) -> RefConvexShape { .init(kind:s.kind.rawValue,vertexCount:Int32(s.vertices.count),dimensions:vector(s.dimensions)) }
    static func transform(_ t: ConvexTransform) -> RefConvexTransform {
        .init(rowX:vector(t.rowX),rowY:vector(t.rowY),rowZ:vector(t.rowZ),origin:vector(t.origin))
    }
    static func shapes() throws -> [ConvexShape] {
        [try .init(box:SIMD3(4.8,1.9,1.3)),try .init(box:SIMD3(1,2,3)),
         try .init(vertices:[SIMD3(1,0,0),SIMD3(0,2,0),SIMD3(0,0,3),SIMD3(-1,-1,-1)],polygon:false),
         try .init(vertices:[SIMD3(-2,-1,0),SIMD3(2,-1,0),SIMD3(2,1,0),SIMD3(-2,1,0)],polygon:true),
         try .init(vertices:[SIMD3(-2,0,-1),SIMD3(-2,0,1),SIMD3(2,0,1),SIMD3(2,0,-1)],polygon:true)]
    }
}
private struct ConvexMetrics {
    var fields = 0, classified = 0, cases = 0, hits = 0
    var worst: Double = 0
    mutating func check(_ n: SIMD3<Double>,_ o: RefDoubleVector) {
        let original = ConvexTestContext.vector(o)
        for i in 0..<3 {
            if original[i].isNaN { XCTAssertTrue(n[i].isNaN); classified += 1 }
            else if original[i].isInfinite { XCTAssertEqual(n[i],original[i]); classified += 1 }
            else {
                XCTAssertTrue(n[i].isFinite); XCTAssertEqual(n[i],original[i],accuracy:1e-11+1e-10*abs(original[i]))
                worst = max(worst,abs(n[i]-original[i])); fields += 1
            }
        }
    }
}
final class ConvexCollisionTests: XCTestCase {
    func testSupportMapsAndPolygonTiesAgainstOriginal() throws {
        var metrics = ConvexMetrics()
        let axes: [SIMD3<Double>] = [.zero,SIMD3(1,0,0),SIMD3(-1,0,0),SIMD3(0,1,0),SIMD3(0,-1,0),SIMD3(0,0,1),SIMD3(0,0,-1)]
        let directions = axes+(0..<1000).map { i in SIMD3(cos(Double(i)*0.017),sin(Double(i)*0.019),sin(Double(i)*0.011)) }+axes.reversed()
        for var shape in try ConvexTestContext.shapes() {
            var output = [RefDoubleVector](repeating:.init(),count:directions.count)
            XCTAssertEqual(ref_convex_support(ConvexTestContext.shape(shape),shape.vertices.map(ConvexTestContext.vector),directions.map(ConvexTestContext.vector),Int32(directions.count),&output),1)
            for i in directions.indices { metrics.check(shape.support(directions[i]),output[i]) }
        }
        XCTAssertEqual(metrics.worst,0)
        print("CONVEX_SUPPORT cases=5070 fields=\(metrics.fields) maxAbsolute=\(metrics.worst)")
    }
    func testSmartContactWithIndependentPreviousTransformsAgainstOriginal() throws {
        let shapes = try ConvexTestContext.shapes()
        var metrics = ConvexMetrics(), advances = 0
        for partner in [0,3,4] {
            var a = shapes[0], b = shapes[partner], query = ConvexCollisionQuery()
            let identity = ConvexTransform()
            var previousFirst = identity, previousSecond = ConvexTransform(origin:SIMD3(8,0,0))
            var nativePoses: [(ConvexTransform,ConvexTransform)] = []
            let initial = RefConvexPoses(first:ConvexTestContext.transform(previousFirst),second:ConvexTestContext.transform(previousSecond))
            for tick in 0..<3000 {
                let t = Float(tick)*0.013
                let first = ConvexTransform(CollisionTransform(position:SIMD3(0.2*sin(t),0,0),orientation:SIMD3(0.03*sin(t),0.1*cos(t),0.2*sin(t))))
                let second = ConvexTransform(CollisionTransform(position:SIMD3(4+4*cos(t),0.2*sin(t*0.3),0),orientation:SIMD3(0.02*cos(t),0.05*sin(t),-0.3*sin(t))))
                nativePoses.append((first,second))
            }
            let poses = nativePoses.map { RefConvexPoses(first:ConvexTestContext.transform($0.0),second:ConvexTestContext.transform($0.1)) }
            var original = [RefConvexResult](repeating:.init(),count:poses.count)
            XCTAssertEqual(ref_convex_smart_sequence(ConvexTestContext.shape(a),a.vertices.map(ConvexTestContext.vector),ConvexTestContext.shape(b),b.vertices.map(ConvexTestContext.vector),initial,poses,Int32(poses.count),&original),1)
            for tick in poses.indices {
                let (first,second) = nativePoses[tick], o = original[tick]
                let contact = try query.smartContact(&a,&b,first:first,second:second,previousFirst:previousFirst,previousSecond:previousSecond)
                XCTAssertEqual(contact != nil,o.hit != 0,"partner \(partner) tick \(tick)")
                if let contact {
                    metrics.check(contact.firstPoint,o.firstPoint); metrics.check(contact.secondPoint,o.secondPoint); metrics.check(contact.normal,o.axis); metrics.hits += 1
                } else { previousFirst = first; previousSecond = second; advances += 1 }
                metrics.cases += 1
                if metrics.worst != 0 { XCTFail("First smart contact divergence partner \(partner) tick \(tick)"); return }
            }
        }
        XCTAssertGreaterThan(metrics.hits,0); XCTAssertGreaterThan(advances,0)
        print("CONVEX_SMART cases=\(metrics.cases) fields=\(metrics.fields) classified=\(metrics.classified) hits=\(metrics.hits) advances=\(advances) maxAbsolute=\(metrics.worst)")
    }
    func testTouchingDegenerateAndToleranceBoundariesAgainstOriginal() throws {
        var metrics = ConvexMetrics(), query = ConvexCollisionQuery()
        for size: Double in [0,1e-11,1e-8,2] {
            for gap: Double in [-1e-8,-1e-11,0,1e-11,1e-8,0.2] {
                for tolerance: Double in [0,1e-6,0.001,0.1,1] {
                    for mode: Int32 in 0...4 {
                        var a = try ConvexShape(box:SIMD3(repeating:size)), b = a, axis = SIMD3<Double>.zero
                        let first = ConvexTransform(), second = ConvexTransform(origin:SIMD3(size+gap,0,0))
                        var original = RefConvexResult()
                        XCTAssertEqual(ref_convex_query(ConvexTestContext.shape(a),nil,ConvexTestContext.shape(b),nil,
                            ConvexTestContext.transform(first),ConvexTestContext.transform(second),mode,ConvexTestContext.vector(axis),tolerance,&original),1)
                        var points: ConvexContactPoints?
                        switch mode {
                        case 0: XCTAssertEqual(try query.intersect(&a,&b,first:first,second:second,axis:&axis),original.hit != 0)
                        case 1: points = try query.commonPoint(&a,&b,first:first,second:second,axis:&axis); XCTAssertEqual(points != nil,original.hit != 0)
                        case 2: points = try query.closestPoints(&a,&b,first:first,second:second,relativeTolerance:tolerance)
                        case 3: XCTAssertEqual(try query.intersectRelative(&a,&b,secondToFirst:second,axis:&axis),original.hit != 0)
                        default: points = try query.commonPointRelative(&a,&b,secondToFirst:second,axis:&axis); XCTAssertEqual(points != nil,original.hit != 0)
                        }
                        metrics.check(axis,original.axis)
                        if let points { metrics.check(points.first,original.firstPoint); metrics.check(points.second,original.secondPoint) }
                        metrics.cases += 1; if original.hit != 0 { metrics.hits += 1 }
                        if metrics.worst != 0 { XCTFail("First convex boundary divergence size \(size) gap \(gap) mode \(mode)"); return }
                    }
                }
            }
        }
        XCTAssertGreaterThan(metrics.classified,0)
        print("CONVEX_BOUNDARY cases=\(metrics.cases) fields=\(metrics.fields) classified=\(metrics.classified) hits=\(metrics.hits) maxAbsolute=\(metrics.worst)")
    }
    func testIntersectionCommonAndClosestPointsAgainstOriginal() throws {
        var query = ConvexCollisionQuery(), metrics = ConvexMetrics()
        var modeHits = [Int](repeating:0,count:5), modeMisses = [Int](repeating:0,count:5)
        let shapes = try ConvexTestContext.shapes()
        for i in shapes.indices { for j in shapes.indices {
            for k in 0..<40 {
                let pose = SIMD3<Float>(Float(k%5)*0.08,Float(k%7)*0.07,Float(k)*0.15)
                let first = ConvexTransform(CollisionTransform(position:SIMD3(10,4,2),orientation:pose))
                let base = ConvexTransform(CollisionTransform(position:SIMD3(10+Float(k%8)-3.5,4+Float(k%3)-1,2+Float(k%4)*0.3),orientation:-pose*0.7))
                let second = k%3==0 ? ConvexTransform(rowX:base.rowX*1.1+SIMD3(0,0.03,0),rowY:base.rowY*0.7,rowZ:base.rowZ,origin:base.origin) : base
                for mode: Int32 in 0...4 {
                    var a = shapes[i], b = shapes[j], axis: SIMD3<Double> = k%2==0 ? .zero : SIMD3(0.4,-0.7,0.1)
                    let querySecond = mode>=3 ? ConvexTransform(rowX:second.rowX,rowY:second.rowY,rowZ:second.rowZ,origin:second.origin-first.origin) : second
                    var original = RefConvexResult()
                    XCTAssertEqual(ref_convex_query(ConvexTestContext.shape(a),a.vertices.map(ConvexTestContext.vector),ConvexTestContext.shape(b),b.vertices.map(ConvexTestContext.vector),
                        ConvexTestContext.transform(first),ConvexTestContext.transform(querySecond),mode,ConvexTestContext.vector(axis),0.001,&original),1)
                    switch mode {
                    case 0: XCTAssertEqual(try query.intersect(&a,&b,first:first,second:second,axis:&axis),original.hit != 0)
                    case 1:
                        let points = try query.commonPoint(&a,&b,first:first,second:second,axis:&axis)
                        XCTAssertEqual(points != nil,original.hit != 0)
                        if let points { metrics.check(points.first,original.firstPoint); metrics.check(points.second,original.secondPoint) }
                    case 3: XCTAssertEqual(try query.intersectRelative(&a,&b,secondToFirst:querySecond,axis:&axis),original.hit != 0)
                    case 4:
                        let points = try query.commonPointRelative(&a,&b,secondToFirst:querySecond,axis:&axis)
                        XCTAssertEqual(points != nil,original.hit != 0)
                        if let points { metrics.check(points.first,original.firstPoint); metrics.check(points.second,original.secondPoint) }
                    default:
                        let points = try query.closestPoints(&a,&b,first:first,second:second)
                        metrics.check(points.first,original.firstPoint); metrics.check(points.second,original.secondPoint)
                    }
                    metrics.check(axis,original.axis); metrics.check(a.support(SIMD3(0,0,1)),original.probeFirst); metrics.check(b.support(SIMD3(0,0,1)),original.probeSecond)
                    metrics.cases += 1
                    if original.hit != 0 { metrics.hits += 1; modeHits[Int(mode)] += 1 } else { modeMisses[Int(mode)] += 1 }
                    if metrics.worst != 0 { XCTFail("First convex divergence shapes \(i),\(j) sample \(k) mode \(mode)"); return }
                }
            }
        } }
        for mode in [0,1,3,4] { XCTAssertGreaterThan(modeHits[mode],0); XCTAssertGreaterThan(modeMisses[mode],0) }
        print("CONVEX_QUERIES cases=\(metrics.cases) fields=\(metrics.fields) classified=\(metrics.classified) hits=\(metrics.hits) maxAbsolute=\(metrics.worst)")
    }
}
