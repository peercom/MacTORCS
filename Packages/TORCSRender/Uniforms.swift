// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd

/// Mirrors `FrameUniforms` in `Shaders/Forward.metal`.
///
/// Every field is 16-byte aligned deliberately. MSL pads `float3` to 16 bytes
/// and pads each column of a `float3x3`; pairing those with tighter Swift types
/// silently shifts every subsequent field. Using only `float4` and `float4x4`
/// makes the layouts trivially identical, and `UniformLayoutTests` pins it.
public struct FrameUniforms: Equatable, Sendable {
    /// Jittered, and therefore what geometry is rasterized with.
    public var viewProjection: simd_float4x4
    public var view: simd_float4x4
    /// Reconstructs world-space view rays in the fullscreen sky pass.
    public var inverseViewProjection: simd_float4x4
    /// Unjittered current and previous transforms, for motion vectors only.
    /// Jitter is a sampling offset, not motion.
    public var unjitteredViewProjection: simd_float4x4
    public var previousViewProjection: simd_float4x4
    /// xyz world-space eye position, w unused.
    public var cameraPosition: SIMD4<Float>
    /// xyz unit vector pointing *toward* the sun, w unused.
    public var sunDirection: SIMD4<Float>
    /// Linear RGB illuminance, w holds the exposure scale.
    public var sunIlluminance: SIMD4<Float>
    /// Flat ambient standing in until real spherical-harmonic irradiance lands.
    public var ambientIrradiance: SIMD4<Float>
    /// xy render size in pixels (motion vectors are in those pixels),
    /// z texture mip bias, w unused.
    public var renderSize: SIMD4<Float>

    public init(viewProjection: simd_float4x4, view: simd_float4x4,
                cameraPosition: SIMD3<Float>, sunDirection: SIMD3<Float>,
                sunIlluminance: SIMD3<Float>, exposureScale: Float,
                ambientIrradiance: SIMD3<Float>,
                unjitteredViewProjection: simd_float4x4? = nil,
                previousViewProjection: simd_float4x4? = nil,
                renderSize: SIMD2<Float> = SIMD2(1, 1),
                mipBias: Float = 0) {
        self.viewProjection = viewProjection
        self.view = view
        self.inverseViewProjection = viewProjection.inverse
        // Without temporal upscaling there is no jitter and no history, so the
        // unjittered and previous transforms collapse onto the current one and
        // every motion vector is zero.
        self.unjitteredViewProjection = unjitteredViewProjection ?? viewProjection
        self.previousViewProjection = previousViewProjection ?? (unjitteredViewProjection ?? viewProjection)
        self.renderSize = SIMD4(renderSize.x, renderSize.y, mipBias, 0)
        self.cameraPosition = SIMD4(cameraPosition, 0)
        self.sunDirection = SIMD4(simd_normalize(sunDirection), 0)
        self.sunIlluminance = SIMD4(sunIlluminance, exposureScale)
        self.ambientIrradiance = SIMD4(ambientIrradiance, 0)
    }

    public var exposureScale: Float { sunIlluminance.w }
}

/// Mirrors `DrawUniforms` in `Shaders/Forward.metal`.
public struct DrawUniforms: Equatable, Sendable {
    public var model: simd_float4x4
    public var normalMatrix: simd_float4x4
    public var baseColour: SIMD4<Float>
    /// x roughness, y metallic, z clearcoat, w clearcoat roughness.
    public var material: SIMD4<Float>
    /// x normal-map strength, y alpha threshold, zw unused.
    public var parameters: SIMD4<Float>
    /// Nonzero enables the corresponding texture: x albedo, y normal, z ORM.
    public var maps: SIMD4<UInt32>

    public init(model: simd_float4x4, baseColour: SIMD4<Float>,
                roughness: Float, metallic: Float,
                clearcoat: Float = 0, clearcoatRoughness: Float = 0.04,
                normalStrength: Float = 1, alphaThreshold: Float = 0,
                maps: SIMD4<UInt32> = .zero) {
        self.model = model
        self.normalMatrix = Self.normalMatrix(for: model)
        self.baseColour = baseColour
        self.material = SIMD4(roughness, metallic, clearcoat, clearcoatRoughness)
        self.parameters = SIMD4(normalStrength, alphaThreshold, 0, 0)
        self.maps = maps
    }

    /// Inverse transpose of the upper 3x3, promoted back to 4x4.
    ///
    /// Reusing the model matrix would skew normals off the surface wherever
    /// scale is non-uniform, which the original car and track node transforms do
    /// contain. Falls back to the model matrix if the basis is singular, which
    /// scene flattening rejects anyway.
    public static func normalMatrix(for model: simd_float4x4) -> simd_float4x4 {
        let upper = simd_float3x3(
            SIMD3(model.columns.0.x, model.columns.0.y, model.columns.0.z),
            SIMD3(model.columns.1.x, model.columns.1.y, model.columns.1.z),
            SIMD3(model.columns.2.x, model.columns.2.y, model.columns.2.z))
        guard abs(simd_determinant(upper)) > 1e-12 else { return model }
        let corrected = upper.inverse.transpose
        return simd_float4x4(
            SIMD4(corrected.columns.0, 0),
            SIMD4(corrected.columns.1, 0),
            SIMD4(corrected.columns.2, 0),
            SIMD4(0, 0, 0, 1))
    }
}

/// Mirrors `InstanceUniforms` in `Shaders/Forward.metal`.
///
/// Places a whole loaded scene in the world. The car body, each wheel and each
/// brake part are separate instances of separate resources, which is how a
/// moving vehicle is assembled without rebuilding any GPU buffer.
public struct InstanceUniforms: Equatable, Sendable {
    public var model: simd_float4x4
    public var normalMatrix: simd_float4x4
    /// Where this instance was last frame. Equal to `model` for static
    /// geometry, whose only motion is then the camera's.
    public var previousModel: simd_float4x4

    public init(model: simd_float4x4, previousModel: simd_float4x4? = nil) {
        self.model = model
        self.normalMatrix = DrawUniforms.normalMatrix(for: model)
        self.previousModel = previousModel ?? model
    }

    public static let identity = InstanceUniforms(model: matrix_identity_float4x4)
}

/// One placement of a loaded resource in the world.
public struct RenderInstance: Equatable, Sendable {
    /// Index into the renderer's resource list.
    public var resource: Int
    public var transform: simd_float4x4
    /// Cockpit views hide the driver; the batch flag marks which geometry that is.
    public var drawsDriver: Bool
    /// Excluded from shadow casting. Used for geometry that would shadow the
    /// camera itself, such as the car in a bonnet view.
    public var castsShadow: Bool

    public init(resource: Int, transform: simd_float4x4 = matrix_identity_float4x4,
                drawsDriver: Bool = true, castsShadow: Bool = true) {
        self.resource = resource
        self.transform = transform
        self.drawsDriver = drawsDriver
        self.castsShadow = castsShadow
    }
}
