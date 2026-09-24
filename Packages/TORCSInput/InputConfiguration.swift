// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import TORCSCore

public enum DrivingAction:String,Codable,CaseIterable,Sendable {
    case throttle,brake,clutch,steerLeft,steerRight,shiftUp,shiftDown,pause
    public var title:String { switch self {
    case .throttle:"Accelerate";case .brake:"Brake";case .clutch:"Clutch";case .steerLeft:"Steer left";case .steerRight:"Steer right"
    case .shiftUp:"Shift up";case .shiftDown:"Shift down";case .pause:"Pause / resume"
    } }
}
public enum ControllerElement:String,Codable,CaseIterable,Sendable {
    case leftX,rightX,dpadX,leftTrigger,rightTrigger,leftShoulder,rightShoulder,south,east,west,north,menu,dpadUp,dpadDown
    public static let axes:[Self]=[.leftX,.rightX,.dpadX]
    public static let buttons:[Self]=[.leftTrigger,.rightTrigger,.leftShoulder,.rightShoulder,.south,.east,.west,.north,.menu,.dpadUp,.dpadDown]
    public var title:String { switch self {
    case .leftX:"Left stick horizontal";case .rightX:"Right stick horizontal";case .dpadX:"D-pad horizontal"
    case .leftTrigger:"Left trigger";case .rightTrigger:"Right trigger";case .leftShoulder:"Left shoulder";case .rightShoulder:"Right shoulder"
    case .south:"South button (A / Cross)";case .east:"East button (B / Circle)";case .west:"West button (X / Square)";case .north:"North button (Y / Triangle)"
    case .menu:"Menu button";case .dpadUp:"D-pad up";case .dpadDown:"D-pad down"
    } }
}
public struct KeyBinding:Codable,Sendable,Equatable {
    public var code:UInt16
    public var label:String
    public init(_ code:UInt16,_ label:String) { self.code=code;self.label=label }
    public static func supported(_ code:UInt16) -> Bool { code<128 && ![53,54,55,56,57,58,59,60,61,62,63].contains(code) }
}
public enum AnalogAction:String,Codable,CaseIterable,Sendable { case steering,throttle,brake,clutch
    public var title:String { rawValue.capitalized }
}
public struct InputConfiguration:Codable,Sendable,Equatable {
    public var version=1
    public var keyboard:[DrivingAction:[KeyBinding]]
    public var analog:[AnalogAction:ControllerElement]
    public var buttons:[DrivingAction:ControllerElement]
    public var calibration:[AnalogAction:AxisCalibration]
    public static var standard:Self { .init(keyboard:[.throttle:[.init(126,"↑"),.init(13,"W")],.brake:[.init(125,"↓"),.init(1,"S"),.init(49,"Space")],.clutch:[.init(8,"C")],.steerLeft:[.init(123,"←"),.init(0,"A")],.steerRight:[.init(124,"→"),.init(2,"D")],.shiftUp:[.init(14,"E")],.shiftDown:[.init(12,"Q")],.pause:[.init(35,"P")]],analog:[.steering:.leftX,.throttle:.rightTrigger,.brake:.leftTrigger,.clutch:.south],buttons:[.shiftUp:.rightShoulder,.shiftDown:.leftShoulder,.pause:.menu],calibration:Dictionary(uniqueKeysWithValues:AnalogAction.allCases.map { ($0,AxisCalibration(deadZone:$0 == .steering ? 0.05:0)) })) }
    public func validate() throws {
        guard version==1,Set(keyboard.keys)==Set(DrivingAction.allCases),Set(analog.keys)==Set(AnalogAction.allCases),Set(calibration.keys)==Set(AnalogAction.allCases),Set(buttons.keys)==[.shiftUp,.shiftDown,.pause] else { throw InputError.invalid("Unsupported or incomplete input settings") }
        var used=Set<UInt16>()
        for action in DrivingAction.allCases {
            guard keyboard[action]!.count<=4 else { throw InputError.invalid("At most four keys can bind one action") }
            for key in keyboard[action]! {
                guard KeyBinding.supported(key.code),!key.label.isEmpty,key.label.count<=32 else { throw InputError.invalid("Unsupported key binding") }
                guard used.insert(key.code).inserted else { throw InputError.invalid("Key \(key.label) is assigned more than once") }
            }
        }
        for role in AnalogAction.allCases {
            let choices=role == .steering ? ControllerElement.axes:ControllerElement.buttons
            guard choices.contains(analog[role]!) else { throw InputError.invalid("Unsupported \(role.title) control") }
            try calibration[role]!.validate()
        }
        guard buttons.values.allSatisfy(ControllerElement.buttons.contains),Set(Array(analog.values)+Array(buttons.values)).count==7 else { throw InputError.invalid("Assign each controller control to only one action") }
    }
}
public enum InputError:Error,CustomStringConvertible { case invalid(String)
    public var description:String { switch self { case .invalid(let text):text } }
}
public struct InputConfigurationStore:Sendable {
    private let store:ConfigurationStore
    public init(directory:URL?=nil) throws { store=try ConfigurationStore(directory:directory) }
    public func load() throws -> InputConfiguration {
        let url=store.directory.appendingPathComponent("input.json")
        guard FileManager.default.fileExists(atPath:url.path) else { return .standard }
        guard try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0 <= 65536 else { throw InputError.invalid("Input settings exceed 64 KiB") }
        let data=try Data(contentsOf:url)
        guard data.count<=65536 else { throw InputError.invalid("Input settings exceed 64 KiB") }
        let config=try JSONDecoder().decode(InputConfiguration.self,from:data);try config.validate();return config
    }
    public func save(_ config:InputConfiguration) throws { try config.validate();try store.save(config,name:"input.json") }
}
