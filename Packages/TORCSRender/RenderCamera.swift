// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd
import TORCSMath

/// Camera for the modern path, in TORCS world space (right-handed, Z up).
///
/// The 31 original driving-camera presets live in the classic package and are
/// ported in a later phase; this carries only what the render passes need. It
/// uses a reversed-depth projection, which the classic path did not: mapping
/// near to 1 and far to 0 spends floating-point precision where it is needed and
/// removes the z-fighting that a 1 m near plane and a 1 km far plane otherwise
/// produce across a whole circuit.
public struct RenderCamera: Equatable, Sendable {
    public var eye: SIMD3<Float>
    public var target: SIMD3<Float>
    public var up: SIMD3<Float>
    public var verticalFieldOfView: Float
    public var near: Float
    public var far: Float

    public init(eye: SIMD3<Float>, target: SIMD3<Float>,
                up: SIMD3<Float> = SIMD3(0, 0, 1),
                verticalFieldOfView: Float = 40 * .pi / 180,
                near: Float = 0.25, far: Float = 2000) {
        self.eye = eye
        self.target = target
        self.up = up
        self.verticalFieldOfView = verticalFieldOfView
        self.near = near
        self.far = far
    }

    /// Frames a bounding box, for inspection and offscreen verification renders.
    public init(framing minimum: SIMD3<Float>, _ maximum: SIMD3<Float>,
                azimuth: Float = -.pi / 3, elevation: Float = 0.45) {
        let center = (minimum + maximum) * 0.5
        let distance = max(1, simd_length(maximum - minimum) * 0.75)
        let offset = SIMD3(cos(azimuth) * cos(elevation), sin(azimuth) * cos(elevation), sin(elevation))
        self.init(eye: center + distance * offset, target: center,
                  near: max(0.25, distance / 5000), far: max(100, distance * 6))
    }

    public func view() -> simd_float4x4 {
        let forward = simd_normalize(eye - target)
        var right = simd_cross(up, forward)
        // Degenerate when the view direction is parallel to up, which the
        // straight-down survey cameras do hit.
        if simd_length(right) < 1e-6 {
            right = simd_cross(SIMD3(0, 1, 0), forward)
        }
        right = simd_normalize(right)
        let trueUp = simd_cross(forward, right)
        return simd_float4x4(
            SIMD4(right.x, trueUp.x, forward.x, 0),
            SIMD4(right.y, trueUp.y, forward.y, 0),
            SIMD4(right.z, trueUp.z, forward.z, 0),
            SIMD4(-simd_dot(right, eye), -simd_dot(trueUp, eye), -simd_dot(forward, eye), 1))
    }

    /// Reversed-depth infinite-far projection. Near maps to 1, far to 0, so the
    /// depth comparison is `greater` and the clear value is 0.
    public func projection(aspect: Float) -> simd_float4x4 {
        let focal = 1 / tan(verticalFieldOfView / 2)
        let a = max(aspect, 1e-4)
        return simd_float4x4(
            SIMD4(focal / a, 0, 0, 0),
            SIMD4(0, focal, 0, 0),
            SIMD4(0, 0, 0, -1),
            SIMD4(0, 0, near, 0))
    }

    public func viewProjection(aspect: Float) -> simd_float4x4 {
        projection(aspect: aspect) * view()
    }
}

/// Sun and ambient description, in the physical-ish units the BRDF expects.
///
/// The classic path hard-coded a 0.2 global ambient and read GL light colours
/// straight from the track XML. Those values are kept as authoring input but
/// are no longer the lighting model.
public struct SunLighting: Equatable, Sendable {
    /// Unit vector pointing toward the sun.
    public var direction: SIMD3<Float>
    public var colour: SIMD3<Float>
    /// Scales `colour` into the BRDF's units.
    public var intensity: Float
    public var ambient: SIMD3<Float>
    /// Middle-grey exposure target; drives the exposure scale until histogram
    /// auto-exposure lands.
    public var exposureEV100: Float

    public init(direction: SIMD3<Float> = simd_normalize(SIMD3(0.35, -0.45, 0.82)),
                colour: SIMD3<Float> = SIMD3(1.0, 0.96, 0.9),
                intensity: Float = 4.0,
                ambient: SIMD3<Float> = SIMD3(0.16, 0.20, 0.28),
                exposureEV100: Float = 0) {
        self.direction = simd_normalize(direction)
        self.colour = colour
        self.intensity = intensity
        self.ambient = ambient
        self.exposureEV100 = exposureEV100
    }

    public var illuminance: SIMD3<Float> { colour * intensity }
    public var exposureScale: Float { Exposure.scale(ev100: exposureEV100) }

    /// The light of a sky covered by `coverage` of cloud: the sun to a
    /// fifth at full cover, so shadows all but go, and the exposure opened
    /// by a stop and a third, as an eye would — an overcast day is short of
    /// sun, not of light, and the skylight the scene receives is raised in
    /// the shader from the same coverage. Applied by whoever owns the
    /// lighting, so the sky pass and the scene agree on how much sun there is.
    public func overcast(_ coverage: Float) -> SunLighting {
        let c = min(max(coverage, 0), 1)
        var lighting = self
        lighting.intensity *= 1 - 0.8 * c
        lighting.ambient *= 1 + 0.5 * c
        lighting.exposureEV100 -= 1.3 * c
        return lighting
    }
}


public extension RenderCamera {
    /// Applies a subpixel sample offset to the projection.
    ///
    /// A perspective matrix's clip x and y pick up a constant screen-space
    /// offset from its z column, because the perspective divide is by -z. So
    /// the jitter goes there, and nothing else about the projection changes.
    ///
    /// `jitter` is in device pixels with y downward, matching how MetalFX
    /// expects to be told about it.
    ///
    /// Both signs are inverted relative to the obvious form, for two separate
    /// reasons that happen to compose. This projection divides by `w = -z`, so
    /// a term added to the z column reaches normalized coordinates negated. And
    /// clip space is y-up while device pixels are y-down, flipping y once more.
    static func jittered(_ projection: simd_float4x4, jitter: SIMD2<Float>,
                         renderWidth: Int, renderHeight: Int) -> simd_float4x4 {
        guard renderWidth > 0, renderHeight > 0 else { return projection }
        var jittered = projection
        jittered.columns.2.x -= 2 * jitter.x / Float(renderWidth)
        jittered.columns.2.y += 2 * jitter.y / Float(renderHeight)
        return jittered
    }

    /// Mip bias that keeps an upscaled image from reproducing a blurry
    /// half-resolution one.
    ///
    /// Sampling at the render resolution selects mips for that resolution, so
    /// without this the upscaler has no high-frequency detail to reconstruct.
    /// The standard bias is log2 of the scale factor.
    static func mipBias(renderWidth: Int, outputWidth: Int) -> Float {
        guard renderWidth > 0, outputWidth > 0 else { return 0 }
        return log2(Float(renderWidth) / Float(outputWidth))
    }
}
