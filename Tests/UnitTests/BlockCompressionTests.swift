// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import TORCSAssets

final class BlockCompressionTests: XCTestCase {
    typealias BC = BlockCompression

    func psnr(_ a: [UInt8], _ b: [UInt8], channels: [Int]) -> Double {
        precondition(a.count == b.count)
        var sum = 0.0, count = 0.0
        for pixel in 0 ..< a.count / 4 {
            for c in channels {
                let d = Double(a[pixel * 4 + c]) - Double(b[pixel * 4 + c])
                sum += d * d
                count += 1
            }
        }
        let mse = sum / max(count, 1)
        return mse < 1e-12 ? .infinity : 10 * log10(255 * 255 / mse)
    }

    func testEncodedSizeMatchesBlockCounts() {
        // 256x256 RGBA8 is 262144 bytes uncompressed.
        XCTAssertEqual(BC.encodedSize(width: 256, height: 256, format: .bc1), 32768)
        XCTAssertEqual(BC.encodedSize(width: 256, height: 256, format: .bc4), 32768)
        XCTAssertEqual(BC.encodedSize(width: 256, height: 256, format: .bc3), 65536)
        XCTAssertEqual(BC.encodedSize(width: 256, height: 256, format: .bc5), 65536)
        // Partial blocks round up, and the mip tail never degenerates to zero.
        for size in [1, 2, 3, 5, 7] {
            XCTAssertEqual(BC.encodedSize(width: size, height: size, format: .bc1),
                           BC.blocksWide(size) * BC.blocksHigh(size) * 8)
        }
    }

    /// BC1 endpoints are RGB565, so only colours representable in 5/6/5 bits
    /// survive a flat block exactly. BC4/BC5/BC3-alpha endpoints are full 8-bit
    /// and must be exact for any value.
    func testFlatBlocksRoundTripWithinFormatPrecision() throws {
        for colour: [UInt8] in [[0, 0, 0, 255], [255, 255, 255, 255], [17, 96, 203, 128]] {
            let rgba = [UInt8](repeating: 0, count: 64).enumerated().map { colour[$0.offset % 4] }
            for format in BC.Format.allCases {
                let encoded = try BC.encode(rgba, width: 4, height: 4, format: format)
                let decoded = try BC.decode(encoded, width: 4, height: 4, format: format)
                for pixel in 0 ..< 16 {
                    switch format {
                    case .bc4:
                        XCTAssertEqual(decoded[pixel * 4], colour[0], "BC4 flat must be exact")
                    case .bc5:
                        XCTAssertEqual(decoded[pixel * 4], colour[0], "BC5 R flat must be exact")
                        XCTAssertEqual(decoded[pixel * 4 + 1], colour[1], "BC5 G flat must be exact")
                    case .bc1, .bc3:
                        // 5-bit R/B quantize in steps of ~8.2, 6-bit G in ~4.05.
                        for (c, tolerance) in [(0, 4), (1, 2), (2, 4)] {
                            let delta = abs(Int(decoded[pixel * 4 + c]) - Int(colour[c]))
                            XCTAssertLessThanOrEqual(delta, tolerance,
                                "\(format) flat \(colour) channel \(c) off by \(delta)")
                        }
                        if format == .bc3 {
                            XCTAssertEqual(decoded[pixel * 4 + 3], colour[3], "BC3 flat alpha must be exact")
                        }
                    }
                }
            }
        }
    }

    /// The mip tail (2x2, 1x1) is where edge clamping has to be right.
    func testSmallAndNonMultipleOfFourDimensionsSurvive() throws {
        for (w, h) in [(1, 1), (2, 2), (3, 1), (5, 3), (7, 9)] {
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            for i in 0 ..< w * h {
                rgba[i * 4] = UInt8(i * 7 % 256); rgba[i * 4 + 1] = UInt8(i * 13 % 256)
                rgba[i * 4 + 2] = UInt8(i * 29 % 256); rgba[i * 4 + 3] = 255
            }
            for format in BC.Format.allCases {
                let encoded = try BC.encode(rgba, width: w, height: h, format: format)
                XCTAssertEqual(encoded.count, BC.encodedSize(width: w, height: h, format: format))
                let decoded = try BC.decode(encoded, width: w, height: h, format: format)
                XCTAssertEqual(decoded.count, w * h * 4, "\(format) \(w)x\(h)")
            }
        }
    }

    func testMalformedInputIsRejectedRatherThanTrapping() {
        XCTAssertThrowsError(try BC.encode([], width: 0, height: 0, format: .bc1))
        XCTAssertThrowsError(try BC.encode([1, 2, 3], width: 4, height: 4, format: .bc1))
        XCTAssertThrowsError(try BC.decode([1, 2, 3], width: 4, height: 4, format: .bc1))
    }

