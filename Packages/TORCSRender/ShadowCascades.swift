// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import simd

/// Cascaded shadow map fitting.
///
/// The classic path had no shadow maps at all: a car cast a projected textured
/// blob re-fitted to the terrain each frame, and track shadows were a baked
/// texture projected onto car bodies. Nothing cast onto anything else — not
/// barriers, not buildings, not trees.
///
/// Two properties matter more than resolution here:
///
/// - **Stability.** Cascades are fitted to a bounding *sphere* of each frustum
///   slice, not its bounding box. A sphere is invariant under camera rotation,
///   so the cascade does not resize as the car turns. The origin is then snapped
///   to whole texels, which is what stops shadow edges crawling while driving —
///   the most obvious artifact in a racing game, because the camera rotates
///   constantly.
/// - **Split placement.** A practical split blends logarithmic and uniform
///   schemes. Pure logarithmic wastes the near cascade on the bonnet; pure
///   uniform starves it.
public struct ShadowCascades: Equatable, Sendable {
    public struct Cascade: Equatable, Sendable {
        /// World to light clip space for this slice.
        public var viewProjection: simd_float4x4
        /// View-space distance where this cascade stops being used.
        public var splitDistance: Float
        /// World size of one shadow texel; drives filter radius and depth bias.
        public var texelWorldSize: Float
        /// Metres spanned by the cascade's [0, 1] depth range, so a bias can be
        /// specified in world units and converted once rather than guessed in
        /// normalized depth.
        public var depthRange: Float
    }

    public let cascades: [Cascade]

    /// - Parameters:
    ///   - lambda: 0 is uniform splitting, 1 is fully logarithmic. 0.7 keeps
    ///     useful near detail without starving the distance.
    public init(camera: RenderCamera, sunDirection: SIMD3<Float>, aspect: Float,
                count: Int, resolution: Int, shadowDistance: Float = 400, lambda: Float = 0.7) {
        let count = max(1, min(count, 8))
        let near = max(camera.near, 0.01)
        let far = max(near + 1, min(camera.far, shadowDistance))

        // Practical split scheme (Zhang et al.).
        var splits: [Float] = []
        for i in 1 ... count {
            let fraction = Float(i) / Float(count)
            let logarithmic = near * pow(far / near, fraction)
            let uniform = near + (far - near) * fraction
            splits.append(lambda * logarithmic + (1 - lambda) * uniform)
        }

        let view = camera.view()
        let inverseView = view.inverse
        let tanHalf = tan(camera.verticalFieldOfView / 2)
        let light = simd_normalize(sunDirection)
        // Degenerate when the light is parallel to the chosen up axis, which a
        // sun directly overhead is.
        let up = abs(light.z) > 0.99 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(0, 0, 1)

        var built: [Cascade] = []
        var sliceNear = near
        for split in splits {
            let sliceFar = split
            // Frustum slice corners in view space. The camera looks down -Z.
            var corners: [SIMD3<Float>] = []
            for distance in [sliceNear, sliceFar] {
                let h = tanHalf * distance, w = h * aspect
                for sx in [Float(-1), 1] {
                    for sy in [Float(-1), 1] {
                        let viewSpace = SIMD4<Float>(sx * w, sy * h, -distance, 1)
                        let world = inverseView * viewSpace
                        corners.append(SIMD3(world.x, world.y, world.z))
                    }
                }
            }

            // Bounding sphere, which is rotation invariant.
            var centre = SIMD3<Float>.zero
            for corner in corners { centre += corner }
            centre /= Float(corners.count)
            var radius: Float = 0
            for corner in corners { radius = max(radius, simd_length(corner - centre)) }
            // Rounding up keeps the radius from oscillating with tiny camera moves.
            radius = (radius * 16).rounded(.up) / 16

            let texelWorldSize = radius * 2 / Float(max(resolution, 1))

            // Far enough back that casters above the slice still reach it, but
            // no further: every extra metre is depth precision spent on empty
            // sky, and with depth16Unorm that precision is not free.
            let casterHeadroom: Float = 120
            let distanceBack = radius + casterHeadroom
            let eye = centre + light * distanceBack
            var lightView = Self.lookAt(eye: eye, target: centre, up: up)

            // Snap the light-space origin to whole texels. Without this the
            // sampled depth shifts by a fraction of a texel every frame and the
            // shadow edge crawls.
            let originInLight = lightView * SIMD4<Float>(0, 0, 0, 1)
            let snappedX = (originInLight.x / texelWorldSize).rounded() * texelWorldSize
            let snappedY = (originInLight.y / texelWorldSize).rounded() * texelWorldSize
            lightView.columns.3.x += snappedX - originInLight.x
            lightView.columns.3.y += snappedY - originInLight.y

            let farPlane = distanceBack + radius + casterHeadroom
            let projection = Self.orthographic(halfWidth: radius, halfHeight: radius,
                                               near: 0.1, far: farPlane)
            built.append(Cascade(viewProjection: projection * lightView,
                                 splitDistance: sliceFar,
                                 texelWorldSize: texelWorldSize,
                                 depthRange: farPlane - 0.1))
            sliceNear = sliceFar
        }
        cascades = built
    }

    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let forward = simd_normalize(eye - target)
        var right = simd_cross(up, forward)
        if simd_length(right) < 1e-6 { right = simd_cross(SIMD3(1, 0, 0), forward) }
        right = simd_normalize(right)
        let trueUp = simd_cross(forward, right)
        return simd_float4x4(
            SIMD4(right.x, trueUp.x, forward.x, 0),
            SIMD4(right.y, trueUp.y, forward.y, 0),
            SIMD4(right.z, trueUp.z, forward.z, 0),
            SIMD4(-simd_dot(right, eye), -simd_dot(trueUp, eye), -simd_dot(forward, eye), 1))
    }

    /// Metal clip space: z in [0, 1], not [-1, 1].
    static func orthographic(halfWidth: Float, halfHeight: Float, near: Float, far: Float) -> simd_float4x4 {
        let depth = max(far - near, 1e-4)
        return simd_float4x4(
            SIMD4(1 / max(halfWidth, 1e-4), 0, 0, 0),
            SIMD4(0, 1 / max(halfHeight, 1e-4), 0, 0),
            SIMD4(0, 0, -1 / depth, 0),
            SIMD4(0, 0, -near / depth, 1))
    }
}
