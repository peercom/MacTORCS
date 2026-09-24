// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSConfiguration
import TORCSSimulation
import TORCSReferenceSupport

struct PitSetupMetrics {
    var fields=0
    mutating func check(_ n: PitSetup,_ o: RefPitSetup) {
        let original=withUnsafeBytes(of:o.values) { Array($0.bindMemory(to:RefPitSetupValue.self)) }
        XCTAssertEqual(n.values.count,original.count)
        for (a,b) in zip(n.values,original) {
            for (x,y) in [(a.value,b.value),(a.minimum,b.minimum),(a.maximum,b.maximum)] { XCTAssertEqual(x,y); fields += 1 }
        }
        let types=withUnsafeBytes(of:o.differentialTypes) { Array($0.bindMemory(to:Int32.self)) }
        XCTAssertEqual(n.differentialTypes.map(\.rawValue),types); fields += 3
    }
    static func reference(_ n: PitSetup) -> RefPitSetup {
        var out=RefPitSetup()
        withUnsafeMutableBytes(of:&out.values) { b in
            let values=b.bindMemory(to:RefPitSetupValue.self)
            for (i,v) in n.values.enumerated() { values[i] = .init(value:v.value,minimum:v.minimum,maximum:v.maximum) }
        }
        withUnsafeMutableBytes(of:&out.differentialTypes) { b in
            for i in 0..<3 { b.bindMemory(to:Int32.self)[i]=n.differentialTypes[i].rawValue }
        }
        return out
    }
    static func modified(_ base: PitSetup,variant: Int) -> PitSetup {
        var s=base
        for field in PitSetupField.allCases { for i in 0..<field.count {
            let current=base[field,i].value
            let delta=max(abs(current)*0.15,Float(0.01))
            let low=current-delta,high=current+delta
            let mode=(variant+field.rawValue+i)%5
            s[field,i] = .init(value:mode==0 ? low-delta : mode==1 ? high+delta : current+delta/2,
                minimum:mode==3 ? current:low,maximum:mode==3 ? current:high)
        } }
        // Safe ratios and suspension geometry for live-physics scenarios.
        for i in 0..<3 {
            if base[.differentialRatio,i].value>0 { s[.differentialRatio,i].minimum=max(0.5,s[.differentialRatio,i].minimum) }
            s[.maximumTorqueBias,i] = .init(value:0.01,minimum:0,maximum:0.04)
        }
        for i in 0..<4 {
            s[.packers,i] = .init(value:0.004+Float(variant%3)*0.001,minimum:0,maximum:0.02)
            s[.rideHeight,i] = .init(value:0.10+Float(variant%3)*0.005,minimum:0.08,maximum:0.15)
        }
        s[differential:0] = .free; s[differential:1] = .spool; s[differential:2] = .none // Upstream ignores requested type changes.
        return s
    }
}

