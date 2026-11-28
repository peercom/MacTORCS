// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
@testable import TORCSRender
import TORCSAssets
import TORCSMaterials
import TORCSTrack
import TORCSTrackMesh

final class SignArtworkTests: XCTestCase {
    /// A board in miniature: a white bar on blue with the soft edge it was
    /// drawn with, and beside it a ramp from black to white.
    private func picture(width: Int = 64, height: Int = 16) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let i = (y * width + x) * 4
                if x < 32 {
                    // Blue, white from 12 to 20, one half-covered texel each side.
                    let cover: Float = (12 ..< 20).contains(x) ? 1 : (x == 11 || x == 20 ? 0.5 : 0)
                    pixels[i] = UInt8(20 + 235 * cover); pixels[i + 1] = UInt8(30 + 225 * cover); pixels[i + 2] = UInt8(160 + 95 * cover)
                } else {
                    let v = UInt8((Float(x - 32) / 31 * 255).rounded())
                    pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v
                }
            }
        }
        return pixels
    }

    func testAnEdgeIsPutBackAndAGradientIsLeftAlone() {
        let width = 64, height = 16, scale = 4
        let source = picture()
        let large = SignArtwork.enlarged(rgba: source, width: width, height: height, scale: scale)
        XCTAssertEqual(large.count, width * scale * height * scale * 4)
        let row = 8 * scale
        func red(_ x: Int) -> Int { Int(large[(row * width * scale + x) * 4]) }
        // Across the bar's left edge, between flat blue and flat white: the
        // soft texel was four of the large picture wide and more with
        // interpolation; put back, it is two at most.
        let between = (8 * scale ..< 14 * scale).filter { red($0) > 40 && red($0) < 235 }.count
        XCTAssertLessThanOrEqual(between, 2, "the edge is \(between) texels wide")
        XCTAssertGreaterThan(between, 0, "and is not a staircase")
        // It falls where the soft texel was half covered: the middle of texel 11.
        let edge = try! XCTUnwrap((8 * scale ..< 14 * scale).first { red($0) > 137 })
        XCTAssertEqual(Float(edge) / Float(scale), 11.5, accuracy: 0.5)
        // Flat colour stays the colour it was.
        XCTAssertEqual(red(4 * scale), 20); XCTAssertEqual(red(16 * scale), 255)
        // The ramp is still a ramp: it rises all the way, by small steps.
        var last = red(36 * scale), largest = 0
        for x in 36 * scale ..< 60 * scale {
            XCTAssertGreaterThanOrEqual(red(x), last)
            largest = max(largest, red(x) - last)
            last = red(x)
        }
        XCTAssertLessThanOrEqual(largest, 4, "a gradient was given an edge")
        // Nothing is made darker or lighter than anything the picture had.
        for c in 0 ..< 3 {
            let range = stride(from: c, to: source.count, by: 4).map { source[$0] }
            let made = stride(from: c, to: large.count, by: 4).map { large[$0] }
            XCTAssertGreaterThanOrEqual(made.min()!, range.min()!); XCTAssertLessThanOrEqual(made.max()!, range.max()!)
        }
        // Once the size it is, the picture is itself.
        XCTAssertEqual(SignArtwork.enlarged(rgba: source, width: width, height: height, scale: 1), source)
    }

    func testASignIsToldByItsShapeAndSize() {
        XCTAssertEqual(SignArtwork.kind(width: 256, height: 64), .board)
        XCTAssertEqual(SignArtwork.kind(width: 512, height: 512), .board)
        XCTAssertEqual(SignArtwork.kind(width: 512, height: 64), .banner)
        XCTAssertEqual(SignArtwork.kind(width: 256, height: 32), .banner)
        XCTAssertEqual(SignArtwork.scale(width: 256, height: 64), 4)
        XCTAssertEqual(SignArtwork.scale(width: 512, height: 128), 2)
        XCTAssertEqual(SignArtwork.scale(width: 1024, height: 256), 1)
        // A board four times as long as high is eight sheets; a banner has
        // an eyelet every half of its height.
        XCTAssertEqual(SignArtwork.panels(width: 256, height: 64), 8)
        XCTAssertEqual(SignArtwork.panels(width: 128, height: 128), 2)
        XCTAssertEqual(SignArtwork.eyelets(width: 512, height: 64), 16)
    }

    func testEachSurfaceIsWhatItIsPrintedOn() {
        func channel(_ bytes: [UInt8], _ c: Int) -> [Float] { stride(from: c, to: bytes.count, by: 4).map { Float(bytes[$0]) / 255 } }
        func mean(_ values: [Float]) -> Float { values.reduce(0, +) / Float(values.count) }
        for kind in SignArtwork.Kind.allCases {
            let w = kind == .banner ? 512 : 256, h = kind == .banner ? 64 : (kind == .wall ? 256 : 64)
            let maps = SignArtwork.surface(kind, width: w, height: h)
            XCTAssertEqual(maps.normal.count, w * h * 4); XCTAssertEqual(maps.orm.count, w * h * 4)
            // Flat on the whole, and matt: a sign is not a mirror.
            XCTAssertEqual(mean(channel(maps.normal, 0)), 0.5, accuracy: 0.01, "\(kind)")
            XCTAssertEqual(mean(channel(maps.normal, 1)), 0.5, accuracy: 0.01, "\(kind)")
            XCTAssertGreaterThan(mean(channel(maps.orm, 1)), 0.68, "\(kind)"); XCTAssertLessThan(mean(channel(maps.orm, 1)), 0.9, "\(kind)")
            XCTAssertEqual(Set(channel(maps.orm, 2)), [0], "no metal")
            // But not featureless.
            let nx = channel(maps.normal, 0)
            XCTAssertGreaterThan(nx.max()! - nx.min()!, 0.05, "\(kind) has relief")
            // The same for the same picture, every time.
            XCTAssertEqual(SignArtwork.surface(kind, width: w, height: h).orm, maps.orm)
        }
        // A board: a joint between sheets, shaded, the height of the board,
        // eight of them on a board four times as long as high.
        let board = SignArtwork.surface(.board, width: 256, height: 64)
        let boardShade = channel(board.orm, 0)
        let jointed = (0 ..< 256).filter { x in (0 ..< 64).allSatisfy { boardShade[$0 * 256 + x] < 0.75 } }
        XCTAssertEqual(Set(jointed.map { ($0 + 2) / 32 % 8 }).count, 8, "joints at \(jointed)")
        XCTAssertLessThan(jointed.count, 8 * 4)
        // A banner: eyelets along both hems and none in the middle of it.
        let banner = SignArtwork.surface(.banner, width: 512, height: 64)
        let bannerShade = channel(banner.orm, 0)
        func holes(rows: Range<Int>) -> Int { rows.reduce(0) { n, y in n + (0 ..< 512).filter { bannerShade[y * 512 + $0] < 0.6 }.count } }
        XCTAssertGreaterThanOrEqual(holes(rows: 0 ..< 6), 16); XCTAssertGreaterThanOrEqual(holes(rows: 58 ..< 64), 16)
        XCTAssertEqual(holes(rows: 16 ..< 48), 0)
        // Its folds are in the middle, where nothing holds it.
        let bannerX = channel(banner.normal, 0)
        func lean(_ y: Int) -> Float { (0 ..< 512).map { abs(bannerX[y * 512 + $0] - 0.5) }.reduce(0, +) / 512 }
        XCTAssertGreaterThan(lean(32), lean(8) * 1.5)
        // A wall: pores, rough and shaded, scattered over it.
        let wall = SignArtwork.surface(.wall, width: 256, height: 256)
        let pores = zip(channel(wall.orm, 0), channel(wall.orm, 1)).filter { $0.0 < 0.8 && $0.1 > 0.9 }.count
        XCTAssertGreaterThan(pores, 256 * 256 / 100); XCTAssertLessThan(pores, 256 * 256 / 4)
    }

    func testSignsAndPaintedWallsAreKnownByName() {
        for name in ["logoagip.png", "logo_megafuel.png", "sign3.png", "torcs1.rgb", "torcsad2.rgb", "turn100.png",
                     "bridgead.png", "100.png", "kilo.png", "data/textures/murpub.rgb", "LOGOFSTN.PNG"] {
            XCTAssertTrue(MaterialLibrary.isSign(name), name)
        }
        for name in ["back-sign.png", "tree1_n.png", "grass.png", "house26facade.png", "std.rgb", "torcs0_arbor_n.rgb", "truck1.rgb"] {
            XCTAssertFalse(MaterialLibrary.isSign(name), name)
        }
        for name in ["megafuel-wall.png", "improveyou-wall.png", "flatspot-wall.png", "wall-torcs.rgb", "wall-m1.rgb", "barrier-2.png"] {
            XCTAssertTrue(MaterialLibrary.isPaintedWall(name), name)
            XCTAssertNil(MaterialLibrary.material(for: name), "\(name) keeps its paint")
            XCTAssertEqual(MaterialLibrary.signKind(name, width: 256, height: 256), .wall)
        }
        // The bare walls beside them are still concrete.
        XCTAssertEqual(MaterialLibrary.material(for: "wall-m1-2.rgb"), "concrete-wall")
        XCTAssertEqual(MaterialLibrary.material(for: "concrete-wall1.png"), "concrete-wall")
        XCTAssertEqual(MaterialLibrary.signKind("logodun2.png", width: 256, height: 32), .banner)
        XCTAssertEqual(MaterialLibrary.signKind("logoagip.png", width: 256, height: 64), .board)
        XCTAssertNil(MaterialLibrary.signKind("grass.png", width: 256, height: 32))
    }

    /// Aalborg with one of its borders made a wall, as a pit wall is.
    private func walled(texture: String?, size: Float? = nil) throws -> (geometry: TrackGeometry, border: Int) {
        let original = try RoadGenerationTests().aalborg().geometry
        let border = try XCTUnwrap(original.segments.indices.first {
            original.segments[$0].role == .rightBorder && original.segments[$0].width > 0.3 && original.segments[$0].curve == .straight
        })
        var segments = original.segments
        segments[border].style = .wall
        segments[border].curbHeight = 1
        segments[border].surface = TrackSurface(material: "pit-wall", friction: 1, rebound: 0.5, rollingResistance: 0.001,
                                                roughness: 0, roughWaveNumber: 1, damage: 10, texture: texture, textureSize: size)
        return (try TrackGeometry(segments: segments), border)
    }

    func testABorderThatIsAWallStandsUp() throws {
        let (geometry, border) = try walled(texture: nil)
        let wall = try XCTUnwrap(RoadGeneration.road(geometry).groups.first { $0.material == "pit-wall" }).geometry
        XCTAssertEqual(wall.positions.count % 4, 0)
        let width = geometry.segments[border].width
        for row in stride(from: 0, to: wall.positions.count, by: 4) {
            let footIn = wall.positions[row], topIn = wall.positions[row + 1], topOut = wall.positions[row + 2], footOut = wall.positions[row + 3]
            XCTAssertEqual(topIn.z - footIn.z, 1, accuracy: 1e-4); XCTAssertEqual(topOut.z - footOut.z, 1, accuracy: 1e-4)
            XCTAssertEqual(simd_distance(SIMD2(footIn.x, footIn.y), SIMD2(topIn.x, topIn.y)), 0, accuracy: 1e-5, "its face is upright")
            XCTAssertEqual(simd_distance(SIMD2(topIn.x, topIn.y), SIMD2(topOut.x, topOut.y)), width, accuracy: 0.02, "as thick as the border is wide")
            // The face to the road looks at the road: away from the back.
            let outward = simd_normalize(SIMD2(topOut.x - topIn.x, topOut.y - topIn.y))
            XCTAssertLessThan(simd_dot(SIMD2(wall.normals[row].x, wall.normals[row].y), outward), -0.99)
            XCTAssertEqual(wall.normals[row + 2].z, 1)
        }
        // Winding agrees with the normals, as for a barrier.
        for i in stride(from: 0, to: wall.indices.count, by: 3) {
            let a = Int(wall.indices[i]), b = Int(wall.indices[i + 1]), c = Int(wall.indices[i + 2])
            let face = simd_cross(wall.positions[b] - wall.positions[a], wall.positions[c] - wall.positions[a])
            XCTAssertGreaterThanOrEqual(simd_dot(face, wall.normals[a] + wall.normals[b] + wall.normals[c]), 0)
        }
        // Laid in metres up it and over the top, like any wall of a set.
        XCTAssertEqual(wall.uv0[1].y, 1, accuracy: 1e-4); XCTAssertEqual(wall.uv0[2].y, 1 + width, accuracy: 0.02)
        // A flat border is still flat.
        let flat = try RoadGenerationTests().aalborg().geometry
        let name = flat.segments[border].surface.material
        let ribbon = try XCTUnwrap(RoadGeneration.road(flat).groups.first { $0.material == name }).geometry
        XCTAssertLessThan(ribbon.normals.map(\.z).min()!, 1.01); XCTAssertGreaterThan(ribbon.normals.map(\.z).min()!, 0.9)
    }

    func testAPictureIsLaidAsItWasDrawnToBe() throws {
        let (geometry, _) = try walled(texture: "megafuel-wall.png", size: 3)
        var parameters = RoadGeneration.Parameters()
        parameters.picturedBarriers["pit-wall"] = 3
        let wall = try XCTUnwrap(RoadGeneration.road(geometry, parameters: parameters).groups.first { $0.material == "pit-wall" }).geometry
        // A third to the face, a third to the top, a third to the back.
        for row in stride(from: 0, to: wall.uv0.count, by: 4) {
            XCTAssertEqual(wall.uv0[row].y, 0); XCTAssertEqual(wall.uv0[row + 1].y, 1.0 / 3, accuracy: 1e-6)
            XCTAssertEqual(wall.uv0[row + 2].y, 2.0 / 3, accuracy: 1e-6); XCTAssertEqual(wall.uv0[row + 3].y, 1)
        }
        // On the right of the track the picture runs back along it, so that
        // seen from the road its lettering runs forward; three metres a repeat.
        let first = wall.uv0[0].x, next = wall.uv0[4].x
        let step = simd_distance(wall.positions[0], wall.positions[4])
        XCTAssertEqual(next - first, -step / 3, accuracy: 0.01)
        XCTAssertEqual(RoadGeneration.wallCoordinates(along: 6, height: 1, thickness: 0.5, side: .left, fit: nil, picture: 3)[0].x, 2)
        XCTAssertEqual(RoadGeneration.wallCoordinates(along: 6, height: 1, thickness: 0.5, side: .right, fit: nil, picture: 3)[0].x, -2)
        // A fence has one face and the whole picture on it.
        XCTAssertEqual(RoadGeneration.wallCoordinates(along: 6, height: 1, thickness: 0.05, side: .left, fit: nil, picture: 3, fence: true).map(\.y),
                       [0, 1, 1, 0])
    }

    func testAPaintedWallKeepsItsPictureWhereThereIsOne() throws {
        let (geometry, _) = try walled(texture: "megafuel-wall.png", size: 4)
        // The picture to hand, under whatever case the circuit spelt it.
        let kept = try TrackSurfaceAssembly.roadBatches(geometry, pictures: ["MEGAFUEL-wall.png", "grass.png"])
        let wall = try XCTUnwrap(kept.first { $0.baseTexture == "MEGAFUEL-wall.png" })
        XCTAssertFalse(wall.paintsRoadMarkings); XCTAssertNil(wall.alphaTestThreshold); XCTAssertTrue(wall.uvInMetres)
        XCTAssertFalse(kept.contains { $0.baseTexture == "pit-wall.rgb" })
        // The picture goes round the lap a whole number of times, near its
        // declared four metres a repeat, so no word is cut at the line.
        let lap = geometry.mainSegments.reduce(Float(0)) { $0 + geometry.segments[$1].length }
        func along(_ i: Int) -> Float {
            Float(wall.mesh.vertices[i].uv0.x) + Float(wall.mesh.vertices[i].uv1.x) * RenderMesh.metresPeriod
        }
        func place(_ i: Int) -> SIMD3<Float> {
            SIMD3(wall.mesh.vertices[i].positionX, wall.mesh.vertices[i].positionY, wall.mesh.vertices[i].positionZ)
        }
        let laid = simd_distance(place(0), place(4)) / abs(along(4) - along(0))
        XCTAssertEqual(laid, 4, accuracy: 0.1)
        XCTAssertEqual(laid, lap / (lap / 4).rounded(), accuracy: 0.02)
        // Without it, the wall under the paint.
        let bare = try TrackSurfaceAssembly.roadBatches(geometry)
        XCTAssertFalse(bare.contains { ($0.baseTexture ?? "").lowercased().contains("megafuel") })
        XCTAssertTrue(bare.contains { $0.baseTexture == "concrete-wall.rgb" })
        XCTAssertEqual(MaterialLibrary.material(for: "concrete-wall.rgb"), "concrete-wall")
    }

    func testASignTakesItsOwnArtworkLargerAndASurface() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let directory = try MaterialLibraryTests().materialsDirectory(["concrete-wall"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try MaterialLibrary(device: device, directory: directory)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("sign-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        library.signCache = cache
        let image = try TextureImage(width: 64, height: 16, channels: 4, pixels: picture())
        func batch(_ texture: String, cutout: Bool = false) throws -> RenderBatch {
            let mesh = try RenderMesh.build(positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)],
                                            normals: Array(repeating: SIMD3(0, 0, 1), count: 4),
                                            uv0: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)], indices: [0, 1, 2, 0, 2, 3])
            let state = ACRenderState(material: [0, 0, 0, 1, 0, 0, 0, 1, 0.2, 0.2, 0.2, 1, 0], texture: texture, flags: 8, alphaClamp: 0)
            return RenderBatch(mesh: mesh, baseTexture: texture, blends: false, isDeferred: false,
                               alphaTestThreshold: cutout ? 0.5 : nil, culls: true, isDriver: false, sourceMaterial: state,
                               material: ResolvedMaterial(baseColour: SIMD4(1, 1, 1, 1), roughness: 0.8, metallic: 0))
        }
        let scene = RenderScene(batches: [try batch("logoagip.png"), try batch("megafuel-wall.png"), try batch("logoagip.png"),
                                          try batch("house1.png"), try batch("logolost.png"), try batch("logocut.png", cutout: true)],
                                minimum: SIMD3(0, 0, 0), maximum: SIMD3(1, 1, 0))
        let resources = try SceneResources(device: device, scene: scene, materials: library, materialDirectory: directory,
                                           originalImage: { $0 == "logolost.png" ? nil : image }, resolveTexture: { _, _ in nil })
        let board = resources.batches[0], wall = resources.batches[1]
        // Four times the picture, as colour, compressed; a surface at half that.
        let artwork = try XCTUnwrap(board.albedo)
        XCTAssertEqual(artwork.width, 256); XCTAssertEqual(artwork.height, 64)
        XCTAssertEqual(artwork.pixelFormat, .bc1_rgba_srgb); XCTAssertGreaterThan(artwork.mipmapLevelCount, 1)
        let surface = try XCTUnwrap(board.structure)
        XCTAssertEqual(surface.width, 128); XCTAssertEqual(surface.pixelFormat, .rgba8Unorm)
        XCTAssertEqual(board.draw.material.x, 1, "the surface's roughness is the sign's"); XCTAssertEqual(board.draw.material.y, 0)
        XCTAssertEqual(board.draw.maps.x, 1); XCTAssertEqual(board.draw.maps.y, 1)
        // A painted wall likewise, on a surface of its own kind.
        XCTAssertNotNil(wall.albedo); XCTAssertNotNil(wall.structure)
        XCTAssertFalse(wall.structure === board.structure)
        // The encode is kept: another library finds it made, the same picture
        // under another name included, and a board of the same shape shares
        // the surface.
        XCTAssertEqual(library.signCacheHits, 1, "the wall is the board's picture again")
        let second = try MaterialLibrary(device: device, directory: directory)
        second.signCache = cache
        let again = try XCTUnwrap(second.signArtwork(texture: "logoagip.png", image: image))
        XCTAssertEqual(second.signCacheHits, 1); XCTAssertEqual(again.albedo.width, 256)
        let other = try XCTUnwrap(second.signArtwork(texture: "logofost.png", image: image))
        XCTAssertTrue(other.structure === again.structure)
        // One picture, one copy, however many boards show it.
        XCTAssertTrue(resources.batches[2].albedo === artwork); XCTAssertTrue(resources.batches[2].structure === surface)
        // A house is no sign; a sign with no picture to hand, or cut out, is left as it was.
        for index in 3 ..< 6 {
            XCTAssertNil(resources.batches[index].albedo, "\(index)")
            XCTAssertEqual(resources.batches[index].draw.material.x, 0.8, "\(index)")
        }
    }
}
