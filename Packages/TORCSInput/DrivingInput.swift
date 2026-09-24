// SPDX-License-Identifier: GPL-2.0-only
import TORCSSimulation

public struct ControllerSample:Sendable {
    public var values:[ControllerElement:Float]
    public var pressed:Set<ControllerElement>
    public init(_ values:[ControllerElement:Float]=[:],pressed:Set<ControllerElement>?=nil) {
        self.values=values;self.pressed=pressed ?? Set(ControllerElement.buttons.filter { (values[$0] ?? 0)>0.5 })
    }
    public subscript(_ element:ControllerElement) -> Float { values[element] ?? 0 }
}
/// Device input is collected outside simulation. Only action values and a gear
/// request become DriverCommand; no physical key code crosses that boundary.
public struct DrivingInput:Sendable {
    public private(set) var configuration=InputConfiguration.standard
    public private(set) var controllerReady=false
    private var held=Set<UInt16>(),previousButtons=Set<DrivingAction>()
    private var controller=ControllerSample()
    private var eventButtons=Set<DrivingAction>()
    public init() {}
    public mutating func configure(_ value:InputConfiguration) throws { try value.validate();configuration=value;releaseAll() }
    public func recognizes(_ code:UInt16) -> Bool { configuration.keyboard.values.contains { $0.contains { $0.code==code } } }
    public mutating func key(_ code:UInt16,pressed:Bool,repeating:Bool=false) -> DrivingAction? {
        let wasHeld=held.contains(code)
        if pressed,repeating,!wasHeld { return nil }
        if pressed { held.insert(code) } else { held.remove(code) }
        guard pressed,!repeating,!wasHeld else { return nil }
        return [.shiftUp,.shiftDown,.pause].first { configuration.keyboard[$0]!.contains { $0.code==code } }
    }
    public mutating func releaseAll() { held.removeAll();controller=ControllerSample();previousButtons.removeAll();eventButtons.removeAll();controllerReady=false }
    public mutating func releaseKeyboard() { held.removeAll() }
    public mutating func updateController(_ sample:ControllerSample?,acceptInput:Bool,detectEdges:Bool=true) -> [DrivingAction] {
        guard let sample,acceptInput else { controller=ControllerSample();controllerReady=false;previousButtons.removeAll();return [] }
        let pressed=Set(configuration.buttons.compactMap { action,element in sample.pressed.contains(element) ? action:nil })
        let previous=previousButtons;previousButtons=pressed
        controller=sample
        if !controllerReady {
            if controlsAreNeutral,pressed.isEmpty { controllerReady=true }
            return []
        }
        guard detectEdges else { return [] }
        return [.pause,.shiftDown,.shiftUp].filter { pressed.contains($0) && !previous.contains($0) }
    }
    public mutating func controllerButton(_ element:ControllerElement,pressed:Bool,acceptInput:Bool) -> DrivingAction? {
        guard let action=configuration.buttons.first(where:{$0.value==element})?.key else { return nil }
        let wasHeld=eventButtons.contains(action)
        if pressed { eventButtons.insert(action) } else { eventButtons.remove(action) }
        return acceptInput && controllerReady && pressed && !wasHeld ? action:nil
    }
    private func active(_ action:DrivingAction) -> Bool { configuration.keyboard[action]!.contains { held.contains($0.code) } }
    private var controlsAreNeutral:Bool {
        // Arming depends on physical position, not gain, response exponent or
        // vehicle speed, which could hide a substantially deflected control.
        for role in AnalogAction.allCases {
            let raw=controller[configuration.analog[role]!],curve=configuration.calibration[role]!
            guard raw.isFinite else { return false }
            let distance=role == .steering ? abs(raw):(curve.inverted ? 1-raw:raw)
            guard distance<=curve.deadZone+0.02 else { return false }
        }
        return true
    }
    private func analogValues(speed:Float) -> DriverCommand {
        func pedal(_ role:AnalogAction) -> Float { configuration.calibration[role]!.pedal(controller[configuration.analog[role]!]) }
        return DriverCommand(throttle:pedal(.throttle),brake:pedal(.brake),steering:configuration.calibration[.steering]!.steering(controller[configuration.analog[.steering]!],speed:speed),clutch:pedal(.clutch))
    }
    public func command(gear:Int,speed:Float=0) -> DriverCommand {
        let analog=controllerReady ? analogValues(speed:speed):DriverCommand()
        let left=active(.steerLeft),right=active(.steerRight)
        return DriverCommand(throttle:max(active(.throttle) ? 1:0,analog.throttle),brake:max(active(.brake) ? 1:0,analog.brake),
            steering:left || right ? (left ? 1:0)-(right ? 1:0):analog.steering,
            clutch:max(active(.clutch) ? 1:0,analog.clutch),gear:gear)
    }
}