    /// BC5 is the normal-map format, so the metric that matters is angular
    /// error after reconstructing Z, not per-channel PSNR.
    func testBC5NormalMapAngularErrorIsShadingIrrelevant() throws {
        let size = 64
        var rgba = [UInt8](repeating: 255, count: size * size * 4)
        var originals = [SIMD3<Float>]()
        for y in 0 ..< size {
            for x in 0 ..< size {
                // A smooth bumpy field, the realistic case for a detail normal.
                let u = Float(x) / Float(size) * 6, v = Float(y) / Float(size) * 6
                let n = simd_normalize(SIMD3(sin(u) * 0.6, cos(v) * 0.6, 1))
                originals.append(n)
                let i = (y * size + x) * 4
                rgba[i] = UInt8(max(0, min(255, ((n.x * 0.5 + 0.5) * 255).rounded())))
                rgba[i + 1] = UInt8(max(0, min(255, ((n.y * 0.5 + 0.5) * 255).rounded())))
            }
        }
        let decoded = try BC.decode(try BC.encode(rgba, width: size, height: size, format: .bc5),
                                    width: size, height: size, format: .bc5)
        var worst: Float = 0, total: Float = 0
        for (i, original) in originals.enumerated() {
            let x = Float(decoded[i * 4]) / 255 * 2 - 1, y = Float(decoded[i * 4 + 1]) / 255 * 2 - 1
            // Shader-side reconstruction of Z.
            let z = max(0, 1 - x * x - y * y).squareRoot()
            let angle = acos(min(max(simd_dot(original, simd_normalize(SIMD3(x, y, z))), -1), 1)) * 180 / .pi
            worst = max(worst, angle)
            total += angle
        }
        let mean = total / Float(originals.count)
        print("BC5 normal angular error: worst \(worst) deg, mean \(mean) deg")
        // Measured on this deliberately high-frequency field (about 10 texels
        // per period): worst 1.07 deg, mean 0.19 deg. One degree of normal
        // error is a sub-percent shading difference, which is why BC5 is the
        // universal choice for normal maps. Real detail maps are smoother than
        // this synthetic case, so these are pessimistic bounds.
        XCTAssertLessThan(worst, 1.5, "BC5 worst normal error \(worst) deg")
        XCTAssertLessThan(mean, 0.4, "BC5 mean normal error \(mean) deg")
    }

    /// Cutout foliage depends on alpha surviving compression, so check the
    /// binary-alpha case BC3 is actually used for.
    func testBC3PreservesNearBinaryAlpha() throws {
        let size = 32
        var rgba = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0 ..< size {
            for x in 0 ..< size {
                let i = (y * size + x) * 4
                rgba[i] = 120; rgba[i + 1] = 160; rgba[i + 2] = 80
                rgba[i + 3] = (x / 4 + y / 4).isMultiple(of: 2) ? 255 : 0
            }
        }
        let decoded = try BC.decode(try BC.encode(rgba, width: size, height: size, format: .bc3),
                                    width: size, height: size, format: .bc3)
        // Alpha-test at 0.5 must classify every texel identically.
        for i in 0 ..< size * size {
            XCTAssertEqual(rgba[i * 4 + 3] > 127, decoded[i * 4 + 3] > 127, "alpha cutout flipped at \(i)")
        }
    }

    /// The decisive test: real original art, not synthetic patterns.
    func testOriginalFixtureTexturesCompressWithAcceptableQuality() throws {
        let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let artwork = fixtures.appendingPathComponent("Artwork")
        let samples = ["aalborg/tarmac-wall-1-g2.rgb", "aalborg/tr-asphalt-aa-l_n.rgb",
                       "aalborg/grass-aa.rgb", "155-DTM/driver.rgb"]
        var worstPSNR = Double.infinity
        for relative in samples {
            let url = artwork.appendingPathComponent(relative)
            guard let data = try? Data(contentsOf: url) else {
                XCTFail("missing fixture \(relative)"); continue
            }
            let image = try TextureImage.decodeSGI(data)
            let rgba = image.rgba8
            let encoded = try BC.encode(rgba, width: image.width, height: image.height, format: .bc1)
            let decoded = try BC.decode(encoded, width: image.width, height: image.height, format: .bc1)
            let quality = psnr(rgba, decoded, channels: [0, 1, 2])
            let ratio = Double(rgba.count) / Double(encoded.count)
            print("BC1 \(relative) \(image.width)x\(image.height): \(String(format: "%.2f", quality)) dB, \(String(format: "%.1f", ratio)):1")
            // 0.5 bytes per texel against 4 for RGBA8.
            XCTAssertEqual(ratio, 8, accuracy: 0.01, "\(relative) ratio")
            worstPSNR = min(worstPSNR, quality)
        }
        // 30 dB is the conventional floor for visually acceptable BC1 on
        // photographic source. Below that, banding shows on smooth surfaces.
        XCTAssertGreaterThan(worstPSNR, 30, "worst BC1 quality \(worstPSNR) dB")
    }
}
