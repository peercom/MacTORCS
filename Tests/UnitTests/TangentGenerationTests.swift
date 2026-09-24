// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import simd
import TORCSAssets

final class TangentGenerationTests: XCTestCase {
    /// Unit quad in the XY plane, normal +Z, U along +X and V along +Y.
    func planarQuad(flipU: Bool = false) -> (positions: [SIMD3<Float>], normals: [SIMD3<Float>],
                                             uvs: [SIMD2<Float>], indices: [UInt32]) {
        let positions: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)]
        let normals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: 4)
        let u: [Float] = flipU ? [1, 0, 0, 1] : [0, 1, 1, 0]
        let uvs: [SIMD2<Float>] = (0 ..< 4).map { SIMD2(u[$0], $0 < 2 ? 0 : 1) }
        return (positions, normals, uvs, [0, 1, 2, 0, 2, 3])
    }

    func assertOrthonormal(_ frames: [TangentGeneration.Frame], normals: [SIMD3<Float>],
                           file: StaticString = #filePath, line: UInt = #line) {
        for (i, frame) in frames.enumerated() {
            let t = frame.tangent
            XCTAssertFalse(t.x.isNaN || t.y.isNaN || t.z.isNaN, "NaN tangent at \(i)", file: file, line: line)
            XCTAssertEqual(simd_length(t), 1, accuracy: 1e-4, "tangent \(i) not unit", file: file, line: line)
            XCTAssertEqual(abs(frame.handedness), 1, accuracy: 1e-6, "handedness \(i)", file: file, line: line)
            let n = normals[i]
            if simd_length(n) > 1e-6 {
                XCTAssertEqual(simd_dot(simd_normalize(n), t), 0, accuracy: 1e-3,
                               "tangent \(i) not perpendicular to normal", file: file, line: line)
            }
        }
    }

    func testPlanarQuadTangentFollowsUDirection() {
        let q = planarQuad()
        let frames = TangentGeneration.frames(positions: q.positions, normals: q.normals, uvs: q.uvs, indices: q.indices)
        XCTAssertEqual(frames.count, 4)
        assertOrthonormal(frames, normals: q.normals)
        for frame in frames {
            XCTAssertEqual(frame.tangent.x, 1, accuracy: 1e-5)
            XCTAssertEqual(frame.handedness, 1)
        }
    }

    func testMirroredUVsInvertHandedness() {
        let q = planarQuad(flipU: true)
        let frames = TangentGeneration.frames(positions: q.positions, normals: q.normals, uvs: q.uvs, indices: q.indices)
        assertOrthonormal(frames, normals: q.normals)
        for frame in frames {
            XCTAssertEqual(frame.tangent.x, -1, accuracy: 1e-5)
            // cross(+Z, -X) = -Y, while V still runs +Y, so the frame is mirrored.
            XCTAssertEqual(frame.handedness, -1)
        }
    }

    func testCollapsedUVsFallBackToAStableOrthonormalFrame() {
        let q = planarQuad()
        let collapsed = [SIMD2<Float>](repeating: SIMD2(0.5, 0.5), count: 4)
        let frames = TangentGeneration.frames(positions: q.positions, normals: q.normals, uvs: collapsed, indices: q.indices)
        assertOrthonormal(frames, normals: q.normals)
    }

    func testMissingUVsStillProduceUsableFrames() {
        let q = planarQuad()
        let frames = TangentGeneration.frames(positions: q.positions, normals: q.normals, uvs: [], indices: q.indices)
        assertOrthonormal(frames, normals: q.normals)
    }

    func testDegenerateNormalsAndOutOfRangeIndicesAreTolerated() {
        let positions: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)]
        let normals: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(.nan, 0, 0), SIMD3(0, 0, 1)]
        let uvs: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1)]
        // Deliberately references a vertex past the end plus a degenerate triangle.
        let frames = TangentGeneration.frames(positions: positions, normals: normals, uvs: uvs,
                                             indices: [0, 1, 2, 0, 0, 0, 0, 1, 99])
        XCTAssertEqual(frames.count, 3)
        for frame in frames {
            XCTAssertEqual(simd_length(frame.tangent), 1, accuracy: 1e-4)
            XCTAssertFalse(frame.tangent.x.isNaN)
        }
    }

    /// The real shipped meshes are the cases that matter. Every frame must be
    /// orthonormal and finite, or normal mapping will produce visible garbage.
    func testOriginalFixtureMeshesProduceOrthonormalFrames() throws {
        let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let sources = [("155-DTM/155-DTM.acc", true), ("aalborg/aalborg.acc", false)]
        var totalVertices = 0, degenerateUVMeshes = 0
        for (relative, car) in sources {
            let url = fixtures.appendingPathComponent("Artwork").appendingPathComponent(relative)
            let scene = try ACScene.parse(Data(contentsOf: url), car: car)
            for node in scene.nodes {
                guard let mesh = node.mesh, let indices = try? mesh.triangleIndices(), !indices.isEmpty else { continue }
                let count = mesh.vertices.count / 3
                let positions = (0 ..< count).map { SIMD3(mesh.vertices[$0 * 3], mesh.vertices[$0 * 3 + 1], mesh.vertices[$0 * 3 + 2]) }
                // Mirrors SceneGeometry: absent normals become +Z, a single
                // stored normal applies to the whole mesh.
                let normals: [SIMD3<Float>] = (0 ..< count).map { i in
                    if mesh.normals.isEmpty { return SIMD3(0, 0, 1) }
                    let base = mesh.normals.count == 3 ? 0 : i * 3
                    return SIMD3(mesh.normals[base], mesh.normals[base + 1], mesh.normals[base + 2])
                }
                let uvs: [SIMD2<Float>] = mesh.uv[0].isEmpty ? []
                    : (0 ..< count).map { SIMD2(mesh.uv[0][$0 * 2], mesh.uv[0][$0 * 2 + 1]) }
                if uvs.isEmpty { degenerateUVMeshes += 1 }
                let frames = TangentGeneration.frames(positions: positions, normals: normals, uvs: uvs, indices: indices)
                XCTAssertEqual(frames.count, count)
                assertOrthonormal(frames, normals: normals)
                totalVertices += count
            }
        }
        // Guards against the fixtures silently failing to load at all.
        XCTAssertGreaterThan(totalVertices, 15_000, "expected the full car + track vertex count")
        print("TANGENTS generated for \(totalVertices) fixture vertices, \(degenerateUVMeshes) meshes without base UVs")
    }
}
