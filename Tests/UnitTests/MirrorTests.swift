// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
import TORCSRender
import TORCSAssets

final class MirrorTests: XCTestCase {
    /// Pixel rectangles are top-down; device coordinates are y-up with the
    /// origin at the centre. A rectangle at the top of the frame lands near
    /// y = +1, and the whole frame maps to the whole clip square.
    func testQuadMapsPixelRectanglesToDeviceCoordinates() {
        let whole = ForwardRenderer.mirrorQuad(rect: (0, 0, 1280, 832), displayWidth: 1280, displayHeight: 832)
        XCTAssertEqual(whole, SIMD4(-1, -1, 2, 2))
        let top = ForwardRenderer.mirrorQuad(rect: (320, 83, 640, 138), displayWidth: 1280, displayHeight: 832)
        XCTAssertEqual(top.x, -0.5, accuracy: 1e-6)
        XCTAssertEqual(top.z, 1.0, accuracy: 1e-6)
        XCTAssertEqual(top.y + top.w, 1 - 2 * 83 / 832, accuracy: 1e-5, "top edge 83 pixels down")
    }

    /// A composited mirror changes only its rectangle, and shows the mirror
    /// view flipped: the left of the mirror image is the right of the view.
    func testMirrorCompositesFlippedIntoItsRectangleOnly() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        var settings = RenderSettings()
        settings.bloom = false; settings.motionBlur = false; settings.screenSpaceReflections = .off
        let renderer = try ForwardRenderer(settings: settings)
        let mirrorRenderer = try ForwardRenderer(device: renderer.device, settings: settings)
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Artwork/155-DTM/155-DTM.acc")
        let scene = try SceneResources(device: renderer.device, scene: RenderScene(ACScene.parse(Data(contentsOf: url), car: true), car: true))
        let camera = RenderCamera(eye: SIMD3(6, -5, 2), target: SIMD3(0, 0, 0.5))
        // The mirror looks at the car from the other side, so it differs.
        let mirrorCamera = RenderCamera(eye: SIMD3(-6, 3, 1.5), target: SIMD3(0, 0, 0.5))
        let width = 256, height = 160
        let rect = (x: 64, y: 16, width: 128, height: 40)
        let instances = [RenderInstance(resource: 0)]
        let plain = try renderer.render(resources: [scene], instances: instances, camera: camera,
                                        lighting: SunLighting(), width: width, height: height)
        let request = ForwardRenderer.MirrorRequest(renderer: mirrorRenderer, resources: [scene], instances: instances,
                                                    camera: mirrorCamera, width: rect.width, height: rect.height, rect: rect)
        let withMirror = try renderer.render(resources: [scene], instances: instances, camera: camera,
                                             lighting: SunLighting(), width: width, height: height, mirror: request)
        var outsideChanged = 0, insideChanged = 0
        for y in 0 ..< height {
            for x in 0 ..< width {
                let i = (y * width + x) * 4
                let same = plain[i] == withMirror[i] && plain[i + 1] == withMirror[i + 1] && plain[i + 2] == withMirror[i + 2]
                let inside = x >= rect.x && x < rect.x + rect.width && y >= rect.y && y < rect.y + rect.height
                if !same { if inside { insideChanged += 1 } else { outsideChanged += 1 } }
            }
        }
        XCTAssertEqual(outsideChanged, 0, "the mirror wrote outside its rectangle")
        XCTAssertGreaterThan(insideChanged, rect.width * rect.height / 4)

        // The flip: the mirror view rendered directly, read left to right,
        // matches the composited rectangle read right to left (inset past
        // the frame line and with a tolerance for the resample).
        let direct = try mirrorRenderer.render(resources: [scene], instances: instances, camera: mirrorCamera,
                                               lighting: SunLighting(), width: rect.width, height: rect.height)
        var agree = 0, total = 0
        for y in stride(from: 4, to: rect.height - 4, by: 2) {
            for x in stride(from: 4, to: rect.width - 4, by: 2) {
                let d = (y * rect.width + x) * 4
                let c = ((rect.y + y) * width + rect.x + (rect.width - 1 - x)) * 4
                total += 1
                if abs(Int(direct[d]) - Int(withMirror[c])) <= 12 && abs(Int(direct[d + 1]) - Int(withMirror[c + 1])) <= 12 { agree += 1 }
            }
        }
        XCTAssertGreaterThan(Double(agree) / Double(total), 0.9, "composite should be the mirror view flipped")
    }
}
