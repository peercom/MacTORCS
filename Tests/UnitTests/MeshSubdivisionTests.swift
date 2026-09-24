// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import TORCSRender
import TORCSAssets

final class MeshSubdivisionTests: XCTestCase {
    /// A closed octahedron: every edge smooth, so two levels round it toward
    /// a sphere and the vertex count grows as Loop predicts.
    func octahedron() -> MeshSubdivision.Mesh {
        let p: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1)]
        let faces: [[Int]] = [[0, 2, 4], [2, 1, 4], [1, 3, 4], [3, 0, 4], [2, 0, 5], [1, 2, 5], [3, 1, 5], [0, 3, 5]]
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uv: [SIMD2<Float>] = [], indices: [UInt32] = []
        for f in faces {
            for i in f {
                indices.append(UInt32(positions.count)); positions.append(p[i]); normals.append(simd_normalize(p[i]))
                uv.append(SIMD2(p[i].x * 0.5 + 0.5, p[i].y * 0.5 + 0.5))
            }
        }
        return MeshSubdivision.Mesh(positions: positions, normals: normals, uv0: uv, uv1: [], indices: indices)
    }

    func testSmoothMeshRoundsAndGrowsFourfoldPerLevel() {
        let base = octahedron()
        // The octahedron's edges meet at 109°, past the default crease angle,
        // so ask for smooth subdivision with a generous angle.
        let once = MeshSubdivision.loop(base, levels: 1, creaseAngle: .pi)
        let twice = MeshSubdivision.loop(base, levels: 2, creaseAngle: .pi)
        XCTAssertEqual(once.triangleCount, 32)
        XCTAssertEqual(twice.triangleCount, 128)
        // Welded output: far fewer vertices than corners.
        XCTAssertLessThan(twice.positions.count, twice.indices.count / 2)
        // Rounder: the radii spread less than the octahedron's (1 at the
        // vertices, 0.577 at the face centres), and every normal is unit.
        let radii = twice.positions.map { simd_length($0) }
        XCTAssertLessThan(radii.max()! - radii.min()!, 0.25)
        for n in twice.normals { XCTAssertEqual(simd_length(n), 1, accuracy: 1e-3) }
        // Normals point outward on a convex body.
        for (p, n) in zip(twice.positions, twice.normals) { XCTAssertGreaterThan(simd_dot(simd_normalize(p), n), 0.8) }
    }

    /// A crease stays a crease: a folded sheet keeps its ridge line in place
    /// and its two faces keep distinct normals across it.
    func testCreaseIsPreserved() {
        // Two quads folded at 90° along the y axis, each as two triangles.
        let p: [SIMD3<Float>] = [SIMD3(-1, -1, 0), SIMD3(0, -1, 0), SIMD3(0, 1, 0), SIMD3(-1, 1, 0),
                                 SIMD3(0, -1, 1), SIMD3(0, 1, 1)]
        let faces: [[Int]] = [[0, 1, 2], [0, 2, 3], [1, 4, 5], [1, 5, 2]]
        var positions: [SIMD3<Float>] = [], indices: [UInt32] = []
        for f in faces { for i in f { indices.append(UInt32(positions.count)); positions.append(p[i]) } }
        let mesh = MeshSubdivision.Mesh(positions: positions, normals: positions.map { _ in SIMD3(0, 0, 1) },
                                        uv0: positions.map { SIMD2($0.x, $0.y) }, uv1: [], indices: indices)
        let out = MeshSubdivision.loop(mesh, levels: 2)
        // Every vertex on the fold (x == 0, z == 0 originally) stays on it.
        let ridge = out.positions.filter { abs($0.x) < 1e-4 && abs($0.z) < 1e-4 }
        XCTAssertGreaterThan(ridge.count, 3)
        // Boundary vertices stay on their boundary lines.
        XCTAssertTrue(out.positions.allSatisfy { $0.z >= -1e-4 && $0.z <= 1 + 1e-4 && $0.x >= -1 - 1e-4 })
        // Two normal directions survive: flat (0,0,1) and upright (1,0,0).
        let flat = out.normals.filter { $0.z > 0.95 }.count, upright = out.normals.filter { $0.x < -0.95 }.count
        print("CREASE_DEBUG positions \(out.positions.count) normals \(out.normals.prefix(12)) z \(out.positions.map(\.z).max()!)")
        XCTAssertGreaterThan(flat, 0); XCTAssertGreaterThan(upright, 0)
        XCTAssertEqual(out.triangleCount, 64)
        // Texture coordinates are interpolated, not invented: they stay in range.
        XCTAssertTrue(out.uv0.allSatisfy { $0.x >= -1 - 1e-4 && $0.x <= 1e-4 && abs($0.y) <= 1 + 1e-4 })
    }

    func testZeroLevelsIsIdentity() {
        let base = octahedron()
        let same = MeshSubdivision.loop(base, levels: 0)
        XCTAssertEqual(same.indices, base.indices)
        XCTAssertEqual(same.positions, base.positions)
    }
}

extension MeshSubdivisionTests {
    /// The fixture car, subdivided twice at load: sixteen times the
    /// triangles, the same footprint, and still a valid scene.
    func testFixtureCarSubdividesInPlace() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Artwork/155-DTM/155-DTM.acc")
        let parsed = try ACScene.parse(Data(contentsOf: url), car: true)
        let flat = try RenderScene(parsed, car: true)
        let smooth = try RenderScene(parsed, car: true, subdivisionLevels: 2)
        let flatTriangles = flat.batches.reduce(0) { $0 + $1.mesh.indices.count / 3 }
        let smoothTriangles = smooth.batches.reduce(0) { $0 + $1.mesh.indices.count / 3 }
        XCTAssertEqual(smooth.batches.count, flat.batches.count)
        // Sixteen per face, less the duplicate and degenerate faces welding
        // removes from an AC file.
        XCTAssertGreaterThan(Double(smoothTriangles) / Double(flatTriangles), 10)
        // Loop shrinks a closed surface slightly; a car's box must not move
        // by more than a few centimetres.
        for axis in 0 ..< 3 {
            XCTAssertEqual(smooth.minimum[axis], flat.minimum[axis], accuracy: 0.05)
            XCTAssertEqual(smooth.maximum[axis], flat.maximum[axis], accuracy: 0.05)
        }
        print("HERO_CAR triangles \(flatTriangles) -> \(smoothTriangles)")
    }
}
