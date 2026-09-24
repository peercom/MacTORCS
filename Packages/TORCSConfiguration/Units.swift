// SPDX-License-Identifier: GPL-2.0-only
// Semantically ported from TORCS 1.3.9 src/libs/tgf/params.cpp.
// Copyright (C) 1999-2014 Eric Espie, Bernhard Wymann.
// Upstream permits GPL version 2 or (at your option) any later version.
import Foundation

public enum Units {
    public static func toSI(_ value: Float, unit: String) -> Float { convert(value, unit: unit, fromSI: false) }
    public static func fromSI(_ value: Float, unit: String) -> Float { convert(value, unit: unit, fromSI: true) }

    private static func coefficient(_ token: String) -> Float {
        switch token {
        case "feet", "ft": 0.304801
        case "deg": Float(Double.pi / 180)
        case "h", "hour", "hours": 3600
        case "day", "days": 86400
        case "km", "kPa": 1000
        case "mm": 0.001
        case "cm", "percent", "%": 0.01
        case "in", "inch", "inches": 0.0254
        case "lbs", "lb": 0.45359237
        case "lbf": Float(0.45359237) * Float(9.80665)
        case "slug", "slugs": 14.59484546
        case "MPa": 1_000_000
        case "PSI", "psi": 6894.76
        case "rpm", "RPM": 0.104719755
        case "mph", "MPH": 0.44704
        default: 1 // TORCS intentionally passes unknown unit tokens through.
        }
    }
    private static func convert(_ value: Float, unit: String, fromSI: Bool) -> Float {
        var result = value, token = "", inverse = fromSI
        func apply(_ token: String, _ inverse: Bool, _ result: inout Float) {
            if inverse { result /= coefficient(token) } else { result *= coefficient(token) }
        }
        for c in unit {
            switch c {
            case ".", "/", "2":
                apply(token, inverse, &result)
                if c == "2" { apply(token, inverse, &result) }
                if c == "/" { inverse = !fromSI }
                token = ""
            default: token.append(c)
            }
        }
        apply(token, inverse, &result)
        return result
    }
}
