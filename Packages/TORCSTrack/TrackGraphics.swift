// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS track.cpp and grscene.cpp configuration.
// Copyright (C) 2000 Eric Espie, 2001 Christophe Guionneau; upstream GPL-2.0-or-later.
import TORCSConfiguration

public struct TrackGraphics: Sendable {
    public let background: String
    public let backgroundType: Int
    public let backgroundColor,ambient,diffuse,specular,lightPosition: SIMD3<Float>
    public var fogColor: SIMD3<Float> { backgroundColor*0.8 }
    public init(parameters: ParameterDocument) throws {
        let section=parameters.section("Graphic")
        func color(_ prefix: String,_ fallback: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3(section?.number(prefix+" R",default:fallback.x) ?? fallback.x,
                  section?.number(prefix+" G",default:fallback.y) ?? fallback.y,
                  section?.number(prefix+" B",default:fallback.z) ?? fallback.z)
        }
        background=section?.string("background image",default:"background.png") ?? "background.png"
        let kind=section?.number("background type",default:0) ?? 0
        guard kind.isFinite,kind>=Float(Int32.min),Double(kind)<=Double(Int32.max) else { throw TrackError.invalid("Invalid background type") }
        backgroundType=Int(kind)
        backgroundColor=color("background color",SIMD3(0,0,0.1));ambient=color("ambient color",SIMD3(repeating:0.2))
        diffuse=color("diffuse color",SIMD3(repeating:0.8));specular=color("specular color",SIMD3(repeating:0.3))
        lightPosition=SIMD3(section?.number("light position x",default:0) ?? 0,section?.number("light position y",default:0) ?? 0,section?.number("light position z",default:200) ?? 200)
        guard [backgroundColor,ambient,diffuse,specular,lightPosition].allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),lightPosition != .zero else { throw TrackError.invalid("Invalid track lighting") }
    }
}
