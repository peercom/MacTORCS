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
        for name in ["asphalt", "grass", "concrete", "asphalt-patched", "brick", "armco", "carbon-weave", "sand",
                     "rock", "snow", "tyre-wall", "tyre-top"] {
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

    /// Grass is blades: green, with a root and a tip, each its own shade, so
    /// neighbouring texels differ. And it is the same grass all over its
    /// tile: a tile with a landmark in it, one dry patch or one dark one,
    /// shows as a grid of them on every hillside.
    func testTurfIsBladesAndHasNoLandmarks() throws {
        let size = 256
        func statistics(_ name: String) throws -> (mean: SIMD3<Double>, texelContrast: Double, blockSpread: Double) {
            let material = try MaterialRecipes.generate(name, size: size, seed: 1)
            XCTAssertEqual(material.worldSize, 8, "\(name) is made for a large tile")
            var mean = SIMD3<Double>.zero
            var luminance = [Double](repeating: 0, count: size * size)
            for texel in 0 ..< size * size {
                let c = SIMD3(Double(material.albedo[texel * 4]), Double(material.albedo[texel * 4 + 1]),
                              Double(material.albedo[texel * 4 + 2]))
                mean += c
                luminance[texel] = (c.x + c.y + c.z) / 3
            }
            mean /= Double(size * size)
            // Difference between horizontal neighbours: the blades.
            var contrast = 0.0
            for y in 0 ..< size { for x in 0 ..< size - 1 { contrast += abs(luminance[y * size + x] - luminance[y * size + x + 1]) } }
            contrast /= Double(size * (size - 1))
            // Means of the sixteen quarters-of-quarters of the tile: the landmarks.
            var blocks = [Double]()
            let side = size / 4
            for by in 0 ..< 4 {
                for bx in 0 ..< 4 {
                    var total = 0.0
                    for y in 0 ..< side { for x in 0 ..< side { total += luminance[(by * side + y) * size + bx * side + x] } }
                    blocks.append(total / Double(side * side))
                }
            }
            let overall = blocks.reduce(0, +) / 16
            return (mean, contrast, (blocks.max()! - blocks.min()!) / overall)
        }
        let grass = try statistics("grass"), dry = try statistics("grass-dry")
        XCTAssertGreaterThan(grass.mean.y, grass.mean.x * 1.25, "grass is green: \(grass.mean)")
        XCTAssertGreaterThan(grass.mean.y, grass.mean.z * 1.8)
        XCTAssertGreaterThan(grass.texelContrast, 6, "blades differ from their neighbours: \(grass.texelContrast)")
        XCTAssertLessThan(grass.blockSpread, 0.25, "no part of the tile stands out from the rest: \(grass.blockSpread)")
        XCTAssertLessThan(dry.blockSpread, 0.25)
        XCTAssertGreaterThan(dry.mean.x / dry.mean.y, grass.mean.x / grass.mean.y + 0.08, "the dry set has more straw in it")
        // The ground is generated larger than the rest, its tile being so.
        XCTAssertEqual(MaterialRecipes.sizeMultiple(for: "grass"), 2)
        XCTAssertEqual(MaterialRecipes.sizeMultiple(for: "grass-dry"), 2)
        XCTAssertEqual(MaterialRecipes.sizeMultiple(for: "asphalt"), 1)
    }

    /// Snow is nearly white and barely varies in colour; a rock face is
    /// neither, and its joints are darker than its faces.
    func testSnowIsPaleAndRockIsJointed() throws {
        let snow = try MaterialRecipes.generate("snow", size: 128, seed: 1)
        let rock = try MaterialRecipes.generate("rock", size: 128, seed: 1)
        var low = 255, high = 0
        for texel in 0 ..< 128 * 128 { low = min(low, Int(snow.albedo[texel * 4 + 1])); high = max(high, Int(snow.albedo[texel * 4 + 1])) }
        XCTAssertGreaterThan(low, 200, "snow is pale everywhere")
        var rockLow = 255, rockHigh = 0
        for texel in 0 ..< 128 * 128 { rockLow = min(rockLow, Int(rock.albedo[texel * 4])); rockHigh = max(rockHigh, Int(rock.albedo[texel * 4])) }
        XCTAssertGreaterThan(rockHigh - rockLow, 80, "a rock face has joints and faces")
        XCTAssertGreaterThan(high - low + 1, 0)
    }

    /// The road's layer of wear: reproducible, continuous where it comes
    /// round, mostly saying nothing, with tar in thin lines and grime only
    /// along the two edges.
    func testRoadWearIsSparseAndComesRoundWithoutASeam() throws {
        let width = 512, height = 128
        let wear = RoadWear.generate(width: width, height: height, seed: 1)
        XCTAssertEqual(wear.count, width * height * 4)
        XCTAssertEqual(wear, RoadWear.generate(width: width, height: height, seed: 1), "reproducible")
        XCTAssertNotEqual(wear, RoadWear.generate(width: width, height: height, seed: 2))
        XCTAssertEqual(RoadWear.length, 96)
        func value(_ x: Int, _ y: Int, _ channel: Int) -> Int { Int(wear[(y * width + x) * 4 + channel]) }
        var tone = 0.0, tarred = 0, grimeMiddle = 0, grimeEdge = 0, seam = 0.0, within = 0.0
        for y in 0 ..< height {
            for x in 0 ..< width {
                tone += Double(value(x, y, 0))
                if value(x, y, 2) > 128 { tarred += 1 }
                if y > height / 4 && y < height * 3 / 4 { grimeMiddle = max(grimeMiddle, value(x, y, 3)) }
                if y == 0 || y == height - 1 { grimeEdge += value(x, y, 3) }
            }
            // Where the map comes round, against the day joint a quarter of
            // the way along: it is a joint like that one and no more.
            seam += Double(abs(value(2, y, 0) - value(width - 3, y, 0)))
            let joint = Int(0.23 * Double(width))
            within += Double(abs(value(joint + 2, y, 0) - value(joint - 3, y, 0)))
        }
        XCTAssertEqual(tone / Double(width * height), 128, accuracy: 14, "mostly the asphalt as it is")
        let share = Double(tarred) / Double(width * height)
        XCTAssertGreaterThan(share, 0.001, "there are sealed joints and cracks")
        XCTAssertLessThan(share, 0.06, "and they are lines, not areas: \(share)")
        XCTAssertEqual(grimeMiddle, 0, "no grime where the tyres run")
        XCTAssertGreaterThan(grimeEdge / (2 * width), 60, "grime along both edges")
        XCTAssertLessThan(seam / Double(height), within / Double(height) * 2 + 8,
                          "where it comes round is one more day's joint")
    }
}

