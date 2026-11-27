// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
import TORCSAssets
import TORCSMaterials
@testable import TORCSRender

/// The generated sets go to the GPU block-compressed: what that costs in
/// quality, measured on the maps themselves, and that the encode is kept
/// beside the source and served from there.
final class MaterialCompressionTests: XCTestCase {
    func psnr(_ a: [UInt8], _ b: [UInt8], channels: [Int]) -> Double {
        var error = 0.0, count = 0
        for i in stride(from: 0, to: min(a.count, b.count), by: 4) {
            for c in channels { let d = Double(a[i + c]) - Double(b[i + c]); error += d * d; count += 1 }
        }
        let mse = max(error / Double(max(count, 1)), 1e-9)
        return 10 * log10(255 * 255 / mse)
    }

    /// Mean angle between a BC5 normal and its source, in degrees.
    func angularError(_ a: [UInt8], _ b: [UInt8]) -> Double {
        func vector(_ p: [UInt8], _ i: Int) -> SIMD3<Float> {
            let x = Float(p[i]) / 127.5 - 1, y = Float(p[i + 1]) / 127.5 - 1
            return simd_normalize(SIMD3(x, y, sqrt(max(1 - x * x - y * y, 0))))
        }
        var total = 0.0, count = 0
        for i in stride(from: 0, to: min(a.count, b.count), by: 4) {
            let cosine = min(max(simd_dot(vector(a, i), vector(b, i)), -1), 1)
            total += Double(acos(cosine)) * 180 / .pi; count += 1
        }
        return total / Double(max(count, 1))
    }

    /// The normal of a packed structure texel, as the shader unpacks it.
    func structureAngularError(packed: [UInt8], normal: [UInt8]) -> Double {
        var unpacked = normal
        for i in stride(from: 0, to: packed.count, by: 4) {
            unpacked[i] = packed[i + 3]
            unpacked[i + 1] = UInt8(max(Int(packed[i + 1]) - Int(StructureMap.greenBias), 0))
        }
        return angularError(normal, unpacked)
    }

    /// What the block formats cost the generated maps. The normal and the
    /// roughness share one BC3 texture, and that is dearer than the BC5 and
    /// BC1 they had to themselves: the bounds here are what one texture
    /// costs, with the two-texture figures printed beside them.
    ///
    /// These 128-texel sets are the hard case. Their occlusion varies three
    /// times as much as their normal does, and the three channels of the
    /// colour block share one line, so the normal's y gives way: 4.4 degrees
    /// where BC5 had 1.0. At the 1024 texels the game's sets are generated
    /// at, and down their mips, the normal varies more than the rest and the
    /// cost is 1.3 to 2.5 times BC5's error (FRAME_RATE.md has the table).
    func testGeneratedMapsSurviveTheirBlockFormats() throws {
        var report: [String] = []
        for name in ["asphalt", "grass", "kerb", "brushed-metal"] {
            let material = try MaterialRecipes.generate(name, size: 128, seed: 1)
            let size = material.size
            func roundTrip(_ pixels: [UInt8], _ format: BlockCompression.Format,
                           weights: SIMD3<Double>? = nil) throws -> [UInt8] {
                try BlockCompression.decode(try BlockCompression.encode(pixels, width: size, height: size, format: format,
                                                                        dataWeights: weights),
                                            width: size, height: size, format: format)
            }
            let albedo = psnr(material.albedo, try roundTrip(material.albedo, .bc1), channels: [0, 1, 2])
            let apart = angularError(material.normal, try roundTrip(material.normal, .bc5))
            let ormApart = try roundTrip(material.orm, .bc1)
            let source = StructureMap.pack(normal: material.normal, orm: material.orm)
            let packed = try roundTrip(source, .bc3, weights: StructureMap.weights)
            let normal = structureAngularError(packed: packed, normal: material.normal)
            let roughness = psnr(source, packed, channels: [0]), occlusion = psnr(source, packed, channels: [2])
            report.append(String(format: "%@: albedo BC1 %.1f dB; normal %.2f deg (BC5 %.2f), roughness %.1f dB (BC1 %.1f), occlusion %.1f dB (BC1 %.1f)",
                                 name as NSString, albedo, normal, apart, roughness,
                                 psnr(material.orm, ormApart, channels: [1]), occlusion,
                                 psnr(material.orm, ormApart, channels: [0])))
            XCTAssertGreaterThan(albedo, 30, "\(name) albedo in BC1: \(albedo) dB")
            XCTAssertLessThan(normal, 5.0, "\(name) normal in the structure texture: \(normal) deg")
            XCTAssertGreaterThan(roughness, 30, "\(name) roughness in the structure texture: \(roughness) dB")
            XCTAssertGreaterThan(occlusion, 28, "\(name) occlusion in the structure texture: \(occlusion) dB")
        }
        print("MATERIAL_COMPRESSION " + report.joined(separator: " | "))
    }

