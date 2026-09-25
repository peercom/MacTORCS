// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Metal

/// The auto-exposure meter (see `Exposure.metal`): meters the HDR frame
/// and keeps the adapted exposure in a buffer every later pass reads.
public final class ExposureMeter {
    /// Mirrors `ExposureState` in the shader.
    public struct State: Sendable, Equatable {
        public var adaptedEV: Float
        public var scale: Float
        public var targetEV: Float
        public var meanLog2: Float
    }

    /// Seconds to adapt when the scene darkens (the exposure opens up): slow.
    public var openingTime: Float = 1.5
    /// Seconds to adapt when the scene brightens (it closes down): fast.
    public var closingTime: Float = 0.4

    private let pipeline: MTLComputePipelineState
    public let state: MTLBuffer

    public init(device: MTLDevice, library: MTLLibrary, archive: PipelineArchive? = nil) throws {
        guard let function = library.makeFunction(name: "exposureMeter") else {
            throw RenderError.unavailable("Missing the exposure meter kernel")
        }
        let descriptor = MTLComputePipelineDescriptor()
        descriptor.computeFunction = function
        descriptor.label = "exposureMeter"
        pipeline = try PipelineArchive.make(descriptor, device: device, archive: archive)
        guard let buffer = device.makeBuffer(length: MemoryLayout<State>.stride, options: .storageModeShared) else {
            throw RenderError.unavailable("Could not allocate the exposure state")
        }
        buffer.label = "Exposure state"
        // Not a number: the first frame snaps to its target.
        var initial = State(adaptedEV: .nan, scale: 1, targetEV: 0, meanLog2: 0)
        buffer.contents().copyMemory(from: &initial, byteCount: MemoryLayout<State>.stride)
        state = buffer
    }

    /// The state as of the last completed frame.
    public var lastState: State { state.contents().load(as: State.self) }

    /// Meters `source` and advances the adapted exposure. With `automatic`
    /// off the state simply carries `manualEV`, so every consumer reads the
    /// same buffer either way. `reset` snaps to the target: a cold
    /// verification render, or a camera cut.
    public func encode(into commands: MTLCommandBuffer, source: MTLTexture, deltaTime: Double,
                       reset: Bool, automatic: Bool, manualEV: Float, compensation: Float,
                       timer: PassTimer? = nil) {
        let pass = MTLComputePassDescriptor()
        timer?.attach(pass, "Exposure meter")
        guard let encoder = commands.makeComputeCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Exposure meter"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setBuffer(state, offset: 0, index: 0)
        var uniforms = Uniforms(
            timing: SIMD4(Float(min(max(deltaTime, 1.0 / 240.0), 0.5)), openingTime, closingTime, compensation),
            control: SIMD4(reset ? 1 : 0, automatic ? 1 : 0, manualEV, 0))
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        let width = min(256, pipeline.maxTotalThreadsPerThreadgroup)
        encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1),
                                     threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
    }

    struct Uniforms {
        var timing: SIMD4<Float>
        var control: SIMD4<Float>
    }
}
