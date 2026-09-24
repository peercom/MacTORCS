// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
import TORCSRender
import TORCSAssets
import TORCSTrackMesh

/// The plan's memory budget: total Metal allocation under the preset's cap
/// on an 8 GB machine, with a whole generated circuit, its car, and native
/// output targets resident.
final class MemoryBudgetTests: XCTestCase {
    func testGeneratedCircuitAtNativeOutputStaysUnderTheBudget() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        let road = try RoadGenerationTests().aalborg()
        let car = try MotionBlurTests().fixtureScene()
        var batches = try TrackSurfaceAssembly.roadBatches(road.geometry)
        if let terrain = try TrackSurfaceAssembly.terrainBatch(road.geometry, parameters: TerrainParameters()) {
            batches.append(terrain)
        }
        batches += try TrackSurfaceAssembly.grassBatches(road.geometry)
        let scene = car.adding(batches)

        let settings = RenderSettings(preset: .m2Air)
        let renderer = try ForwardRenderer(settings: settings)
        let resources = try SceneResources(device: renderer.device, scene: scene)
        let camera = RenderCamera(eye: SIMD3(0, -40, 20), target: SIMD3(0, 0, 0))
        for _ in 0 ..< 3 {
            _ = try renderer.render(scene: resources, camera: camera, lighting: SunLighting(), width: 2560, height: 1664)
        }
        let bytes = renderer.device.currentAllocatedSize
        print(String(format: "MEMORY_BUDGET allocatedMB=%.1f budgetMB=%.0f batches=%d",
                     Double(bytes) / 1_048_576, Double(settings.textureMemoryBudgetBytes) / 1_048_576, scene.batches.count))
        XCTAssertLessThan(bytes, settings.textureMemoryBudgetBytes)
    }
}
