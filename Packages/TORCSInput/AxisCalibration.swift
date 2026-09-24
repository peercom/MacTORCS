// SPDX-License-Identifier: GPL-2.0-only
// Selected joystick arithmetic ported from TORCS 1.3.9 human.cpp.
// Copyright (C) 2000-2024 Eric Espie, Bernhard Wymann; upstream GPL-2.0-or-later.
import Foundation

public struct AxisCalibration:Codable,Sendable,Equatable {
    public var deadZone:Float
    public var sensitivity:Float=1
    public var linearity:Float=1
    public var speedSensitivity:Float=0
    public var inverted=false
    public init(deadZone:Float=0) { self.deadZone=deadZone }
    public func validate() throws {
        guard (0...0.5).contains(deadZone),(0.1...2).contains(sensitivity),(0.2...4).contains(linearity),(0...1).contains(speedSensitivity) else { throw InputError.invalid("Invalid axis calibration") }
    }
    public func steering(_ raw:Float,speed:Float) -> Float {
        guard raw.isFinite,speed.isFinite else { return 0 }
        let value=inverted ? -raw:raw,velocity=max(0,speed)
        let left=Self.halfAxis(value,minimum:-1,maximum:0,deadZone:deadZone,gain:sensitivity,exponent:linearity,speedSensitivity:speedSensitivity,speed:velocity,left:true)
        let right=Self.halfAxis(value,minimum:0,maximum:1,deadZone:deadZone,gain:sensitivity,exponent:linearity,speedSensitivity:speedSensitivity,speed:velocity,left:false)
        return left+right
    }
    /// Original formulas intentionally do not renormalize steering after applying
    /// dead-zone offsets. Simulation control checking handles output saturation.
    public static func halfAxis(_ value:Float,minimum:Float,maximum:Float,deadZone:Float,gain:Float,exponent:Float,speedSensitivity:Float,speed:Float,left:Bool) -> Float {
        var axis=value+(left ? deadZone:-deadZone)
        if axis>maximum { axis=maximum } else if axis<minimum { axis=minimum }
        axis=(axis-(left ? maximum:minimum))/(maximum-minimum)
        let signedGain = -(axis<0 ? Float(-1):Float(1))*gain
        // C++ resolves the original fabs/pow calls to their float overloads;
        // only division by the 1.0-based denominator promotes to double.
        return Float(Double(signedGain*powf(abs(axis),exponent))/(1+Double(speedSensitivity*speed)))
    }
    public func pedal(_ raw:Float) -> Float {
        guard raw.isFinite else { return 0 }
        return Self.pedalAxis(inverted ? 1-raw:raw,minimum:deadZone,maximum:1,minimumValue:deadZone,gain:sensitivity,exponent:linearity)
    }
    public static func pedalAxis(_ value:Float,minimum:Float,maximum:Float,minimumValue:Float,gain:Float,exponent:Float) -> Float {
        var axis=value
        if axis>maximum { axis=maximum } else if axis<minimum { axis=minimum }
        return abs(gain*powf(abs((axis-minimumValue)/(maximum-minimum)),exponent))
    }
}
