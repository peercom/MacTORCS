// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import ImageIO
import UniformTypeIdentifiers
import simd
import TORCSRender
import TORCSAssets
import TORCSMaterials

final class SkyMapTests: XCTestCase {
    /// Four shapes to a map, each using its range, and the map tiles: a
    /// cloud that stopped at the tile's edge would be a line across the sky.
    func testTheCloudMapTilesAndItsCirrusIsDrawnOut() {
        let size = 128
        let map = CloudMap.generate(size: size, seed: 3)
        XCTAssertEqual(map.count, size * size * 4)
        XCTAssertEqual(map, CloudMap.generate(size: size, seed: 3), "not reproducible")
        XCTAssertNotEqual(map, CloudMap.generate(size: size, seed: 4))
        func value(_ x: Int, _ y: Int, _ channel: Int) -> Int { Int(map[(((y + size) % size) * size + (x + size) % size) * 4 + channel]) }
        for channel in 0 ..< 4 {
            var low = 255, high = 0, seam = 0, inside = 0
            for y in 0 ..< size {
                for x in 0 ..< size { low = min(low, value(x, y, channel)); high = max(high, value(x, y, channel)) }
                seam = max(seam, abs(value(0, y, channel) - value(size - 1, y, channel)), abs(value(y, 0, channel) - value(y, size - 1, channel)))
                for x in 1 ..< size { inside = max(inside, abs(value(x, y, channel) - value(x - 1, y, channel))) }
            }
            XCTAssertGreaterThan(high - low, 150, "channel \(channel) is flat")
            XCTAssertLessThanOrEqual(seam, inside + 6, "channel \(channel) does not tile")
        }
        // Cirrus changes less along its length than across it.
        var along = 0, across = 0
        for y in 0 ..< size { for x in 0 ..< size {
            along += abs(value(x + 1, y, 2) - value(x, y, 2)); across += abs(value(x, y + 1, 2) - value(x, y, 2))
        } }
        XCTAssertLessThan(along * 5, across * 4)
        // The thickness is the heaps', broadly: where there is most cloud it is thickest.
        var thickInCloud = 0, thickInClear = 0, cloud = 0, clear = 0
        for y in 0 ..< size { for x in 0 ..< size {
            if value(x, y, 0) > 170 { thickInCloud += value(x, y, 3); cloud += 1 } else if value(x, y, 0) < 85 { thickInClear += value(x, y, 3); clear += 1 }
        } }
        XCTAssertGreaterThan(thickInCloud / max(cloud, 1), thickInClear / max(clear, 1) + 40)
    }

    func testACircuitsCountryIsToldByItsName() {
        XCTAssertEqual(HorizonMap.kind(forTrack: "Alpine 1"), .mountains); XCTAssertEqual(HorizonMap.kind(forTrack: "Aalborg"), .mountains)
        XCTAssertEqual(HorizonMap.kind(forTrack: "Alpine 2"), .snow)
        XCTAssertEqual(HorizonMap.kind(forTrack: "Corkscrew"), .dry); XCTAssertEqual(HorizonMap.kind(forTrack: "E-Track 6"), .dry)
        for green in ["E-Track 2", "CG Speedway number 1", "Street 1", "Brondehach", "Forza", "Wheel 1", ""] {
            XCTAssertEqual(HorizonMap.kind(forTrack: green), .hills, green)
        }
    }

    /// Sky at the top, land at the bottom, the same at 360° as at 0°, and
    /// paler the farther off: the nearest ridge hides most and the plain all.
    func testAHorizonIsLandBelowSkyAllTheWayRound() {
        let width = 512, height = 64
        var tops: [HorizonMap.Kind: Int] = [:]
        for kind in HorizonMap.Kind.allCases {
            let map = HorizonMap.generate(kind, width: width, height: height, seed: 2)
            XCTAssertEqual(map.count, width * height * 4)
            func alpha(_ x: Int, _ y: Int) -> Int { Int(map[(y * width + x) * 4 + 3]) }
            var highest = height
            for x in 0 ..< width {
                XCTAssertEqual(alpha(x, 0), 0, "\(kind): land at the top of the sky")
                XCTAssertGreaterThan(alpha(x, height - 1), 240, "\(kind): sky through the plain")
                // Never clearer below than above by more than a ridge's edge.
                for y in 1 ..< height { XCTAssertGreaterThanOrEqual(alpha(x, y) + 40, alpha(x, y - 1), "\(kind) at \(x), \(y)") }
                if let first = (0 ..< height).first(where: { alpha(x, $0) > 20 }) { highest = min(highest, first) }
            }
            tops[kind] = highest
            // The horizon's own row, zero elevation, is land.
            let level = Int(HorizonMap.highest / (HorizonMap.highest - HorizonMap.lowest) * Float(height))
            XCTAssertGreaterThan(alpha(width / 3, min(level + 2, height - 1)), 100)
            var seam = 0, inside = 0
            for y in 0 ..< height {
                seam = max(seam, abs(alpha(0, y) - alpha(width - 1, y)))
                for x in 1 ..< width { inside = max(inside, abs(alpha(x, y) - alpha(x - 1, y))) }
            }
            XCTAssertLessThanOrEqual(seam, inside + 4, "\(kind) has an edge at north")
            // The plain's colour is its country's.
            let i = ((height - 1) * width + width / 2) * 4
            let (r, g, b) = (Int(map[i]), Int(map[i + 1]), Int(map[i + 2]))
            switch kind {
            case .hills, .mountains: XCTAssertGreaterThan(g, r + 10); XCTAssertGreaterThan(g, b + 10)
            case .snow: XCTAssertGreaterThan(min(r, g, b), 150)
            case .dry: XCTAssertGreaterThan(r, b + 30)
            }
        }
        XCTAssertLessThan(tops[.mountains]!, tops[.hills]!, "mountains stand higher than hills")
    }

