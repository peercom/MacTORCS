// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSConfiguration
import TORCSSimulation
import TORCSReferenceSupport

final class RunningGearTests: XCTestCase {
    struct Metrics {
        var fields = 0
        var worst: Float = 0
        mutating func check(_ native: Float, _ original: Float, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertTrue(native.isFinite && original.isFinite, name, file: file, line: line)
            XCTAssertEqual(native, original, accuracy: 1e-5 + 1e-6 * abs(original), name, file: file, line: line)
            worst = max(worst, abs(native-original)); fields += 1
        }
        mutating func suspension(_ n: SuspensionDefinition, _ o: RefSuspensionSetup) {
            for (name,a,b) in [
                ("springK", -n.springRate, o.springK), ("preload", n.preload/n.bellcrank, o.springPreload),
                ("rest", n.rest*n.bellcrank, o.springRest), ("travel", n.travel, o.travel), ("bellcrank", n.bellcrank, o.bellcrank),
                ("packers", n.packers, o.packers), ("slowBump", n.bump.slow, o.slowBump), ("fastBump", n.bump.fast, o.fastBump),
                ("bumpThreshold", n.bump.threshold, o.bumpThreshold), ("bumpOffset", (n.bump.slow-n.bump.fast)*n.bump.threshold, o.bumpOffset),
                ("slowRebound", n.rebound.slow, o.slowRebound), ("fastRebound", n.rebound.fast, o.fastRebound),
                ("reboundThreshold", n.rebound.threshold, o.reboundThreshold),
                ("reboundOffset", (n.rebound.slow-n.rebound.fast)*n.rebound.threshold, o.reboundOffset)] { check(a,b,name) }
        }
        mutating func gear(_ n: RunningGearConfiguration, _ original: RefRunningGear,state: RunningGearState? = nil) {
            var o = original
            let wheels = withUnsafePointer(to: &o.wheels) { $0.withMemoryRebound(to: RefWheelSetup.self, capacity: 4) { Array(UnsafeBufferPointer(start: $0, count: 4)) } }
            let axles = withUnsafePointer(to: &o.axles) { $0.withMemoryRebound(to: RefAxleSetup.self, capacity: 2) { Array(UnsafeBufferPointer(start: $0, count: 2)) } }
            for (a,b) in zip(n.axles, axles) {
                for (name,x,y) in [("axlePosition", a.position,b.position), ("axleInertia", a.inertia,b.inertia),
                                  ("rollCenter", a.rollCenter,b.rollCenter), ("antiRoll", a.antiRollSpring,b.antiRollSpring)] { check(x,y,name) }
                suspension(a.thirdSuspension,b.suspension)
            }
            for (index,pair) in zip(n.wheels,wheels).enumerated() {
                let (a,b)=pair
                let current=state?.wheels[index].thermal
                let f = a.force, t = a.thermal
                let fields: [(String,Float,Float)] = [
                    ("staticX", a.staticPosition.x,b.staticPosition.x), ("staticY", a.staticPosition.y,b.staticPosition.y), ("staticZ", a.staticPosition.z,b.staticPosition.z),
                    ("relativeX", a.initialRelativePosition.x,b.relativePosition.x), ("relativeY", a.initialRelativePosition.y,b.relativePosition.y), ("relativeZ", a.initialRelativePosition.z,b.relativePosition.z),
                    ("relativeAX", 0,b.relativeAngles.x), ("relativeAY", 0,b.relativeAngles.y), ("relativeAZ", 0,b.relativeAngles.z),
                    ("staticLoad", a.staticLoad,b.staticLoad), ("rollCenter", a.rollCenter,b.rollCenter), ("inertia", a.inertia,b.inertia),
                    ("feedbackInertia", a.feedbackInertia,b.feedbackInertia), ("tireSpring", a.tireSpringRate,b.tireSpringRate),
                    ("rimRadius", a.rimRadius,b.rimRadius), ("tireHeight", a.tireHeight,b.tireHeight), ("treadThickness", a.treadThickness,b.treadThickness),
                    ("radius", f.radius,b.radius), ("mass", f.mass,b.mass), ("tireWidth", f.tireWidth,b.tireWidth), ("friction", f.friction,b.friction),
                    ("B", f.magicB,b.magicB), ("C", f.magicC,b.magicC), ("E", f.magicE,b.magicE),
                    ("loadMin", f.loadMinimum,b.loadMinimum), ("loadMax", f.loadMaximum,b.loadMaximum), ("loadK", f.loadExponent,b.loadExponent), ("opLoad", f.operatingLoad,b.operatingLoad),
                    ("camber", f.camber,b.camber), ("caster", f.caster,b.caster), ("toe", f.toe,b.toe),
                    ("brakeCoeff", a.brake.coefficient,b.brakeCoefficient), ("brakeRadius", a.brake.radius,b.brakeRadius), ("brakeInertia", a.brake.inertia,b.brakeInertia),
                    ("pressure", t.pressure,b.thermal.pressure), ("initialTemperature", t.initialTemperature,b.thermal.initialTemperature),
                    ("idealTemperature", t.idealTemperature,b.thermal.idealTemperature), ("treadMass", t.treadMass,b.thermal.treadMass),
                    ("baseMass", t.baseMass,b.thermal.baseMass), ("gasMass", t.gasMass,b.thermal.gasMass),
                    ("surface", t.convectionSurface,b.thermal.convectionSurface), ("hysteresis", t.hysteresisFactor,b.thermal.hysteresisFactor), ("wearFactor", t.wearFactor,b.thermal.wearFactor),
                    ("currentPressure", current?.pressure ?? t.pressure,b.thermalState.pressure), ("currentTemperature", current?.temperature ?? t.initialTemperature,b.thermalState.temperature),
                    ("graining", current?.graining ?? 0,b.thermalState.graining), ("grip", current?.grip ?? 1,b.thermalState.grip)]
                for (name,x,y) in fields { check(x,y,name) }
                XCTAssertEqual(b.thermalState.wear,current?.wear ?? 0)
                suspension(a.suspension,b.suspension)
            }
        }
    }
    static func xml(variant v: Int) -> String {
        func section(_ name: String, _ values: [(String,Float)]) -> String {
            "<section name='\(name)'>" + values.map { "<attnum name='\($0.0)' val='\($0.1)'/>" }.joined() + "</section>"
        }
        var sections = [section("Car", [("mass", 1100 + Float(v)*37), ("GC height", 0.35), ("front-rear weight repartition", 0.56),
                                      ("front right-left weight repartition", 0.48), ("rear right-left weight repartition", 0.53)])]
        for (i,end) in ["Front","Rear"].enumerated() {
            sections.append(section(end + " Axle", [("xpos", i == 0 ? 1.4 : -1.1), ("inertia", 0.32), ("roll center height", 0.24),
                ("suspension course", 0.35), ("bellcrank", [Float(0.7), 1, 1.6][v%3]), ("spring", 46000),
                ("slow bump", 2200), ("slow rebound", 3400)]))
            sections.append(section(end + " Anti-Roll Bar", [("spring", Float(18000 + i*13000))]))
        }
        for (i,name) in ["Front Right","Front Left","Rear Right","Rear Left"].enumerated() {
            let f = Float(i)
            var values: [(String,Float)] = [("pressure", 230000+Float(v)*1700), ("rim diameter", 0.33+0.01*f), ("tire width", 0.19+f*0.01),
                ("tire height-width ratio", 0.64), ("mu", 1.1), ("inertia", 1.7+0.1*f), ("ypos", i%2 == 0 ? -0.75 : 0.78),
                ("ride height", 0.17), ("toe", -0.004+f*0.003), ("camber", -0.07+f*0.01), ("caster", 0.07), ("stiffness", 27+f),
                ("dynamic friction", [Float(-0.5),0.8,1.8][v%3]), ("elasticity factor", [Float(-0.2),0.7,1.3][v%3]),
                ("load factor min", [Float(1.2),0.8,0.2][v%3]), ("load factor max", [Float(0.2),1.6,2.1][v%3]),
                ("mass", v%2 == 0 ? 20 : 5), ("tread thickness", 0.006), ("rim mass", 7), ("hysteresis", 1.1), ("wear", 0.9), ("ideal temperature", 365)]
            if v%2 == 0 { values.append(("operating load", 4200+f*30)) }
            sections.append(section(name + " Wheel", values))
            sections.append(section(name + " Suspension", [("spring", 140000+f*15000), ("suspension course", 0.45),
                ("bellcrank", [Float(0.5),1,1.7][v%3]), ("packers", 0.02), ("slow bump", 2100), ("fast bump", 900),
                ("slow rebound", 4200), ("fast rebound", 1700), ("fast bump threshold", 0.4), ("fast rebound threshold", 0.6)]))
            sections.append(section(name + " Brake", [("disk diameter", 0.24), ("piston area", 0.0025), ("mu", 0.36), ("inertia", 0.23)]))
        }
        return "<params name='running-gear'>" + sections.joined() + "</params>"
    }
    static func context(_ n: VehicleMassProperties) -> RefMassProperties {
        var c = RefMassProperties()
        c.cgX = n.centerOfGravity.x; c.cgY = n.centerOfGravity.y; c.cgZ = n.centerOfGravity.z
        c.frontRightLoad = n.staticWheelLoads.x; c.frontLeftLoad = n.staticWheelLoads.y
        c.rearRightLoad = n.staticWheelLoads.z; c.rearLeftLoad = n.staticWheelLoads.w
        return c
    }
    func testOriginal155DTMConfiguration() throws {
        let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let content = try ReferenceContent(fixtures: fixtures)
        let p = try ParameterDocument.parse(Data(contentsOf: content.category)).merging(ParameterDocument.parse(Data(contentsOf: content.car)))
        let n = try RunningGearConfiguration(parameters: p)
        let world = try ReferenceWorld(track: content.track, car: content.car, category: content.category)
        defer { world.close(); withExtendedLifetime(content) {} }
        var metrics = Metrics(); metrics.gear(n, try world.runningGear())
        print("RUNNING_GEAR_CAR fields=\(metrics.fields) maxAbsolute=\(metrics.worst)")
    }
    func testDefaultsClampsAndAsymmetricConfiguration() throws {
        var metrics = Metrics(), fallback = 0
        for xml in ["<params name='defaults'/>"] + (0..<12).map(Self.xml) {
            let n = try RunningGearConfiguration(parameters: ParameterDocument.parse(Data(xml.utf8)))
            var original = RefRunningGear()
            XCTAssertEqual(ref_running_gear_xml(xml, Self.context(n.mass), &original), 1)
            metrics.gear(n,original)
            for w in n.wheels {
                // Both initialization-order quirks matter to later integration.
                XCTAssertEqual(w.initialRelativePosition.z,w.force.radius)
                XCTAssertEqual(w.feedbackInertia,w.inertia+n.axles[0].inertia/2)
                XCTAssertNotEqual(w.inertia,w.inertia+w.brake.inertia)
                if w.thermal.baseMass == 3 { fallback += 1 }
            }
        }
        XCTAssertGreaterThan(fallback,0)
        print("RUNNING_GEAR_AUTHORED cases=13 fields=\(metrics.fields) maxAbsolute=\(metrics.worst) massFallbacks=\(fallback)")
    }
    func testSingularConfigurationRejected() throws {
        for (section,name,value) in [("Front Right Wheel","tire width", "0"), ("Front Left Wheel","pressure","0"),
                                      ("Rear Right Suspension","bellcrank","0"), ("Rear Left Wheel","mass","0"),
                                      ("Front Axle","inertia","-1")] {
            let xml = "<params name='invalid'><section name='\(section)'><attnum name='\(name)' val='\(value)'/></section></params>"
            XCTAssertThrowsError(try RunningGearConfiguration(parameters: ParameterDocument.parse(Data(xml.utf8))))
        }
    }
}