final class PitSetupTests: XCTestCase {
    func testAdjustmentThresholdsAgainstOriginal() {
        var cases=0,fields=0,classified=0
        let epsilon=Float(0.0001)
        for low: Float in [-10,-1,0,1,10000] {
            for width: Float in [-1,-epsilon,0,epsilon.nextDown,epsilon,epsilon.nextUp,1] {
                for value: Float in [low-2,low,low+width/2,low+width,low+2] {
                    var n=PitSetupValue(value:value,minimum:low,maximum:low+width),o=RefPitSetupValue()
                    let changed=ref_adjust_pit_value(.init(value:value,minimum:low,maximum:low+width),&o)
                    XCTAssertEqual(n.adjust(),changed != 0); XCTAssertEqual(n.value,o.value)
                    XCTAssertEqual(n.minimum,o.minimum); XCTAssertEqual(n.maximum,o.maximum); cases += 1; fields += 4
                }
            }
        }
        for v in [PitSetupValue(value:.nan,minimum:0,maximum:1),.init(value:0,minimum:.nan,maximum:1),.init(value:0,minimum:0,maximum:.nan),.init(value:.infinity,minimum:0,maximum:1),.init(value:-.infinity,minimum:0,maximum:1)] {
            var n=v,o=RefPitSetupValue(); let flag=ref_adjust_pit_value(.init(value:v.value,minimum:v.minimum,maximum:v.maximum),&o)
            XCTAssertEqual(n.adjust(),flag != 0); fields += 1
            for (x,y) in [(n.value,o.value),(n.minimum,o.minimum),(n.maximum,o.maximum)] {
                if y.isNaN { XCTAssertTrue(x.isNaN); classified += 1 } else { XCTAssertEqual(x,y); fields += 1 }
            }
            cases += 1
        }
        print("PIT_ADJUST cases=\(cases) fields=\(fields) classified=\(classified) maxAbsolute=0")
    }
    func testOriginalCarSetupAndBoundsOnlyLoading() throws {
        let content=try ReferenceContent(fixtures:XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)))
        let parameters=try ParameterDocument.parse(Data(contentsOf:content.category)).merging(ParameterDocument.parse(Data(contentsOf:content.car)))
        let world=try ReferenceWorld(track:content.track,car:content.car,category:content.category)
        defer { world.close(); withExtendedLifetime(content) {} }
        var metrics=PitSetupMetrics(); metrics.check(PitSetup(parameters:parameters),try world.pitSetup())
        print("PIT_CAR_SETUP fields=\(metrics.fields) maxAbsolute=0")
    }
    func testCompleteMissingAndWrongTypeSetupLoading() throws {
        var metrics=PitSetupMetrics(),cases=0
        for variant in 0..<9 {
            var sections:[String:[String]]=[:]
            var n=PitSetup()
            for field in PitSetupField.allCases { for i in 0..<field.count {
                let slot=field.offset+i,p=field.parameter(i)
                n[field,i] = .init(value:Float(slot+100),minimum:Float(-slot-2),maximum:Float(slot+3))
                if (slot+variant)%4==0 { continue }
                let entry: String
                if (slot+variant)%7==0 { entry="<attstr name='\(p.key)' val='ignored'/>" }
                else {
                    let unit: String
                    switch field {
                    case .steeringLock,.camber,.toe,.caster,.wingAngle: unit="deg"
                    case .rideHeight,.packers,.thirdTravel: unit="mm"
                    case .brakePressure: unit="kPa"
                    default: unit=""
                    }
                    entry="<attnum name='\(p.key)' val='\(1+Float(slot)/100)' min='0' max='10' unit='\(unit)'/>"
                }
                sections[p.section,default:[]].append(entry)
            } }
            for (i,name) in ["Front","Rear","Central"].enumerated() {
                sections[name+" Differential",default:[]].append("<attstr name='type' val='\(["FREE","SPOOL","LIMITED SLIP","VISCOUS COUPLER","invalid"][(variant+i)%5])'/>")
            }
            func tree(_ prefix: String) -> String {
                let lead=prefix.isEmpty ? "":prefix+"/"
                let children=Set(sections.keys.filter { $0.hasPrefix(lead) && $0 != prefix }.compactMap { $0.dropFirst(lead.count).split(separator:"/").first.map(String.init) })
                return (sections[prefix] ?? []).joined()+children.sorted().map { "<section name='\($0)'>"+tree(lead+$0)+"</section>" }.joined()
            }
            let xml="<params name='pit'>"+tree("")+"</params>",p=try ParameterDocument.parse(Data(xml.utf8))
            for boundsOnly in [false,true] {
                var native=n,output=RefPitSetup()
                XCTAssertEqual(ref_pit_setup_xml(xml,PitSetupMetrics.reference(n),boundsOnly ? 1:0,&output),1)
                native.load(parameters:p,boundsOnly:boundsOnly); metrics.check(native,output); cases += 1
            }
        }
        print("PIT_XML cases=\(cases) fields=\(metrics.fields) maxAbsolute=0")
    }
    func testRepeatedWholeCarReconfigurationAgainstOriginal() throws {
        let content=try ReferenceContent(fixtures:XCTUnwrap(Bundle.module.url(forResource:"Fixtures",withExtension:nil)))
        let p=try ParameterDocument.parse(Data(contentsOf:content.category)).merging(ParameterDocument.parse(Data(contentsOf:content.car)))
        let world=try ReferenceWorld(track:content.track,car:content.car,category:content.category)
        defer { world.close(); withExtendedLifetime(content) {} }
        var native=try SingleVehicleSimulation(definition:VehicleDynamicsDefinition(parameters:p),road:ChassisTestContext.road())
        let base=native.vehicle.pitSetup
        var setup=PitSetupMetrics(),running=RunningGearTests.Metrics(),transmission=TransmissionMetrics()
        var extra=0
        for variant in 0..<40 {
            var request=PitSetupMetrics.modified(base,variant:variant)
            if variant==21 { request[.gearRatio,2] = .init(value:0,minimum:0,maximum:0) }
            var command=PitServiceCommand(setup:request,fuel:Float(variant%4-1)*40,repair:Int32(variant%4-1)*700,changeAllTires:variant%2==0)
            try native.updateCarStatus(fuel:30,damage:1000); try world.updateCarStatus(car:0,fuel:30,damage:1000)
            let result=try world.service(setup:PitSetupMetrics.reference(request),fuel:command.fuel,repair:command.repair,changeAllTires:command.changeAllTires)
            try native.service(&command)
            setup.check(command.setup,result); setup.check(native.vehicle.pitSetup,try world.pitSetup())
            let n=native.vehicle, d=n.definition
            running.gear(d.chassis.runningGear,try world.runningGear(),state:n.runningGear)
            transmission.setup(d.transmission,try world.transmissionSetup()); transmission.state(n.transmission,try world.transmissionState(),throttle:n.driverCommand.throttle)
            let sample=try world.sample(); XCTAssertEqual(Double(n.fuel),sample["fuel"]); XCTAssertEqual(Double(n.damage),sample["damage"]); extra += 2
            let driver=try world.driverSetup()
            for (a,b) in [(d.controls.steeringLock,driver.steeringLock),(d.controls.maximumSteeringSpeed,driver.maximumSteeringSpeed),
                          (d.controls.brakes.repartition,driver.repartition),(d.controls.brakes.coefficient,driver.brakeCoefficient),
                          (d.controls.brakes.clickValue,driver.clickValue)] { XCTAssertEqual(a,b); extra += 1 }
            XCTAssertEqual(d.controls.brakes.maximumClicks,driver.maximumClicks); extra += 1
            let aero=try world.aeroSetup()
            for (a,b) in [(d.chassis.aerodynamics.draftingCoefficient,aero.draftingCoefficient),(d.chassis.aerodynamics.frontWing.angle,aero.frontWing.angle),(d.chassis.aerodynamics.rearWing.angle,aero.rearWing.angle)] { XCTAssertEqual(a,b); extra += 1 }
            XCTAssertEqual(running.worst,0); XCTAssertEqual(transmission.values.worst,0)
        }
        print("PIT_RECONFIG cases=40 setupFields=\(setup.fields) runningFields=\(running.fields) transmissionFields=\(transmission.values.fields) extraFields=\(extra) maxAbsolute=0")
    }
}