/// The sets for what stands along the track are laid out as their objects.
extension MaterialGenerationTests {
    private func luminance(_ m: GeneratedMaterial, _ x: Int, _ y: Int) -> Float {
        let i = (y * m.size + x) * 4
        return (Float(m.albedo[i]) + Float(m.albedo[i + 1]) + Float(m.albedo[i + 2])) / 3
    }

    /// Six tyres up the tile and two stacks along it, the top row painted,
    /// the gaps between the stacks in the dark.
    func testATyreWallIsStacksSeenEdgeOnWithAPaintedTopRow() throws {
        let m = try MaterialRecipes.generate("tyre-wall", size: 256, seed: 1)
        XCTAssertEqual(m.worldSize, 1.3, "the tile is the wall's height")
        let size = m.size, row = size / 6
        func rowMean(_ index: Int) -> Float {
            var sum: Float = 0
            for y in index * row + row / 4 ..< index * row + row * 3 / 4 { for x in 0 ..< size { sum += luminance(m, x, y) } }
            return sum / Float(size * (row / 2))
        }
        let rows = (0 ..< 6).map(rowMean)
        for other in 1 ..< 6 { XCTAssertGreaterThan(rows[0], rows[other] * 2.5, "row \(other) against the painted one") }
        // Rubber is black: no unpainted row is lighter than a dark grey.
        XCTAssertLessThan(rows[1 ..< 6].max()!, 70)
        func columnMean(_ x: Int) -> Float {
            var sum: Float = 0
            for y in row ..< size { sum += luminance(m, x, y) }
            return sum / Float(size - row)
        }
        for stack in 0 ..< 2 {
            let middle = columnMean(stack * size / 2 + size / 4), edge = columnMean(stack * size / 2)
            XCTAssertGreaterThan(middle, edge * 2, "stack \(stack) is not round")
        }
        // Each tyre is a drum: its normals lean left on its left and right on its right.
        var left: Float = 0, right: Float = 0
        for y in row ..< size {
            left += Float(m.normal[(y * size + size / 8) * 4]); right += Float(m.normal[(y * size + size * 3 / 8) * 4])
        }
        XCTAssertGreaterThan(abs(left - right) / Float(size - row), 20)
    }