    /// Roughness in red, the normal's y in green, occlusion in blue, the
    /// normal's x in alpha; and a flat normal comes back exactly flat, which
    /// green's six bits would not manage for 128.
    func testStructureMapPacksFourChannelsAndFlatStaysFlat() throws {
        let normal: [UInt8] = [10, 20, 255, 255, 128, 128, 255, 255, 200, 254, 255, 255, 0, 0, 255, 255]
        let orm: [UInt8] = [240, 90, 0, 255, 255, 128, 0, 255, 100, 30, 255, 255, 1, 2, 3, 255]
        XCTAssertEqual(StructureMap.pack(normal: normal, orm: orm),
                       [90, 22, 240, 10, 128, 130, 255, 128, 30, 255, 100, 200, 2, 2, 1, 0])
        // A flat map, any roughness: through BC3 and back, the normal is the
        // one that went in.
        var flatNormal = [UInt8](), someORM = [UInt8]()
        for i in 0 ..< 64 { flatNormal += [128, 128, 255, 255]; someORM += [UInt8(200 + i % 40), UInt8(60 + i * 2), 0, 255] }
        let source = StructureMap.pack(normal: flatNormal, orm: someORM)
        let packed = try BlockCompression.decode(
            try BlockCompression.encode(source, width: 8, height: 8, format: .bc3, dataWeights: StructureMap.weights),
            width: 8, height: 8, format: .bc3)
        for i in stride(from: 0, to: packed.count, by: 4) {
            XCTAssertEqual(packed[i + 3], 128, "x at texel \(i / 4)")
            XCTAssertEqual(Int(packed[i + 1]) - Int(StructureMap.greenBias), 128, "y at texel \(i / 4)")
        }
        XCTAssertEqual(structureAngularError(packed: packed, normal: flatNormal), 0, accuracy: 1e-4)
    }

