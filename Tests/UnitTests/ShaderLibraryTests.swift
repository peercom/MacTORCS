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
        for name in ["forwardVertex", "forwardFragment", "fullscreenVertex", "resolveFragment", "dofPrefilterFragment", "dofGatherFragment", "exposureMeter"] {
            XCTAssertNotNil(library.makeFunction(name: name), "missing entry point \(name)")
        }
    }

    /// A measurement that names a library which is not there must fail, not
    /// compile the sources and compare a change against itself.
    func testExplicitMetallibPathMustExist() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let missing = NSTemporaryDirectory() + "no-such-\(UUID().uuidString).metallib"
        setenv("TORCS_METALLIB", missing, 1)
        defer { unsetenv("TORCS_METALLIB") }
        XCTAssertThrowsError(try ShaderLibrary(device: device)) { error in
            XCTAssertTrue(String(describing: error).contains("TORCS_METALLIB"), "\(error)")
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
    /// The dither is half a display level either way at every brightness.
    /// Added to the linear value instead, it was seven levels in the
    /// shadows and a fifth of one near white.
    func testDitherIsHalfADisplayLevelAtEveryBrightness() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable")
        }
        let probe = """
        kernel void probeDither(const device float *inputs [[buffer(0)]],
                                device float4 *out [[buffer(1)]],
                                uint i [[thread_position_in_grid]]) {
            float3 radiance = float3(inputs[i]);
            out[i] = float4(tonemapAgXDithered(radiance, 0.0f).x, tonemapAgXDithered(radiance, 0.5f).x,
                            tonemapAgXDithered(radiance, 1.0f).x, tonemapAgX(radiance, 1.0f).x);
        }
        """
        let library = try ShaderLibrary(device: device,
                                        source: try ShaderLibrary.combinedSource() + probe).library
        let pipeline = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "probeDither")))
        // Black to white in steps of a third of a stop.
        let inputs: [Float] = [0] + (0 ..< 60).map { 1e-4 * pow(2, Float($0) / 3) }
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

        // What the sRGB target stores for a linear value, in levels of 255.
        func level(_ linear: Float) -> Float {
            (linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055) * 255
        }
        let mapped = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: inputs.count)
        var widest: Float = 0
        for (i, input) in inputs.enumerated() {
            let low = level(mapped[i].x), middle = level(mapped[i].y), high = level(mapped[i].z)
            XCTAssertEqual(middle, level(mapped[i].w), accuracy: 0.01, "noise of a half is no dither, at \(input)")
            XCTAssertLessThanOrEqual(low, middle + 0.001, "at \(input)")
            XCTAssertGreaterThanOrEqual(high, middle - 0.001, "at \(input)")
            XCTAssertLessThan(middle - low, 0.75, "dither below at \(input), level \(middle)")
            XCTAssertLessThan(high - middle, 0.75, "dither above at \(input), level \(middle)")
            widest = max(widest, high - low)
        }
        XCTAssertGreaterThan(widest, 0.9, "and it is a whole level wide where the encoding is not at its toe")
        XCTAssertEqual(mapped[0].x, 0, "black stays black under the dither")
    }

    /// The sky's irradiance is stored as a quadratic in the normal and
    /// evaluated nested. It has to be the order-2 harmonics it was made
    /// from, convolved to irradiance: the textbook sum, term by term.
    func testSkyIrradiancePolynomialIsTheHarmonicsItCameFrom() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal device unavailable")
        }
        let probe = """
        kernel void probeIrradiance(const device float4 *harmonics [[buffer(0)]],
                                    const device float4 *normals [[buffer(1)]],
                                    device float4 *out [[buffer(2)]],
                                    device SkyIrradiance &sky [[buffer(3)]],
                                    uint i [[thread_position_in_grid]]) {
            float3 sh[9];
            for (uint k = 0; k < 9; ++k) { sh[k] = harmonics[k].rgb; }
            if (i == 0) { sky = skyIrradianceFromHarmonics(sh); }
            SkyIrradiance local = skyIrradianceFromHarmonics(sh);
            float3 n = normals[i].xyz;
            float3 result = local.coefficients[0].rgb
                + n.x * (local.coefficients[1].rgb + n.x * local.coefficients[4].rgb + n.y * local.coefficients[5].rgb
                         + n.z * local.coefficients[7].rgb)
                + n.y * (local.coefficients[2].rgb - n.y * local.coefficients[4].rgb + n.z * local.coefficients[6].rgb)
                + n.z * (local.coefficients[3].rgb + n.z * local.coefficients[8].rgb);
            out[i] = float4(result, 0.0f);
        }
        kernel void probeIrradianceEvaluate(constant SkyIrradiance &sky [[buffer(3)]],
                                            const device float4 *normals [[buffer(1)]],
                                            device float4 *out [[buffer(2)]],
                                            uint i [[thread_position_in_grid]]) {
            out[i] = float4(evaluateSkyIrradiance(sky, normals[i].xyz), 0.0f);
        }
        """
        let library = try ShaderLibrary(device: device,
                                        source: try ShaderLibrary.combinedSource() + probe).library
        // Harmonics of a sky brighter above than below, bluer to one side,
        // with every band and every coefficient in play.
        let harmonics: [SIMD4<Float>] = [
            SIMD4(3.0, 3.4, 4.1, 0), SIMD4(0.3, 0.2, -0.1, 0), SIMD4(1.1, 1.3, 1.6, 0), SIMD4(-0.4, 0.1, 0.5, 0),
            SIMD4(0.2, -0.1, 0.05, 0), SIMD4(0.15, 0.1, -0.2, 0), SIMD4(0.5, 0.45, 0.4, 0), SIMD4(-0.25, 0.05, 0.1, 0),
            SIMD4(0.1, 0.2, -0.15, 0),
        ]
        var normals: [SIMD4<Float>] = [SIMD4(0, 0, 1, 0), SIMD4(0, 0, -1, 0), SIMD4(1, 0, 0, 0), SIMD4(0, -1, 0, 0)]
        for k in 0 ..< 28 {
            let z = 1 - 2 * (Float(k) + 0.5) / 28, r = (1 - z * z).squareRoot(), phi = 2.39996323 * Float(k)
            normals.append(SIMD4(r * cos(phi), r * sin(phi), z, 0))
        }
        func buffer<T>(_ values: [T]) throws -> MTLBuffer {
            try XCTUnwrap(values.withUnsafeBytes {
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            })
        }
        let harmonicsBuffer = try buffer(harmonics), normalBuffer = try buffer(normals)
        let sky = try XCTUnwrap(device.makeBuffer(length: 9 * 16, options: .storageModeShared))
        func run(_ name: String) throws -> [SIMD4<Float>] {
            let pipeline = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: name)))
            let output = try XCTUnwrap(device.makeBuffer(length: normals.count * 16, options: .storageModeShared))
            let commands = try XCTUnwrap(queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(commands.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(harmonicsBuffer, offset: 0, index: 0)
            encoder.setBuffer(normalBuffer, offset: 0, index: 1)
            encoder.setBuffer(output, offset: 0, index: 2)
            encoder.setBuffer(sky, offset: 0, index: 3)
            encoder.dispatchThreads(MTLSize(width: normals.count, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 16, height: 1, depth: 1))
            encoder.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            XCTAssertNil(commands.error)
            let values = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: normals.count)
            return (0 ..< normals.count).map { values[$0] }
        }
        // The first writes the stored form, which the second reads through
        // the function the shading uses.
        _ = try run("probeIrradiance")
        let evaluated = try run("probeIrradianceEvaluate")

        // Ramamoorthi and Hanrahan, equation 13, over pi.
        let a0: Float = 3.141593, a1: Float = 2.094395, a2: Float = 0.785398
        for (index, normal) in normals.enumerated() {
            let x = normal.x, y = normal.y, z = normal.z
            var expected = harmonics[0] * (0.282095 * a0)
            expected += harmonics[1] * (0.488603 * y * a1)
            expected += harmonics[2] * (0.488603 * z * a1)
            expected += harmonics[3] * (0.488603 * x * a1)
            expected += harmonics[4] * (1.092548 * x * y * a2)
            expected += harmonics[5] * (1.092548 * y * z * a2)
            expected += harmonics[6] * (0.315392 * (3 * z * z - 1) * a2)
            expected += harmonics[7] * (1.092548 * x * z * a2)
            expected += harmonics[8] * (0.546274 * (x * x - y * y) * a2)
            expected = simd_max(expected / .pi, SIMD4(repeating: 0))
            for channel in 0 ..< 3 {
                XCTAssertEqual(evaluated[index][channel], expected[channel], accuracy: 2e-5,
                               "channel \(channel) facing \(normal)")
            }
        }
    }
}