    func testATyreWallsTopIsOnePaintedRingToATile() throws {
        let m = try MaterialRecipes.generate("tyre-top", size: 256, seed: 1)
        XCTAssertEqual(m.worldSize, 0.65, "a tile to a stack")
        let size = m.size, centre = size / 2
        XCTAssertLessThan(luminance(m, centre, centre), 26, "down the middle is the inside of the stack")
        XCTAssertLessThan(luminance(m, 1, 1), 26, "between the stacks is the ground")
        var ring: Float = 0
        for step in 0 ..< 64 {
            let angle = Float(step) / 64 * 2 * .pi
            ring += luminance(m, centre + Int(cos(angle) * 0.38 * Float(size)), centre + Int(sin(angle) * 0.38 * Float(size)))
        }
        XCTAssertGreaterThan(ring / 64, 60, "the sidewall is painted")
    }

    /// A block of each colour to the tile, and sixteen teeth along it.
    func testAKerbIsRibbedBlocksRedAndWhiteByTurns() throws {
        let m = try MaterialRecipes.generate("kerb", size: 256, seed: 1)
        XCTAssertEqual(m.worldSize, 2)
        let size = m.size
        func mean(_ range: Range<Int>, channel: Int) -> Float {
            var sum: Float = 0
            for y in 0 ..< size { for x in range { sum += Float(m.albedo[(y * size + x) * 4 + channel]) } }
            return sum / Float(size * range.count)
        }
        let red = size / 16 ..< size * 7 / 16, white = size * 9 / 16 ..< size * 15 / 16
        XCTAssertGreaterThan(mean(red, channel: 0), mean(red, channel: 1) * 2, "the first block is red")
        XCTAssertLessThan(abs(mean(white, channel: 0) - mean(white, channel: 1)), 8, "the second is white")
        XCTAssertGreaterThan(mean(white, channel: 1), mean(red, channel: 1) * 2)
        // The teeth: the normal's lean along the kerb comes round every sixteenth of the tile.
        let lean = (0 ..< size).map { x -> Float in
            var sum: Float = 0
            for y in 0 ..< size { sum += Float(m.normal[(y * size + x) * 4]) }
            return sum / Float(size)
        }
        let pitch = size / 16
        var inStep: Float = 0, outOfStep: Float = 0
        for x in 0 ..< size {
            inStep += abs(lean[x] - lean[(x + pitch) % size]); outOfStep += abs(lean[x] - lean[(x + pitch / 2) % size])
        }
        XCTAssertLessThan(inStep * 3, outOfStep, "no sixteen ribs: \(inStep) in step, \(outOfStep) out")
    }

    /// Three beams one above another with a dark gap between, each a W of
    /// two ribs; steel, but weathered dull and not drawn as a mirror.
    func testAGuardRailIsThreeBeamsOfWeatheredZinc() throws {
        // A size three divides, so each gap falls on a row of its own.
        let m = try MaterialRecipes.generate("armco", size: 192, seed: 1)
        XCTAssertFalse(m.isMetal)
        let size = m.size, beam = size / 3
        let rows = (0 ..< size).map { y -> Float in
            var sum: Float = 0
            for x in 0 ..< size { sum += luminance(m, x, y) }
            return sum / Float(size)
        }
        let body = rows.sorted()[size / 2]
        for index in 0 ..< 3 {
            XCTAssertLessThan(rows[index * beam], body * 0.4, "no gap under beam \(index)")
            XCTAssertGreaterThan(rows[index * beam + beam / 4], body * 0.7, "beam \(index) has no rib")
        }
        // The W: up the beam the normal tips up, down, up and down again.
        let tilt = (0 ..< beam).map { y -> Float in
            var sum: Float = 0
            for x in 0 ..< size { sum += Float(m.normal[(y * size + x) * 4 + 1]) - 127.5 }
            return sum / Float(size)
        }
        var turns = 0
        var last: Float = 0
        for value in tilt where abs(value) > 6 {
            if last != 0, (value > 0) != (last > 0) { turns += 1 }
            last = value
        }
        XCTAssertEqual(turns, 3, "two ribs make three turns of the normal")
        var roughest = 0, smoothest = 255
        for texel in 0 ..< size * size { roughest = max(roughest, Int(m.orm[texel * 4 + 1])); smoothest = min(smoothest, Int(m.orm[texel * 4 + 1])) }
        XCTAssertGreaterThan(smoothest, 76, "weathered zinc is nowhere glossy")
    }
}
