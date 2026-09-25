// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
import TORCSAssets
import TORCSMaterials
@testable import TORCSRender

/// The generated sets go to the GPU block-compressed: what that costs in
/// quality, measured on the maps themselves, and that the encode is kept
/// beside the source and served from there.
final class MaterialCompressionTests: XCTestCase {
    func psnr(_ a: [UInt8], _ b: [UInt8], channels: [Int]) -> Double {
        var error = 0.0, count = 0
        for i in stride(from: 0, to: min(a.count, b.count), by: 4) {
            for c in channels { let d = Double(a[i + c]) - Double(b[i + c]); error += d * d; count += 1 }
        }
        let mse = max(error / Double(max(count, 1)), 1e-9)
        return 10 * log10(255 * 255 / mse)
    }

    /// Mean angle between a BC5 normal and its source, in degrees.
    func angularError(_ a: [UInt8], _ b: [UInt8]) -> Double {
        func vector(_ p: [UInt8], _ i: Int) -> SIMD3<Float> {
            let x = Float(p[i]) / 127.5 - 1, y = Float(p[i + 1]) / 127.5 - 1
            return simd_normalize(SIMD3(x, y, sqrt(max(1 - x * x - y * y, 0))))
        }
        var total = 0.0, count = 0
        for i in stride(from: 0, to: min(a.count, b.count), by: 4) {
            let cosine = min(max(simd_dot(vector(a, i), vector(b, i)), -1), 1)
            total += Double(acos(cosine)) * 180 / .pi; count += 1
        }
        return total / Double(max(count, 1))
    }

    func testGeneratedMapsSurviveTheirBlockFormats() throws {
        var report: [String] = []
        for name in ["asphalt", "grass", "kerb", "brushed-metal"] {
            let material = try MaterialRecipes.generate(name, size: 128, seed: 1)
            let size = material.size
            func roundTrip(_ pixels: [UInt8], _ format: BlockCompression.Format) throws -> [UInt8] {
                try BlockCompression.decode(try BlockCompression.encode(pixels, width: size, height: size, format: format),
                                            width: size, height: size, format: format)
            }
            let albedo = psnr(material.albedo, try roundTrip(material.albedo, .bc1), channels: [0, 1, 2])
            let orm = psnr(material.orm, try roundTrip(material.orm, .bc1), channels: [0, 1, 2])
            let ormChannels = [0, 1, 2].map { psnr(material.orm, try! roundTrip(material.orm, .bc1), channels: [$0]) }
            let normal = angularError(material.normal, try roundTrip(material.normal, .bc5))
            report.append(String(format: "%@: albedo BC1 %.1f dB, ORM BC1 %.1f dB (O %.1f R %.1f M %.1f), normal BC5 %.2f deg",
                                 name as NSString, albedo, orm, ormChannels[0], ormChannels[1], ormChannels[2], normal))
            XCTAssertGreaterThan(albedo, 30, "\(name) albedo in BC1: \(albedo) dB")
            XCTAssertGreaterThan(orm, 30, "\(name) ORM in BC1: \(orm) dB")
            XCTAssertLessThan(normal, 1.5, "\(name) normal in BC5: \(normal) deg")
        }
        print("MATERIAL_COMPRESSION " + report.joined(separator: " | "))
    }

    func testMapsUploadCompressedAndTheEncodeIsKeptBesideTheSource() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let directory = try MaterialLibraryTests().materialsDirectory(["armco", "asphalt"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let wasCompressing = MaterialLibrary.compressesMaps
        defer { MaterialLibrary.compressesMaps = wasCompressing }

        MaterialLibrary.compressesMaps = true
        let first = try MaterialLibrary(device: device, directory: directory)
        let armco = try XCTUnwrap(first.resolve(texture: "armco-1.png", directory: directory))
        XCTAssertEqual(armco.albedo.pixelFormat, .bc1_rgba_srgb)
        XCTAssertEqual(armco.normal.pixelFormat, .bc5_rgUnorm)
        XCTAssertEqual(armco.orm.pixelFormat, .bc1_rgba)
        XCTAssertEqual(first.sidecarHits, 0, "nothing to serve the first time")
        for suffix in ["albedo.bc1", "normal.bc5", "orm.bc1"] {
            let sidecar = directory.appendingPathComponent("armco-\(suffix).torcsbc")
            XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path), "missing \(suffix) sidecar")
        }
        let compressedBytes = first.uploadedBytes

        let second = try MaterialLibrary(device: device, directory: directory)
        _ = try XCTUnwrap(second.resolve(texture: "armco-1.png", directory: directory))
        XCTAssertEqual(second.sidecarHits, 3, "the second load reads the encode rather than doing it")
        XCTAssertEqual(second.uploadedBytes, compressedBytes)

        // A damaged sidecar is ignored and rewritten, never uploaded.
        let damaged = directory.appendingPathComponent("armco-albedo.bc1.torcsbc")
        var bytes = try Data(contentsOf: damaged)
        bytes[bytes.count / 2] ^= 0xff
        try bytes.write(to: damaged)
        let third = try MaterialLibrary(device: device, directory: directory)
        _ = try XCTUnwrap(third.resolve(texture: "armco-1.png", directory: directory))
        XCTAssertEqual(third.sidecarHits, 2, "the damaged one was re-encoded")
        XCTAssertNotEqual(try Data(contentsOf: damaged), bytes, "and rewritten")

        MaterialLibrary.compressesMaps = false
        let plain = try MaterialLibrary(device: device, directory: directory)
        let rgba = try XCTUnwrap(plain.resolve(texture: "armco-1.png", directory: directory))
        XCTAssertEqual(rgba.albedo.pixelFormat, .rgba8Unorm_srgb)
        XCTAssertGreaterThan(plain.uploadedBytes, compressedBytes * 4, "RGBA8 is at least four times the bytes")
    }
}
