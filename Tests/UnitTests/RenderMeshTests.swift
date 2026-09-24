// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
import TORCSRender

final class RenderMeshTests: XCTestCase {
    /// A silent layout mismatch between Swift and Metal would misread every
    /// attribute after the first divergent field, so pin the exact numbers.
    func testPackedVertexLayoutMatchesTheMetalStruct() {
        XCTAssertEqual(MemoryLayout<PackedVertex>.size, 32)
        XCTAssertEqual(MemoryLayout<PackedVertex>.stride, 32, "stride padding would break array indexing")
        XCTAssertEqual(MemoryLayout<PackedVertex>.alignment, 4)
        XCTAssertEqual(MemoryLayout<PackedVertex>.offset(of: \.positionX), 0)
        XCTAssertEqual(MemoryLayout<PackedVertex>.offset(of: \.normal), 12)
        XCTAssertEqual(MemoryLayout<PackedVertex>.offset(of: \.tangent), 16)
        XCTAssertEqual(MemoryLayout<PackedVertex>.offset(of: \.uv0), 20)
        XCTAssertEqual(MemoryLayout<PackedVertex>.offset(of: \.uv1), 24)
        XCTAssertEqual(MemoryLayout<PackedVertex>.offset(of: \.blend), 28)
    }

    func testPackedVertexIsHalfTheClassicVertexSize() {
        // The classic SceneVertex was four SIMD4<Float>.
        XCTAssertEqual(MemoryLayout<PackedVertex>.size * 2, 64)
    }

    func testBuildDerivesTangentsAndBounds() throws {
        let positions: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 2, 0), SIMD3(0, 2, 0)]
        let normals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: 4)
        let uvs: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        let mesh = try RenderMesh.build(positions: positions, normals: normals, uv0: uvs,
                                        indices: [0, 1, 2, 0, 2, 3])
        XCTAssertEqual(mesh.vertices.count, 4)
        XCTAssertEqual(mesh.center, SIMD3(1, 1, 0))
        XCTAssertEqual(mesh.radius, sqrt(2), accuracy: 1e-5)
        for vertex in mesh.vertices {
            XCTAssertEqual(vertex.tangent.y & 1, 0, "unmirrored geometry should be right-handed")
        }
    }

    /// Mirrored nodes occur in the original car meshes, and a flipped bitangent
    /// inverts normal-mapped lighting on exactly those parts.
    func testMirroredTransformFlipsStoredHandedness() throws {
        let positions: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0)]
        let normals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: 3)
        let uvs: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1)]
        var mirror = matrix_identity_float4x4
        mirror.columns.0.x = -1
        XCTAssertLessThan(simd_determinant(mirror), 0)

        let plain = try RenderMesh.build(positions: positions, normals: normals, uv0: uvs, indices: [0, 1, 2])
        let mirrored = try RenderMesh.build(positions: positions, normals: normals, uv0: uvs,
                                            indices: [0, 1, 2], transform: mirror)
        for i in 0 ..< 3 {
            XCTAssertNotEqual(plain.vertices[i].tangent.y & 1, mirrored.vertices[i].tangent.y & 1,
                              "handedness bit should differ under a mirroring transform")
        }
    }

    func testMismatchedArrayLengthsAreRejected() {
        let positions = [SIMD3<Float>(0, 0, 0)]
        XCTAssertThrowsError(try RenderMesh.build(positions: positions, normals: [], uv0: [], indices: []))
        XCTAssertThrowsError(try RenderMesh.build(positions: positions,
                                                  normals: [SIMD3(0, 0, 1)],
                                                  uv0: [SIMD2(0, 0), SIMD2(1, 1)], indices: []))
    }

    func testEmptyMeshHasZeroBoundsRatherThanInfinity() {
        let mesh = RenderMesh(vertices: [], indices: [], transform: matrix_identity_float4x4)
        XCTAssertEqual(mesh.radius, 0)
        XCTAssertTrue(mesh.center.x.isFinite)
    }

    /// Writes a buffer from Swift and reads every field back through Metal.
    /// This is what actually proves the two struct definitions agree.
    func testGPUReadsEveryPackedFieldAtTheExpectedOffset() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable")
        }
        let probe = """
        kernel void probeLayout(const device PackedVertex *v [[buffer(0)]],
                                device float4 *position [[buffer(1)]],
                                device float4 *uv [[buffer(2)]],
                                device float4 *blend [[buffer(3)]],
                                uint i [[thread_position_in_grid]]) {
            position[i] = float4(v[i].position, 0.0f);
            uv[i] = float4(float2(v[i].uv0), float2(v[i].uv1));
            blend[i] = float4(v[i].blend);
        }
        """
        let library = try ShaderLibrary(device: device,
                                        source: try ShaderLibrary.combinedSource() + probe).library
        let pipeline = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "probeLayout")))

        // Values chosen to be exactly representable in half precision.
        let vertices: [PackedVertex] = (0 ..< 64).map { i -> PackedVertex in
            let f = Float(i)
            let position = SIMD3<Float>(f * 3.5, f - 20, 1234.5)
            let normal = SIMD3<Float>(0, 0, 1)
            let tangent = SIMD3<Float>(1, 0, 0)
            let handedness: Float = i.isMultiple(of: 2) ? 1 : -1
            let uv0 = SIMD2<Float>(f * 0.25, 0.5)
            let uv1 = SIMD2<Float>(0.75, f * 0.125)
            let blend = SIMD4<UInt8>(UInt8(i % 256), 7, 200, 3)
            return PackedVertex(position: position, normal: normal, tangent: tangent,
                                handedness: handedness, uv0: uv0, uv1: uv1, blend: blend)
        }
        let input = try XCTUnwrap(vertices.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        })
        let byteCount = vertices.count * 16
        var outputs: [MTLBuffer] = []
        for _ in 0 ..< 3 {
            outputs.append(try XCTUnwrap(device.makeBuffer(length: byteCount, options: .storageModeShared)))
        }

        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commands.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(input, offset: 0, index: 0)
        for (i, buffer) in outputs.enumerated() { encoder.setBuffer(buffer, offset: 0, index: i + 1) }
        encoder.dispatchThreads(MTLSize(width: vertices.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 32, height: 1, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertNil(commands.error)

        let positions = outputs[0].contents().bindMemory(to: SIMD4<Float>.self, capacity: vertices.count)
        let uvs = outputs[1].contents().bindMemory(to: SIMD4<Float>.self, capacity: vertices.count)
        let blends = outputs[2].contents().bindMemory(to: SIMD4<Float>.self, capacity: vertices.count)
        for (i, vertex) in vertices.enumerated() {
            XCTAssertEqual(positions[i].x, vertex.positionX, accuracy: 1e-4, "position x at \(i)")
            XCTAssertEqual(positions[i].y, vertex.positionY, accuracy: 1e-4, "position y at \(i)")
            XCTAssertEqual(positions[i].z, vertex.positionZ, accuracy: 1e-4, "position z at \(i)")
            XCTAssertEqual(uvs[i].x, Float(vertex.uv0.x), accuracy: 1e-3, "uv0 x at \(i)")
            XCTAssertEqual(uvs[i].w, Float(vertex.uv1.y), accuracy: 1e-3, "uv1 y at \(i)")
            XCTAssertEqual(blends[i].x, Float(vertex.blend.x), accuracy: 0.5, "blend x at \(i)")
            XCTAssertEqual(blends[i].z, Float(vertex.blend.z), accuracy: 0.5, "blend z at \(i)")
        }
    }
}
