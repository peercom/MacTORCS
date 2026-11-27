// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import TORCSRender
import TORCSAssets
import TORCSMaterials

final class TyreUnwrapTests: XCTestCase {
    /// A tyre as the wheel models have it: a unit across every way, axle
    /// along `axis`, a section of bead, sidewall, shoulder, tread and back.
    private func tyre(axis: Int, part: CarMaterials.Part? = .tyre) throws -> RenderBatch {
        // (along the axle, radius), bead to bead over the tread.
        let section: [(Float, Float)] = [(-0.5, 0.30), (-0.5, 0.40), (-0.42, 0.48), (-0.25, 0.5), (0, 0.5), (0.25, 0.5), (0.42, 0.48), (0.5, 0.40), (0.5, 0.30)]
        let around = 24
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uv: [SIMD2<Float>] = [], indices: [UInt32] = []
        for step in 0 ..< around {
            let angle = Float(step) / Float(around) * 2 * .pi
            for (along, radius) in section {
                var p = SIMD3<Float>(repeating: 0)
                p[axis] = along; p[(axis + 1) % 3] = cos(angle) * radius; p[(axis + 2) % 3] = sin(angle) * radius
                positions.append(p)
                var n = SIMD3<Float>(repeating: 0)
                n[(axis + 1) % 3] = cos(angle); n[(axis + 2) % 3] = sin(angle)
                normals.append(n)
                // The picture of a wheel from its side: everything at the tread is one texel.
                uv.append(SIMD2(0.125 + cos(angle) * radius * 0.25, 0.75 + sin(angle) * radius * 0.25))
            }
        }
        let rows = UInt32(section.count)
        for step in 0 ..< UInt32(around) {
            let next = (step + 1) % UInt32(around)
            for k in 0 ..< rows - 1 {
                let a = step * rows + k, b = next * rows + k
                indices += [a, b, a + 1, a + 1, b, b + 1]
            }
        }
        let mesh = try RenderMesh.build(positions: positions, normals: normals, uv0: uv, indices: indices)
        let state = ACRenderState(material: [0, 0, 0, 1, 0, 0, 0, 1, 0.2, 0.2, 0.2, 1, 0], texture: "wheel3d.png", flags: 8, alphaClamp: 0)
        return RenderBatch(mesh: mesh, baseTexture: "wheel3d.png", blends: false, isDeferred: false, alphaTestThreshold: nil,
                           culls: true, isDriver: false, sourceMaterial: state,
                           material: ResolvedMaterial(baseColour: SIMD4(1, 1, 1, 1), roughness: 0.88, metallic: 0), carPart: part)
    }

    /// Round the wheel in `u`, twice to the texture; across the section in
    /// `v`, the tread in its band and the sidewalls outside it, whichever
    /// way the axle lies.
    func testATyreIsUnwrappedRoundItsAxleAndAcrossItsSection() throws {
        let tread = MaterialRecipes.tyreTread
        for axis in 0 ..< 3 {
            let batch = try tyre(axis: axis)
            let scene = RenderScene(batches: [batch, try tyre(axis: axis, part: .rim)], minimum: SIMD3(repeating: -0.5), maximum: SIMD3(repeating: 0.5))
            let result = TyreUnwrap.unwrapped(scene, texture: "car-tyre.rgb")
            XCTAssertEqual(result.batches.count, 2)
            XCTAssertEqual(result.batches[0].baseTexture, "car-tyre.rgb"); XCTAssertEqual(result.batches[0].carPart, .tyre)
            // The rim is left alone, coordinates and all.
            XCTAssertEqual(result.batches[1].baseTexture, "wheel3d.png")
            XCTAssertEqual(result.batches[1].mesh.vertices, scene.batches[1].mesh.vertices)
            let mesh = result.batches[0].mesh
            XCTAssertEqual(mesh.indices.count, batch.mesh.indices.count, "the same triangles")
            // The same vertices too, but for the row along which the angle wraps.
            XCTAssertLessThanOrEqual(mesh.vertices.count, batch.mesh.vertices.count + 2 * 9)
            XCTAssertGreaterThanOrEqual(mesh.vertices.count, batch.mesh.vertices.count)
            var lowest: Float = 10, highest: Float = -10
            for vertex in mesh.vertices {
                let p = vertex.position, v = Float(vertex.uv0.y), u = Float(vertex.uv0.x)
                var q = p; q[axis] = 0
                let radius = simd_length(q), along = p[axis]
                lowest = min(lowest, u); highest = max(highest, u)
                if radius > 0.495 {
                    XCTAssertTrue(tread.contains(v), "the tread at \(along) is at \(v), axle \(axis)")
                    // Across the tread as across the tyre.
                    XCTAssertEqual(v, 0.5 + along / 0.25 * (v - 0.5 == 0 ? 0 : abs(v - 0.5)), accuracy: 0.001)
                } else if radius < 0.41 {
                    XCTAssertFalse(tread.contains(v), "a sidewall at radius \(radius) is at \(v), axle \(axis)")
                    XCTAssertEqual(v < 0.5, along < 0, "each sidewall on its own side")
                }
                if radius < 0.305 { XCTAssertTrue(v < 0.02 || v > 0.98, "the bead is at the tile's edge") }
            }
            XCTAssertGreaterThan(highest - lowest, TyreUnwrap.repeats * 0.95, "all the way round")
            XCTAssertLessThan(highest - lowest, TyreUnwrap.repeats * 1.1)
            // No triangle is drawn backwards across the tyre where the angle wraps.
            for triangle in stride(from: 0, to: mesh.indices.count, by: 3) {
                let us = (0 ..< 3).map { Float(mesh.vertices[Int(mesh.indices[triangle + $0])].uv0.x) }
                XCTAssertLessThan(us.max()! - us.min()!, TyreUnwrap.repeats / 4)
            }
        }
    }

    func testOnlyAWheelsTyreIsUnwrappedAndEachSpeedHasItsSet() throws {
        // A scene with no tyre in it comes back as it went.
        let rim = try tyre(axis: 1, part: .rim)
        let scene = RenderScene(batches: [rim], minimum: SIMD3(repeating: -0.5), maximum: SIMD3(repeating: 0.5))
        XCTAssertEqual(TyreUnwrap.unwrapped(scene, texture: "car-tyre.rgb").batches[0].mesh.vertices, rim.mesh.vertices)
        // The first car's wheels are resources 1 to 4, a further model's the same within its seventeen.
        XCTAssertEqual((0 ... 6).map(TyreUnwrap.wheelLevel), [nil, 0, 1, 2, 3, nil, nil])
        XCTAssertEqual((17 ... 23).map(TyreUnwrap.wheelLevel), [nil, nil, 0, 1, 2, 3, nil])
        XCTAssertEqual((35 ... 40).map(TyreUnwrap.wheelLevel), [nil, 0, 1, 2, 3, nil])
        XCTAssertEqual(MaterialLibrary.material(for: TyreUnwrap.texture(level: 0)), "car-tyre")
        for level in 1 ... 3 { XCTAssertEqual(MaterialLibrary.material(for: TyreUnwrap.texture(level: level)), "car-tyre-rolling") }
    }
}
