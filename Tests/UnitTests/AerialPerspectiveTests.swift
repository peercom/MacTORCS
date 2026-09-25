// SPDX-License-Identifier: GPL-2.0-only
import Metal
import XCTest
@testable import TORCSRender

/// The aerial perspective marches fewer steps over the near field than the
/// sky LUT does over the whole atmosphere. This pins the shortcut against the
/// eight-step reference it replaced: same library, same tables, same ray.
final class AerialPerspectiveTests: XCTestCase {
    func testAdaptiveStepsMatchEightStepReference() throws {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { throw XCTSkip("Metal device unavailable") }
        let probe = """
        kernel void probeAerialPerspective(const device float *distancesMetres [[buffer(0)]],
                                           device float4 *adaptive [[buffer(1)]],
                                           device float4 *reference [[buffer(2)]],
                                           device float4 *throughputs [[buffer(3)]],
                                           texture2d<float> transmittanceLUT [[texture(0)]],
                                           texture2d<float> multiScatterLUT [[texture(1)]],
                                           uint i [[thread_position_in_grid]]) {
            // A driver's view: the camera a metre up, the ray a shade below level.
            float3 camera = float3(120.0f, 1.2f, -40.0f);
            float3 direction = normalize(float3(0.8f, -0.01f, 0.6f));
            float3 sun = normalize(float3(0.35f, 0.45f, 0.82f));
            float3 illuminance = float3(4.0f, 3.84f, 3.6f);
            float3 world = camera + direction * distancesMetres[i];
            float3 tA, tR;
            float3 a = aerialPerspective(world, camera, sun, illuminance,
                                         transmittanceLUT, multiScatterLUT, tA);
            float3 r = integrateScattering(defaultMedium(), atmospherePosition(camera), direction,
                                           sun, illuminance, distancesMetres[i] / kMetresPerKilometre,
                                           8u, transmittanceLUT, multiScatterLUT, tR);
            adaptive[i] = float4(a, 0.0f);
            reference[i] = float4(r, 0.0f);
            throughputs[i] = float4(tA - tR, 0.0f);
        }
        """
        let library = try ShaderLibrary(device: device,
                                        source: try ShaderLibrary.combinedSource() + probe).library
        let atmosphere = try AtmosphereResources(device: device, library: library)
        let pipeline = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "probeAerialPerspective")))

        // Every band of the step schedule, each edge from both sides.
        let distances: [Float] = [2, 25, 100, 250, 299, 301, 500, 800, 999, 1001, 2000, 5000]
        let input = try XCTUnwrap(distances.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        })
        let outputs = try (0 ..< 3).map { _ in
            try XCTUnwrap(device.makeBuffer(length: distances.count * 16, options: .storageModeShared))
        }

        let commands = try XCTUnwrap(queue.makeCommandBuffer())
        atmosphere.update(into: commands, lighting: SunLighting(), cameraAltitude: 1.2)
        let encoder = try XCTUnwrap(commands.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(input, offset: 0, index: 0)
        for (index, buffer) in outputs.enumerated() { encoder.setBuffer(buffer, offset: 0, index: index + 1) }
        encoder.setTexture(atmosphere.transmittance, index: 0)
        encoder.setTexture(atmosphere.multiScatter, index: 1)
        encoder.dispatchThreads(MTLSize(width: distances.count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 1, depth: 1))
        encoder.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertNil(commands.error)

        let adaptive = outputs[0].contents().bindMemory(to: SIMD4<Float>.self, capacity: distances.count)
        let reference = outputs[1].contents().bindMemory(to: SIMD4<Float>.self, capacity: distances.count)
        let throughput = outputs[2].contents().bindMemory(to: SIMD4<Float>.self, capacity: distances.count)
        var previous: Float = 0
        for (i, distance) in distances.enumerated() {
            let a = adaptive[i], r = reference[i]
            let magnitude = max(r.x, r.y, r.z)
            XCTAssertGreaterThan(magnitude, 0, "no in-scatter at \(distance) m")
            XCTAssertGreaterThanOrEqual(magnitude, previous, "in-scatter must grow with distance")
            previous = magnitude
            // Relative to the brightest channel: the shortcut is invisible when
            // it is under a thousandth, well below one 8-bit step of any
            // pixel it touches (the renders differ by at most one LSB). The
            // absolute floor covers the first metres, where the in-scatter is
            // itself far below a display step.
            for c in 0 ..< 3 {
                XCTAssertEqual(a[c], r[c], accuracy: max(magnitude * 1e-3, 1e-6),
                               "in-scatter channel \(c) at \(distance) m")
                XCTAssertEqual(throughput[i][c], 0, accuracy: 1e-4,
                               "transmittance channel \(c) at \(distance) m")
            }
        }
        // The far end is where eight steps still run: the two must agree to
        // rounding (the compiler folds the constant step count differently).
        let last = distances.count - 1
        for c in 0 ..< 3 {
            XCTAssertEqual(adaptive[last][c], reference[last][c], accuracy: reference[last][c] * 1e-5)
        }
    }
}
