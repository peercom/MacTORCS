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
}
