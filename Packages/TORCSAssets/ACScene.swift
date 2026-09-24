// SPDX-License-Identifier: GPL-2.0-only
// Semantic port of TORCS 1.3.9 grloadac.cpp (PLIB), Copyright (C) 2001 Steve Baker.
// Derived LGPL-2.0-or-later portions converted to GPL v2 under LGPL v2 section 3,
// effective 2026-09-23. Original attribution and license retained in Upstream.
import Foundation

public struct ACRenderState: Codable, Sendable, Equatable {
    /// specular RGBA, emission RGBA, ambient RGBA, shininess.
    public var material: [Float]
    public var texture: String?
    /// blend, lighting, color-material, texture, alpha-test, translucent.
    public var flags: UInt32
    public var alphaClamp: Float
    /// Bit 0 explicitly sets alpha-test enable; bit 1 sets its threshold.
    /// Unset bits inherit the preceding GL state. Authored states default explicit.
    public var alphaCare: UInt32
    public init(material:[Float],texture:String?,flags:UInt32,alphaClamp:Float,alphaCare:UInt32=3) {
        self.material=material;self.texture=texture;self.flags=flags;self.alphaClamp=alphaClamp;self.alphaCare=alphaCare
    }
    /// The ACC compiler always sets the base clamp; extensions only set alpha
    /// state for cutouts. This losslessly recovers metadata from existing caches.
    static func loaderAlphaCare(flags:UInt32,layer:Int) -> UInt32 { (flags & 16 != 0 ? 3:0) | (layer==0 ? 2:0) }
}
public struct ACMesh: Codable, Sendable, Equatable {
    /// Original GL primitive identifier: loop 2, line-strip 3, triangles 4, strip 5, fan 6.
    public var primitive: Int
    public var vertices, normals: [Float]
    public var uv: [[Float]]
    public var colors: [Float]
    public var indices, strips: [UInt32]
    public var indexed, cull: Bool
    public var mapCount, mapLevel: Int
    public var states: [ACRenderState?]
}
public struct ACNode: Codable, Sendable, Equatable {
    public var parent: Int
    /// 0 transform, 1 group callback scope, 2 geometry.
    public var kind: Int
    public var name: String
    /// Original SG column-major matrix; translations at indices 12...14.
    public var matrix: [Float]
    public var mesh: ACMesh?
}
/// Raw loader XY extents, including unreferenced vertices before node transforms.
/// TORCS initializes each minimum/maximum to ±999999 rather than infinity.
public struct ACLoaderBounds: Codable,Sendable,Equatable {
    public var minimumX,maximumX,minimumY,maximumY: Float
    public init(minimumX: Float,maximumX: Float,minimumY: Float,maximumY: Float) {
        self.minimumX=minimumX;self.maximumX=maximumX;self.minimumY=minimumY;self.maximumY=maximumY
    }
    public var values: [Float] { [minimumX,maximumX,minimumY,maximumY] }
    public func validate() throws {
        guard values.allSatisfy(\.isFinite),minimumX<=maximumX,minimumY<=maximumY else { throw ACError.invalid("Invalid raw loader bounds") }
    }
}
public struct ACScene: Codable, Sendable, Equatable {
    public var nodes: [ACNode]
    public var loaderBounds: ACLoaderBounds? = nil
    /// Recoverable upstream format quirks; never silently hide a short child list.
    public var warnings: [String]? = nil
    public static func parse(_ data: Data,car: Bool = false,textureUnits: Int = 4,limits: ACLimits = .init()) throws -> ACScene {
        try ACParser(data:data,car:car,textureUnits:textureUnits,limits:limits).parse()
    }
}
public struct ACLimits: Sendable {
    public var bytes=64*1024*1024, nodes=100_000, materials=1000, vertices=2_000_000, references=8_000_000, depth=128, lineBytes=4096
    public init() {}
}
public enum ACError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String { switch self { case .invalid(let s): return s } }
}
let acIdentity: [Float]=[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]
