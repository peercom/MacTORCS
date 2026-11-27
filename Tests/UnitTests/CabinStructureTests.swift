// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
@testable import TORCSRender
import TORCSAssets
import TORCSMaterials

final class CabinStructureTests: XCTestCase {
    /// A driver's picture in miniature: an orange helmet, white overalls, a
    /// black strap across them, a hand, and a grey panel.
    private func picture(side: Int = 64) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        func fill(_ xs: Range<Int>, _ ys: Range<Int>, _ c: (UInt8, UInt8, UInt8)) {
            for y in ys { for x in xs { pixels[(y * side + x) * 4] = c.0; pixels[(y * side + x) * 4 + 1] = c.1; pixels[(y * side + x) * 4 + 2] = c.2 } }
        }
        fill(0 ..< side, 0 ..< side, (235, 235, 235))            // overalls
        fill(0 ..< 16, 0 ..< 32, (230, 140, 20))                 // helmet
        fill(24 ..< 40, 0 ..< side, (12, 12, 14))                // strap
        fill(48 ..< 64, 0 ..< 16, (215, 165, 130))               // a hand
        fill(48 ..< 64, 40 ..< 64, (70, 70, 72))                 // a dark grey panel
        return pixels
    }

    func testAMaterialIsToldByItsColour() {
        let side = 64
        let m = CabinStructure.materials(rgba: picture(), width: side, height: side)
        func at(_ field: [Float], _ x: Int, _ y: Int) -> Float { field[y * side + x] }
        XCTAssertEqual(at(m.paint, 8, 16), 1, accuracy: 0.01, "the helmet is paint")
        XCTAssertEqual(at(m.trim, 8, 16), 0, accuracy: 0.01); XCTAssertEqual(at(m.skin, 8, 16), 0, accuracy: 0.01)
        XCTAssertEqual(at(m.trim, 32, 30), 1, accuracy: 0.01, "the strap is trim")
        XCTAssertEqual(at(m.trim, 56, 52), 1, accuracy: 0.01, "what is dark is trim, grey as well as black")
        XCTAssertEqual(at(m.skin, 56, 8), 1, accuracy: 0.01, "the hand is skin")
        XCTAssertEqual(at(m.paint, 56, 8), 0, accuracy: 0.01)
        // The overalls are none of the three: cloth.
        XCTAssertEqual(at(m.paint, 44, 30) + at(m.trim, 44, 30) + at(m.skin, 44, 30), 0, accuracy: 0.01)
    }

    /// Finer than the picture, each material with its own roughness, cloth
    /// and trim woven and paint smooth.
    func testTheMapIsFinerThanThePictureAndEachMaterialIsItself() {
        XCTAssertEqual(CabinStructure.scale(width: 256, height: 256), 4); XCTAssertEqual(CabinStructure.scale(width: 512, height: 256), 2)
        XCTAssertEqual(CabinStructure.scale(width: 1024, height: 1024), 1)
        let side = 64
        let maps = CabinStructure.derive(rgba: picture(), width: side, height: side)
        XCTAssertEqual(maps.width, side * 4); XCTAssertEqual(maps.height, side * 4)
        XCTAssertEqual(maps.normal.count, maps.width * maps.height * 4); XCTAssertEqual(maps.orm.count, maps.normal.count)
        func roughness(_ x: Int, _ y: Int) -> Int { Int(maps.orm[(y * 4 * maps.width + x * 4) * 4 + 1]) }
        XCTAssertEqual(roughness(8, 16), 51, accuracy: 3, "a helmet shines")
        XCTAssertGreaterThan(roughness(44, 30), 225, "overalls do not")
        XCTAssertEqual(roughness(32, 30), 133, accuracy: 16, "a strap is between")
        XCTAssertEqual(roughness(56, 8), 140, accuracy: 4)
        // How far the normals stray from flat, over a patch.
        func relief(_ x: Int, _ y: Int) -> Int {
            var most = 0
            for dy in 0 ..< 24 { for dx in 0 ..< 24 {
                let i = ((y * 4 + dy) * maps.width + x * 4 + dx) * 4
                most = max(most, abs(Int(maps.normal[i]) - 128), abs(Int(maps.normal[i + 1]) - 128))
            } }
            return most
        }
        XCTAssertLessThanOrEqual(relief(4, 8), 1, "paint is smooth")
        XCTAssertGreaterThan(relief(42, 28), 8, "cloth is woven")
        XCTAssertGreaterThan(relief(28, 28), 4, "trim has its twill")
        for texel in stride(from: 0, to: maps.width * maps.height, by: 11) {
            let n = SIMD3(Float(maps.normal[texel * 4]) / 127.5 - 1, Float(maps.normal[texel * 4 + 1]) / 127.5 - 1, Float(maps.normal[texel * 4 + 2]) / 127.5 - 1)
            XCTAssertEqual(simd_length(n), 1, accuracy: 0.03)
            XCTAssertEqual(maps.orm[texel * 4], 255); XCTAssertEqual(maps.orm[texel * 4 + 2], 0)
        }
    }

    /// A car's cabin and driver take the map made from their picture; its
    /// paint does not, and with no picture to read they keep the weave.
    func testACabinAndADriverTakeTheirOwnMap() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let directory = try MaterialLibraryTests().materialsDirectory(["paint-flake", "fabric"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try MaterialLibrary(device: device, directory: directory)
        let image = try TextureImage(width: 64, height: 64, channels: 4, pixels: picture())
        func part(_ part: CarMaterials.Part, _ texture: String) throws -> RenderBatch {
            let mesh = try RenderMesh.build(positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)],
                                            normals: Array(repeating: SIMD3(0, 0, 1), count: 4),
                                            uv0: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)], indices: [0, 1, 2, 0, 2, 3])
            let state = ACRenderState(material: [0, 0, 0, 1, 0, 0, 0, 1, 0.2, 0.2, 0.2, 1, 0], texture: texture, flags: 8, alphaClamp: 0)
            let base = ResolvedMaterial(baseColour: SIMD4(1, 1, 1, 1), roughness: 0.5, metallic: 0.5)
            return RenderBatch(mesh: mesh, baseTexture: texture, blends: false, isDeferred: false, alphaTestThreshold: nil,
                               culls: true, isDriver: part == .driver, sourceMaterial: state,
                               material: CarMaterials.material(for: part, base: base), carPart: part)
        }
        let scene = RenderScene(batches: [try part(.driver, "driver.rgb"), try part(.interior, "car.rgb"), try part(.paint, "car.rgb"),
                                          try part(.interior, "lost.rgb")],
                                minimum: SIMD3(0, 0, 0), maximum: SIMD3(1, 1, 0))
        let resources = try SceneResources(device: device, scene: scene, materials: library, materialDirectory: directory,
                                           originalImage: { $0 == "lost.rgb" ? nil : image }, resolveTexture: { _, _ in nil })
        let fabric = try XCTUnwrap(library.detailBinding("fabric", directory: directory)).structure
        let flake = try XCTUnwrap(library.detailBinding("paint-flake", directory: directory)).structure
        let driver = try XCTUnwrap(resources.batches[0].structure), cabin = try XCTUnwrap(resources.batches[1].structure)
        XCTAssertFalse(driver === fabric); XCTAssertFalse(cabin === fabric)
        XCTAssertFalse(driver === cabin, "each picture its own map")
        XCTAssertEqual(driver.width, 256); XCTAssertEqual(driver.pixelFormat, .rgba8Unorm); XCTAssertGreaterThan(driver.mipmapLevelCount, 1)
        for index in 0 ..< 2 {
            let draw = resources.batches[index].draw
            XCTAssertEqual(draw.material.x, 1, "the map's roughness is the surface's"); XCTAssertEqual(draw.material.y, 0)
            XCTAssertEqual(draw.maps.y, 1); XCTAssertEqual(draw.fade.z, 1, "laid on the atlas, texel over texel")
        }
        XCTAssertTrue(resources.batches[2].structure === flake, "paint keeps its flake")
        XCTAssertTrue(resources.batches[3].structure === fabric, "no picture: the weave")
        XCTAssertEqual(resources.batches[3].draw.material.x, CarMaterials.material(for: .interior, base: ResolvedMaterial(baseColour: SIMD4(1, 1, 1, 1), roughness: 0.5, metallic: 0.5)).roughness)
        // One picture, one map, however many parts wear it.
        XCTAssertTrue(library.cabinStructure(texture: "car.rgb", image: image) === cabin)
    }
}
