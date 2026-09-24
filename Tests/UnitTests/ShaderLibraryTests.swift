// SPDX-License-Identifier: GPL-2.0-only
import XCTest
import Metal
import simd
import TORCSRender

final class ShaderLibraryTests: XCTestCase {
    func testUniformLayoutsMatchTheMetalStructs() {
        // 5 matrices (64 each) plus 5 vectors (16 each). The unjittered and
        // previous view-projections feed motion vectors for temporal upscaling.
        XCTAssertEqual(MemoryLayout<FrameUniforms>.size, 400)
        XCTAssertEqual(MemoryLayout<FrameUniforms>.stride, 400)
        XCTAssertEqual(MemoryLayout<DrawUniforms>.size, 224)
        XCTAssertEqual(MemoryLayout<DrawUniforms>.offset(of: \.fade), 208)
        XCTAssertEqual(MemoryLayout<DrawUniforms>.stride, 224)
        XCTAssertEqual(MemoryLayout<DrawUniforms>.offset(of: \.emissive), 192)
        XCTAssertEqual(MemoryLayout<FrameUniforms>.offset(of: \.cameraPosition), 320)
        XCTAssertEqual(MemoryLayout<DrawUniforms>.offset(of: \.baseColour), 128)
        XCTAssertEqual(MemoryLayout<DrawUniforms>.offset(of: \.maps), 176)
        // model, normalMatrix, previousModel and the light state.
        XCTAssertEqual(MemoryLayout<InstanceUniforms>.size, 208)
        XCTAssertEqual(MemoryLayout<InstanceUniforms>.offset(of: \.previousModel), 128)
        XCTAssertEqual(MemoryLayout<InstanceUniforms>.offset(of: \.lightState), 192)
    }

    /// The offline build script lists the sources in its own order; it must
    /// be the runtime order, or the prebuilt library differs from the
    /// compiled one.
    func testOfflineBuildScriptMirrorsTheSourceOrder() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Scripts/build-shaders.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        let line = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("order=(") })
        let names = line.dropFirst("order=(".count).dropLast().split(separator: " ").map(String.init)
        XCTAssertEqual(names, ShaderLibrary.sourceOrder)
    }

    func testLocalIncludesAreStrippedButSystemIncludesSurvive() throws {
        let combined = try ShaderLibrary.combinedSource()
        XCTAssertFalse(combined.contains("#include \""), "local includes must be stripped for makeLibrary(source:)")
        XCTAssertTrue(combined.contains("#include <metal_stdlib>"), "system includes must remain")
        // Guards against silently loading a subset of the sources.
        for name in ShaderLibrary.sourceOrder {
            XCTAssertTrue(combined.contains("TORCS_\(name.uppercased())_METAL"), "missing \(name).metal")
        }
    }

    /// The whole point of the concatenation: it has to actually compile as one
    /// translation unit, not merely as five separate files.
    func testCombinedLibraryCompilesAndExposesEveryEntryPoint() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let library = try ShaderLibrary(device: device).library
        for name in ["forwardVertex", "forwardFragment", "fullscreenVertex", "resolveFragment"] {
            XCTAssertNotNil(library.makeFunction(name: name), "missing entry point \(name)")
        }
    }

    func testNormalMatrixCorrectsNonUniformScale() {
        // Non-uniform scale is where reusing the model matrix visibly fails.
        var model = matrix_identity_float4x4
        model.columns.0.x = 4
        model.columns.1.y = 1
        model.columns.2.z = 0.25
        let normalMatrix = DrawUniforms.normalMatrix(for: model)

        // A surface in the XZ plane scaled this way keeps its normal along Y.
        let tangentA = SIMD3<Float>(1, 0, 0), tangentB = SIMD3<Float>(0, 0, 1)
        func transformed(_ m: simd_float4x4, _ v: SIMD3<Float>) -> SIMD3<Float> {
            let r = m * SIMD4(v, 0)
            return SIMD3(r.x, r.y, r.z)
        }
        let normal = transformed(normalMatrix, SIMD3(0, 1, 0))
        XCTAssertEqual(simd_dot(simd_normalize(normal), simd_normalize(transformed(model, tangentA))), 0, accuracy: 1e-5)
        XCTAssertEqual(simd_dot(simd_normalize(normal), simd_normalize(transformed(model, tangentB))), 0, accuracy: 1e-5)
    }

    func testNormalMatrixFallsBackOnSingularBasis() {
        var collapsed = matrix_identity_float4x4
        collapsed.columns.0 = SIMD4(0, 0, 0, 0)
        let result = DrawUniforms.normalMatrix(for: collapsed)
        XCTAssertTrue(result.columns.3.w.isFinite, "must not produce NaN on a singular basis")
    }

    /// AgX replaces a clamp that flattened every highlight to white. These are
    /// the properties that actually matter: monotonic, finite, and no output
    /// outside the display range however bright the input.
    func testAgXTonemapIsMonotonicFiniteAndBounded() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable")
        }
        let probe = """
        kernel void probeTonemap(const device float *inputs [[buffer(0)]],
                                 device float4 *out [[buffer(1)]],
                                 uint i [[thread_position_in_grid]]) {
            out[i] = float4(tonemapAgX(float3(inputs[i]), 1.0f), 0.0f);
        }
        """
        let library = try ShaderLibrary(device: device,
                                        source: try ShaderLibrary.combinedSource() + probe).library
        let pipeline = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "probeTonemap")))

        // Zero through far beyond clipping, including a direct-sun magnitude.
        var inputs: [Float] = [0, 1e-6, 0.001, 0.018, 0.18, 0.5, 1, 2, 4, 16, 100, 10_000]
        inputs += stride(from: Float(0), through: 3, by: 0.05)
        let inputBuffer = try XCTUnwrap(inputs.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        })
        let output = try XCTUnwrap(device.makeBuffer(length: inputs.count * 16, options: .storageModeShared))

        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(commands.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(inputBuffer, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        encoder.dispatchThreads(MTLSize(width: inputs.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 1, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertNil(commands.error)

        let mapped = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: inputs.count)
        for (i, input) in inputs.enumerated() {
            let value = mapped[i]
            for channel in [value.x, value.y, value.z] {
                XCTAssertFalse(channel.isNaN, "NaN at input \(input)")
                XCTAssertGreaterThanOrEqual(channel, 0, "negative output at \(input)")
                XCTAssertLessThanOrEqual(channel, 1.0001, "output above display range at \(input)")
            }
        }
        // Black must stay black, or every shadow lifts to grey.
        XCTAssertLessThan(mapped[0].x, 0.02, "zero radiance should map near black")
        // The sorted sweep at the tail must be non-decreasing.
        let sweepStart = 12
        for i in (sweepStart + 1) ..< inputs.count {
            XCTAssertGreaterThanOrEqual(mapped[i].x + 1e-4, mapped[i - 1].x,
                                        "tonemap not monotonic between \(inputs[i - 1]) and \(inputs[i])")
        }
        // A bright highlight must still be brighter than middle grey, not clipped equal.
        XCTAssertGreaterThan(mapped[10].x, mapped[4].x, "100.0 should read brighter than 0.18")
        print("AgX: 0->\(mapped[0].x), 0.18->\(mapped[4].x), 1.0->\(mapped[6].x), 100->\(mapped[10].x)")
    }
}