    /// A set's metalness is not in its texture: the manifest's word goes
    /// into the draw. A substituted metal is all metal, anything else
    /// substituted is none; a set laid under a car part as detail leaves a
    /// metal part's metalness alone and takes a non-metal's away, as the
    /// roughness map's blue channel used to.
    func testASetsMetalnessComesFromTheManifestNotTheTexture() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let directory = try MaterialLibraryTests().materialsDirectory(["paint-flake", "rubber-tread", "fabric", "armco", "asphalt"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try MaterialLibrary(device: device, directory: directory)

        let car = try MotionBlurTests().fixtureScene()
        let carResources = try SceneResources(device: device, scene: car, materials: library, materialDirectory: directory,
                                              resolveTexture: { _, _ in nil })
        XCTAssertEqual(carResources.batches.count, car.batches.count)
        var metalDetails = 0, plainDetails = 0
        for (batch, built) in zip(car.batches, carResources.batches) {
            guard let choice = batch.carPart.flatMap(MaterialLibrary.detail) else {
                XCTAssertEqual(built.draw.material.y, batch.material.metallic, "a part without a set keeps its own")
                XCTAssertNil(built.structure)
                continue
            }
            XCTAssertNotNil(built.structure)
            XCTAssertEqual(built.draw.maps.y, 1); XCTAssertEqual(built.draw.maps.z, 0)
            if try XCTUnwrap(library.detailBinding(choice.material, directory: directory)).metallic {
                XCTAssertEqual(built.draw.material.y, batch.material.metallic, "\(choice.material) under \(batch.carPart!)")
                metalDetails += 1
            } else {
                XCTAssertEqual(built.draw.material.y, 0, "\(choice.material) under \(batch.carPart!)")
                plainDetails += 1
            }
        }
        XCTAssertGreaterThan(metalDetails, 0); XCTAssertGreaterThan(plainDetails, 0)

        // Substituted sets, on a surface whose own metalness is neither.
        let mesh = try RenderMesh.build(positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)],
                                        normals: Array(repeating: SIMD3(0, 0, 1), count: 4),
                                        uv0: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)], indices: [0, 1, 2, 0, 2, 3])
        let state = ACRenderState(material: [0, 0, 0, 1, 0, 0, 0, 1, 0.2, 0.2, 0.2, 1, 0], texture: nil, flags: 8, alphaClamp: 0)
        func batch(_ texture: String) -> RenderBatch {
            RenderBatch(mesh: mesh, baseTexture: texture, blends: false, isDeferred: false, alphaTestThreshold: nil,
                        culls: false, isDriver: false, sourceMaterial: state,
                        material: ResolvedMaterial(baseColour: SIMD4(1, 1, 1, 1), roughness: 0.9, metallic: 0.3))
        }
        let world = RenderScene(batches: [batch("armco-1.png"), batch("tr-asphalt-1.png"), batch("unknown.png")],
                                minimum: SIMD3(0, 0, 0), maximum: SIMD3(1, 1, 0))
        let resources = try SceneResources(device: device, scene: world, materials: library, materialDirectory: directory,
                                           resolveTexture: { _, _ in nil })
        XCTAssertEqual(resources.batches.map(\.draw.material.y), [1, 0, 0.3])
        XCTAssertEqual(resources.batches.map { $0.structure != nil }, [true, true, false])
    }

    /// The original scenery spreads one repeat of a texture over twenty
    /// metres of ground; a generated set is made for two or three. Drawn at
    /// the original's scale its grain is many times life size, so it is
    /// repeated a whole number of times within each of the original's
    /// repeats, and carries its own drift of colour with it.
    func testAGeneratedSetIsTiledAtItsOwnScaleOnOriginalScenery() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let directory = try MaterialLibraryTests().materialsDirectory(["asphalt", "armco"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = try MaterialLibrary(device: device, directory: directory)
        let state = ACRenderState(material: [0, 0, 0, 1, 0, 0, 0, 1, 0.2, 0.2, 0.2, 1, 0], texture: nil, flags: 8, alphaClamp: 0)
        func quad(side: Float, texture: String, inMetres: Bool = false) throws -> RenderBatch {
            let uv: [SIMD2<Float>] = inMetres ? [SIMD2(0, 0), SIMD2(side, 0), SIMD2(side, side), SIMD2(0, side)]
                : [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
            let mesh = try RenderMesh.build(positions: [SIMD3(0, 0, 0), SIMD3(side, 0, 0), SIMD3(side, side, 0), SIMD3(0, side, 0)],
                                            normals: Array(repeating: SIMD3(0, 0, 1), count: 4), uv0: uv,
                                            indices: [0, 1, 2, 0, 2, 3], uvInMetres: inMetres)
            return RenderBatch(mesh: mesh, baseTexture: texture, blends: false, isDeferred: false, alphaTestThreshold: nil,
                               culls: false, isDriver: false, sourceMaterial: state,
                               material: ResolvedMaterial(baseColour: SIMD4(1, 1, 1, 1), roughness: 0.9, metallic: 0),
                               uvInMetres: inMetres)
        }
        let field = try quad(side: 20, texture: "tr-asphalt-1.png")
        XCTAssertEqual(try XCTUnwrap(field.mesh.metresPerTextureRepeat()), 20, accuracy: 0.01)
        let world = RenderScene(batches: [field, try quad(side: 2.4, texture: "tr-asphalt-1.png"),
                                          try quad(side: 20, texture: "unknown.png"),
                                          try quad(side: 20, texture: "tr-asphalt-1.png", inMetres: true),
                                          try quad(side: 13, texture: "armco-1.png")],
                                minimum: SIMD3(0, 0, 0), maximum: SIMD3(20, 20, 0))
        let resources = try SceneResources(device: device, scene: world, materials: library, materialDirectory: directory,
                                           resolveTexture: { _, _ in nil })
        let asphalt = try XCTUnwrap(library.resolve(texture: "tr-asphalt-1.png", directory: directory))
        XCTAssertEqual(asphalt.worldSize, 2)
        let scales = resources.batches.map(\.draw.parameters.z)
        XCTAssertEqual(scales[0], 10, "twenty metres of a two-metre tile")
        XCTAssertEqual(scales[1], 1, "already at about its own scale")
        XCTAssertEqual(scales[2], 1, "original artwork keeps its author's scale")
        XCTAssertEqual(scales[3], 0.5, "generated geometry, in metres, divides by the tile")
        let armco = try XCTUnwrap(library.resolve(texture: "armco-1.png", directory: directory))
        XCTAssertEqual(scales[4], (13 / armco.worldSize).rounded(),
                       "always a whole number, so the texture wraps where the mesh expects it to")
        // The ground's drift of colour rides with the set; nothing else has one.
        XCTAssertEqual(resources.batches.map(\.draw.fade.w),
                       [0.3, 0.3, 0, 0.3, 0].map { Float($0) })
    }

    func testMapsUploadCompressedAndTheEncodeIsKeptBesideTheSource() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let directory = try MaterialLibraryTests().materialsDirectory(["armco", "asphalt"])
        defer { try? FileManager.default.removeItem(at: directory) }
        let wasCompressing = MaterialLibrary.compressesMaps
        defer { MaterialLibrary.compressesMaps = wasCompressing }

        MaterialLibrary.compressesMaps = true
        let first = try MaterialLibrary(device: device, directory: directory)
        let armco = try XCTUnwrap(first.resolve(texture: "armco-1.png", directory: directory))
        XCTAssertEqual(armco.albedo.pixelFormat, .bc1_rgba_srgb)
        XCTAssertEqual(armco.structure.pixelFormat, .bc3_rgba)
        XCTAssertEqual(armco.structure.width, armco.albedo.width)
        XCTAssertEqual(first.sidecarHits, 0, "nothing to serve the first time")
        for suffix in ["albedo.bc1", "structure.bc3"] {
            let sidecar = directory.appendingPathComponent("armco-\(suffix).torcsbc")
            XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path), "missing \(suffix) sidecar")
        }
        let compressedBytes = first.uploadedBytes

        let second = try MaterialLibrary(device: device, directory: directory)
        _ = try XCTUnwrap(second.resolve(texture: "armco-1.png", directory: directory))
        XCTAssertEqual(second.sidecarHits, 2, "the second load reads the encodes rather than doing them")
        XCTAssertEqual(second.uploadedBytes, compressedBytes)

        // A damaged sidecar is ignored and rewritten, never uploaded.
        let damaged = directory.appendingPathComponent("armco-albedo.bc1.torcsbc")
        var bytes = try Data(contentsOf: damaged)
        bytes[bytes.count / 2] ^= 0xff
        try bytes.write(to: damaged)
        let third = try MaterialLibrary(device: device, directory: directory)
        _ = try XCTUnwrap(third.resolve(texture: "armco-1.png", directory: directory))
        XCTAssertEqual(third.sidecarHits, 1, "the damaged one was re-encoded")
        XCTAssertNotEqual(try Data(contentsOf: damaged), bytes, "and rewritten")

        // The structure's encode is keyed by both maps it was made from: a
        // roughness map regenerated under it is not served the old one.
        let structure = directory.appendingPathComponent("armco-structure.bc3.torcsbc")
        let before = try Data(contentsOf: structure)
        try Data(contentsOf: directory.appendingPathComponent("asphalt-orm.png"))
            .write(to: directory.appendingPathComponent("armco-orm.png"))
        let fourth = try MaterialLibrary(device: device, directory: directory)
        _ = try XCTUnwrap(fourth.resolve(texture: "armco-1.png", directory: directory))
        XCTAssertEqual(fourth.sidecarHits, 1, "the albedo's, and not the structure's")
        XCTAssertNotEqual(try Data(contentsOf: structure), before)

        MaterialLibrary.compressesMaps = false
        let plain = try MaterialLibrary(device: device, directory: directory)
        let rgba = try XCTUnwrap(plain.resolve(texture: "armco-1.png", directory: directory))
        XCTAssertEqual(rgba.albedo.pixelFormat, .rgba8Unorm_srgb)
        XCTAssertGreaterThan(plain.uploadedBytes, compressedBytes * 4, "RGBA8 is at least four times the bytes")
    }
}
