// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSConfiguration
import TORCSSimulation
import TORCSReferenceSupport

final class DifferentialTests: XCTestCase {
    static func configurations() throws -> [(DifferentialDefinition,RefDifferentialConfig)] {
        var results: [(DifferentialDefinition,RefDifferentialConfig)] = []
        for type in ["NONE","SPOOL","FREE","LIMITED SLIP","VISCOUS COUPLER","unknown"] {
            for variant in 0..<2 {
                let xml = """
                <params name='diff'><section name='Differential'><attstr name='type' val='\(type)'/>
                <attnum name='inertia' val='0.17'/><attnum name='efficiency' val='0.92'/><attnum name='ratio' val='3.9'/>
                <attnum name='min torque bias' val='0.15'/><attnum name='max torque bias' val='\(variant == 0 ? 0.8 : 0.1)'/>
                <attnum name='max slip bias' val='0.08'/><attnum name='locking input torque' val='2200'/>
                \(variant == 0 ? "<attnum name='locking brake input torque' val='600'/>" : "")
                <attnum name='viscosity factor' val='0.7'/></section></params>
                """
                let n = try DifferentialDefinition(parameters:ParameterDocument.parse(Data(xml.utf8)),section:"Differential",inputInertias:SIMD2(1.7,2.2))
                var o = RefDifferentialConfig()
                XCTAssertEqual(ref_differential_config_xml(xml,"Differential",1.7,2.2,&o),1)
                results.append((n,o))
            }
        }
        return results
    }
    func compareSetup(_ n: DifferentialDefinition,_ o: RefDifferentialConfig,metrics: inout EngineMetrics) {
        XCTAssertEqual(n.type.rawValue,o.type)
        for (a,b) in [(n.inertia,o.inertia),(n.efficiency,o.efficiency),(n.ratio,o.ratio),(n.minimumTorqueBias,o.minimumTorqueBias),
                      (n.torqueBiasRange,o.torqueBiasRange),(n.maximumSlipBias,o.maximumSlipBias),(n.lockingTorque,o.lockingTorque),
                      (n.brakingLockingTorque,o.brakingLockingTorque),(n.viscosity,o.viscosity),(n.feedbackInertia,o.feedbackInertia)] { metrics.check(a,b) }
    }
    func compareAxes(_ first: DriveAxis,_ second: DriveAxis,_ o: RefDifferentialOutput,metrics: inout EngineMetrics) {
        for (n,r) in [(first,o.first),(second,o.second)] {
            for (a,b) in [(n.spin,r.spin),(n.torque,r.torque),(n.brakeTorque,r.brakeTorque),(n.inertia,r.inertia)] { metrics.check(a,b) }
        }
    }
    func testConfigurationTypesDefaultsAndOriginalCar() throws {
        var metrics = EngineMetrics()
        for (n,o) in try Self.configurations() { compareSetup(n,o,metrics:&metrics) }
        let empty = "<params name='defaults'/>"
        let n = try DifferentialDefinition(parameters:ParameterDocument.parse(Data(empty.utf8)),section:"Differential",inputInertias:SIMD2(1.7,2.2))
        var o = RefDifferentialConfig(); XCTAssertEqual(ref_differential_config_xml(empty,"Differential",1.7,2.2,&o),1)
        compareSetup(n,o,metrics:&metrics)
        try EngineTestContext.withWorld { p,_,world in
            let gear = try RunningGearConfiguration(parameters:p)
            let front = try DifferentialDefinition(parameters:p,section:"Front Differential",inputInertias:SIMD2(gear.wheels[0].feedbackInertia,gear.wheels[1].feedbackInertia))
            let rear = try DifferentialDefinition(parameters:p,section:"Rear Differential",inputInertias:SIMD2(gear.wheels[2].feedbackInertia,gear.wheels[3].feedbackInertia))
            let center = try DifferentialDefinition(parameters:p,section:"Central Differential",inputInertias:SIMD2(front.feedbackInertia,rear.feedbackInertia))
            for (i,n) in [front,rear,center].enumerated() { compareSetup(n,try world.differentialConfiguration(i),metrics:&metrics) }
        }
        print("DIFFERENTIAL_CONFIG cases=16 fields=\(metrics.fields) maxAbsolute=\(metrics.worst)")
    }
    func testAllModesAndEngineReactionAgainstOriginal() throws {
        let configurations = try Self.configurations()
        try EngineTestContext.withWorld { _,engineDefinition,world in
            var metrics = EngineMetrics(), count = 0, calls = 0
            for (d,config) in configurations {
                let torques: [Float] = [-d.brakingLockingTorque-1,-d.brakingLockingTorque,-200,0,500,d.lockingTorque,d.lockingTorque+1]
                for drive in torques {
                    for spins: SIMD2<Float> in [SIMD2(0,0),SIMD2(-100,100),SIMD2(-200,-100),SIMD2(0,120),SIMD2(100,100),SIMD2(100,120),SIMD2(400,300)] {
                        for brake: Float in [-20,0,800,100000] {
                            for primary in [false,true] {
                                for fuel: Float in [0,30] {
                                    let a = DriveAxis(spin:spins.x,torque:-130,brakeTorque:brake,inertia:1.7)
                                    let b = DriveAxis(spin:spins.y,torque:270,brakeTorque:brake*0.7,inertia:2.2)
                                    var input = EngineTestContext.input(); input.fuel = fuel; input.randomSeed = UInt32(count+5)
                                    let random = ref_uniform_random(input.randomSeed)
                                    let o = try world.differentialStep(configuration:config,driveTorque:drive,
                                        first:RefDriveAxis(spin:a.spin,torque:a.torque,brakeTorque:a.brakeTorque,inertia:a.inertia),
                                        second:RefDriveAxis(spin:b.spin,torque:b.torque,brakeTorque:b.brakeTorque,inertia:b.inertia),
                                        outputInertias:SIMD2(2.4,3.7),primary:primary,engine:input)
                                    var engine = EngineState(speed:input.speed,torque:input.torque,pressure:input.pressure,exhaustPressure:input.exhaustPressure,smoke:input.smoke)
                                    var clutch = ClutchState(phase:.released,transfer:input.clutchTransfer), draws = 0
                                    let n = d.update(driveTorque:drive,first:a,second:b,outputInertias:SIMD2(2.4,3.7),primary:primary) { axle in
                                        engine.updateRPM(definition:engineDefinition,axleSpeed:axle,overallRatio:input.overallRatio,gear:Int(input.gear),clutch:&clutch,fuel:fuel) {
                                            draws += 1; return random
                                        }
                                    }
                                    compareAxes(n.first,n.second,o,metrics:&metrics)
                                    metrics.state(engine,fuel:fuel,clutch:clutch,reaction:0,o.engine)
                                    XCTAssertEqual(draws,primary && fuel>0 ? 1 : 0)
                                    calls += draws; count += 1
                                }
                            }
                        }
                    }
                }
            }
            print("DIFFERENTIAL_SWEEP samples=\(count) maxAbsolute=\(metrics.worst) randomDraws=\(calls)")
        }
    }
    func testIndependentDifferentialAndEngineSequences() throws {
        let configurations = try Self.configurations().enumerated().filter { $0.offset%2 == 0 && $0.offset<10 }.map(\.element)
        try EngineTestContext.withWorld { _,definition,world in
            var metrics = EngineMetrics()
            for (d,c) in configurations {
                var native = EngineState(definition:definition), original = RefEngineOutput(), fuel: Float = 30
                original.speed = definition.idleSpeed; original.fuel = 30; original.clutchPhase = 0
                var clutch = ClutchState(phase:.released,transfer:1)
                var spin = SIMD2<Float>.zero, originalSpin = SIMD2<Float>.zero
                for tick in 0..<3000 {
                    let throttle: Float = tick%800<600 ? 0.9 : 0
                    let transfer: Float = tick%700<80 ? 0 : 1
                    let braking: Float = tick%900<200 ? 1100 : 0
                    let loads = SIMD2<Float>(180*sin(Float(tick)*0.013),210*cos(Float(tick)*0.017))
                    var input = EngineTestContext.input(speed:original.speed,torque:original.torque)
                    input.pressure = original.pressure; input.exhaustPressure = original.exhaustPressure; input.smoke = original.smoke
                    input.fuel = original.fuel; input.throttle = throttle; input.clutchTransfer = transfer; input.clutchPhase = original.clutchPhase
                    input.stages = 1; input.randomSeed = UInt32(tick+31337)
                    original = try world.engineStep(input)
                    input.speed = original.speed; input.torque = original.torque; input.fuel = original.fuel
                    let random = ref_uniform_random(input.randomSeed)
                    let o = try world.differentialStep(configuration:c,driveTorque:original.torque*5*min(transfer*3,1),
                        first:RefDriveAxis(spin:originalSpin.x,torque:loads.x,brakeTorque:braking,inertia:1.7),
                        second:RefDriveAxis(spin:originalSpin.y,torque:loads.y,brakeTorque:braking*0.8,inertia:2.2),
                        outputInertias:SIMD2(2.4,3.7),primary:true,engine:input)
                    original = o.engine; originalSpin = SIMD2(o.first.spin,o.second.spin)
                    clutch.transfer = transfer
                    native.updateTorque(definition:definition,throttle:throttle,fuel:&fuel)
                    let n = d.update(driveTorque:native.torque*5*min(transfer*3,1),
                        first:DriveAxis(spin:spin.x,torque:loads.x,brakeTorque:braking,inertia:1.7),
                        second:DriveAxis(spin:spin.y,torque:loads.y,brakeTorque:braking*0.8,inertia:2.2),
                        outputInertias:SIMD2(2.4,3.7),primary:true) { axle in
                            native.updateRPM(definition:definition,axleSpeed:axle,overallRatio:5,gear:1,clutch:&clutch,fuel:fuel) { random }
                        }
                    spin = SIMD2(n.first.spin,n.second.spin)
                    compareAxes(n.first,n.second,o,metrics:&metrics)
                    metrics.state(native,fuel:fuel,clutch:clutch,reaction:0,original)
                }
            }
            print("DIFFERENTIAL_SEQUENCE ticks=15000 modes=5 maxAbsolute=\(metrics.worst)")
        }
    }
}
