// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import CReference
import GameController
import TORCSInput
import TORCSRaceEngine
import TORCSSimulation

@MainActor private final class SnapshotDeviceList {
    var controllers:[GCController]
    init(_ controllers:[GCController]) { self.controllers=controllers }
}

final class DrivingInputTests:XCTestCase {
    func testOriginalHumanJoystickBranches() {
        var count=0,maximum:Float=0
        for left in [false,true] { for value:Float in [-2,-1,-0.9,-0.5,-0.05,0,0.05,0.5,0.9,1,2] {
            for dead:Float in [0,0.05,0.2,0.5] { for gain:Float in [0.1,1,2] { for exponent:Float in [0.2,1,2,4] {
                for sensitivity:Float in [0,0.1,1] { for speed:Float in [0,0.5,20,100] {
                    let minimum:Float=left ? -1:0,maximumValue:Float=left ? 0:1
                    let expected=ref_human_axis(left ? 0:1,value,minimum,maximumValue,0,dead,gain,exponent,sensitivity,speed)
                    let actual=AxisCalibration.halfAxis(value,minimum:minimum,maximum:maximumValue,deadZone:dead,gain:gain,exponent:exponent,speedSensitivity:sensitivity,speed:speed,left:left)
                    maximum=max(maximum,abs(actual-expected));XCTAssertEqual(actual,expected);count += 1
                } }
            } } }
        } }
        for value:Float in [-2,-1,-0.1,0,0.01,0.2,0.5,0.9,1,2] { for dead:Float in [0,0.05,0.5] {
            for gain:Float in [0.1,1,2] { for exponent:Float in [0.2,1,2,4] {
                let expected=ref_human_axis(2,value,dead,1,dead,0,gain,exponent,0,0)
                let actual=AxisCalibration.pedalAxis(value,minimum:dead,maximum:1,minimumValue:dead,gain:gain,exponent:exponent)
                maximum=max(maximum,abs(actual-expected));XCTAssertEqual(actual,expected);count += 1
            } }
        } }
        print("HUMAN_AXIS samples=\(count) maximumAbsolute=\(maximum)")
    }
    func testKeyboardAliasesEdgesAndPauseRelease() throws {
        var input=DrivingInput()
        XCTAssertNil(input.key(126,pressed:true));XCTAssertNil(input.key(13,pressed:true))
        _=input.key(126,pressed:false);XCTAssertEqual(input.command(gear:1).throttle,1)
        _=input.key(13,pressed:false);XCTAssertEqual(input.command(gear:1).throttle,0)
        XCTAssertEqual(input.key(14,pressed:true),.shiftUp);XCTAssertNil(input.key(14,pressed:true,repeating:true));XCTAssertNil(input.key(14,pressed:true))
        _=input.key(14,pressed:false);XCTAssertEqual(input.key(14,pressed:true),.shiftUp)
        _=input.key(123,pressed:true);_ = input.key(124,pressed:true);XCTAssertEqual(input.command(gear:1).steering,0)
        input.releaseAll();_ = input.key(13,pressed:true,repeating:true);XCTAssertEqual(input.command(gear:1).throttle,0)
        var config=input.configuration;config.keyboard[.throttle]=[KeyBinding(17,"T")];try input.configure(config)
        XCTAssertFalse(input.recognizes(13));XCTAssertTrue(input.recognizes(17))
        _=input.key(17,pressed:true);XCTAssertEqual(input.command(gear:4).throttle,1);XCTAssertEqual(input.command(gear:4).gear,4)
    }
    func testControllerNeutralGateFocusEdgesAndMixing() throws {
        var input=DrivingInput()
        let held=ControllerSample([.rightTrigger:1,.rightShoulder:1])
        XCTAssertTrue(input.updateController(held,acceptInput:true).isEmpty)
        XCTAssertFalse(input.controllerReady);XCTAssertEqual(input.command(gear:1).throttle,0)
        _=input.updateController(ControllerSample(),acceptInput:true);XCTAssertTrue(input.controllerReady)
        XCTAssertEqual(input.updateController(held,acceptInput:true),[.shiftUp])
        XCTAssertTrue(input.updateController(held,acceptInput:true).isEmpty);XCTAssertEqual(input.command(gear:1).throttle,1)
        _=input.updateController(ControllerSample([.leftX:0.5,.leftTrigger:0.6]),acceptInput:true)
        XCTAssertLessThan(input.command(gear:1).steering,0);XCTAssertEqual(input.command(gear:1).brake,0.6)
        _=input.key(123,pressed:true);XCTAssertEqual(input.command(gear:1).steering,1)
        _=input.updateController(held,acceptInput:false);XCTAssertFalse(input.controllerReady)
        input.releaseAll();_ = input.updateController(ControllerSample(),acceptInput:true,detectEdges:false)
        XCTAssertEqual(input.controllerButton(.rightShoulder,pressed:true,acceptInput:true),.shiftUp)
        XCTAssertNil(input.controllerButton(.rightShoulder,pressed:true,acceptInput:true))
        XCTAssertNil(input.controllerButton(.rightShoulder,pressed:false,acceptInput:true))
        XCTAssertEqual(input.controllerButton(.rightShoulder,pressed:true,acceptInput:true),.shiftUp)
        input.releaseAll();XCTAssertNil(input.controllerButton(.menu,pressed:true,acceptInput:true))
        _=input.updateController(nil,acceptInput:true);XCTAssertFalse(input.controllerReady)
        var curve=AxisCalibration();curve.inverted=true
        XCTAssertEqual(curve.steering(0.5,speed:0),0.5);XCTAssertEqual(curve.pedal(0.25),0.75)
        XCTAssertEqual(curve.pedal(.nan),0);XCTAssertEqual(curve.steering(.infinity,speed:0),0)
        var config=input.configuration
        config.calibration[.steering]!.linearity=4
        config.calibration[.steering]!.speedSensitivity=1
        try input.configure(config)
        _=input.updateController(ControllerSample([.leftX:0.3]),acceptInput:true)
        XCTAssertFalse(input.controllerReady)
        _=input.updateController(ControllerSample([.leftX:Float.nan]),acceptInput:true)
        XCTAssertFalse(input.controllerReady)
        _=input.updateController(ControllerSample(),acceptInput:true);XCTAssertTrue(input.controllerReady)
    }
    func testSettingsValidationAndAtomicPersistence() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let store=try InputConfigurationStore(directory:directory);XCTAssertEqual(try store.load(),.standard)
        var config=InputConfiguration.standard;config.calibration[.steering]!.inverted=true
        config.keyboard[.throttle]=[KeyBinding(17,"T")];try store.save(config);XCTAssertEqual(try store.load(),config)
        let file=directory.appendingPathComponent("input.json"),original=try Data(contentsOf:file)
        var invalid=config;invalid.keyboard[.brake]=[KeyBinding(17,"T")]
        XCTAssertThrowsError(try store.save(invalid));XCTAssertEqual(try Data(contentsOf:file),original)
        invalid=config;invalid.buttons[.pause] = .rightTrigger;XCTAssertThrowsError(try invalid.validate())
        invalid=config;invalid.version=2;XCTAssertThrowsError(try invalid.validate())
        invalid=config;invalid.calibration[.steering]!.linearity = .nan;XCTAssertThrowsError(try invalid.validate())
        try Data("{broken}".utf8).write(to:file);XCTAssertThrowsError(try store.load())
        try Data(repeating:32,count:65537).write(to:file);XCTAssertThrowsError(try store.load())
    }
    @MainActor func testAppleSnapshotAdapterSelectionAndButtonPulses() async throws {
        let first=GCController.withExtendedGamepad(),second=GCController.withExtendedGamepad()
        let pad=try XCTUnwrap(first.extendedGamepad)
        let devices=SnapshotDeviceList([first])
        var events:[Bool]=[]
        let source=GameControllerSource(devices:{devices.controllers})
        source.onButtonChange={ element,pressed in if element == .rightShoulder { events.append(pressed) } }
        XCTAssertTrue(source.poll().changed);XCTAssertFalse(source.poll().changed)
        pad.leftThumbstick.xAxis.setValue(-0.5);pad.rightTrigger.setValue(0.75);pad.buttonA.setValue(1)
        let sample=try XCTUnwrap(source.poll().sample)
        XCTAssertEqual(sample[.leftX],-0.5);XCTAssertEqual(sample[.rightTrigger],0.75);XCTAssertEqual(sample[.south],1)
        XCTAssertTrue(sample.pressed.contains(.south))
        pad.rightShoulder.setValue(1);pad.rightShoulder.setValue(0)
        for _ in 0..<100 { if events.count>=2 { break };try await Task.sleep(for:.milliseconds(10)) }
        XCTAssertEqual(events,[true,false])
        devices.controllers=[second,first];XCTAssertFalse(source.poll().changed);XCTAssertEqual(source.poll().sample?[.rightTrigger],0.75)
        devices.controllers=[second];XCTAssertTrue(source.poll().changed);XCTAssertEqual(source.poll().sample?[.rightTrigger],0)
        devices.controllers=[];XCTAssertTrue(source.poll().changed);XCTAssertNil(source.poll().sample)
        print("GAMECONTROLLER snapshotProfiles=2 buttonPulseEvents=\(events.count) connectedPhysicalControllers=\(GCController.controllers().count)")
    }
    func testMappedCommandsRetainFixedStepCadenceIndependence() throws {
        let original=try DrivingRuntimeTests().makeRuntime()
        var input=DrivingInput();_ = input.updateController(ControllerSample(),acceptInput:true)
        _=input.updateController(ControllerSample([.rightTrigger:0.7,.leftX:0.08]),acceptInput:true)
        let command=input.command(gear:1),expectedTicks=1000
        var direct=original
        for _ in 0..<expectedTicks { try direct.advance(elapsed:0.002,command:command) }
        for hz in [60,120,144,240] {
            var runtime=original
            for _ in 0..<(hz*2) { try runtime.advance(elapsed:1/Double(hz),command:command) }
            XCTAssertEqual(runtime.clock.tick,UInt64(expectedTicks));XCTAssertEqual(runtime.current.body.position,direct.current.body.position)
            XCTAssertEqual(runtime.current.body.orientation,direct.current.body.orientation);XCTAssertEqual(runtime.frame.rpm,direct.frame.rpm)
        }
    }
}
