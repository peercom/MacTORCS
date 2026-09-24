// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import TORCSMath

final class VertexPackingTests: XCTestCase {
    /// Deterministic quasi-uniform directions over the sphere (Fibonacci
    /// spiral). Random sampling would make a precision regression flaky.
    func sphereDirections(_ count: Int) -> [SIMD3<Float>] {
        let golden = Float.pi * (3 - (5 as Float).squareRoot())
        return (0 ..< count).map { i in
            let z = 1 - 2 * (Float(i) + 0.5) / Float(count)
            let r = max(0, 1 - z * z).squareRoot()
            let theta = golden * Float(i)
            return simd_normalize(SIMD3(r * cos(theta), r * sin(theta), z))
        }
    }

    func angularErrorDegrees(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        acos(min(max(simd_dot(a, b), -1), 1)) * 180 / .pi
    }

    func testNormalRoundTripErrorIsBelowOneMilliradian() {
        var worst: Float = 0
        for n in sphereDirections(20_000) {
            worst = max(worst, angularErrorDegrees(n, OctahedralPacking.decodeNormal(OctahedralPacking.encodeNormal(n))))
        }
        // One milliradian is 0.0573 degrees. oct16 should land well inside it.
        // Measured worst case over this sample set: 0.0343 deg.
        XCTAssertLessThan(worst, 0.0573, "worst normal error \(worst) deg")
    }

    /// The axis directions are where the octahedral fold is evaluated exactly on
    /// a seam, so they are the cases most likely to break a sign convention.
    func testAxisAlignedNormalsSurviveExactly() {
        let axes: [SIMD3<Float>] = [
            SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0),
            SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1)]
        for axis in axes {
            let decoded = OctahedralPacking.decodeNormal(OctahedralPacking.encodeNormal(axis))
            XCTAssertLessThan(angularErrorDegrees(axis, decoded), 1e-3, "axis \(axis) -> \(decoded)")
        }
    }

    /// Stealing the low bit for handedness costs precision on one axis only.
    /// This pins how much, so a future format change cannot silently regress it.
    func testTangentRoundTripPreservesDirectionAndHandedness() {
        var worst: Float = 0
        for (i, t) in sphereDirections(20_000).enumerated() {
            let handedness: Float = i.isMultiple(of: 2) ? 1 : -1
            let (decoded, sign) = OctahedralPacking.decodeTangent(
                OctahedralPacking.encodeTangent(t, handedness: handedness))
            XCTAssertEqual(sign, handedness, "handedness lost for \(t)")
            worst = max(worst, angularErrorDegrees(t, decoded))
        }
        // One bit narrower than the normal path, so allow twice the budget.
        // Measured worst case is 0.0343 deg, identical to the normal path:
        // octahedral projection error dominates, not the y quantization, so
        // the stolen handedness bit costs nothing observable here.
        XCTAssertLessThan(worst, 0.115, "worst tangent error \(worst) deg")
    }

    func testNonFiniteAndDegenerateInputsDoNotProduceNaN() {
        for bad in [SIMD3<Float>(0, 0, 0), SIMD3(.nan, 1, 0), SIMD3(.infinity, 0, 0)] {
            let decoded = OctahedralPacking.decodeNormal(OctahedralPacking.encodeNormal(bad))
            XCTAssertFalse(decoded.x.isNaN || decoded.y.isNaN || decoded.z.isNaN, "\(bad) -> \(decoded)")
            XCTAssertEqual(simd_length(decoded), 1, accuracy: 1e-5)
        }
    }

    func testSRGBTransferRoundTripsAndMatchesKnownAnchors() {
        XCTAssertEqual(ColorSpace.linear(fromSRGB: 0), 0, accuracy: 1e-7)
        XCTAssertEqual(ColorSpace.linear(fromSRGB: 1), 1, accuracy: 1e-6)
        // Mid grey 0.5 sRGB is the canonical ~0.2140 linear.
        XCTAssertEqual(ColorSpace.linear(fromSRGB: 0.5), 0.2140, accuracy: 1e-4)
        // 0.04045 is the piecewise breakpoint; both branches must agree there.
        XCTAssertEqual(ColorSpace.linear(fromSRGB: 0.04045), 0.04045 / 12.92, accuracy: 1e-7)
        for i in 0 ... 255 {
            let c = Float(i) / 255
            XCTAssertEqual(ColorSpace.srgb(fromLinear: ColorSpace.linear(fromSRGB: c)), c, accuracy: 1e-5)
        }
    }

    func testExposureScaleTracksLuminance() {
        // Doubling scene luminance must cost exactly one stop.
        XCTAssertEqual(Exposure.ev100(luminance: 0.2) + 1, Exposure.ev100(luminance: 0.4), accuracy: 1e-5)
        XCTAssertGreaterThan(Exposure.scale(ev100: 0), Exposure.scale(ev100: 1))
        XCTAssertTrue(Exposure.scale(ev100: Exposure.ev100(luminance: 0)).isFinite)
    }
}
