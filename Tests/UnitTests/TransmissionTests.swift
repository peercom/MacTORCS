// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSConfiguration
import TORCSTrack
import TORCSSimulation
import TORCSReferenceSupport

struct TransmissionMetrics {
    var values = EngineMetrics()
    mutating func axis(_ n: DriveAxis,_ o: RefDriveAxis) {
        for (a,b) in [(n.spin,o.spin),(n.torque,o.torque),(n.brakeTorque,o.brakeTorque),(n.inertia,o.inertia)] { values.check(a,b) }
    }
    mutating func state(_ n: TransmissionState,_ original: RefTransmissionState,throttle: Float) {
        var o = original
        XCTAssertEqual(n.gear,Int(o.gear)); XCTAssertEqual(n.clutch.phase.rawValue,o.clutchPhase)
        for (a,b) in [(n.clutch.transfer,o.clutchTransfer),(n.clutch.timeToRelease,o.timeToRelease),
                      (n.currentRatio,o.currentRatio),(n.currentInertia,o.currentInertia),(throttle,o.throttle)] { values.check(a,b) }
        withUnsafePointer(to:&o.wheelInputs) { p in
            p.withMemoryRebound(to:RefDriveAxis.self,capacity:4) { b in
                for i in 0..<4 { axis(n.wheelInputs[i],b[i]) }
            }
        }
        withUnsafePointer(to:&o.differentialInputs) { p in
            p.withMemoryRebound(to:RefDriveAxis.self,capacity:3) { b in
                for (i,a) in [n.frontInput,n.rearInput,n.centralInput].enumerated() { axis(a,b[i]) }
            }
        }
        withUnsafePointer(to:&o.differentialFeedback) { p in
            p.withMemoryRebound(to:RefDriveAxis.self,capacity:3) { b in
                for (i,a) in [n.frontFeedback,n.rearFeedback,n.centralFeedback].enumerated() { axis(a,b[i]) }
            }
        }
    }
    mutating func setup(_ n: TransmissionDefinition,_ original: RefTransmissionSetup) {
        var o = original
        XCTAssertEqual(n.layout.rawValue,o.layout); XCTAssertEqual(n.minimumGear,Int(o.minimumGear))
        XCTAssertEqual(n.maximumGear,Int(o.maximumGear)); XCTAssertEqual(n.gearOffset,Int(o.gearOffset)); XCTAssertEqual(n.gearCount,Int(o.gearCount))
        values.check(n.shiftTime,o.shiftTime)
        withUnsafePointer(to:&o.gears) { p in
            p.withMemoryRebound(to:RefGearSetup.self,capacity:10) { b in
                for i in 0..<10 {
                    let a = n.gears[i], r = b[i]
                    for (x,y) in [(a.ratio,r.ratio),(a.drivenInertia,r.drivenInertia),(a.freeInertia,r.freeInertia),(a.efficiency,r.efficiency)] { values.check(x,y) }
                }
            }
        }
        withUnsafePointer(to:&o.differentials) { p in
            p.withMemoryRebound(to:RefDifferentialConfig.self,capacity:3) { b in
                for (i,a) in [n.front,n.rear,n.central].enumerated() {
                    let r = b[i]
                    XCTAssertEqual(a?.type.rawValue ?? 0,r.type)
                    let fields: [(Float,Float)] = [(a?.inertia ?? 0,r.inertia),(a?.efficiency ?? 0,r.efficiency),(a?.ratio ?? 0,r.ratio),
                        (a?.minimumTorqueBias ?? 0,r.minimumTorqueBias),(a?.torqueBiasRange ?? 0,r.torqueBiasRange),
                        (a?.maximumSlipBias ?? 0,r.maximumSlipBias),(a?.lockingTorque ?? 0,r.lockingTorque),
                        (a?.brakingLockingTorque ?? 0,r.brakingLockingTorque),(a?.viscosity ?? 0,r.viscosity),(a?.feedbackInertia ?? 0,r.feedbackInertia)]
                    for (x,y) in fields { values.check(x,y) }
                }
            }
        }
    }
}

