// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSSimulation
import TORCSTrack
import TORCSReferenceSupport

enum RemovalContext {
    static func vector(_ v: SIMD3<Float>) -> RefTrackVector { .init(x:v.x,y:v.y,z:v.z) }
    static func body(_ b: ChassisDynamics) -> RefChassisDynamics { .init(position:vector(b.position),orientation:vector(b.orientation),velocity:vector(b.velocity),angularVelocity:vector(b.angularVelocity),acceleration:vector(b.acceleration),angularAcceleration:vector(b.angularAcceleration)) }
    static func matrix(_ t: CollisionTransform) -> [Float] {
        let a=t.rotation.toWorld(SIMD3(1,0,0)),b=t.rotation.toWorld(SIMD3(0,1,0)),c=t.rotation.toWorld(SIMD3(0,0,1)),p=t.position
        return [a.x,a.y,a.z,0,b.x,b.y,b.z,0,c.x,c.y,c.z,0,p.x,p.y,p.z,1]
    }
    static func input(_ s: VehicleRemovalState,dt: Float) -> RefRemovalState {
        var r=RefRemovalState(); r.publicBody=body(s.publicBody); r.mechanicalBody=body(s.mechanicalBody); r.parking=body(s.parking)
        let p=s.trackPosition; r.trackPosition = .init(segment:Int32(p.segment),mode:Int32(p.mode.rawValue),toStart:p.toStart,toRight:p.toRight,toMiddle:p.toMiddle,toLeft:p.toLeft)
        r.flags=s.flags; r.collision=s.collision; r.publishedCollision=s.publishedCollision; r.publishedSimCollision=s.publishedSimCollision
        r.damage=s.damage; r.maximumDamage=s.maximumDamage; r.gear=s.gear; r.publishedGear=s.publishedGear; r.registered=s.collisionRegistered ? 1:0
        r.hasPit=s.pitOccupant == nil ? 0:1; r.pitOccupant=s.pitOccupant ?? 0; r.cgHeight=s.cgHeight; r.engineRPM=s.engineRPM; r.publishedRPM=s.publishedRPM; r.dt=dt
        withUnsafeMutableBytes(of:&r.matrix) { bytes in for (i,x) in matrix(s.publicTransform).enumerated() { bytes.bindMemory(to:Float.self)[i]=x } }
        withUnsafeMutableBytes(of:&r.skid) { bytes in for i in 0..<4 { bytes.bindMemory(to:Float.self)[i]=s.publishedSkid[i] } }
        withUnsafeMutableBytes(of:&r.spin) { bytes in for i in 0..<4 { bytes.bindMemory(to:Float.self)[i]=s.publishedSpin[i] } }
        withUnsafeMutableBytes(of:&r.brakeTemperature) { bytes in for i in 0..<4 { bytes.bindMemory(to:Float.self)[i]=s.publishedBrakeTemperature[i] } }
        return r
    }
    static func scalars(_ r: RefRemovalState) -> [Double] {
        var result: [Double]=[]
        for b in [r.publicBody,r.mechanicalBody,r.parking] {
            for v in [b.position,b.orientation,b.velocity,b.angularVelocity,b.acceleration,b.angularAcceleration] { result += [Double(v.x),Double(v.y),Double(v.z)] }
        }
        result += [Double(r.flags),Double(r.collision),Double(r.publishedCollision),Double(r.publishedSimCollision),Double(r.gear),Double(r.publishedGear),Double(r.registered),Double(r.hasPit),Double(r.pitOccupant),Double(r.engineRPM),Double(r.publishedRPM)]
        for values in [withUnsafeBytes(of:r.matrix,{ Array($0.bindMemory(to:Float.self)) }),withUnsafeBytes(of:r.skid,{ Array($0.bindMemory(to:Float.self)) }),withUnsafeBytes(of:r.spin,{ Array($0.bindMemory(to:Float.self)) }),withUnsafeBytes(of:r.brakeTemperature,{ Array($0.bindMemory(to:Float.self)) })] { result += values.map(Double.init) }
        return result
    }
}
final class VehicleRemovalTests: XCTestCase {
    private func context(_ action: (ReferenceWorld,TrackRoad) throws -> Void) throws {
        let content=try ReferenceContent(fixtures:XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)))
        let world=try ReferenceWorld(track:content.track,car:content.car,category:content.category)
        defer { world.close(); withExtendedLifetime(content) {} }
        try action(world,ChassisTestContext.road())
    }
    private func state(road: TrackRoad,index: Int,left: Bool) -> VehicleRemovalState {
        let segment=road.geometry.mainSegments[index%road.geometry.mainSegments.count],s=road.geometry.segments[segment]
        let p=TrackLocalPosition(segment:segment,toStart:s.extent*0.37,toRight:s.width*(left ? 0.8:0.2),toMiddle:0,toLeft:s.width*(left ? 0.2:0.8))
        let xy=road.geometry.localToGlobal(p),z=road.geometry.height(p)
        var n=VehicleRemovalState(trackPosition:p); n.cgHeight=0.3; n.pitOccupant=7; n.gear=3; n.publishedGear=4; n.engineRPM=420; n.publishedRPM=430
        n.mechanicalBody = .init(position:SIMD3(xy.x,xy.y,z+0.7),orientation:SIMD3(0.2,-0.17,3.16),velocity:SIMD3(9,0.4,-0.2),angularVelocity:SIMD3(0.03,0.04,0.1),acceleration:SIMD3(1,2,3),angularAcceleration:SIMD3(4,5,6))
        n.publicBody=n.mechanicalBody; n.publicBody.position += SIMD3(0.4,0.2,0.1); n.publicBody.velocity.x=0
        n.publicTransform = .init(position:n.publicBody.position,orientation:n.publicBody.orientation)
        n.parking = .init(position:n.publicBody.position+SIMD3(1.7,-2.3,-0.2),orientation:SIMD3(0,0,0.4),velocity:SIMD3(0.1,0.2,0.5),angularVelocity:SIMD3(0.02,-0.03,0.07))
        n.collision=7; n.publishedCollision=9; n.publishedSimCollision=3; n.publishedSkid=SIMD4(1,2,3,4); n.publishedSpin=SIMD4(10,20,30,40); n.publishedBrakeTemperature=SIMD4(0.1,0.2,0.3,0.4)
        return n
    }
    private func compare(_ native: VehicleRemovalState,_ original: RefRemovalState,fields: inout Int) -> Bool {
        let n=RemovalContext.scalars(RemovalContext.input(native,dt:0.002)),o=RemovalContext.scalars(original)
        for i in n.indices { XCTAssertEqual(n[i],o[i],"removal field \(i)"); if n[i] != o[i] { return false }; fields += 1 }
        return true
    }
    func testRemovalFlagsSpeedDamageAndTrackTargetsAgainstOriginal() throws {
        try context { world,road in
            var cases=0,fields=0
            let flags: [UInt32]=[0,0x100,0x200,0x400,0x800,1,2,4,8,16,0x102,12,24]
            for index in [0,31,91,155,220,310] { for left in [false,true] { for flag in flags { for damage: Int32 in [99,100,101] { for speed: Float in [-2,-1,0,1,2] {
                var native=state(road:road,index:index,left:left); native.flags=flag; native.damage=damage; native.maximumDamage=100; native.publicBody.velocity.x=speed
                let output=try world.removalStep(RemovalContext.input(native,dt:0.002)); try native.remove(track:road.geometry)
                guard compare(native,output,fields:&fields) else { XCTFail("case \(cases) flags \(flag) index \(index)"); return }; cases += 1
            } } } } }
            print("REMOVAL_SWEEP cases=\(cases) fields=\(fields) maxAbsolute=0")
        }
    }
    func testIndependentTowTrajectoriesAgainstOriginal() throws {
        try context { world,road in
            var ticks=0,fields=0
            for index in [0,155,310] { for left in [false,true] {
                var native=state(road:road,index:index,left:left),original=RemovalContext.input(native,dt:0.002)
                var phases=Set<UInt32>()
                for _ in 0..<60000 {
                    original=try world.removalStep(original); try native.remove(track:road.geometry)
                    guard compare(native,original,fields:&fields) else { XCTFail("trajectory index \(index) left \(left) tick \(ticks)"); return }
                    phases.insert(native.flags & 0xFF); ticks += 1
                    if native.flags & 0x102 == 0x102 { break }
                }
                XCTAssertTrue(phases.isSuperset(of:[4,8,16,2])); XCTAssertFalse(native.collisionRegistered)
            } }
            print("REMOVAL_SEQUENCE cases=6 ticks=\(ticks) fields=\(fields) maxAbsolute=0")
        }
    }
}

