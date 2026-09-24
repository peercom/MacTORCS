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
    /// xyz flat ambient standing in until real spherical-harmonic irradiance
    /// lands; w seconds of animation time, zero for verification renders.
    public var ambientIrradiance: SIMD4<Float>
    /// xy render size in pixels (motion vectors are in those pixels),
    /// z texture mip bias, w nonzero when a screen-space occlusion target is
    /// bound for this frame.
    public var renderSize: SIMD4<Float>

    public init(viewProjection: simd_float4x4, view: simd_float4x4,
                cameraPosition: SIMD3<Float>, sunDirection: SIMD3<Float>,
                sunIlluminance: SIMD3<Float>, exposureScale: Float,
                ambientIrradiance: SIMD3<Float>,
                unjitteredViewProjection: simd_float4x4? = nil,
                previousViewProjection: simd_float4x4? = nil,
                renderSize: SIMD2<Float> = SIMD2(1, 1),
                mipBias: Float = 0, animationTime: Float = 0, wetness: Float = 0) {
        self.viewProjection = viewProjection
        self.view = view
        self.inverseViewProjection = viewProjection.inverse
        // Without temporal upscaling there is no jitter and no history, so the
        // unjittered and previous transforms collapse onto the current one and
        // every motion vector is zero.
        self.unjitteredViewProjection = unjitteredViewProjection ?? viewProjection
        self.previousViewProjection = previousViewProjection ?? (unjitteredViewProjection ?? viewProjection)
        self.renderSize = SIMD4(renderSize.x, renderSize.y, mipBias, 0)
        // The spare lane carries the scene's wetness, 0 dry to 1 soaked.
        self.cameraPosition = SIMD4(cameraPosition, wetness)
        self.sunDirection = SIMD4(simd_normalize(sunDirection), 0)
        self.sunIlluminance = SIMD4(sunIlluminance, exposureScale)
        self.ambientIrradiance = SIMD4(ambientIrradiance, animationTime)
    }

    public var exposureScale: Float { sunIlluminance.w }
    public var wetness: Float { cameraPosition.w }
}

/// Mirrors `DrawUniforms` in `Shaders/Forward.metal`.
public struct DrawUniforms: Equatable, Sendable {
    public var model: simd_float4x4
    public var normalMatrix: simd_float4x4
    public var baseColour: SIMD4<Float>
    /// x roughness, y metallic, z clearcoat, w clearcoat roughness.
    public var material: SIMD4<Float>
    /// x normal-map strength, y alpha threshold, z uv0 scale, w metre-UV fold
    /// period (zero for texture-space UVs).
    public var parameters: SIMD4<Float>
    /// Nonzero enables the corresponding texture: x albedo, y normal, z ORM.
    /// w is a bitfield: 1 receives screen-space occlusion, 2 paints road
    /// markings, 4 sways in the wind and tints per leaf.
    public var maps: SIMD4<UInt32>
    /// rgb emitted radiance when lit, w the channel that lights it: 0 never,
    /// 1 the brake command, 2 the headlight command, 3 any light command.
    /// Which channel is lit comes per instance, in `InstanceUniforms.lightState`.
    public var emissive: SIMD4<Float>
    /// x coverage 0–1 of a detail cross-fade, y +1 when this build is
    /// leaving (keeps noise < coverage) or −1 when arriving (keeps
    /// noise ≥ 1 − coverage); see `LevelOfDetail`. zw unused.
    public var fade: SIMD4<Float>

    public init(model: simd_float4x4, baseColour: SIMD4<Float>,
                roughness: Float, metallic: Float,
                clearcoat: Float = 0, clearcoatRoughness: Float = 0.04,
                normalStrength: Float = 1, alphaThreshold: Float = 0,
                maps: SIMD4<UInt32> = .zero, uvScale: Float = 1, uvPeriod: Float = 0,
                emissive: SIMD3<Float> = .zero, emissiveChannel: Float = 0) {
        self.model = model
        self.normalMatrix = Self.normalMatrix(for: model)
        self.baseColour = baseColour
        self.material = SIMD4(roughness, metallic, clearcoat, clearcoatRoughness)
        self.parameters = SIMD4(normalStrength, alphaThreshold, uvScale, uvPeriod)
        self.maps = maps
        self.emissive = SIMD4(emissive, emissiveChannel)
        self.fade = SIMD4(1, 1, 0, 0)
    }

    /// Sets the detail cross-fade for this draw.
    public mutating func setFade(_ fade: LevelOfDetail.Fade) {
        self.fade = SIMD4(fade.coverage, fade.side == .leaving ? 1 : -1, 0, 0)
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
    /// x brake lights lit, y headlights lit, z rear lights lit, w unused.
    /// Per instance because it changes every frame while the draw's material
    /// does not.
    public var lightState: SIMD4<Float>

    public init(model: simd_float4x4, previousModel: simd_float4x4? = nil, lightState: SIMD4<Float> = .zero) {
        self.model = model
        self.normalMatrix = DrawUniforms.normalMatrix(for: model)
        self.previousModel = previousModel ?? model
        self.lightState = lightState
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
    /// See `InstanceUniforms.lightState`. Zero for anything but a car.
    public var lightState: SIMD4<Float>

    public init(resource: Int, transform: simd_float4x4 = matrix_identity_float4x4,
                drawsDriver: Bool = true, castsShadow: Bool = true, lightState: SIMD4<Float> = .zero) {
        self.resource = resource
        self.transform = transform
        self.drawsDriver = drawsDriver
        self.castsShadow = castsShadow
        self.lightState = lightState
    }

    /// The light state a car's commands produce, as grcar reads them: brake
    /// lights from the brake command, headlights from bit 0 of the light
    /// command, rear lights from either headlight bit.
    public static func lightState(brakeCommand: Float, lightCommand: UInt32) -> SIMD4<Float> {
        SIMD4(brakeCommand > 0 ? 1 : 0, lightCommand & 1 != 0 ? 1 : 0, lightCommand & 3 != 0 ? 1 : 0, 0)
    }
}
