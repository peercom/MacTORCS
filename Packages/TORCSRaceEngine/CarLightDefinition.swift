// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 grcar.cpp and grcarlight.cpp.
// Copyright (C) 2000 Eric Espie, 2001 Christophe Guionneau; upstream GPL-2.0-or-later.
import Foundation
import TORCSConfiguration

public enum CarLightType: Int, Sendable, CaseIterable {
    case unspecified=0,front=1,front2=2,rear=3,rear2=4,brake=5,brake2=6,reverse=7
    /// Original grcar maps only these five names. In particular, "reverse"
    /// and "rear2" fall through to unspecified despite constants in the header.
    public init(configurationName: String) {
        switch configurationName {
        case "head1":self = .front
        case "head2":self = .front2
        case "rear":self = .rear
        case "brake":self = .brake
        case "brake2":self = .brake2
        default:self = .unspecified
        }
    }
    public var textureName: String {
        switch self {
        case .front:return "frontlight1.rgb"
        case .front2:return "frontlight2.rgb"
        case .brake:return "breaklight1.rgb"
        case .brake2:return "breaklight2.rgb"
        default:return "rearlight1.rgb"
        }
    }
    /// grUpdateCarlight uses the command, not wheel temperature or brake torque.
    public func isOn(brakeCommand: Float,lightCommand: UInt32) -> Bool {
        switch self {
        case .brake,.brake2:return brakeCommand>0
        case .front:return lightCommand & 1 != 0
        case .front2:return lightCommand & 2 != 0
        case .rear:return lightCommand & 3 != 0
        default:return true
        }
    }
}

public struct CarLightDefinition: Sendable, Equatable {
    public let type: CarLightType
    public let position: SIMD3<Float>
    public let size: Float
    public init(type: CarLightType,position: SIMD3<Float>,size: Float) throws {
        guard position.x.isFinite,position.y.isFinite,position.z.isFinite,size.isFinite else {
            throw ParameterError.invalid("Nonfinite car light configuration")
        }
        self.type=type;self.position=position;self.size=size
    }
    public static func load(_ parameters: ParameterDocument) throws -> [Self] {
        let section=parameters.section("Graphic Objects/Light"),count=section?.sections.count ?? 0
        // Upstream has fixed arrays of fourteen entries and no overflow guard.
        guard count<=14 else { throw ParameterError.invalid("Car has more than fourteen original light slots") }
        return try (0..<count).map { i in
            // Preserve counted, numbered lookup rather than iterating child names.
            let entry=section?.section(String(i+1))
            return try Self(type:CarLightType(configurationName:entry?.string("type") ?? ""),
                position:SIMD3(entry?.number("xpos",default:0) ?? 0,entry?.number("ypos",default:0) ?? 0,entry?.number("zpos",default:0) ?? 0),
                size:entry?.number("size",default:0.2) ?? 0.2)
        }
    }
}
