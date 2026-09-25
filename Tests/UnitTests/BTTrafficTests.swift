// SPDX-License-Identifier: GPL-2.0-only
// The native BT opponent handling, fed the exact field the original driver saw at
// every callback, compared control by control against the original's output.
import XCTest
import TORCSConfiguration
import TORCSRobots
import TORCSTrack
import CReference
import TORCSReferenceSupport

final class BTTrafficTests: XCTestCase {
    private func parameters(_ content: ReferenceContent) throws -> ParameterDocument {
        try ParameterDocument.parse(Data(contentsOf:content.category))
            .merging(ParameterDocument.parse(Data(contentsOf:content.car)))
    }
    /// The original segment ids are upstream ids; the native geometry indexes
    /// main segments separately.
    private func index(_ upstream: Int32,road: TrackRoad) throws -> Int {
        try XCTUnwrap(road.geometry.mainSegments.first { road.geometry.segments[$0].upstreamID==Int(upstream) })
    }
    private func position(_ car: RefBTFieldCar,road: TrackRoad) throws -> TrackLocalPosition {
        .init(segment:try index(car.segment,road:road),toStart:car.toStart,toRight:car.toRight,
              toMiddle:car.toMiddle,toLeft:car.toLeft)
    }
    private func corners(_ car: RefBTFieldCar) -> [SIMD2<Float>] {
        [SIMD2(car.cornerX.0,car.cornerY.0),SIMD2(car.cornerX.1,car.cornerY.1),
         SIMD2(car.cornerX.2,car.cornerY.2),SIMD2(car.cornerX.3,car.cornerY.3)]
    }
    private func observation(_ car: RefBTFieldCar,road: TrackRoad,speed: Float) throws -> BTObservation {
        let spin=SIMD4(car.spin.0,car.spin.1,car.spin.2,car.spin.3)
        let place=try position(car,road:road)
        return BTObservation(position:place,worldPosition:SIMD2(car.x,car.y),
            worldVelocity:SIMD2(car.vx,car.vy),yaw:car.yaw,speed:speed,
            fuel:car.fuel,rpm:car.rpm,wheelSpin:spin,gear:Int(car.gear),laps:Int(car.laps),
            remainingLaps:Int(car.remainingLaps),distanceFromStart:car.distance,
            lapsBehindLeader:Int(car.lapsBehindLeader),damage:car.damage,pitFree:car.pitFree != 0,
            corners:corners(car))
    }
    private func state(_ car: RefBTFieldCar,road: TrackRoad) throws -> BTCarState {
        let place=try position(car,road:road)
        return BTCarState(position:place,worldPosition:SIMD2(car.x,car.y),
            worldVelocity:SIMD2(car.vx,car.vy),corners:corners(car),
            yaw:car.yaw,length:car.length,width:car.width,distanceFromStart:car.distance,
            laps:Int(car.laps),damage:car.damage,flags:UInt32(bitPattern:car.state),teamMate:false)
    }
    func testFieldCallbackCommandsMatchTheOriginal() throws {
        let cars=3,ticks=20_000
        let content=try ReferenceContent(fixtures:XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)),
            bt:true,drivers:cars)
        let world=try ReferenceWorld(track:content.track,car:content.car,category:content.category,
            cars:cars,btDirectory:content.directory,laps:3,grid: .quickRace)
        defer { world.close() }
        let road=try ChassisTestContext.road(),p=try parameters(content)
        // One native driver per original driver index, with the stall the original
        // pit allocation gives each car in grid order.
        var drivers=try (0..<cars).map { index in
            try BTDriver(road:road,parameters:p,totalLaps:3,driverIndex:index,pitStall:index,fieldSize:cars)
        }
        var callbacks=Array(repeating:UInt64(0),count:cars)
        var compared=0,exact=0,maximum:Float=0,classified=0,offsets=0
        for _ in 0..<ticks {
            guard try world.stepRace() >= 0 else { break }
            for car in 0..<cars {
                let status=try world.robotStatus(car:car)
                guard status.driveCalls>callbacks[car] else { continue }
                callbacks[car]=status.driveCalls
                let field=try world.robotField(car:car)
                XCTAssertEqual(field.count,cars)
                let mine=try observation(field[car],road:road,speed:try world.robotObservation(car:car).speed)
                let others=try (0..<cars).filter { $0 != car }.map { try state(field[$0],road:road) }
                let decision=try drivers[car].drive(mine,field:others,deltaTime:status.robotDelta)
                let command=decision.command
                for (name,a,b) in [("throttle",command.throttle,status.throttle),("brake",command.brake,status.brake),
                                   ("steering",command.steering,status.steering),("clutch",command.clutch,status.clutch)] {
                    let error=abs(a-b);maximum=max(maximum,error);compared += 1
                    if a==b { exact += 1 }
                    guard a.isFinite,error<=0.000002 else {
                        let dump=drivers[car].opponents.enumerated().map { "o\($0.offset) state=\($0.element.state.rawValue) dist=\($0.element.distance) side=\($0.element.sideDistance) w=\($0.element.width) yaw=\($0.element.yaw) toMid=\($0.element.toMiddle)" }
                        XCTFail("BT field \(name) car=\(car) tick=\(world.tick) callback=\(status.driveCalls) native=\(a) original=\(b) error=\(error) offset=\(drivers[car].offset) mySpeed=\(mine.speed) toMiddle=\(mine.position.toMiddle) myYaw=\(mine.yaw) steerLock=\(drivers[car].steerLock) | \(dump.joined(separator:" | "))")
                        return
                    }
                }
                XCTAssertEqual(command.gear,Int(status.gear),"gear car=\(car) callback=\(status.driveCalls)")
                // Count the ticks where the port actually had traffic to reason
                // about, so a passing run cannot be a vacuous one.
                if drivers[car].opponents.contains(where:{ !$0.state.isEmpty }) { classified += 1 }
                if drivers[car].offset != 0 { offsets += 1 }
            }
        }
        XCTAssertGreaterThan(compared,10_000,"the comparison must cover a meaningful run")
        XCTAssertGreaterThan(classified,100,"opponents must actually be classified during the run")
        XCTAssertGreaterThan(offsets,10,"the overtaking offset must actually move")
        print("NATIVE_BT_FIELD cars=\(cars) ticks=\(world.tick) callbacks=\(callbacks) compared=\(compared) exactFloats=\(exact) maxAbsolute=\(maximum) classifiedCallbacks=\(classified) offsetCallbacks=\(offsets)")
    }
    func testOpponentClassificationAndSoloPathBoundaries() throws {
        let road=try ChassisTestContext.road()
        let content=try ReferenceContent(fixtures:XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)))
        defer { withExtendedLifetime(content) {} }
        let p=try parameters(content)
        // A solo driver has no opponents and rejects a field.
        var solo=try BTDriver(road:road,parameters:p,totalLaps:1,pitStall:0)
        XCTAssertEqual(solo.opponents.count,0)
        XCTAssertTrue(solo.alone)
        // Both cars aligned with the track, so the projected track-direction
        // speeds are the ones intended: mine 30 m/s, the other 10 m/s.
        let segment=road.geometry.mainSegments[0]
        let place=TrackLocalPosition(segment:segment,toStart:1,toRight:5,toMiddle:0,toLeft:5)
        let tangent=road.geometry.tangent(place)
        let ahead=SIMD2(cos(tangent),sin(tangent))
        let here=road.geometry.localToGlobal(place)
        func box(_ centre:SIMD2<Float>) -> [SIMD2<Float>] {
            let side=SIMD2(-ahead.y,ahead.x)
            return [centre+ahead*2.35+side*(-0.95),centre+ahead*2.35+side*0.95,
                    centre-ahead*2.35+side*(-0.95),centre-ahead*2.35+side*0.95]
        }
        let mySegment=road.geometry.segments[segment]
        let myAlong=mySegment.distanceFromStart
        let mine=BTObservation(position:place,worldPosition:here,worldVelocity:ahead*30,yaw:tangent,speed:30,
            fuel:50,rpm:400,wheelSpin:SIMD4<Float>.zero,gear:3,laps:1,remainingLaps:1,
            distanceFromStart:myAlong+1,corners:box(here))
        // 50 m further along the same straight, in the same line, and slower.
        let theirPlace=TrackLocalPosition(segment:segment,toStart:51,toRight:5,toMiddle:0,toLeft:5)
        let there=road.geometry.localToGlobal(theirPlace)
        let other=BTCarState(position:theirPlace,worldPosition:there,worldVelocity:ahead*10,
            corners:box(there),yaw:tangent,length:4.7,width:1.9,distanceFromStart:myAlong+51,laps:1)
        XCTAssertThrowsError(try solo.drive(mine,field:[other]),"a solo driver rejects a field")
        // A two-car driver classifies the slower car ahead as a front opponent it
        // may collide with, so it is no longer alone.
        var racer=try BTDriver(road:road,parameters:p,totalLaps:1,pitStall:0,fieldSize:2)
        XCTAssertEqual(racer.opponents.count,1)
        _=try racer.drive(mine,field:[other])
        XCTAssertTrue(racer.opponents[0].state.contains(.front),"a slower car 50 m ahead is a front opponent")
        XCTAssertTrue(racer.opponents[0].state.contains(.collision),"directly ahead in the same line is a collision risk")
        XCTAssertFalse(racer.alone,"a collision risk means not alone")
        XCTAssertGreaterThan(racer.opponents[0].catchDistance,0)
        print("NATIVE_BT_CLASSIFY front=1 collision=1 alone=0 catchDistance=\(racer.opponents[0].catchDistance)")
    }
}