extension VehicleRemovalTests {
    func testTowThresholdsAndZeroDistanceClassification() throws {
        try context { world,road in
            var cases=0,fields=0,classified=0
            for flag: UInt32 in [4,8,16] { for offset: Float in [-0.002,-0.00001,0,0.00001,0.002] {
                var n=state(road:road,index:31,left:false); n.flags=flag
                if flag==4 { n.publicBody.position.z=n.parking.position.z+3-n.parking.velocity.z*0.002+offset }
                if flag==8 { n.publicBody.position.x=n.parking.position.x+0.5+offset; n.publicBody.position.y=n.parking.position.y+0.5+offset }
                if flag==16 { n.publicBody.position.z=n.parking.position.z+n.parking.velocity.z*0.002+offset }
                let o=try world.removalStep(RemovalContext.input(n,dt:0.002)); try n.remove(track:road.geometry)
                XCTAssertTrue(compare(n,o,fields:&fields)); cases += 1
            } }
            var n=state(road:road,index:0,left:true); n.flags=8; n.publicBody.position=n.parking.position
            let o=try world.removalStep(RemovalContext.input(n,dt:0.002)); try n.remove(track:road.geometry)
            let actual=RemovalContext.scalars(RemovalContext.input(n,dt:0.002)), expected=RemovalContext.scalars(o)
            for i in actual.indices {
                if expected[i].isNaN { XCTAssertTrue(actual[i].isNaN); classified += 1 }
                else { XCTAssertEqual(actual[i],expected[i]); fields += 1 }
            }
            XCTAssertGreaterThan(classified,0); cases += 1
            var missingPit=state(road:road,index:0,left:false); missingPit.flags=1; missingPit.damage=101; missingPit.maximumDamage=100; missingPit.pitOccupant=nil
            XCTAssertThrowsError(try missingPit.remove(track:road.geometry))
            print("REMOVAL_BOUNDARY cases=\(cases) fields=\(fields) classified=\(classified) maxAbsolute=0")
        }
    }
}
