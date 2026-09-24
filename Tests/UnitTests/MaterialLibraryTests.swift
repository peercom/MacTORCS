// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import ImageIO
import UniformTypeIdentifiers
import TORCSRender
import TORCSAssets
import TORCSMaterials

final class MaterialLibraryTests: XCTestCase {
    func testNamesMapToTheMaterialList() {
        let cases: [(String, String?)] = [
            ("tr-asphalt-aa-bw1_n.rgb", "asphalt"), ("tr-asphalt-aa-l_n.rgb", "asphalt-patched"),
            ("tr-asphalt-2-aa-r_n.rgb", "asphalt-patched"), ("tr-curb-bw-aa-r.rgb", "kerb"),
            ("grass-aa.rgb", "grass"), ("tr-g-to-asphalt-aa-l_n.rgb", "grass"),
            ("tarmac-wall-2-g2.rgb", "concrete"), ("tr-barrier-aa-1.rgb", "concrete"),
            ("armco-1.png", "armco"), ("tyres.png", "tyre-wall"), ("fence-2.rgb", "chain-link"),
            ("brick-red.png", "brick"), ("wood-fence.png", "wood"), ("pylon1.rgb", "painted-steel"),
            ("sand-pit.rgb", "sand"), ("mud-1.rgb", "mud"), ("155-DTM.rgb", nil), ("shadow2.rgb", nil)]
        for (texture, expected) in cases {
            XCTAssertEqual(MaterialLibrary.material(for: texture), expected, texture)
        }
        for material in MaterialLibrary.rules.map(\.material) {
            XCTAssertTrue(MaterialRecipes.all.contains(material), "rule targets an unknown set \(material)")
        }
    }

    func testCarPartsTakeDetailSets() {
        XCTAssertEqual(MaterialLibrary.detail(for: .paint)?.material, "paint-flake")
        XCTAssertEqual(MaterialLibrary.detail(for: .wheel)?.material, "rubber-tread")
        XCTAssertEqual(MaterialLibrary.detail(for: .interior)?.material, "fabric")
        XCTAssertNil(MaterialLibrary.detail(for: .glass))
        XCTAssertNil(MaterialLibrary.detail(for: .brakeLens))
        for part in CarMaterials.Part.allCases {
            if let choice = MaterialLibrary.detail(for: part) {
                XCTAssertTrue(MaterialRecipes.all.contains(choice.material), "\(part)")
                XCTAssertGreaterThan(choice.uvScale, 1)
            }
        }
    }

    /// Writes a few small sets to a temporary directory, as the generator would.
    func materialsDirectory(_ names: [String]) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("torcs-materials-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var manifest: [[String: Any]] = []
        for name in names {
            let material = try MaterialRecipes.generate(name, size: 32, seed: 1)
            for (suffix, bytes) in [("albedo", material.albedo), ("normal", material.normal), ("orm", material.orm)] {
                let space = CGColorSpace(name: CGColorSpace.sRGB)!
                let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
                let image = try XCTUnwrap(CGImage(width: 32, height: 32, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 128,
                                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
                let url = directory.appendingPathComponent("\(name)-\(suffix).png")
                let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
                CGImageDestinationAddImage(destination, image, nil)
                XCTAssertTrue(CGImageDestinationFinalize(destination))
            }
            manifest.append(["name": name, "size": 32, "worldSize": material.worldSize, "metal": material.isMetal])
        }
        try JSONSerialization.data(withJSONObject: ["materials": manifest]).write(to: directory.appendingPathComponent("materials.json"))
        return directory
    }

    /// A car's paint takes the flake set's structure under its own atlas,
    /// and a metal set marks its binding as metal.
    func testCarBatchesBindDetailStructureAndMetalSetsAreFlagged() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let directory = try materialsDirectory(["paint-flake", "rubber-tread", "fabric", "armco"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try MaterialLibrary(device: device, directory: directory)
        let armco = try XCTUnwrap(library.resolve(texture: "armco-1.png", directory: directory))
        XCTAssertTrue(armco.metallic)
        let flake = try XCTUnwrap(library.detailBinding("paint-flake", directory: directory))
        XCTAssertTrue(flake.metallic)

        let scene = try MotionBlurTests().fixtureScene()
        XCTAssertTrue(scene.batches.contains { $0.carPart == .paint })
        let resources = try SceneResources(device: device, scene: scene, materials: library, materialDirectory: directory,
                                           resolveTexture: { _, _ in nil })
        XCTAssertGreaterThan(resources.structuredBatches, 0, "no car batch took a detail set")
        XCTAssertEqual(resources.structuredBatches, scene.batches.filter { $0.carPart.flatMap(MaterialLibrary.detail) != nil }.count)
    }
}
