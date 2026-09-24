// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 rttrack.cpp RtInitCarPitSetup and
// simuv2/simu.cpp SimAdjustPitCarSetupParam.
// Copyright (C) Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation
import TORCSConfiguration

public struct PitSetupValue: Sendable, Equatable {
    public var value, minimum, maximum: Float
    public init(value: Float = 0,minimum: Float = 0,maximum: Float = 0) {
        self.value=value; self.minimum=minimum; self.maximum=maximum
    }
    /// False means the live setting must remain unchanged. The requested value
    /// still becomes maximum, including for ranges narrower than 0.0001f.
    @discardableResult public mutating func adjust() -> Bool {
        if abs(maximum-minimum)>=Float(0.0001) {
            if value>maximum { value=maximum } else if value<minimum { value=minimum }
            return true
        }
        value=maximum; return false
    }
}
public enum PitSetupField: Int, CaseIterable, Sendable {
    case steeringLock, camber, toe, rideHeight, caster, brakePressure, brakeRepartition
    case spring, packers, slowBump, slowRebound, fastBump, fastRebound, bumpThreshold, reboundThreshold
    case antiRoll, thirdSpring, thirdBump, thirdRebound, thirdTravel, gearRatio, wingAngle
    case differentialRatio, minimumTorqueBias, maximumTorqueBias, slipBias, lockingTorque, brakingLockingTorque
    public var count: Int {
        switch self {
        case .steeringLock,.brakePressure,.brakeRepartition: return 1
        case .antiRoll,.thirdSpring,.thirdBump,.thirdRebound,.thirdTravel,.wingAngle: return 2
        case .differentialRatio,.minimumTorqueBias,.maximumTorqueBias,.slipBias,.lockingTorque,.brakingLockingTorque: return 3
        case .gearRatio: return 8
        default: return 4
        }
    }
    public var offset: Int { Self.allCases.prefix(rawValue).reduce(0) { $0+$1.count } }
    public func parameter(_ index: Int) -> (section: String,key: String) {
        precondition((0..<count).contains(index))
        let wheels=["Front Right","Front Left","Rear Right","Rear Left"], axles=["Front","Rear"]
        switch self {
        case .steeringLock: return ("Steer","steer lock")
        case .camber: return (wheels[index]+" Wheel","camber")
        case .toe: return (wheels[index]+" Wheel","toe")
        case .rideHeight: return (wheels[index]+" Wheel","ride height")
        case .caster: return (wheels[index]+" Wheel","caster")
        case .brakePressure: return ("Brake System","max pressure")
        case .brakeRepartition: return ("Brake System","front-rear brake repartition")
        case .spring: return (wheels[index]+" Suspension","spring")
        case .packers: return (wheels[index]+" Suspension","packers")
        case .slowBump: return (wheels[index]+" Suspension","slow bump")
        case .slowRebound: return (wheels[index]+" Suspension","slow rebound")
        case .fastBump: return (wheels[index]+" Suspension","fast bump")
        case .fastRebound: return (wheels[index]+" Suspension","fast rebound")
        case .bumpThreshold: return (wheels[index]+" Suspension","fast bump threshold")
        case .reboundThreshold: return (wheels[index]+" Suspension","fast rebound threshold")
        case .antiRoll: return (axles[index]+" Anti-Roll Bar","spring")
        case .thirdSpring: return (axles[index]+" Axle","spring")
        case .thirdBump: return (axles[index]+" Axle","slow bump")
        case .thirdRebound: return (axles[index]+" Axle","slow rebound")
        case .thirdTravel: return (axles[index]+" Axle","suspension course")
        case .gearRatio: return ("Gearbox/gears/\(index+1)","ratio")
        case .wingAngle: return (axles[index]+" Wing","angle")
        default:
            let names=["ratio","min torque bias","max torque bias","max slip bias","locking input torque","locking brake input torque"]
            return (["Front","Rear","Central"][index]+" Differential",names[rawValue-Self.differentialRatio.rawValue])
        }
    }
}
public struct PitSetup: Sendable {
    public private(set) var values=[PitSetupValue](repeating:.init(),count:89)
    public private(set) var differentialTypes=[DifferentialType](repeating:.none,count:3)
    public init() {}
    public subscript(differential index: Int) -> DifferentialType {
        get { precondition((0..<3).contains(index)); return differentialTypes[index] }
        set { precondition((0..<3).contains(index)); differentialTypes[index]=newValue }
    }
    public init(parameters: ParameterDocument) { load(parameters:parameters) }
    public subscript(_ field: PitSetupField,_ index: Int = 0) -> PitSetupValue {
        get { precondition((0..<field.count).contains(index)); return values[field.offset+index] }
        _modify { precondition((0..<field.count).contains(index)); yield &values[field.offset+index] }
    }
    /// Missing/wrong-type entries reset value only; original boundary lookup
    /// fails without touching the existing limits. Differential types always load.
    public mutating func load(parameters: ParameterDocument,boundsOnly: Bool = false) {
        for field in PitSetupField.allCases { for index in 0..<field.count {
            let p=field.parameter(index)
            if case .number(let n) = parameters.section(p.section)?.parameters[p.key] {
                if !boundsOnly { self[field,index].value=n.value }
                self[field,index].minimum=n.minimum; self[field,index].maximum=n.maximum
            } else if !boundsOnly { self[field,index].value=0 }
        } }
        for (i,name) in ["Front","Rear","Central"].enumerated() {
            switch parameters.section(name+" Differential")?.string("type",default:"NONE") ?? "NONE" {
            case "SPOOL": differentialTypes[i] = .spool
            case "FREE": differentialTypes[i] = .free
            case "LIMITED SLIP": differentialTypes[i] = .limitedSlip
            case "VISCOUS COUPLER": differentialTypes[i] = .viscous
            default: differentialTypes[i] = .none
            }
        }
    }
}
public struct PitServiceCommand: Sendable {
    public var fuel: Float
    public var repair: Int32
    public var changeAllTires: Bool
    public var setup: PitSetup
    public init(setup: PitSetup,fuel: Float = 0,repair: Int32 = 0,changeAllTires: Bool = false) {
        self.setup=setup; self.fuel=fuel; self.repair=repair; self.changeAllTires=changeAllTires
    }
}
