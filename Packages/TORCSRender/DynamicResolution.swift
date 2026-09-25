// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// Chooses a render scale from measured GPU time so the frame budget survives
/// thermal throttling.
///
/// The M2 Air has no fan. A scene that costs 10 ms at room temperature can cost
/// noticeably more once the chip has been at load for a few minutes, so a fixed
/// render scale must either waste headroom when cool or miss frames when hot.
/// This trades a little sharpness for a held frame rate instead.
///
/// Two design choices matter:
///
/// - The scale comes from a **discrete ladder**, not a continuous value.
///   Render targets are allocated once at the largest scale and a sub-region is
///   used, but half-resolution passes and motion vectors still want stable,
///   repeatable dimensions. A ladder also stops the controller from dithering
///   between neighbouring sizes every frame.
/// - Stepping down is **fast** and stepping up is **slow and hysteretic**.
///   Dropping a frame is far more visible than running one step softer than
///   necessary, and an eager climb back up oscillates.
public struct DynamicResolutionController: Sendable, Equatable {
    /// Coarse near the top where the cost difference per step is largest.
    public static let ladder: [Float] = [0.40, 0.45, 0.50, 0.55, 0.60, 0.67, 0.75, 0.85, 1.0]

    public private(set) var scale: Float
    private var index: Int
    private let minimumIndex: Int, maximumIndex: Int

    /// Target GPU time per frame in seconds, typically slightly under the
    /// presentation interval to leave room for the rest of the frame.
    public let targetGPUTime: Double
    /// Consecutive over-budget frames required before dropping a step.
    public let framesBeforeDecrease: Int
    /// Consecutive comfortable frames required before climbing a step.
    public let framesBeforeIncrease: Int
    /// Fraction of the target that counts as comfortable. The gap between this
    /// and 1.0 is the hysteresis band where nothing happens.
    public let increaseThreshold: Double

    private var overBudgetRun = 0, underBudgetRun = 0
    /// Exponential moving average of GPU time; a single slow frame from a
    /// hitch or a window resize should not move the scale on its own.
    private var averageGPUTime: Double?
    /// Frames still to ignore after a step. Changing scale reallocates the
    /// render targets, and the frame that does so is slow for that reason
    /// alone; measured, it seeded the next decision and cascaded the scale
    /// down three steps in a second.
    private var cooldown = 0
    /// Frames ignored after a step.
    public static let cooldownFrames = 12

    /// Frames ignored before the controller may act at all.
    public private(set) var warmupRemaining: Int

    public init(targetGPUTime: Double = 1.0 / 60.0 * 0.66,
                minimumScale: Float = 0.4, maximumScale: Float = 1.0,
                initialScale: Float = 0.5,
                framesBeforeDecrease: Int = 30, framesBeforeIncrease: Int = 180,
                increaseThreshold: Double = 0.70, warmupFrames: Int = 0) {
        warmupRemaining = max(0, warmupFrames)
        let ladder = Self.ladder
        func nearest(_ value: Float) -> Int {
            ladder.indices.min { abs(ladder[$0] - value) < abs(ladder[$1] - value) } ?? 0
        }
        minimumIndex = nearest(minimumScale)
        maximumIndex = max(nearest(maximumScale), nearest(minimumScale))
        index = min(max(nearest(initialScale), minimumIndex), maximumIndex)
        scale = ladder[index]
        self.targetGPUTime = max(targetGPUTime, 1e-4)
        self.framesBeforeDecrease = max(1, framesBeforeDecrease)
        self.framesBeforeIncrease = max(1, framesBeforeIncrease)
        self.increaseThreshold = min(max(increaseThreshold, 0.1), 0.99)
    }

    /// Feeds one frame's measured GPU time. Returns true if the scale changed,
    /// which is the signal to recompute dependent viewport sizes.
    @discardableResult
    public mutating func record(gpuTime: Double) -> Bool {
        guard gpuTime.isFinite, gpuTime > 0 else { return false }
        if warmupRemaining > 0 { warmupRemaining -= 1; return false }
        if cooldown > 0 { cooldown -= 1; return false }
        // Weighted toward history; 0.2 settles in roughly 15 frames. Each
        // sample is clamped to twice the running average first: a clock
        // transition on a throttling chip delivers bursts of frames at double
        // the median, and unclamped they walked the average over the target
        // while the median never came near it.
        let sample = averageGPUTime.map { min(gpuTime, $0 * 2) } ?? gpuTime
        averageGPUTime = averageGPUTime.map { $0 * 0.8 + sample * 0.2 } ?? gpuTime
        guard let average = averageGPUTime else { return false }

        if average > targetGPUTime {
            overBudgetRun += 1
            underBudgetRun = 0
        } else if average < targetGPUTime * increaseThreshold {
            underBudgetRun += 1
            overBudgetRun = 0
        } else {
            // Inside the hysteresis band: hold.
            overBudgetRun = 0
            underBudgetRun = 0
        }

        let previous = index
        if overBudgetRun >= framesBeforeDecrease, index > minimumIndex {
            index -= 1
            overBudgetRun = 0
        } else if underBudgetRun >= framesBeforeIncrease, index < maximumIndex {
            index += 1
            underBudgetRun = 0
        }
        guard index != previous else { return false }
        scale = Self.ladder[index]
        // Reset the average so the next decision is made on the new cost, not
        // on times measured at the old resolution, and skip the frames that
        // pay for the change.
        averageGPUTime = nil
        cooldown = Self.cooldownFrames
        return true
    }

    /// Discards accumulated history, for a camera cut or a resize.
    public mutating func reset() {
        overBudgetRun = 0
        underBudgetRun = 0
        averageGPUTime = nil
        cooldown = 0
    }
}
