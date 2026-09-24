// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
import TORCSRender
import TORCSAssets

final class CarMaterialsTests: XCTestCase {
    func fixture() throws -> ACScene {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Artwork/155-DTM/155-DTM.acc")
        return try ACScene.parse(Data(contentsOf: url), car: true)
    }

    /// The conventions grcar relies on, applied to the names TORCS cars use.
    func testPartsFollowTheNodeNameConventions() {
        let base = ResolvedMaterial(baseColour: SIMD4(1, 1, 1, 1), roughness: 0.9, metallic: 0)
        XCTAssertEqual(CarMaterials.part(name: "CARBODY_s_90", texture: "155-DTM.rgb", isDriver: false), .paint)
        XCTAssertEqual(CarMaterials.part(name: "WIFRONTWINDOW_s_0", texture: "155-DTM.rgb", isDriver: false), .glass)
        XCTAssertEqual(CarMaterials.part(name: "WISIDE_s_3", texture: nil, isDriver: false), .glass)
        XCTAssertEqual(CarMaterials.part(name: "WILIGHTREAR1_s_0", texture: nil, isDriver: false), .lens)
        XCTAssertEqual(CarMaterials.part(name: "WIFRONTLIGHT_s_1", texture: nil, isDriver: false), .lens)
        XCTAssertEqual(CarMaterials.part(name: "BODYINTERIOR_s_30", texture: nil, isDriver: false), .interior)
        XCTAssertEqual(CarMaterials.part(name: "DRIVER_s_22", texture: "driver.rgb", isDriver: false), .driver)
        XCTAssertEqual(CarMaterials.part(name: "anything", texture: nil, isDriver: true), .driver)
        XCTAssertEqual(CarMaterials.part(name: "wheel", texture: "tex-wheel.rgb", isDriver: false), .wheel)
        // A wheel arch is body, not wheel.
        XCTAssertEqual(CarMaterials.part(name: "WHEELCOVERBODY_s_3", texture: "155-DTM.rgb", isDriver: false), .paint)
        // Paint is the only coated part, and glass the smoothest.
        let paint = CarMaterials.material(for: .paint, base: base), glass = CarMaterials.material(for: .glass, base: base)
        XCTAssertEqual(paint.clearcoat, 1)
        XCTAssertEqual(glass.clearcoat, 0)
        XCTAssertLessThan(glass.roughness, paint.roughness)
        XCTAssertEqual(paint.baseColour, base.baseColour, "the atlas colour is kept")
    }

    /// Flattening a car with the flag must produce distinct materials, and
    /// must not touch which batches are transparent: glass stays deferred
    /// whether or not it is coated.
    func testCarFlagDifferentiatesMaterialsWithoutChangingTransparency() throws {
        let scene = try fixture()
        let plain = try RenderScene(scene), car = try RenderScene(scene, car: true)
        XCTAssertEqual(plain.batches.count, car.batches.count)
        XCTAssertEqual(plain.batches.map(\.isDeferred), car.batches.map(\.isDeferred))
        XCTAssertEqual(Set(plain.batches.map(\.material.roughness)).count, 1, "one AC material means one roughness")
        XCTAssertGreaterThan(Set(car.batches.map(\.material.roughness)).count, 2)
        XCTAssertTrue(car.batches.contains { $0.material.clearcoat > 0 }, "some paint")
        XCTAssertTrue(car.batches.contains { $0.isDeferred && $0.material.roughness < 0.1 }, "some glass")
    }

    func testCarMaterialsChangeTheRenderedFrame() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        var settings = RenderSettings()
        settings.bloom = false
        let renderer = try ForwardRenderer(settings: settings)
        let scene = try fixture()
        let camera = RenderCamera(eye: SIMD3(6, -5, 2), target: SIMD3(0, 0, 0.5))
        let plain = try renderer.render(scene: try SceneResources(device: renderer.device, scene: RenderScene(scene)),
                                        camera: camera, lighting: SunLighting(), width: 256, height: 160)
        let car = try renderer.render(scene: try SceneResources(device: renderer.device, scene: RenderScene(scene, car: true)),
                                      camera: camera, lighting: SunLighting(), width: 256, height: 160)
        XCTAssertNotEqual(plain, car)
    }
}
