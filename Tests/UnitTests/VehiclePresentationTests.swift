// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import CReference
import TORCSConfiguration
import TORCSTrack
import TORCSReferenceSupport
@testable import TORCSSimulation
@testable import TORCSPresentation

final class VehiclePresentationTests: XCTestCase {
    struct Metrics { var cases=0,scalars=0;var maximum: Float=0 }
    func floats<T>(_ value: T) -> [Float] { withUnsafeBytes(of:value) { Array($0.bindMemory(to:Float.self)) } }
    func compare(_ n: VehiclePresentation,_ r: RefVehicleVisual,_ m: inout Metrics) {
        let expected=floats(r.matrix)+floats(r.wheelMatrix)+floats(r.brakeColor)+floats(r.brakeMatrix)
        var actual=(0..<4).flatMap { column in (0..<4).map { c in n.body[column][c] } }
        for i in 0..<4 { actual += (0..<4).flatMap { column in (0..<4).map { c in n.wheels[i].transform[column][c] } } }
        for i in 0..<4 { actual += (0..<3).map { n.wheels[i].brakeColor[$0] } }
        for i in 0..<4 { actual += (0..<4).flatMap { column in (0..<4).map { c in n.wheels[i].brakeTransform[column][c] } } }
        let levels=withUnsafeBytes(of:r.level) { Array($0.bindMemory(to:Int32.self)) }
        for i in 0..<4 { XCTAssertEqual(n.wheels[i].level,Int(levels[i])) }
        XCTAssertEqual(actual.count,expected.count)
        for (a,b) in zip(actual,expected) { m.maximum=max(m.maximum,abs(a-b));XCTAssertEqual(a,b,accuracy:0.0001);m.scalars += 1 }
        m.cases += 1
    }
    func setup() throws -> (ReferenceContent,VehicleDynamicsDefinition) {
        let content=try ReferenceContent(fixtures:XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)))
        let parameters=try ParameterDocument.parse(Data(contentsOf:content.category)).merging(ParameterDocument.parse(Data(contentsOf:content.car)))
        return (content,try VehicleDynamicsDefinition(parameters:parameters))
    }
    func testWheelTransformsAndSpeedThresholdsAgainstOriginal() throws {
        let (content,d)=try setup();defer { withExtendedLifetime(content) {} }
        var metrics=Metrics()
        for speed: Float in [-200,-70,-69.999,-40,-39.999,-20,-19.999,0,19.999,20,39.999,40,69.999,70,200] {
            for angle in 0..<20 {
                var published=VehicleRemovalState(trackPosition:TrackLocalPosition(segment:0,toStart:0,toRight:0))
                published.publicTransform=CollisionTransform(position:SIMD3(12.3,-4.7,1.9),orientation:SIMD3(Float(angle)*0.01,-0.16,Float(angle)*0.37))
                for i in 0..<4 {
                    published.publishedWheelPose[i]=WheelVisualPose(position:SIMD3(i<2 ? 1.2:-1.1,i%2==0 ? -0.75:0.75,0.22+Float(angle)*0.006),orientation:SIMD3(Float(i-2)*0.03,Float(angle)*0.35-3,Float(i)*0.1))
                    published.publishedSpin[i]=speed;published.publishedBrakeTemperature[i]=Float(angle)*0.07
                }
                let snapshot=VehicleVisualSnapshot(tick:angle,published:published,configuration:d.chassis.runningGear),native=try VehiclePresentation(snapshot)
                let body=(0..<4).flatMap { column in (0..<4).map { c in native.body[column][c] } }
                var wheels: [RefVisualWheel]=[]
                for i in 0..<4 {
                    let w=snapshot.wheels[i],p=w.pose.position,a=w.pose.orientation
                    wheels.append(RefVisualWheel(position:(p.x,p.y,p.z),orientation:(a.x,a.y,a.z),spin:w.spin,radius:w.radius,width:w.width,brakeTemperature:w.brakeTemperature))
                }
                var original=RefVehicleVisual();ref_wheel_graphics(body,wheels,&original)
                compare(native,original,&metrics)
            }
        }
        print("VEHICLE_GRAPHICS cases=\(metrics.cases) scalars=\(metrics.scalars) maxAbsolute=\(metrics.maximum)")
    }
    func testPublishedVisualSnapshotsAgainstOriginalSimulation() throws {
        let (content,d)=try setup(),road=try ChassisTestContext.road()
        let reference=try ReferenceWorld(track:content.track,car:content.car,category:content.category)
        defer { reference.close();withExtendedLifetime(content) {} }
        var native=try SingleVehicleSimulation(definition:d,road:road),metrics=Metrics(),publishedScalars=0
        func check() throws {
            let s=native.visualSnapshot,r=try reference.visual()
            XCTAssertEqual(s.flags,r.flags)
            let expected=withUnsafeBytes(of:r.wheels) { Array($0.bindMemory(to:RefVisualWheel.self)) }
            for i in 0..<4 {
                let w=s.wheels[i],p=w.pose.position,a=w.pose.orientation
                let actual=[p.x,p.y,p.z,a.x,a.y,a.z,w.spin,w.radius,w.width,w.brakeTemperature]
                XCTAssertEqual(actual,floats(expected[i]));publishedScalars += actual.count
            }
            compare(try VehiclePresentation(s),r,&metrics)
        }
        try check();try native.settle();try reference.settle();try check()
        for tick in 0..<1500 {
            let mode: VehicleUpdateMode=tick<100 ? .prestart:.running
            let command=DriverCommand(throttle:tick<1000 ? 0.7:0,brake:tick>=1000 ? 0.5:0,steering:0.08*sin(Float(tick)*0.01),gear:1)
            try reference.command(.init(throttle:command.throttle,brake:command.brake,steering:command.steering,clutch:command.clutch,gear:1))
            try reference.step(raceState:tick<100 ? 16:1);try native.step(command:command,mode:mode);try check()
        }
        // Fuel-empty towing retains wheel publication while body placement changes.
        try native.updateCarStatus(fuel:0);try reference.updateCarStatus(car:0,fuel:0)
        for _ in 0..<500 { try native.step(command:.init());try reference.step();try check() }
        print("VEHICLE_VISUAL_PUBLICATION cases=\(metrics.cases) publishedScalars=\(publishedScalars) matrixScalars=\(metrics.scalars) maxAbsolute=\(metrics.maximum)")
    }
    func testPresentationInterpolationEndpointsAndAngleWrap() throws {
        let (content,d)=try setup();defer { withExtendedLifetime(content) {} }
        func pose(x: Float,yaw: Float) throws -> VehiclePresentation {
            var published=VehicleRemovalState(trackPosition:TrackLocalPosition(segment:0,toStart:0,toRight:0))
            published.publicTransform=CollisionTransform(position:SIMD3(x,0,0),orientation:SIMD3(0,0,yaw))
            for i in 0..<4 { published.publishedWheelPose[i]=WheelVisualPose(position:d.chassis.runningGear.wheels[i].initialRelativePosition,orientation:SIMD3(0,yaw,0)) }
            return try VehiclePresentation(VehicleVisualSnapshot(tick:0,published:published,configuration:d.chassis.runningGear))
        }
        let a=try pose(x:0,yaw:3.13),b=try pose(x:2,yaw:-3.13)
        let first=try VehiclePresentation.interpolate(previous:a,current:b,alpha:0),last=try VehiclePresentation.interpolate(previous:a,current:b,alpha:1)
        for column in 0..<4 { XCTAssertEqual(first.body[column],a.body[column]);XCTAssertEqual(last.body[column],b.body[column]) }
        let mid=try VehiclePresentation.interpolate(previous:a,current:b,alpha:0.5)
        XCTAssertEqual(mid.body[3].x,1,accuracy:0.000001);XCTAssertLessThan(mid.body[0].x,-0.999)
        for i in 0..<4 { for column in 0..<3 {
            let m=mid.wheels[i].transform[column],n=a.wheels[i].transform[column]
            XCTAssertEqual(simd_length(SIMD3(m.x,m.y,m.z)),simd_length(SIMD3(n.x,n.y,n.z)),accuracy:0.000001)
        } }
        for alpha: Float in [-1,2,.nan,.infinity] { XCTAssertThrowsError(try VehiclePresentation.interpolate(previous:a,current:b,alpha:alpha)) }
        print("VEHICLE_INTERPOLATION endpoints=2 wrap=1 scaleChecks=12 invalidAlpha=4")
    }
}