    // MARK: - Drawn

    private func scene() throws -> RenderScene {
        // The renderer wants something to draw: a square of ground behind the camera.
        let mesh = try RenderMesh.build(positions: [SIMD3(-1, -30, 0), SIMD3(1, -30, 0), SIMD3(1, -28, 0), SIMD3(-1, -28, 0)],
                                        normals: Array(repeating: SIMD3(0, 0, 1), count: 4),
                                        uv0: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)], indices: [0, 1, 2, 0, 2, 3])
        let state = ACRenderState(material: [0, 0, 0, 1, 0, 0, 0, 1, 0.2, 0.2, 0.2, 1, 0], texture: nil, flags: 8, alphaClamp: 0)
        let batch = RenderBatch(mesh: mesh, baseTexture: nil, blends: false, isDeferred: false, alphaTestThreshold: nil,
                                culls: false, isDriver: false, sourceMaterial: state,
                                material: ResolvedMaterial(baseColour: SIMD4(0.2, 0.2, 0.2, 1), roughness: 0.9, metallic: 0))
        return RenderScene(batches: [batch], minimum: SIMD3(-1, -30, 0), maximum: SIMD3(1, -28, 0))
    }

    private func renderer() throws -> ForwardRenderer {
        var settings = RenderSettings()
        settings.autoExposure = false
        settings.bloom = false; settings.motionBlur = false; settings.screenSpaceReflections = .off; settings.sunGlare = false
        settings.ambientOcclusion = .off; settings.contactShadows = false; settings.heatHaze = false
        return try ForwardRenderer(settings: settings)
    }

    private func flat(_ device: MTLDevice, _ pixel: [UInt8]) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        var bytes = pixel
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &bytes, bytesPerRow: 4)
        return texture
    }

    /// A fair sky has cloud in it and the weather's sky is covered, both
    /// from the map; and with no map the sky is the one it always was.
    func testTheSkyIsDrawnFromItsCloudMap() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        let scene = try scene()
        let sun = SunLighting(direction: simd_normalize(SIMD3(0.3, -0.5, 0.8)))
        // Looking up and away from the sun.
        let camera = RenderCamera(eye: SIMD3(0, 0, 2), target: SIMD3(0, 10, 9), verticalFieldOfView: 40 * .pi / 180)
        func mean(_ r: ForwardRenderer) throws -> SIMD3<Float> {
            let resources = try SceneResources(device: r.device, scene: scene)
            let pixels = try r.render(scene: resources, camera: camera, lighting: sun, width: 64, height: 40)
            var sum = SIMD3<Float>(repeating: 0)
            for i in 0 ..< 64 * 40 { sum += SIMD3(Float(pixels[i * 4]), Float(pixels[i * 4 + 1]), Float(pixels[i * 4 + 2])) }
            return sum / Float(64 * 40)
        }
        let clear = try renderer()
        let blue = try mean(clear)
        XCTAssertFalse(clear.lastSkyWasDressed)
        XCTAssertGreaterThan(blue.z, blue.x + 20, "a clear sky is blue")

        // A map that is cloud everywhere, thick and unbroken.
        let dressed = try renderer()
        dressed.cloudMap = try flat(dressed.device, [255, 255, 0, 255])
        XCTAssertEqual(try mean(dressed), blue, "a map and no cloud asked for: the clear sky")
        XCTAssertTrue(dressed.lastSkyWasDressed)
        dressed.fairWeatherCumulus = 0.5
        let fair = try mean(dressed)
        XCTAssertLessThan(fair.z - fair.x, (blue.z - blue.x) * 0.5, "cloud is white, not blue")
        XCTAssertGreaterThan(fair.x, blue.x + 20)
        dressed.fairWeatherCumulus = 0
        dressed.overcast = 1
        let covered = try mean(dressed)
        XCTAssertLessThan(covered.z - covered.x, (blue.z - blue.x) * 0.5)
        // A map with no cloud in it anywhere leaves the sky clear whatever is asked.
        dressed.cloudMap = try flat(dressed.device, [0, 255, 0, 0])
        dressed.overcast = 0; dressed.fairWeatherCumulus = 1
        let empty = try mean(dressed)
        XCTAssertEqual(empty.x, blue.x, accuracy: 2); XCTAssertEqual(empty.z, blue.z, accuracy: 2)
        // Cirrus is the map's blue channel.
        dressed.cloudMap = try flat(dressed.device, [0, 255, 255, 0])
        dressed.fairWeatherCumulus = 0; dressed.cirrus = 1
        let streaked = try mean(dressed)
        XCTAssertGreaterThan(streaked.x, blue.x + 10)
    }

    /// The land stands round the horizon and below it, in front of the sky
    /// and behind everything else, and no higher than its map's top.
    func testTheHorizonIsDrawnBelowItsTopAndNotAbove() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal device unavailable") }
        let scene = try scene()
        let sun = SunLighting(direction: simd_normalize(SIMD3(0.3, -0.5, 0.8)))
        let level = RenderCamera(eye: SIMD3(0, 0, 2), target: SIMD3(0, 10, 2), verticalFieldOfView: 40 * .pi / 180)
        let r = try renderer()
        let resources = try SceneResources(device: r.device, scene: scene)
        let before = try r.render(scene: resources, camera: level, lighting: sun, width: 64, height: 64)
        r.horizonMap = try flat(r.device, [255, 0, 0, 255])        // all of it land, and red
        r.horizonSpan = (-0.10, 0.14)
        let after = try r.render(scene: resources, camera: level, lighting: sun, width: 64, height: 64)
        XCTAssertTrue(r.lastSkyWasDressed)
        func pixel(_ image: [UInt8], _ row: Int) -> (r: Int, g: Int, b: Int) {
            let i = (row * 64 + 32) * 4
            return (Int(image[i]), Int(image[i + 1]), Int(image[i + 2]))
        }
        // The field of view is twenty degrees up and down: sin 8° is the map's top, at about row 19.
        for row in [28, 34, 44, 60] {
            let p = pixel(after, row)
            XCTAssertGreaterThan(p.r, p.b * 3, "row \(row) is land"); XCTAssertGreaterThan(p.r, 40)
        }
        for row in [2, 8, 14] {
            let p = pixel(after, row), was = pixel(before, row)
            XCTAssertEqual(p.r, was.r); XCTAssertEqual(p.b, was.b, "row \(row) is sky")
        }
    }

    /// The maps come from beside the generated sets; without them there, the sky stays clear.
    func testTheSkyIsDressedFromTheMaterialsDirectory() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let directory = try MaterialLibraryTests().materialsDirectory(["asphalt"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let bare = try renderer()
        bare.dressSky(from: try MaterialLibrary(device: device, directory: directory), directory: directory, track: "Alpine 2")
        XCTAssertNil(bare.cloudMap); XCTAssertNil(bare.horizonMap); XCTAssertEqual(bare.fairWeatherCumulus, 0)

        func write(_ bytes: [UInt8], _ width: Int, _ height: Int, _ name: String) throws {
            let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
            let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let url = directory.appendingPathComponent(name + ".png")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        try write(CloudMap.generate(size: 32, seed: 1), 32, 32, "cloud-map")
        try write(HorizonMap.generate(.snow, width: 64, height: 16, seed: 1), 64, 16, "horizon-snow")
        let library = try MaterialLibrary(device: device, directory: directory)
        let r = try renderer()
        r.dressSky(from: library, directory: directory, track: "Alpine 2")
        let clouds = try XCTUnwrap(r.cloudMap), land = try XCTUnwrap(r.horizonMap)
        XCTAssertEqual(clouds.width, 32); XCTAssertGreaterThan(clouds.mipmapLevelCount, 1); XCTAssertEqual(clouds.pixelFormat, .rgba8Unorm)
        XCTAssertEqual(land.width, 64); XCTAssertEqual(land.height, 16); XCTAssertEqual(land.mipmapLevelCount, 1)
        XCTAssertEqual(land.pixelFormat, .rgba8Unorm_srgb)
        XCTAssertEqual(r.fairWeatherCumulus, ForwardRenderer.fairSky.cumulus); XCTAssertEqual(r.cirrus, ForwardRenderer.fairSky.cirrus)
        XCTAssertEqual(r.horizonSpan.lowest, HorizonMap.lowest); XCTAssertEqual(r.horizonSpan.highest, HorizonMap.highest)
        // A circuit in other country finds no map of its own here, and keeps its clouds.
        let green = try renderer()
        green.dressSky(from: library, directory: directory, track: "Forza")
        XCTAssertNotNil(green.cloudMap); XCTAssertNil(green.horizonMap)
        // And with nowhere to look, nothing.
        let none = try renderer()
        none.dressSky(from: nil, directory: nil, track: "Forza")
        XCTAssertNil(none.cloudMap)
    }
}
