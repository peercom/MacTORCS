// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
import TORCSMath
import TORCSRender

/// Proves the GPU reproduces the CPU vertex packing.
///
/// This is the one place in the new render path where the same bit layout is
/// decoded by two independently written implementations in two languages, and
/// the tangent's handedness lives in a stolen low bit that a hardware snorm
/// conversion would silently destroy. A mismatch would not crash — it would
/// produce subtly wrong normal mapping that is very hard to attribute later.
final class ShaderPackingParityTests: XCTestCase {
    /// Appends a probe kernel to the shared shader sources.
    static let probeSource = """
    kernel void probePacking(const device short2 *normals [[buffer(0)]],
                             const device short2 *tangents [[buffer(1)]],
                             device float4 *decodedNormals [[buffer(2)]],
                             device float4 *decodedTangents [[buffer(3)]],
                             uint i [[thread_position_in_grid]]) {
        decodedNormals[i] = float4(decodeNormal(normals[i]), 0.0f);
        decodedTangents[i] = decodeTangent(tangents[i]);
    }
    """

    func sphereDirections(_ count: Int) -> [SIMD3<Float>] {
        let golden = Float.pi * (3 - (5 as Float).squareRoot())
        return (0 ..< count).map { i in
            let z = 1 - 2 * (Float(i) + 0.5) / Float(count)
            let r = max(0, 1 - z * z).squareRoot()
            return simd_normalize(SIMD3(r * cos(golden * Float(i)), r * sin(golden * Float(i)), z))
        }
    }

    func testGPUDecodeMatchesSwiftEncoderForNormalsAndTangents() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable")
        }
        let source = try ShaderLibrary.combinedSource() + Self.probeSource
        let library = try ShaderLibrary(device: device, source: source).library
        let function = try XCTUnwrap(library.makeFunction(name: "probePacking"))
        let pipeline = try device.makeComputePipelineState(function: function)

        let directions = sphereDirections(4096)
        var packedNormals = [SIMD2<Int16>](), packedTangents = [SIMD2<Int16>]()
        var expectedNormals = [SIMD3<Float>](), expectedTangents = [(SIMD3<Float>, Float)]()
        for (i, d) in directions.enumerated() {
            let handedness: Float = i.isMultiple(of: 3) ? -1 : 1
            let n = OctahedralPacking.encodeNormal(d)
            let t = OctahedralPacking.encodeTangent(d, handedness: handedness)
            packedNormals.append(n)
            packedTangents.append(t)
            expectedNormals.append(OctahedralPacking.decodeNormal(n))
            expectedTangents.append(OctahedralPacking.decodeTangent(t))
        }

        let count = directions.count
        func buffer<T>(_ values: [T]) throws -> MTLBuffer {
            try XCTUnwrap(values.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) })
        }
        let normalBuffer = try buffer(packedNormals), tangentBuffer = try buffer(packedTangents)
        let outNormals = try XCTUnwrap(device.makeBuffer(length: count * 16, options: .storageModeShared))
        let outTangents = try XCTUnwrap(device.makeBuffer(length: count * 16, options: .storageModeShared))

        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commands.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(normalBuffer, offset: 0, index: 0)
        encoder.setBuffer(tangentBuffer, offset: 0, index: 1)
        encoder.setBuffer(outNormals, offset: 0, index: 2)
        encoder.setBuffer(outTangents, offset: 0, index: 3)
        let width = min(pipeline.maxTotalThreadsPerThreadgroup, 64)
        encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertNil(commands.error)

        let gpuNormals = outNormals.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        let gpuTangents = outTangents.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        var worstNormal: Float = 0, worstTangent: Float = 0, handednessMismatches = 0

        for i in 0 ..< count {
            let gpuN = SIMD3(gpuNormals[i].x, gpuNormals[i].y, gpuNormals[i].z)
            worstNormal = max(worstNormal, simd_length(gpuN - expectedNormals[i]))
            let gpuT = SIMD3(gpuTangents[i].x, gpuTangents[i].y, gpuTangents[i].z)
            worstTangent = max(worstTangent, simd_length(gpuT - expectedTangents[i].0))
            if gpuTangents[i].w != expectedTangents[i].1 { handednessMismatches += 1 }
        }
        print("GPU/CPU packing parity: normal \(worstNormal), tangent \(worstTangent), handedness mismatches \(handednessMismatches)")
        // Only floating-point rounding should differ between the two decoders.
        XCTAssertEqual(handednessMismatches, 0, "handedness bit disagrees between CPU and GPU")
        XCTAssertLessThan(worstNormal, 1e-5, "GPU normal decode diverges")
        XCTAssertLessThan(worstTangent, 1e-5, "GPU tangent decode diverges")
    }
}
