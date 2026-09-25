// SPDX-License-Identifier: GPL-2.0-only
import Metal
import XCTest
@testable import TORCSRender

final class PipelineArchiveTests: XCTestCase {
    func testArchiveIsWrittenLoadedAndRendersTheSameFrame() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("torcs-archive-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = RenderSettings()
        settings.bloom = false; settings.motionBlur = false; settings.upscaling = false
        let scene = try MotionBlurTests().fixtureScene()
        let camera = RenderCamera(eye: SIMD3(6, -5, 2), target: SIMD3(0, 0, 0.5))

        let first = try PipelineArchive(device: device, directory: directory)
        XCTAssertFalse(first.loaded, "nothing to load the first time")
        let renderer = try ForwardRenderer(device: device, settings: settings, archive: first)
        XCTAssertGreaterThan(first.added, 10, "every pipeline the renderer builds is recorded: \(first.added)")
        let reference = try renderer.render(scene: try SceneResources(device: device, scene: scene), camera: camera,
                                            lighting: SunLighting(), width: 256, height: 160)
        try first.save()
        let attributes = try FileManager.default.attributesOfItem(atPath: first.url.path)
        XCTAssertGreaterThan((attributes[.size] as? Int) ?? 0, 1000, "the archive holds compiled binaries")
        XCTAssertTrue(first.url.lastPathComponent.hasPrefix("pipelines-"), "named by the shaders' hash")

        let second = try PipelineArchive(device: device, directory: directory)
        XCTAssertTrue(second.loaded)
        XCTAssertEqual(second.url, first.url)
        // Strict: every pipeline must come from the file, or construction
        // fails. This is what says the archive, not the system's cache, served.
        second.requiresHit = true
        let warm = try ForwardRenderer(device: device, settings: settings, archive: second)
        let frame = try warm.render(scene: try SceneResources(device: device, scene: scene), camera: camera,
                                    lighting: SunLighting(), width: 256, height: 160)
        XCTAssertEqual(frame, reference, "pipelines from the archive draw the same frame")

        // A file that is not an archive is ignored, not fatal.
        let bogus = directory.appendingPathComponent("bogus.metallib")
        try Data("not an archive".utf8).write(to: bogus)
        let fallback = try PipelineArchive(device: device, url: bogus)
        XCTAssertFalse(fallback.loaded)
        _ = try ForwardRenderer(device: device, settings: settings, archive: fallback)
        // And an empty archive in strict mode cannot serve anything.
        let empty = try PipelineArchive(device: device, url: directory.appendingPathComponent("empty.metallib"))
        empty.requiresHit = true
        XCTAssertThrowsError(try ForwardRenderer(device: device, settings: settings, archive: empty))
    }

    func testShaderIdentityIsStableAndShort() throws {
        let a = try PipelineArchive.shaderIdentity(), b = try PipelineArchive.shaderIdentity()
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 16)
    }
}
