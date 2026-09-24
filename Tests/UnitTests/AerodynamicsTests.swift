// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSConfiguration
import TORCSSimulation

final class AerodynamicsTests: XCTestCase {
    static func xml(angle: Float = 0.15,area: Float = 1.2,cx: Float = 0.4) -> String {
        """
        <params name='aero'><section name='Aerodynamics'><attnum name='Cx' val='\(cx)'/>
        <attnum name='front area' val='2.3'/><attnum name='front Clift' val='0.3'/><attnum name='rear Clift' val='0.7'/></section>
        <section name='Front Wing'><attnum name='area' val='\(area)'/><attnum name='angle' val='\(angle)'/>
        <attnum name='xpos' val='2.4'/><attnum name='zpos' val='0.35'/></section>
        <section name='Rear Wing'><attnum name='area' val='\(area*1.1)'/><attnum name='angle' val='\(angle*0.9)'/>
        <attnum name='xpos' val='-2.1'/><attnum name='zpos' val='0.9'/></section></params>
        """
    }
    func configuration(_ xml: String = AerodynamicsTests.xml(),cg: Float = 0.17) throws -> (AerodynamicsDefinition,RefAeroSetup) {
        let n = try AerodynamicsDefinition(parameters:ParameterDocument.parse(Data(xml.utf8)),centerOfGravityX:cg)
        var o = RefAeroSetup(); XCTAssertEqual(ref_aero_config_xml(xml,cg,&o),1)
        return (n,o)
    }
    func compare(_ n: AerodynamicsDefinition,_ o: RefAeroSetup,metrics: inout EngineMetrics) {
        for (a,b) in [(n.bodyDragCoefficient,o.bodyDragCoefficient),(n.draftingCoefficient,o.draftingCoefficient),
                      (n.bodyLiftCoefficients.x,o.frontLift),(n.bodyLiftCoefficients.y,o.rearLift)] { metrics.check(a,b) }
        for (a,b) in [(n.frontWing,o.frontWing),(n.rearWing,o.rearWing)] {
            for (x,y) in [(a.angle,b.angle),(a.dragCoefficient,b.dragCoefficient),(a.liftCoefficient,b.liftCoefficient),
                          (a.position.x,b.position.x),(a.position.y,b.position.y),(a.position.z,b.position.z)] { metrics.check(x,y) }
        }
    }
    func input(x: Float = 0,y: Float = 0,yaw: Float = 0,vx: Float = 35,vy: Float = 0,vz: Float = 0,coefficient: Float = 1) -> RefAeroInput {
        var i = RefAeroInput()
        i.position = RefTrackVector(x:x,y:y,z:0); i.yaw = yaw
        i.bodyVelocity = RefTrackVector(x:vx,y:vy,z:vz)
        i.worldVelocity = RefTrackVector(x:vx*cos(yaw)-vy*sin(yaw),y:vx*sin(yaw)+vy*cos(yaw),z:0)
        i.speed = sqrt(vx*vx+vy*vy+vz*vz); i.draftingCoefficient = coefficient
        i.rideHeights = RefFourValues(frontRight:0.15,frontLeft:0.16,rearRight:0.17,rearLeft:0.14)
        return i
    }
    @discardableResult
    func check(_ d: AerodynamicsDefinition,_ setup: RefAeroSetup,_ inputs: [RefAeroInput],index: Int = 0,metrics: inout EngineMetrics) -> AerodynamicsResult {
        var o = RefAeroOutput()
        XCTAssertEqual(ref_aero_step(setup,inputs,Int32(inputs.count),Int32(index),&o),1)
        let p = inputs[index]
        let traffic = inputs.map { AeroTrafficState(position:SIMD2($0.position.x,$0.position.y),yaw:$0.yaw,
            longitudinalSpeed:$0.bodyVelocity.x,dragCoefficient:$0.draftingCoefficient) }
        let n = d.forces(carIndex:index,position:SIMD2(p.position.x,p.position.y),yaw:p.yaw,
            bodyVelocity:SIMD3(p.bodyVelocity.x,p.bodyVelocity.y,p.bodyVelocity.z),worldVelocity:SIMD2(p.worldVelocity.x,p.worldVelocity.y),
            speed:p.speed,damage:p.damage,rideHeights:SIMD4(p.rideHeights.frontRight,p.rideHeights.frontLeft,p.rideHeights.rearRight,p.rideHeights.rearLeft),traffic:traffic)
        for (a,b) in [(n.airSpeedSquared,o.airSpeedSquared),(n.drag,o.drag),(n.bodyLift.x,o.frontLift),(n.bodyLift.y,o.rearLift),
                      (n.frontWing.x,o.frontWing.x),(n.frontWing.y,o.frontWing.y),(n.frontWing.z,o.frontWing.z),
                      (n.rearWing.x,o.rearWing.x),(n.rearWing.y,o.rearWing.y),(n.rearWing.z,o.rearWing.z)] { metrics.check(a,b) }
        return n
    }
    func testFreshConfigurationAgainstOriginal() throws {
        var metrics = EngineMetrics(), cases = 0
        for angle: Float in [-0.3,0,0.25] {
            for area: Float in [0,1.4,3] {
                let (n,o) = try configuration(Self.xml(angle:angle,area:area),cg:-0.37)
                compare(n,o,metrics:&metrics); cases += 1
            }
        }
        let (n,o) = try configuration("<params name='defaults'/>")
        compare(n,o,metrics:&metrics); cases += 1
        try EngineTestContext.withWorld { p,_,world in
            let r = try RunningGearConfiguration(parameters:p)
            let n = try AerodynamicsDefinition(parameters:p,centerOfGravityX:r.mass.centerOfGravity.x)
            compare(n,try world.aeroSetup(),metrics:&metrics); cases += 1
        }
        print("AERO_CONFIG cases=\(cases) fields=\(metrics.fields) maxAbsolute=\(metrics.worst)")
    }
    func testDragGroundEffectWingsAndDamageAgainstOriginal() throws {
        let (d,c) = try configuration()
        var metrics = EngineMetrics(), cases = 0
        for vx: Float in [-60,-1,-0.01,0,0.01,1,10,10.000001,40,110] {
            for vy: Float in [-20,0,20] {
                for vz: Float in [-30,0,15] {
                    for damage: Int32 in [0,2500,10000] {
                        for height: Float in [0,0.05,0.2,1] {
                            var p = input(vx:vx,vy:vy,vz:vz); p.damage = damage
                            p.rideHeights = RefFourValues(frontRight:height,frontLeft:height*0.9,rearRight:height*1.1,rearLeft:height)
                            let result = check(d,c,[p],metrics:&metrics)
                            if vx<=0 { XCTAssertEqual(result.frontWing,.zero); XCTAssertEqual(result.rearWing,.zero) }
                            cases += 1
                        }
                    }
                }
            }
        }
        // The >1 speed gate uses caller state, with no cosine upper clamp.
        for speed: Float in [0,1,Float(1).nextUp,30] {
            var p = input(vx:5); p.speed = speed
            check(d,c,[p],metrics:&metrics); cases += 1
        }
        print("AERO_FORCES cases=\(cases) fields=\(metrics.fields) maxAbsolute=\(metrics.worst)")
    }
    func testDraftingThresholdsWraparoundAndCarIndicesAgainstOriginal() throws {
        let (d,c) = try configuration()
        var metrics = EngineMetrics(), cases = 0
        let small: Float = 0.1396, large: Float = 2.9671
        let directions: [Float] = [0,small.nextDown,small,small.nextUp,large.nextDown,large,large.nextUp,Float.pi,-Float.pi,-small,-large]
        for speed: Float in [10,Float(10).nextUp,35] {
            for otherSpeed: Float in [10,Float(10).nextUp,55] {
                for yaw: Float in [0,small.nextDown,small,small.nextUp,Float(2*Double.pi),Float(-2*Double.pi)] {
                    for direction in directions {
                        for distance: Float in [0,1,30,200] {
                            let subject = input(vx:speed,coefficient:d.draftingCoefficient)
                            let other = input(x:-distance*cos(direction),y:-distance*sin(direction),yaw:yaw,vx:otherSpeed,coefficient:0.9)
                            // Rotate index to establish that every self entry is excluded.
                            let index = cases%2, cars = index == 0 ? [subject,other] : [other,subject]
                            check(d,c,cars,index:index,metrics:&metrics); cases += 1
                        }
                    }
                }
            }
        }
        // Multiple opponents choose the minimum drag factor rather than multiplying effects.
        let subject = input(coefficient:d.draftingCoefficient), near = input(x:3), far = input(x:15), behind = input(x:-2)
        let nearResult = check(d,c,[subject,near],metrics:&metrics)
        let allResult = check(d,c,[subject,far,behind,near],metrics:&metrics)
        XCTAssertEqual(nearResult.drag,allResult.drag)
        let baseline = check(d,c,[subject],metrics:&metrics)
        XCTAssertLessThan(abs(nearResult.drag),abs(baseline.drag))
        // Original ignores a NaN candidate from coincident cars with zero Cd.
        check(d,c,[subject,input(coefficient:0)],metrics:&metrics)
        print("AERO_DRAFTING cases=\(cases+4) fields=\(metrics.fields) maxAbsolute=\(metrics.worst)")
    }
    func testOriginalCarAeroAndReferenceTableRestoration() throws {
        var metrics = EngineMetrics()
        try EngineTestContext.withWorld { p,_,world in
            let running = try RunningGearConfiguration(parameters:p)
            let d = try AerodynamicsDefinition(parameters:p,centerOfGravityX:running.mass.centerOfGravity.x)
            let c = try world.aeroSetup(), before = try world.sample()
            for tick in 0..<500 {
                let t = Float(tick)*0.01
                let subject = input(x:20*t,yaw:sin(t)*0.1,vx:40,vy:2*cos(t),vz:sin(t),coefficient:d.draftingCoefficient)
                check(d,c,[subject,input(x:20*t+5,y:sin(t),vx:45)],metrics:&metrics)
            }
            XCTAssertEqual(before,try world.sample(),"Temporary aero oracle must restore SimCarTable without mutating the live world")
            try world.command(.init(brake:1)); try world.step()
            XCTAssertEqual(try world.sample().count,142)
        }
        print("AERO_ORIGINAL_CAR cases=500 fields=\(metrics.fields) maxAbsolute=\(metrics.worst)")
    }
    func testSequentialMovingTrafficAgainstOriginal() throws {
        let (d,c) = try configuration()
        var metrics = EngineMetrics()
        for tick in 0..<10000 {
            let t = Float(tick)*0.002
            var subject = input(x:35*t,y:sin(t)*5,yaw:sin(t)*0.2,vx:35+10*sin(t),vy:3*cos(t),vz:sin(t)*2,coefficient:d.draftingCoefficient)
            subject.damage = Int32(tick/100)*23
            let h: Float = 0.12+0.05*sin(t*2)
            subject.rideHeights = RefFourValues(frontRight:h,frontLeft:h*0.9,rearRight:h*1.1,rearLeft:h)
            let cars = [input(x:35*t+8*cos(t),y:3*sin(t),yaw:0.1*sin(t),vx:40,coefficient:0.8),subject,
                        input(x:35*t-6,y:sin(t),yaw:0.05*sin(t),vx:30,coefficient:1.2),
                        input(x:35*t+1,y:12,yaw:Float(2*Double.pi)+0.1*sin(t),vx:45,coefficient:1.1)]
            check(d,c,cars,index:1,metrics:&metrics)
        }
        print("AERO_MOVING_TRAFFIC ticks=10000 cars=4 fields=\(metrics.fields) maxAbsolute=\(metrics.worst)")
    }
}
