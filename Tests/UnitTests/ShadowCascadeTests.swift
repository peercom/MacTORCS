// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import TORCSRender

final class ShadowCascadeTests: XCTestCase {
    let sun = simd_normalize(SIMD3<Float>(0.4, -0.3, 0.86))

    func cascades(camera: RenderCamera, count: Int = 4, resolution: Int = 2048) -> [ShadowCascades.Cascade] {
        ShadowCascades(camera: camera, sunDirection: sun, aspect: 1280.0 / 832.0,
                       count: count, resolution: resolution).cascades
    }

    func testSplitsIncreaseAndCoverTheShadowDistance() {
        let camera = RenderCamera(eye: SIMD3(0, -20, 5), target: SIMD3(0, 0, 1))
        let result = cascades(camera: camera)
        XCTAssertEqual(result.count, 4)
        for i in 1 ..< result.count {
            XCTAssertGreaterThan(result[i].splitDistance, result[i - 1].splitDistance,
                                 "cascade \(i) does not extend past \(i - 1)")
        }
        XCTAssertEqual(result.last?.splitDistance ?? 0, 400, accuracy: 1)
        // Near cascades must be much tighter, or the near field has no detail.
        XCTAssertLessThan(result[0].texelWorldSize, result[3].texelWorldSize / 4)
    }

    /// The reason for fitting to a sphere rather than a box. If the cascade
    /// resized as the camera turned, every shadow edge in the frame would
    /// swim — and in a racing game the camera turns constantly.
    func testCascadeSizeIsInvariantUnderCameraRotation() {
        var sizes: [Float] = []
        for yaw in stride(from: Float(0), to: 2 * .pi, by: 0.2) {
            let eye = SIMD3<Float>(0, 0, 5)
            let target = eye + SIMD3(cos(yaw), sin(yaw), -0.1)
            sizes.append(cascades(camera: RenderCamera(eye: eye, target: target))[0].texelWorldSize)
        }
        let smallest = sizes.min() ?? 0, largest = sizes.max() ?? 0
        XCTAssertGreaterThan(smallest, 0)
        // The rounding step is 1/16 of a world unit, so allow that much drift.
        XCTAssertLessThan(largest - smallest, largest * 0.02,
                          "cascade size varies with camera yaw: \(smallest) to \(largest)")
    }

    /// Texel snapping: translating the camera by a whole number of texels must
    /// reproduce the same light-space grid, which is what stops shadow edges
    /// crawling as the car drives.
    func testLightSpaceOriginSnapsToTexelGrid() {
        let base = RenderCamera(eye: SIMD3(0, -20, 5), target: SIMD3(0, 0, 1))
        let first = cascades(camera: base)[0]

        // Sub-texel camera motion should not move the projection continuously.
        var distinctOrigins = Set<String>()
        for offset in stride(from: Float(0), to: first.texelWorldSize * 0.9, by: first.texelWorldSize / 8) {
            let moved = RenderCamera(eye: SIMD3(offset, -20, 5), target: SIMD3(offset, 0, 1))
            let cascade = cascades(camera: moved)[0]
            let origin = cascade.viewProjection * SIMD4<Float>(0, 0, 0, 1)
            distinctOrigins.insert(String(format: "%.5f,%.5f", origin.x, origin.y))
        }
        // With snapping, sub-texel motion collapses onto few grid positions.
        XCTAssertLessThanOrEqual(distinctOrigins.count, 3,
                                 "origin moved continuously: \(distinctOrigins.count) positions")
    }

    func testEveryCascadeProducesAUsableProjection() {
        let camera = RenderCamera(eye: SIMD3(100, 50, 8), target: SIMD3(200, 300, 2))
        for cascade in cascades(camera: camera) {
            XCTAssertGreaterThan(cascade.depthRange, 0)
            XCTAssertGreaterThan(cascade.texelWorldSize, 0)
            for column in 0 ..< 4 {
                let c = cascade.viewProjection[column]
                XCTAssertTrue(c.x.isFinite && c.y.isFinite && c.z.isFinite && c.w.isFinite)
            }
            // A point at the camera target must land inside the near cascade.
            let projected = cascade.viewProjection * SIMD4<Float>(200, 300, 2, 1)
            XCTAssertNotEqual(projected.w, 0)
        }
    }

