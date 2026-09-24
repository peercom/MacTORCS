// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSConfiguration
import TORCSSimulation
import TORCSReferenceSupport

enum EngineTestContext {
    static func withWorld(_ body: (ParameterDocument,EngineDefinition,ReferenceWorld) throws -> Void) throws {
        let fixtures = try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil))
        let content = try ReferenceContent(fixtures:fixtures)
        let p = try ParameterDocument.parse(Data(contentsOf:content.category)).merging(ParameterDocument.parse(Data(contentsOf:content.car)))
        let definition = try EngineDefinition(parameters:p)
        let world = try ReferenceWorld(track:content.track,car:content.car,category:content.category)
        defer { world.close(); withExtendedLifetime(content) {} }
        try body(p,definition,world)
    }
    static func input(speed: Float = 400, torque: Float = 200) -> RefEngineInput {
        RefEngineInput(speed:speed,torque:torque,pressure:23,exhaustPressure:0.4,smoke:0.8,fuel:30,throttle:0.7,
            axleSpeed:80,overallRatio:5,clutchTransfer:1,dt:0.002,gear:1,clutchPhase:0,stages:3,carFlags:0,randomSeed:12345)
    }
}
struct EngineMetrics {
    var fields = 0, classified = 0
    var worst: Float = 0
    mutating func check(_ a: Float,_ b: Float,_ label: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(a.isFinite && b.isFinite,label,file:file,line:line)
        XCTAssertEqual(a,b,accuracy:1e-5+1e-6*abs(b),label,file:file,line:line)
        fields += 1; worst = max(worst,abs(a-b))
    }
    mutating func state(_ n: EngineState, fuel: Float, clutch: ClutchState, reaction: Float, _ o: RefEngineOutput) {
        for (a,b) in [(n.speed,o.speed),(n.torque,o.torque),(n.pressure,o.pressure),(n.exhaustPressure,o.exhaustPressure),
                      (n.smoke,o.smoke),(fuel,o.fuel),(clutch.transfer,o.clutchTransfer),(reaction,o.reaction)] { check(a,b) }
        XCTAssertEqual(clutch.phase.rawValue,o.clutchPhase)
    }
    mutating func setup(_ n: EngineDefinition, _ o: RefEngineSetup, _ curve: [RefEngineCurvePoint]) {
        for (a,b) in [(n.limiter,o.limiter),(n.maximumSpeed,o.maximumSpeed),(n.idleSpeed,o.idleSpeed),(n.inertia,o.inertia),
                      (n.fuelConsumption,o.fuelConsumption),(n.brakeCoefficient,o.brakeCoefficient),(n.maximumTorque,o.maximumTorque),
                      (n.maximumPower,o.maximumPower),(n.maximumTorqueSpeed,o.maximumTorqueSpeed),(n.maximumPowerSpeed,o.maximumPowerSpeed),
                      (n.torqueAtMaximumPower,o.torqueAtMaximumPower)] { check(a,b) }
        XCTAssertEqual(n.curve.count,Int(o.curveCount))
        for (a,b) in zip(n.curve,curve) {
            check(a.limit,b.limit)
            for (x,y) in [(a.slope,b.slope),(a.intercept,b.intercept)] {
                if y.isNaN { XCTAssertTrue(x.isNaN); classified += 1 } else { check(x,y) }
            }
        }
    }
}
final class EngineTests: XCTestCase {
    static func xml(limiter: Float = 800) -> String {
        let points: [(Float,Float)] = [(50,1000),(150,50),(300,200),(600,180),(800,140),(1000,0)]
        let curve = points.enumerated().map { i,p in "<section name='\(i+1)'><attnum name='rpm' val='\(p.0)'/><attnum name='Tq' val='\(p.1)'/></section>" }.joined()
        return "<params name='engine'><section name='Engine'><attnum name='revs limiter' val='\(limiter)'/><section name='data points'>\(curve)</section></section></params>"
    }
    func testConfigurationAgainstOriginal() throws {
        var metrics = EngineMetrics()
        for limiter: Float in [550,800,1100] {
            for factor: Float in [0,1,2.3] {
                let xml = Self.xml(limiter:limiter), n = try EngineDefinition(parameters:ParameterDocument.parse(Data(xml.utf8)),fuelFactor:factor)
                var original = RefEngineSetup(), points = [RefEngineCurvePoint](repeating:.init(),count:128)
                XCTAssertEqual(ref_engine_config_xml(xml,factor,&original,&points,128),1)
                metrics.setup(n,original,Array(points.prefix(Int(original.curveCount))))
                XCTAssertEqual(n.maximumTorque,200,"Original maximum scan skips the first input point")
            }
        }
        try EngineTestContext.withWorld { _,definition,world in
            let (setup,curve) = try world.engineSetup(); metrics.setup(definition,setup,curve)
        }
        XCTAssertEqual(metrics.classified,20)
        print("ENGINE_CONFIG cases=10 fields=\(metrics.fields) maxAbsolute=\(metrics.worst) terminalNaNs=\(metrics.classified)")
    }
    func testTorqueCurveFuelLimiterAndFlagsAgainstOriginal() throws {
        try EngineTestContext.withWorld { _,d,world in
            var metrics = EngineMetrics(), count = 0
            let speeds: [Float] = [-10,0,d.idleSpeed-1,d.idleSpeed,d.idleSpeed+1,d.limiter-1,d.limiter,d.limiter+1,d.maximumSpeed,d.maximumSpeed+100]
                + d.curve.flatMap { [$0.limit.nextDown,$0.limit,$0.limit.nextUp] }
            for speed in speeds {
                for throttle: Float in [-0.2,0,0.1,0.5,1,1.2] {
                    for flags: UInt32 in [0,0x200,0x800,0x40] {
                        for initialFuel: Float in [-1,0,0.00000001,12] {
                            var input = EngineTestContext.input(speed:speed,torque:17)
                            input.stages = 1; input.throttle = throttle; input.carFlags = flags; input.fuel = initialFuel
                            let o = try world.engineStep(input)
                            var n = EngineState(speed:speed,torque:17,pressure:input.pressure,exhaustPressure:input.exhaustPressure,smoke:input.smoke)
                            var fuel = initialFuel
                            n.updateTorque(definition:d,throttle:throttle,fuel:&fuel,carFlags:flags)
                            metrics.state(n,fuel:fuel,clutch:.init(phase:.released,transfer:1),reaction:0,o)
                            count += 1
                        }
                    }
                }
            }
            print("ENGINE_TORQUE samples=\(count) maxAbsolute=\(metrics.worst)")
        }
    }
    func testRPMClutchReactionAndRandomConsumptionAgainstOriginal() throws {
        try EngineTestContext.withWorld { _,d,world in
            var metrics = EngineMetrics(), count = 0, consumed = 0, reactions = 0
            for fuel: Float in [0,30] {
                for transfer: Float in [0,0.01,0.010001,0.5,0.99,1] {
                    for gear in [-1,0,1] {
                        for axle: Float in [-400,-1,0,1,80,400] {
                            for speed: Float in [-10,d.idleSpeed,d.maximumSpeed+200] {
                                var p = EngineTestContext.input(speed:speed)
                                p.stages = 2; p.fuel = fuel; p.gear = Int32(gear); p.overallRatio = gear<0 ? -5 : 5
                                p.clutchTransfer = transfer; p.axleSpeed = axle; p.randomSeed = UInt32(count+1)
                                let random = ref_uniform_random(p.randomSeed), o = try world.engineStep(p)
                                var n = EngineState(speed:p.speed,torque:p.torque,pressure:p.pressure,exhaustPressure:p.exhaustPressure,smoke:p.smoke)
                                var clutch = ClutchState(phase:.released,transfer:transfer), calls = 0
                                let reaction = n.updateRPM(definition:d,axleSpeed:axle,overallRatio:p.overallRatio,gear:gear,clutch:&clutch,fuel:fuel) {
                                    calls += 1; return random
                                }
                                metrics.state(n,fuel:fuel,clutch:clutch,reaction:reaction,o)
                                XCTAssertEqual(calls,fuel>0 ? 1 : 0)
                                consumed += calls; if reaction != 0 { reactions += 1 }; count += 1
                            }
                        }
                    }
                }
            }
            XCTAssertGreaterThan(reactions,0)
            print("ENGINE_RPM samples=\(count) maxAbsolute=\(metrics.worst) randomDraws=\(consumed) axleCorrections=\(reactions)")
        }
    }
    func testMissingCurveIntervalRetainsTorque() throws {
        let xml = Self.xml(limiter:1100), d = try EngineDefinition(parameters:ParameterDocument.parse(Data(xml.utf8)))
        var setup = RefEngineSetup(), points = [RefEngineCurvePoint](repeating:.init(),count:128)
        XCTAssertEqual(ref_engine_config_xml(xml,1,&setup,&points,128),1)
        for speed: Float in [999.99,1000,1050,1100,1100.01] {
            var p = EngineTestContext.input(speed:speed,torque:37); p.stages = 1
            var o = RefEngineOutput(), n = EngineState(speed:speed,torque:37), fuel: Float = 30
            p.pressure = 0; p.exhaustPressure = 0; p.smoke = 0
            XCTAssertEqual(ref_engine_configured_step(setup,points,setup.curveCount,p,&o),1)
            n.updateTorque(definition:d,throttle:p.throttle,fuel:&fuel)
            var metrics = EngineMetrics(); metrics.state(n,fuel:fuel,clutch:.init(phase:.released,transfer:1),reaction:0,o)
            if speed>=1000 && speed<=1100 { XCTAssertEqual(n.torque,37); XCTAssertEqual(fuel,30) }
        }
    }
    func testIndependentSequentialEngineState() throws {
        try EngineTestContext.withWorld { _,d,world in
            var n = EngineState(definition:d), o = RefEngineOutput(), fuel: Float = 30
            o.speed = d.idleSpeed; o.fuel = fuel; o.clutchPhase = 0
            var clutch = ClutchState(phase:.released), metrics = EngineMetrics(), reactions = 0
            for tick in 0..<20000 {
                let throttle: Float = tick%3000<2200 ? 0.8 : 0
                let transfer: Float = tick%700<100 ? 0 : 1
                let axle: Float = 160 + 180*sin(Float(tick)*0.001)
                var p = EngineTestContext.input(speed:o.speed,torque:o.torque)
                p.pressure = o.pressure; p.exhaustPressure = o.exhaustPressure; p.smoke = o.smoke; p.fuel = o.fuel
                p.throttle = throttle; p.clutchTransfer = transfer; p.clutchPhase = o.clutchPhase; p.axleSpeed = axle
                p.randomSeed = UInt32(tick+12345)
                let random = ref_uniform_random(p.randomSeed)
                o = try world.engineStep(p)
                clutch.transfer = transfer
                n.updateTorque(definition:d,throttle:throttle,fuel:&fuel)
                let reaction = n.updateRPM(definition:d,axleSpeed:axle,overallRatio:5,gear:1,clutch:&clutch,fuel:fuel) { random }
                metrics.state(n,fuel:fuel,clutch:clutch,reaction:reaction,o)
                if reaction != 0 { reactions += 1 }
            }
            XCTAssertLessThan(fuel,30); XCTAssertGreaterThan(reactions,0)
            print("ENGINE_SEQUENCE ticks=20000 maxAbsolute=\(metrics.worst) axleCorrections=\(reactions)")
        }
    }
    func testInvalidTorqueCurveRejected() throws {
        for xml in ["<params name='empty'/>",Self.xml().replacingOccurrences(of:"val='150.0'",with:"val='50.0'")] {
            XCTAssertThrowsError(try EngineDefinition(parameters:ParameterDocument.parse(Data(xml.utf8))))
        }
    }
}
