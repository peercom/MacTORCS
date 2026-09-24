// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import TORCSMaterials

final class MaterialGenerationTests: XCTestCase {
    /// Generated sets are content. If the same seed did not produce the same
    /// bytes, the pipeline could not hash-verify its own output and a
    /// "regenerate" would silently change what ships.
    func testGenerationIsDeterministic() throws {
        for name in ["asphalt", "grass", "kerb"] {
            let first = try MaterialRecipes.generate(name, size: 64, seed: 7)
            let second = try MaterialRecipes.generate(name, size: 64, seed: 7)
            XCTAssertEqual(first.albedo, second.albedo, "\(name) albedo not reproducible")
            XCTAssertEqual(first.normal, second.normal, "\(name) normal not reproducible")
            XCTAssertEqual(first.orm, second.orm, "\(name) ORM not reproducible")
        }
    }

    func testSeedChangesTheResult() throws {
        let a = try MaterialRecipes.generate("asphalt", size: 64, seed: 1)
        let b = try MaterialRecipes.generate("asphalt", size: 64, seed: 2)
        XCTAssertNotEqual(a.albedo, b.albedo, "seed had no effect")
    }

    func testEveryRecipeProducesCompleteWellFormedMaps() throws {
        for name in MaterialRecipes.all {
            let material = try MaterialRecipes.generate(name, size: 64, seed: 3)
            let texels = material.size * material.size
            XCTAssertEqual(material.albedo.count, texels * 4, "\(name) albedo size")
            XCTAssertEqual(material.normal.count, texels * 4, "\(name) normal size")
            XCTAssertEqual(material.orm.count, texels * 4, "\(name) ORM size")
            XCTAssertGreaterThan(material.worldSize, 0, "\(name) needs a real world size")

            // Normals must decode to unit vectors pointing out of the surface,
            // or lighting is wrong wherever the map is used.
            for texel in stride(from: 0, to: texels, by: 7) {
                let n = SIMD3(Float(material.normal[texel * 4]) / 255 * 2 - 1,
                              Float(material.normal[texel * 4 + 1]) / 255 * 2 - 1,
                              Float(material.normal[texel * 4 + 2]) / 255 * 2 - 1)
                XCTAssertEqual(simd_length(n), 1, accuracy: 0.02, "\(name) normal not unit at \(texel)")
                XCTAssertGreaterThan(n.z, 0, "\(name) normal points into the surface at \(texel)")
            }

            // Roughness must never reach zero: a perfect mirror produces a
            // specular lobe that aliases into single pixels. Chrome and glass
            // are allowed lower, but not zero.
            var minimumRoughness = 255
            let metal = MaterialRecipes.metals.contains(name)
            for texel in 0 ..< texels {
                minimumRoughness = min(minimumRoughness, Int(material.orm[texel * 4 + 1]))
                if metal {
                    XCTAssertEqual(material.orm[texel * 4 + 2], 255, "\(name) should be metal")
                } else {
                    XCTAssertEqual(material.orm[texel * 4 + 2], 0, "\(name) should be dielectric")
                }
            }
            XCTAssertEqual(material.isMetal, metal, "\(name) metal flag")
            XCTAssertGreaterThan(minimumRoughness, MaterialRecipes.smooth.contains(name) ? 10 : 40,
                                 "\(name) has a near-mirror texel")
        }
    }

    /// These textures tile. A discontinuity at the wrap shows as a hard line
    /// repeating across the surface, which is the most visible failure a
    /// generated material can have.
    func testMaterialsTileWithoutASeam() throws {
        for name in ["asphalt", "grass", "concrete", "asphalt-patched", "brick", "armco", "carbon-weave", "sand"] {
            let material = try MaterialRecipes.generate(name, size: 64, seed: 5)
            let size = material.size
            func albedo(_ x: Int, _ y: Int) -> Int { Int(material.albedo[(y * size + x) * 4]) }
            var worstHorizontal = 0, worstInterior = 0
            for y in 0 ..< size {
                // Across the wrap, against the largest step anywhere inside:
                // a seam is a discontinuity bigger than any the texture has
                // on purpose, such as a tar snake or a mortar line.
                worstHorizontal = max(worstHorizontal, abs(albedo(0, y) - albedo(size - 1, y)))
                for x in 1 ..< size { worstInterior = max(worstInterior, abs(albedo(x, y) - albedo(x - 1, y))) }
            }
            XCTAssertLessThanOrEqual(worstHorizontal, worstInterior + 8,
                                     "\(name) seams at the wrap: \(worstHorizontal) vs interior \(worstInterior)")
        }
    }

    func testUnknownRecipeIsRejected() {
        XCTAssertThrowsError(try MaterialRecipes.generate("marzipan", size: 32))
    }

    /// The fix for substitution deleting lane markings.
    func testMarkingExtractionKeepsPaintAndLeavesSurfaceAlone() {
        let size = 64
        // A flat mid-grey surface with one bright stripe, standing in for a
        // lane marking on tarmac.
        var original = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0 ..< size {
            for x in 0 ..< size {
                let painted = x >= 30 && x < 34
                let value: UInt8 = painted ? 240 : 40
                for channel in 0 ..< 3 { original[(y * size + x) * 4 + channel] = value }
            }
        }
        let generated = [UInt8](repeating: 90, count: size * size * 4)
        let merged = MarkingExtraction.composite(generated: generated, original: original, size: size)

        for y in stride(from: 0, to: size, by: 8) {
            // The stripe survives.
            XCTAssertGreaterThan(Int(merged[(y * size + 32) * 4]), 180, "marking lost at row \(y)")
            // The surface away from it is the generated material, untouched.
            XCTAssertEqual(Int(merged[(y * size + 8) * 4]), 90, "surface altered at row \(y)")
        }
    }

    func testMarkingExtractionIgnoresAnUnmarkedSurface() {
        let size = 32
        let original = [UInt8](repeating: 60, count: size * size * 4)
        let generated = [UInt8](repeating: 120, count: size * size * 4)
        XCTAssertEqual(MarkingExtraction.composite(generated: generated, original: original, size: size),
                       generated, "a surface with no paint must pass through unchanged")
    }

    func testNoiseWrapsAtItsPeriod() {
        for seed in [UInt32(1), 99] {
            for y in stride(from: Float(0), to: 8, by: 1.3) {
                XCTAssertEqual(Noise.value(0, y, period: 8, seed: seed),
                               Noise.value(8, y, period: 8, seed: seed), accuracy: 1e-5)
                XCTAssertEqual(Noise.worley(0.25, y, period: 8, seed: seed),
                               Noise.worley(8.25, y, period: 8, seed: seed), accuracy: 1e-5)
            }
        }
    }
}
