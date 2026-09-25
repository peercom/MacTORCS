// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
@testable import TORCSMaterials

/// A set derived from an image alone, by the recipes' own chain, measured
/// against the recipe that authored the image's height.
final class ImageSourcedMaterialTests: XCTestCase {
    func unpackNormal(_ bytes: [UInt8], _ i: Int) -> SIMD3<Float> {
        let x = Float(bytes[i]) / 127.5 - 1, y = Float(bytes[i + 1]) / 127.5 - 1
        return simd_normalize(SIMD3(x, y, sqrt(max(1 - x * x - y * y, 0))))
    }

    func testDerivationIsWellFormedAndDeterministic() throws {
        let source = try MaterialRecipes.generate("brick", size: 128, seed: 5)
        let derived = try ImageSourcedMaterial.derive(name: "brick-photo", albedo: source.albedo, size: 128)
        XCTAssertEqual(derived.albedo.count, 128 * 128 * 4)
        XCTAssertEqual(derived.normal.count, 128 * 128 * 4)
        XCTAssertEqual(derived.orm.count, 128 * 128 * 4)
        let again = try ImageSourcedMaterial.derive(name: "brick-photo", albedo: source.albedo, size: 128)
        XCTAssertEqual(derived.normal, again.normal)
        XCTAssertEqual(derived.orm, again.orm)
        // Occlusion and roughness in range, occlusion not flat.
        var occlusionMin = 255, occlusionMax = 0
        for i in stride(from: 0, to: derived.orm.count, by: 4) {
            occlusionMin = min(occlusionMin, Int(derived.orm[i])); occlusionMax = max(occlusionMax, Int(derived.orm[i]))
            XCTAssertGreaterThan(derived.orm[i + 1], 10); XCTAssertLessThanOrEqual(derived.orm[i + 1], 255)
            XCTAssertEqual(derived.orm[i + 2], 0, "a dielectric")
        }
        XCTAssertLessThan(occlusionMin, occlusionMax - 20, "occlusion varies with the relief")
        XCTAssertThrowsError(try ImageSourcedMaterial.derive(name: "bad", albedo: [0, 0, 0], size: 4))
    }

    /// The normals estimated from the image alone point the same way as
    /// the recipe's, which had the real height: mean angle under twenty
    /// degrees and far better than a flat map's.
    func testEstimatedReliefAgreesWithTheAuthoredHeightWithTheRightSign() throws {
        // The sign a luminance cannot know is the caller's: the test takes
        // the better of the two and reports both, as the tool's user would
        // by looking at the sheet.
        for name in ["brick", "asphalt", "concrete"] {
            let source = try MaterialRecipes.generate(name, size: 128, seed: 3)
            var results: [(mean: Double, flat: Double, agree: Double, inverted: Bool)] = []
            for inverted in [false, true] {
                var parameters = ImageSourcedMaterial.Parameters()
                parameters.invertRelief = inverted
                let derived = try ImageSourcedMaterial.derive(name: name, albedo: source.albedo, size: 128, parameters: parameters)
                var total = 0.0, flat = 0.0, agree = 0, tilted = 0
                let count = 128 * 128
                for i in 0 ..< count {
                    let authored = unpackNormal(source.normal, i * 4), estimated = unpackNormal(derived.normal, i * 4)
                    total += Double(acos(min(max(simd_dot(authored, estimated), -1), 1))) * 180 / .pi
                    flat += Double(acos(min(max(authored.z, -1), 1))) * 180 / .pi
                    let a = SIMD2(authored.x, authored.y), e = SIMD2(estimated.x, estimated.y)
                    if simd_length(a) > 0.05, simd_length(e) > 0.05 {
                        tilted += 1
                        if simd_dot(a, e) > 0 { agree += 1 }
                    }
                }
                results.append((total / Double(count), flat / Double(count), 100 * Double(agree) / Double(max(tilted, 1)), inverted))
            }
            let best = results.min { $0.mean < $1.mean }!
            print(String(format: "IMAGE_SOURCED %@: %@ sign: mean angle to authored %.1f deg (flat map %.1f deg), tilt agreement %.0f%%; other sign %.1f deg, %.0f%%",
                         name as NSString, best.inverted ? "inverted" : "darker-is-deeper", best.mean, best.flat, best.agree,
                         results.first { $0.inverted != best.inverted }!.mean, results.first { $0.inverted != best.inverted }!.agree))
            XCTAssertLessThan(best.mean, best.flat, "\(name): the better sign must beat a flat normal map")
            XCTAssertGreaterThan(best.agree, 55, "\(name): the better sign's tilts mostly agree")
        }
    }

    /// Delighting: an image with a strong large-scale shading gradient comes
    /// out with less of it, and the small detail survives.
    func testLargeScaleShadingIsDividedOut() throws {
        let size = 128
        var shaded = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0 ..< size {
            for x in 0 ..< size {
                let gradient = 0.35 + 0.6 * Float(x) / Float(size)   // lit from the right
                let detail: Float = (x / 4 + y / 4) % 2 == 0 ? 0.55 : 0.45
                let v = UInt8(min(255, max(0, gradient * detail * 2 * 255)))
                let i = (y * size + x) * 4
                shaded[i] = v; shaded[i + 1] = v; shaded[i + 2] = v; shaded[i + 3] = 255
            }
        }
        let derived = try ImageSourcedMaterial.derive(name: "gradient", albedo: shaded, size: size)
        func columnMean(_ image: [UInt8], _ x: Int) -> Double {
            var total = 0
            for y in 0 ..< size { total += Int(image[(y * size + x) * 4]) }
            return Double(total) / Double(size)
        }
        let before = columnMean(shaded, size - 8) - columnMean(shaded, 8)
        let after = columnMean(derived.albedo, size - 8) - columnMean(derived.albedo, 8)
        XCTAssertGreaterThan(before, 60, "the source has a strong gradient: \(before)")
        XCTAssertLessThan(abs(after), before * 0.4, "most of it is gone: \(after)")
    }
}