final class TransmissionTests: XCTestCase {
    static func xml(layout: String,variant: Int = 0,shiftTime: Float = 0.003) -> String {
        let ratios: [(String,Float)] = [("r",variant == 1 ? 0 : -2.9),("n",0),("1",3.1),("2",variant == 2 ? 0 : 2.3),("3",1.4),("4",1.1),("8",variant == 2 ? 0.75 : 0)]
        let gears = ratios.map { name,ratio in
            "<section name='\(name)'><attnum name='ratio' val='\(ratio)'/><attnum name='inertia' val='0.025'/><attnum name='efficiency' val='\(ratio == 0 ? 0 : variant == 1 ? 1.2 : 0.82)'/></section>"
        }.joined()
        let diffs = [("Front Differential","FREE",Float(2.1)),("Rear Differential","LIMITED SLIP",Float(3.9)),("Central Differential","VISCOUS COUPLER",Float(3.4))].map { name,type,ratio in
            "<section name='\(name)'><attstr name='type' val='\(type)'/><attnum name='ratio' val='\(ratio)'/><attnum name='efficiency' val='0.92'/><attnum name='inertia' val='0.17'/></section>"
        }.joined()
        return "<params name='transmission'><section name='Drivetrain'><attstr name='type' val='\(layout)'/></section><section name='Gearbox'><attnum name='shift time' val='\(shiftTime)'/><section name='gears'>\(gears)</section></section>\(diffs)</params>"
    }
    func testConfigurationAndInitialStateAgainstOriginal() throws {
        var metrics = TransmissionMetrics(), cases = 0
        try EngineTestContext.withWorld { p,e,world in
            let running = try RunningGearConfiguration(parameters:p)
            func check(_ parameters: ParameterDocument) throws {
                let d = try TransmissionDefinition(parameters:parameters,engine:e,runningGear:running)
                metrics.setup(d,try world.transmissionSetup())
                metrics.state(TransmissionState(definition:d),try world.transmissionState(),throttle:0)
                cases += 1
            }
            try check(p)
            for layout in ["RWD","FWD","4WD"] {
                for variant in 0..<3 {
                    let xml = Self.xml(layout:layout,variant:variant)
                    try world.configureTransmission(xml:xml)
                    try check(ParameterDocument.parse(Data(xml.utf8)))
                }
            }
            let empty = "<params name='defaults'/>"
            try world.configureTransmission(xml:empty); try check(ParameterDocument.parse(Data(empty.utf8)))
        }
        print("TRANSMISSION_CONFIG cases=\(cases) fields=\(metrics.values.fields) maxAbsolute=\(metrics.values.worst)")
    }
    func testGearboxClutchBoundariesAndCachedInertiasAgainstOriginal() throws {
        var metrics = TransmissionMetrics(), shifts = 0, delayed = 0, limited = 0, ticks = 0
        for layout in ["RWD","FWD","4WD"] {
            for time: Float in [0,0.003,0.2] {
                try EngineTestContext.withWorld { p,e,world in
                    let r = try RunningGearConfiguration(parameters:p), xml = Self.xml(layout:layout,variant:2,shiftTime:time)
                    let d = try TransmissionDefinition(parameters:ParameterDocument.parse(Data(xml.utf8)),engine:e,runningGear:r)
                    try world.configureTransmission(xml:xml)
                    var n = TransmissionState(definition:d)
                    let gears = [1,8,2,0,-1,9,-2,4,3]
                    let transfers: [Float] = [1,0.99,0.990001,0.5,0,0.01]
                    for tick in 0..<1500 {
                        let requested = gears[(tick/17)%gears.count], transfer = transfers[tick%transfers.count]
                        var throttle: Float = tick%3 == 0 ? 0.1 : 0.9
                        let input = RefPowertrainControl(requestedGear:Int32(requested),updateEngineTorque:0,clutchTransfer:transfer,
                            throttle:throttle,dt:0.002,carFlags:0,randomSeed:1)
                        let oldGear = n.gear, oldPhase = n.clutch.phase
                        let o = try world.preparePowertrain(input)
                        n.updateGear(requested:requested,clutchTransfer:transfer,throttle:&throttle)
                        metrics.state(n,o,throttle:throttle)
                        if n.gear != oldGear { shifts += 1 }
                        if oldPhase == .releasing && requested != oldGear { XCTAssertEqual(n.gear,oldGear); delayed += 1 }
                        if throttle != input.throttle { limited += 1 }
                        ticks += 1
                    }
                    XCTAssertThrowsError(try world.configureTransmission(xml:xml),"Do not reset original component configuration during a sequence")
                }
            }
        }
        XCTAssertGreaterThan(shifts,0); XCTAssertGreaterThan(delayed,0); XCTAssertGreaterThan(limited,0)
        print("GEARBOX_SEQUENCE ticks=\(ticks) shifts=\(shifts) delayedRequests=\(delayed) throttleLimits=\(limited) fields=\(metrics.values.fields) maxAbsolute=\(metrics.values.worst)")
    }
    func testSingularConfigurationsRejected() throws {
        try EngineTestContext.withWorld { p,e,_ in
            let r = try RunningGearConfiguration(parameters:p)
            for xml in [Self.xml(layout:"invalid"),Self.xml(layout:"RWD").replacingOccurrences(of:"val='0.82'",with:"val='0'"),
                        Self.xml(layout:"4WD").replacingOccurrences(of:"val='3.4'",with:"val='0'")] {
                XCTAssertThrowsError(try TransmissionDefinition(parameters:ParameterDocument.parse(Data(xml.utf8)),engine:e,runningGear:r))
            }
        }
    }
    func testDrivenFourWheelSequencesAgainstOriginal() throws {
        let fixtures = try XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil))
        let trackParameters = try ParameterDocument.parse(Data(contentsOf:fixtures.appendingPathComponent("aalborg.xml")),entities:[
            "default-surfaces":Data(contentsOf:fixtures.appendingPathComponent("surfaces.xml")),
            "default-objects":Data(contentsOf:fixtures.appendingPathComponent("objects.xml"))],allowLegacyLatin1:true)
        let road = try TrackBuilder.buildRoad(parameters:trackParameters)
        var metrics = TransmissionMetrics(), wheelMetrics = RunningGearTests.Metrics(), draws = 0, freeCalls = 0, blended = 0
        for layout in ["original","RWD","FWD","4WD"] {
            try EngineTestContext.withWorld { p,e,world in
                let config = try RunningGearConfiguration(parameters:p)
                let tp: ParameterDocument
                if layout == "original" { tp = p }
                else { let xml = Self.xml(layout:layout); tp = try ParameterDocument.parse(Data(xml.utf8)); try world.configureTransmission(xml:xml) }
                let d = try TransmissionDefinition(parameters:tp,engine:e,runningGear:config)
                var n = TransmissionState(definition:d), engine = EngineState(definition:e), running = RunningGearState(configuration:config)
                var fuel = config.mass.initialFuel
                for tick in 0..<4000 {
                    let main = road.geometry.mainSegments[(tick/25)%road.geometry.mainSegments.count]
                    let local = TrackLocalPosition(segment:main,toStart:road.geometry.segments[main].extent*Float(tick%25)/25,
                        toRight:6+7*sin(Float(tick)*0.003))
                    let xy = road.geometry.localToGlobal(local), height = try road.geometry.height(at:xy,startingAt:main)
                    let origin = SIMD3(xy.x,xy.y,height+config.mass.centerOfGravity.z+0.2+0.1*sin(Float(tick)*0.03))
                    let roll: Float = 0.08*sin(Float(tick)*0.01), pitch: Float = 0.06*cos(Float(tick)*0.007)
                    let yaw = road.geometry.tangent(local)+0.1*sin(Float(tick)*0.008)
                    let body = SIMD3<Float>(25+12*sin(Float(tick)*0.002),2*cos(Float(tick)*0.003),0)
                    let yawVelocity: Float = 0.3*cos(Float(tick)*0.008), steer: Float = 0.15*sin(Float(tick)*0.004)
                    let steering = SIMD4(steer,steer*0.9,0,0)
                    let pressure: Float = tick%800<200 ? 7000000 : 0
                    let pressures = SIMD4(pressure,pressure,pressure*0.7,pressure*0.7), preSimulation = tick<100
                    var input = RefRunningGearInput()
                    input.worldPosition = RefTrackVector(x:origin.x,y:origin.y,z:origin.z)
                    input.bodyVelocity = RefTrackVector(x:body.x,y:body.y,z:body.z)
                    input.roll = roll; input.pitch = pitch; input.yaw = yaw; input.yawVelocity = yawVelocity
                    input.localTemperature = 288.15; input.localPressure = 96000; input.tireFactor = 2; input.dt = 0.002
                    input.mainSegment = Int32(main); input.skillLevel = 3; input.preSimulation = preSimulation ? 1 : 0
                    input.brakePressures = RefFourValues(frontRight:pressures.x,frontLeft:pressures.y,rearRight:pressures.z,rearLeft:pressures.w)
                    input.steering = RefFourValues(frontRight:steering.x,frontLeft:steering.y,rearRight:0,rearLeft:0)
                    let requested = [1,2,3,4,0,-1][(tick/500)%6], transfer: Float = tick%300<50 ? 0.5 : 1
                    var throttle: Float = tick%600<450 ? 0.9 : 0
                    let flags: UInt32 = tick>=3500 ? 0x200 : 0
                    let control = RefPowertrainControl(requestedGear:Int32(requested),updateEngineTorque:1,clutchTransfer:transfer,
                        throttle:throttle,dt:0.002,carFlags:flags,randomSeed:UInt32(tick+1777))
                    let prepared = try world.preparePowertrain(control)
                    n.updateGear(requested:requested,clutchTransfer:transfer,throttle:&throttle)
                    engine.updateTorque(definition:e,throttle:throttle,fuel:&fuel,carFlags:flags)
                    metrics.state(n,prepared,throttle:throttle)
                    metrics.values.state(engine,fuel:fuel,clutch:n.clutch,reaction:0,prepared.engine)
                    let random = ref_uniform_random(control.randomSeed)
                    var (original,o) = try world.stepDrivenGear(input)
                    try running.updateForces(worldPosition:origin,roll:roll,pitch:pitch,yaw:yaw,bodyVelocity:body,yawVelocity:yawVelocity,
                        carSegment:main,track:road.geometry,brakePressures:pressures,steering:steering,localTemperature:288.15,localPressure:96000,
                        skillLevel:3,tireFactor:2,preSimulation:preSimulation)
                    let feedback = running.driveFeedback()
                    var calls = 0
                    let spins = n.update(engineDefinition:e,engine:&engine,fuel:fuel,feedback:feedback,random:{ draws += 1; return random },freeAxle:{ axle in
                        calls += 1; XCTAssertEqual(axle,d.layout == .rear ? 0 : 1)
                        return running.freeAxleInputs(axle)
                    })
                    XCTAssertEqual(calls,d.layout == .all ? 0 : 1); freeCalls += calls
                    running.updateRotation(drivetrainSpins:spins)
                    metrics.state(n,o,throttle:throttle)
                    metrics.values.state(engine,fuel:fuel,clutch:n.clutch,reaction:0,o.engine)
                    let counts = try compareRunningGear(running,&original,tick:tick,preSimulation:preSimulation,metrics:&wheelMetrics)
                    blended += counts.blended
                    // Stop at the first divergent tick instead of generating thousands of cascading failures.
                    if metrics.values.worst != 0 || wheelMetrics.worst != 0 { XCTFail("First divergence: \(layout) tick \(tick)"); return }
                }
                XCTAssertLessThan(fuel,config.mass.initialFuel)
            }
        }
        XCTAssertGreaterThan(blended,0); XCTAssertEqual(draws,16000); XCTAssertEqual(freeCalls,8000)
        print("DRIVEN_GEAR_SEQUENCE ticks=16000 wheelTicks=64000 layouts=4 powertrainFields=\(metrics.values.fields) wheelFields=\(wheelMetrics.fields) maxAbsolute=\(max(metrics.values.worst,wheelMetrics.worst)) randomDraws=\(draws) freeAxleUpdates=\(freeCalls) blended=\(blended)")
    }
}
