// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import TORCSConfiguration
import TORCSSimulation

extension DriverCommand {
    var reference: RefDriverCommand { .init(throttle:throttle,brake:brake,steering:steering,clutch:clutch,gear:Int32(gear),brakeRepartitionClicks:brakeRepartitionClicks) }
}
struct DriverMetrics {
    var values = EngineMetrics()
    mutating func command(_ n: DriverCommand,_ o: RefDriverCommand) {
        values.check(n.throttle,o.throttle); values.check(n.brake,o.brake); values.check(n.steering,o.steering); values.check(n.clutch,o.clutch)
        XCTAssertEqual(n.gear,Int(o.gear)); XCTAssertEqual(n.brakeRepartitionClicks,o.brakeRepartitionClicks)
    }
    mutating func setup(_ n: DriverControlDefinition,_ o: RefDriverSetup) {
        for (a,b) in [(n.steeringLock,o.steeringLock),(n.maximumSteeringSpeed,o.maximumSteeringSpeed),(n.brakes.repartition,o.repartition),
                      (n.brakes.coefficient,o.brakeCoefficient),(n.brakes.clickValue,o.clickValue)] { values.check(a,b) }
        XCTAssertEqual(n.brakes.maximumClicks,o.maximumClicks)
    }
}
final class DriverControlTests: XCTestCase {
    func testConfigurationAgainstOriginal() throws {
        var metrics = DriverMetrics()
        let bodies = ["", "<section name='Steer'><attnum name='steer lock' val='30' unit='deg'/><attnum name='max steer speed' val='1.7'/></section>",
            "<section name='Brake System'><attnum name='front-rear brake repartition' val='1.2'/><attnum name='max pressure' val='12000000'/><attnum name='brake repartition offset per click' val='0.017'/><attnum name='brake repartition max clicks' val='12.7'/></section>"]
        for body in bodies {
            let xml = "<params name='controls'>\(body)</params>"
            let n = try DriverControlDefinition(parameters:ParameterDocument.parse(Data(xml.utf8)))
            var o = RefDriverSetup(); XCTAssertEqual(ref_driver_config_xml(xml,&o),1); metrics.setup(n,o)
        }
        try EngineTestContext.withWorld { p,_,world in metrics.setup(try DriverControlDefinition(parameters:p),try world.driverSetup()) }
        XCTAssertEqual(metrics.values.worst,0)
        print("DRIVER_CONFIG fields=\(metrics.values.fields) maxAbsolute=\(metrics.values.worst)")
    }
    func testControlCheckingAgainstOriginal() {
        var metrics = DriverMetrics(), cases = 0
        let values: [Float] = [-Float.infinity,-3,-1,-0.1,0,0.05,0.2,0.7,1,2,Float.infinity,Float.nan]
        for flags: UInt32 in [0,0x100,0x200,0x800,0x300,0x900,0xA00] {
            for speed: Float in [-10,30,Float(30).nextUp,90] {
                for right: Float in [0,6,Float(6).nextUp,12] {
                    for (i,x) in values.enumerated() {
                        let input = DriverCommand(throttle:x,brake:values[(i+3)%values.count],steering:values[(i+6)%values.count],
                            clutch:values[(i+9)%values.count],gear:i-3,brakeRepartitionClicks:Int32(i*10-50))
                        let n = input.checked(carFlags:flags,longitudinalSpeed:speed,toRight:right,trackWidth:12)
                        let o = ref_check_control(input.reference,flags,speed,right,12)
                        metrics.command(n,o.command); metrics.values.check(n.clutchTransfer,o.clutchTransfer); cases += 1
                    }
                }
            }
        }
        XCTAssertEqual(metrics.values.worst,0)
        print("DRIVER_COMMAND cases=\(cases) fields=\(metrics.values.fields) maxAbsolute=\(metrics.values.worst)")
    }
}
