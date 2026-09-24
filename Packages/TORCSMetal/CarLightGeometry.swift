// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 ssgVtxTableCarlight::draw_geometry.
// Copyright (C) 2001 Christophe Guionneau; upstream GPL-2.0-or-later.
import Foundation
import simd
import TORCSAssets
import TORCSRaceEngine
import TORCSSimulation

public struct CarLightInstance: Sendable {
    public let definition: CarLightDefinition
    public let position: SIMD3<Float>
    public let isOn: Bool
    public init(definition: CarLightDefinition,body: simd_float4x4,brakeCommand: Float,lightCommand: UInt32) throws {
        guard (0..<4).allSatisfy({ i in (0..<4).allSatisfy { body[i][$0].isFinite } }) else { throw ACError.invalid("Invalid car light body transform") }
        self.definition=definition
        let p=definition.position
        func coordinate(_ i: Int) -> Float { p.x*body[0][i]+p.y*body[1][i]+p.z*body[2][i]+body[3][i] }
        position=SIMD3(coordinate(0),coordinate(1),coordinate(2))
        guard position.x.isFinite,position.y.isFinite,position.z.isFinite else { throw ACError.invalid("Car light position overflow") }
        isOn=definition.type.isOn(brakeCommand:brakeCommand,lightCommand:lightCommand)
    }
    /// A hidden current car has no light children. Visible but switched-off
    /// lights remain in the original graph as one-point geometry.
    public static func instances(definitions: [CarLightDefinition],body: simd_float4x4,brakeCommand: Float,lightCommand: UInt32,display: Bool) throws -> [Self] {
        guard definitions.count<=14 else { throw ACError.invalid("Too many car lights") }
        guard display else { return [] }
        return try definitions.map { try Self(definition:$0,body:body,brakeCommand:brakeCommand,lightCommand:lightCommand) }
    }
}

/// One original camera-facing four-vertex triangle strip. The texture rotation
/// takes an explicit rand() value, so geometry evaluation never changes physics
/// randomness. The draw scheduler supplies one value per visible draw.
public struct CarLightGeometry: Sendable {
    public let positions: [SIMD3<Float>]
    public let textureCoordinates: [SIMD2<Float>]
    public let textureMatrix: simd_float4x4
    public let color=SIMD4<Float>(0.8,0.8,0.8,0.75)
    public let depthWrites=false
    public let cullsFaces=false
    public let depthBias=SIMD2<Float>(-15,-20) // original GL slope, units
    public let center: SIMD3<Float>
    public let angleDegrees: Float

    public init(position: SIMD3<Float>,size: Float,factor: Double=1,view: simd_float4x4,randomValue: UInt32) throws {
        guard position.x.isFinite,position.y.isFinite,position.z.isFinite,size.isFinite,factor.isFinite,
              randomValue<=2147483647,(0..<4).allSatisfy({ i in (0..<4).allSatisfy { view[i][$0].isFinite } }) else {
            throw ACError.invalid("Invalid car light draw input")
        }
        center=position
        let right=SIMD3(view[0].x,view[1].x,view[2].x),up=SIMD3(view[0].y,view[1].y,view[2].y)
        let corners=[-right-up,right-up,-right+up,right+up]
        positions=corners.map { corner in
            SIMD3(Float(Double(position.x)+factor*Double(size)*Double(corner.x)),
                  Float(Double(position.y)+factor*Double(size)*Double(corner.y)),
                  Float(Double(position.z)+factor*Double(size)*Double(corner.z)))
        }
        guard positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { throw ACError.invalid("Car light geometry overflow") }
        textureCoordinates=[SIMD2(0,0),SIMD2(0,1),SIMD2(1,0),SIMD2(1,1)]
        angleDegrees=(Float(randomValue)/Float(2147483647))*45
        // sgMakeRotMat4 uses Float degree conversion and Float libm overloads.
        let radians=angleDegrees*(Float.pi/180),s=sin(radians),c=cos(radians)
        // T(.5,.5) * Rz(angle) * T(-.5,-.5), original GL texture matrix order.
        textureMatrix=simd_float4x4(SIMD4(c,s,0,0),SIMD4(-s,c,0,0),SIMD4(0,0,1,0),SIMD4((-0.5*c+0.5*s)+0.5,(-0.5*s-0.5*c)+0.5,0,1))
    }
    public var rotatedTextureCoordinates: [SIMD2<Float>] {
        textureCoordinates.map { let v=textureMatrix*SIMD4($0.x,$0.y,0,1);return SIMD2(v.x,v.y) }
    }
}

/// Draw-scoped presentation stream. Call only after view visibility and scene
/// culling; switched-off lights consume no random values, matching draw_geometry.
/// Rendering this effect never reads or advances the simulation's random stream.
public struct CarLightDrawing: Sendable {
    private var random: DarwinRandomStream
    public var randomDraws: UInt64 { random.draws }
    public init(seed: UInt32=12345) throws {
        guard seed<=2147483647 else { throw ACError.invalid("Invalid car light random seed") }
        random=DarwinRandomStream(seed:seed)
    }
    public mutating func draw(_ light: CarLightInstance,view: simd_float4x4) throws -> CarLightGeometry? {
        guard light.isOn else { return nil }
        var next=random
        _=next.next()
        let result=try CarLightGeometry(position:light.position,size:light.definition.size,view:view,randomValue:next.state)
        random=next
        return result
    }
}
