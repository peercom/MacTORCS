// SPDX-License-Identifier: GPL-2.0-only
import GameController

/// Main-actor polling keeps framework objects out of physics. Latch one device
/// until it disconnects; input from another pad never silently takes over.
@MainActor public final class GameControllerSource {
    private var selected:GCController?
    public private(set) var name:String?
    private let devices:@MainActor ()->[GCController]
    public var onButtonChange:((ControllerElement,Bool)->Void)?
    public init(devices:@escaping @MainActor ()->[GCController] = { GCController.controllers() }) {
        self.devices=devices;GCController.shouldMonitorBackgroundEvents=false
    }
    public func poll() -> (sample:ControllerSample?,changed:Bool) {
        let available=devices().filter { $0.extendedGamepad != nil }
        let old=selected
        if let selected,!available.contains(where:{$0 === selected}) { self.selected=nil }
        if selected==nil { selected=available.first }
        if old !== selected {
            if let old { for element in ControllerElement.buttons { Self.button(element,on:old)?.pressedChangedHandler=nil } }
            if let selected {
                selected.handlerQueue = .main
                for element in ControllerElement.buttons {
                    Self.button(element,on:selected)?.pressedChangedHandler={ [weak self,weak selected] _,_,pressed in
                        MainActor.assumeIsolated {
                            guard let self,let selected,self.selected === selected else { return }
                            self.onButtonChange?(element,pressed)
                        }
                    }
                }
            }
        }
        name=selected?.vendorName ?? (selected==nil ? nil:"Game controller")
        return (selected.map(Self.sample),old !== selected)
    }
    private static func button(_ element:ControllerElement,on controller:GCController) -> GCControllerButtonInput? {
        guard let p=controller.extendedGamepad else { return nil }
        switch element {
        case .leftTrigger:return p.leftTrigger;case .rightTrigger:return p.rightTrigger
        case .leftShoulder:return p.leftShoulder;case .rightShoulder:return p.rightShoulder
        case .south:return p.buttonA;case .east:return p.buttonB;case .west:return p.buttonX;case .north:return p.buttonY
        case .menu:return p.buttonMenu;case .dpadUp:return p.dpad.up;case .dpadDown:return p.dpad.down
        default:return nil
        }
    }
    public static func sample(_ controller:GCController) -> ControllerSample {
        // SDK capture() freezes all axes/buttons together; tests use Apple's
        // writable snapshot controllers, never synthetic OS input events.
        let snapshot=controller.capture()
        guard let p=snapshot.extendedGamepad else { return ControllerSample() }
        let pressed=Set(ControllerElement.buttons.filter { button($0,on:snapshot)?.isPressed==true })
        return ControllerSample([.leftX:p.leftThumbstick.xAxis.value,.rightX:p.rightThumbstick.xAxis.value,.dpadX:p.dpad.xAxis.value,
            .leftTrigger:p.leftTrigger.value,.rightTrigger:p.rightTrigger.value,.leftShoulder:p.leftShoulder.value,.rightShoulder:p.rightShoulder.value,
            .south:p.buttonA.value,.east:p.buttonB.value,.west:p.buttonX.value,.north:p.buttonY.value,.menu:p.buttonMenu.value,
            .dpadUp:p.dpad.up.value,.dpadDown:p.dpad.down.value],pressed:pressed)
    }
}
