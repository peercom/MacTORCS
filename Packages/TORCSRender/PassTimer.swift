// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Metal

/// Per-pass GPU timing from the GPU's own timestamp counter.
///
/// Every pass attaches a pair of samples to its descriptor — the start of
/// its vertex stage and the end of its fragment stage, or the ends of a
/// compute or blit encoder — into one sample buffer, and after the command
/// buffer completes the pairs resolve to durations. Every pass of a frame
/// is then measured in the *same* frame, on the same clocks, which is what
/// the back-to-back runs of the render tool could never guarantee on a
/// fanless chip: the three null results that preceded this were all
/// comparisons across thermal states.
///
/// Apple GPUs sample at stage boundaries only, and their timestamps are in
/// nanoseconds, as `MTLDevice.sampleTimestamps` confirms. Each stage is
/// bracketed by its own pair: a tile-based GPU runs the vertex stages of
/// several passes before their fragment stages, so "first vertex to last
/// fragment" of one pass spans the others — the first version reported
/// every pass as the time since the frame began — and a depth-only pass
/// has no fragment stage to end at.
public final class PassTimer {
    public struct Sample: Equatable, Sendable {
        public var name: String
        /// Vertex (or encoder) stage duration; NaN when not sampled.
        public var vertexSeconds: Double
        /// Fragment stage duration; NaN for compute, blit and depth-only passes.
        public var fragmentSeconds: Double
        /// The stage that did the work: the fragment stage when it ran, else the vertex one.
        public var seconds: Double { fragmentSeconds.isFinite ? fragmentSeconds : vertexSeconds }
    }

    public let capacity: Int
    private let buffer: MTLCounterSampleBuffer
    private var names: [String] = []
    private var used = 0
    public private(set) var lastFrame: [Sample] = []

    public static func isSupported(_ device: MTLDevice) -> Bool {
        device.supportsCounterSampling(.atStageBoundary)
            && device.counterSets?.contains { $0.name == MTLCommonCounterSet.timestamp.rawValue } == true
    }

    public init(device: MTLDevice, capacity passes: Int = 64) throws {
        guard let set = device.counterSets?.first(where: { $0.name == MTLCommonCounterSet.timestamp.rawValue }),
              device.supportsCounterSampling(.atStageBoundary) else {
            throw RenderError.unavailable("This GPU does not sample timestamps at stage boundaries")
        }
        let descriptor = MTLCounterSampleBufferDescriptor()
        descriptor.counterSet = set
        descriptor.sampleCount = passes * 4
        descriptor.storageMode = .shared
        descriptor.label = "Pass timer"
        buffer = try device.makeCounterSampleBuffer(descriptor: descriptor)
        capacity = passes
    }

    /// Forgets the previous frame's attachments; call before encoding.
    public func beginFrame() {
        names = []
        used = 0
    }

    private func reserve(_ name: String) -> Int? {
        guard used < capacity else { return nil }
        names.append(name)
        used += 1
        return (used - 1) * 4
    }

    /// Times a render pass from its first vertex to its last fragment.
    public func attach(_ pass: MTLRenderPassDescriptor, _ name: String) {
        guard let start = reserve(name) else { return }
        let attachment = pass.sampleBufferAttachments[0]!
        attachment.sampleBuffer = buffer
        attachment.startOfVertexSampleIndex = start
        attachment.endOfVertexSampleIndex = start + 1
        attachment.startOfFragmentSampleIndex = start + 2
        attachment.endOfFragmentSampleIndex = start + 3
    }

    public func attach(_ pass: MTLComputePassDescriptor, _ name: String) {
        guard let start = reserve(name) else { return }
        let attachment = pass.sampleBufferAttachments[0]!
        attachment.sampleBuffer = buffer
        attachment.startOfEncoderSampleIndex = start
        attachment.endOfEncoderSampleIndex = start + 1
    }

    public func attach(_ pass: MTLBlitPassDescriptor, _ name: String) {
        guard let start = reserve(name) else { return }
        let attachment = pass.sampleBufferAttachments[0]!
        attachment.sampleBuffer = buffer
        attachment.startOfEncoderSampleIndex = start
        attachment.endOfEncoderSampleIndex = start + 1
    }

    /// Reads the pairs back; call after the command buffer has completed.
    @discardableResult
    public func resolve() -> [Sample] {
        guard used > 0, let data = try? buffer.resolveCounterRange(0 ..< used * 4) else { lastFrame = []; return [] }
        var samples: [Sample] = []
        data.withUnsafeBytes { raw in
            let stamps = raw.bindMemory(to: MTLCounterResultTimestamp.self)
            func duration(_ a: UInt64, _ b: UInt64) -> Double {
                // A stage the GPU did not run reports the sentinel.
                guard a != MTLCounterErrorValue, b != MTLCounterErrorValue, b >= a, a != 0 else { return .nan }
                return Double(b - a) * 1e-9
            }
            for i in 0 ..< used {
                let base = i * 4
                samples.append(Sample(name: names[i],
                                      vertexSeconds: duration(stamps[base].timestamp, stamps[base + 1].timestamp),
                                      fragmentSeconds: duration(stamps[base + 2].timestamp, stamps[base + 3].timestamp)))
            }
        }
        lastFrame = samples
        return samples
    }
}