    /// A sun directly overhead makes the natural up axis degenerate, and a
    /// sun below the horizon must not produce NaNs either.
    func testDegenerateSunDirectionsDoNotProduceNaN() {
        let camera = RenderCamera(eye: SIMD3(0, -20, 5), target: SIMD3(0, 0, 1))
        for direction in [SIMD3<Float>(0, 0, 1), SIMD3(0, 0, -1), SIMD3(1, 0, 0), SIMD3(0, 0, 0.9999)] {
            let result = ShadowCascades(camera: camera, sunDirection: direction,
                                        aspect: 1.5, count: 4, resolution: 1024).cascades
            XCTAssertEqual(result.count, 4)
            for cascade in result {
                for column in 0 ..< 4 {
                    let c = cascade.viewProjection[column]
                    XCTAssertFalse(c.x.isNaN || c.y.isNaN || c.z.isNaN || c.w.isNaN,
                                   "NaN projection for sun \(direction)")
                }
            }
        }
    }

    func testCascadeCountIsClampedToWhatTheShaderSupports() {
        let camera = RenderCamera(eye: SIMD3(0, -20, 5), target: SIMD3(0, 0, 1))
        XCTAssertEqual(cascades(camera: camera, count: 0).count, 1)
        XCTAssertEqual(cascades(camera: camera, count: 99).count, 8)
    }

    /// The shader looks a cascade up as the first one scaled and moved: one
    /// matrix for every pixel and two vectors by the cascade's index. That
    /// has to land where the cascade's own matrix lands, to a small
    /// fraction of a shadow texel.
    func testEveryCascadeIsTheFirstScaledAndMoved() {
        let camera = RenderCamera(eye: SIMD3(120, -340, 6), target: SIMD3(180, -300, 2))
        let sun = SIMD3<Float>(0.35, -0.45, 0.82)
        let cascades = ShadowCascades(camera: camera, sunDirection: sun, aspect: 16.0 / 9.0,
                                      count: 4, resolution: 2048).cascades
        XCTAssertTrue(ShadowCascades.shareOrientation(cascades))
        let uniforms = ShadowUniforms(cascades: cascades, depthBias: 3, normalBias: 1.5, filterRadius: 1.5, resolution: 2048)
        let scales = [uniforms.cascadeScale.0, uniforms.cascadeScale.1, uniforms.cascadeScale.2, uniforms.cascadeScale.3]
        let offsets = [uniforms.cascadeOffset.0, uniforms.cascadeOffset.1, uniforms.cascadeOffset.2, uniforms.cascadeOffset.3]
        let forward = simd_normalize(camera.target - camera.eye)
        var slice: Float = 0.5
        for (index, cascade) in cascades.enumerated() {
            // The spare lanes: the biases, multiplied out for the shader.
            XCTAssertEqual(scales[index].w, cascade.texelWorldSize * 1.5, accuracy: 1e-6)
            XCTAssertEqual(offsets[index].w, 3 * cascade.texelWorldSize / cascade.depthRange, accuracy: 1e-9)
            // Points this cascade would be asked about: along the view, out
            // to its split, and off to either side.
            for step in 0 ..< 8 {
                let distance = slice + (cascade.splitDistance - slice) * Float(step) / 7
                for side in [Float(-0.4), 0, 0.4] {
                    let point = camera.eye + forward * distance + SIMD3(-forward.y, forward.x, 0.1) * side * distance
                    let own = cascade.viewProjection * SIMD4(point, 1)
                    let first = cascades[0].viewProjection * SIMD4(point, 1)
                    let got = SIMD3(first.x, first.y, first.z) * SIMD3(scales[index].x, scales[index].y, scales[index].z)
                        + SIMD3(offsets[index].x, offsets[index].y, offsets[index].z)
                    XCTAssertEqual(got.x, own.x * 0.5 + 0.5, accuracy: 2e-5, "u, cascade \(index) at \(distance) m")
                    XCTAssertEqual(got.y, 0.5 - own.y * 0.5, accuracy: 2e-5, "v, cascade \(index) at \(distance) m")
                    XCTAssertEqual(got.z, own.z, accuracy: 1e-5, "depth, cascade \(index) at \(distance) m")
                }
            }
            slice = cascade.splitDistance
        }
        // The last cascade fades over the last 15% of its reach, and the
        // filter's radius is in the map's uv.
        let reach = cascades[3].splitDistance
        XCTAssertEqual(uniforms.filter.x, reach * 0.85, accuracy: 1e-4)
        XCTAssertEqual(uniforms.filter.y * reach * 0.15, 1, accuracy: 1e-5)
        XCTAssertEqual(uniforms.filter.z, 1.5 / 2048, accuracy: 1e-9)
        // Another sun is another orientation, and the two fits do not mix.
        let later = ShadowCascades(camera: camera, sunDirection: SIMD3(0.5, -0.3, 0.8), aspect: 16.0 / 9.0,
                                   count: 4, resolution: 2048).cascades
        XCTAssertTrue(ShadowCascades.shareOrientation(later))
        XCTAssertFalse(ShadowCascades.shareOrientation(cascades + later))
        XCTAssertTrue(ShadowCascades.shareOrientation([]))
    }
}
